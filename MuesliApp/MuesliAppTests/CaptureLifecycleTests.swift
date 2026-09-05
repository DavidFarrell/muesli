import XCTest

final class CaptureLifecycleTests: XCTestCase {
    func testSameDeviceInvalidationIsGenerationBoundAndCoalesced() {
        var health = CaptureSourceHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.begin(generation: 10, now: now)
        XCTAssertTrue(health.progress(frames: 1, generation: 10, at: now))
        XCTAssertFalse(health.invalidate(generation: 9, now: now))
        XCTAssertTrue(health.invalidate(generation: 10, now: now))
        for _ in 0..<100 { XCTAssertFalse(health.invalidate(generation: 10, now: now)) }
        XCTAssertTrue(health.shouldRecover(now: now, requireContinuousCallbacks: true))
        XCTAssertFalse(health.shouldRecover(now: now, requireContinuousCallbacks: true))
        health.begin(generation: 11, now: now)
        XCTAssertFalse(health.invalidate(generation: 10, now: now))
        XCTAssertTrue(health.progress(frames: 1, generation: 11, at: now))
        XCTAssertEqual(health.phase, .healthy)
    }

    func testThrownStartsRemainSupervisedUntilFiniteTerminalFailure() async {
        let owner = CaptureOperationOwner()
        var health = CaptureSourceHealth()
        var now = Date(timeIntervalSince1970: 100)
        for attempt in 1...3 {
            health.begin(generation: attempt, now: now)
            do {
                try await owner.perform { throw TestCaptureFailure.injected }
                XCTFail("Expected injected native failure")
            } catch { health.fail(error.localizedDescription, now: now) }
            XCTAssertFalse(owner.isBusy)
            now.addTimeInterval(5)
            XCTAssertEqual(health.shouldRecover(now: now, requireContinuousCallbacks: true), attempt < 3)
        }
        XCTAssertEqual(health.phase, .failed)
        XCTAssertEqual(health.attempts, 3)
        XCTAssertNotNil(health.message)
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(600), requireContinuousCallbacks: true))
    }

    func testPermissionFailureDoesNotRetryUntilFreshUserIntent() {
        var health = CaptureSourceHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.begin(generation: 1, now: now)
        health.fail("Microphone permission denied", retryable: false, now: now)
        XCTAssertEqual(health.phase, .failed)
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(600), requireContinuousCallbacks: true))
        health.reset()
        health.begin(generation: 2, now: now)
        XCTAssertTrue(health.progress(frames: 1, generation: 2, at: now))
        XCTAssertEqual(health.phase, .healthy)
    }

    func testPreviewAndMeetingUseIdenticalNoFirstSampleRecovery() {
        let now = Date(timeIntervalSince1970: 100)
        for _ in ["preview", "meeting"] {
            var health = CaptureSourceHealth()
            health.begin(generation: 1, now: now)
            XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(3), requireContinuousCallbacks: true))
            XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(5), requireContinuousCallbacks: true))
            XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(6), requireContinuousCallbacks: true))
            XCTAssertEqual(health.phase, .recovering)
        }
    }

    func testSilentSystemDoesNotEnterAbsenceRestartLoop() {
        let now = Date(timeIntervalSince1970: 100)
        var health = CaptureSourceHealth()
        health.begin(generation: 1, now: now)
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(3600), requireContinuousCallbacks: false))
        XCTAssertEqual(health.phase, .starting, "No samples is unverified, not a fabricated failure")
        XCTAssertTrue(health.progress(frames: 160, generation: 1, at: now))
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(7200), requireContinuousCallbacks: false))
        XCTAssertEqual(health.phase, .healthy)
        health.fail("Injected SCStream stop", now: now)
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(5), requireContinuousCallbacks: false))
    }

    func testSameGenerationFlowCanResumeAfterStall() {
        let now = Date(timeIntervalSince1970: 100)
        var health = CaptureSourceHealth()
        health.begin(generation: 1, now: now)
        _ = health.progress(frames: 1, generation: 1, at: now)
        _ = health.shouldRecover(now: now.addingTimeInterval(5), requireContinuousCallbacks: true)
        XCTAssertTrue(health.progress(frames: 2, generation: 1, at: now.addingTimeInterval(5)))
        XCTAssertEqual(health.phase, .healthy)
        XCTAssertNil(health.message)
    }

    func testTimedOutStartRemainsOwnedThroughLateCleanup() async {
        let owner = CaptureOperationOwner()
        let nativeReturn = TaskCompletion()
        let cleanupStarted = TaskCompletion()
        let cleanupReturn = TaskCompletion()
        let start = ContinuousClock.now
        do {
            try await owner.perform(timeoutSeconds: 0.02, operation: {
                _ = await nativeReturn.wait(timeoutSeconds: 10)
            }, cleanupIfAbandoned: {
                cleanupStarted.markCompleted()
                _ = await cleanupReturn.wait(timeoutSeconds: 10)
            })
            XCTFail("Expected deadline")
        } catch {
            guard case CaptureOperationOwner.Failure.timedOut = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertTrue(owner.isBusy)
        do { try await owner.perform { XCTFail("A competing owner must never start") }; XCTFail("Expected busy") }
        catch { guard case CaptureOperationOwner.Failure.busy = error else { return XCTFail("Unexpected \(error)") } }
        nativeReturn.markCompleted()
        let cleanup = await cleanupStarted.wait(timeoutSeconds: 1)
        XCTAssertEqual(cleanup, .completed)
        XCTAssertTrue(owner.isBusy, "Native start returning is insufficient until late-start stop completes")
        cleanupReturn.markCompleted()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(owner.isBusy)
        do { try await owner.perform {} } catch { XCTFail("Confirmed retirement permits a new owner: \(error)") }
    }

    func testTimedOutMicrophoneDoesNotBlockIndependentSystemOwner() async {
        let microphone = CaptureOperationOwner()
        let system = CaptureOperationOwner()
        let returnFromMic = TaskCompletion()
        do { try await microphone.perform(timeoutSeconds: 0.01) { _ = await returnFromMic.wait(timeoutSeconds: 10) } }
        catch { }
        XCTAssertTrue(microphone.isBusy)
        do { try await system.perform {} } catch { XCTFail("System source must remain independent") }
        returnFromMic.markCompleted()
    }

    func testRepeatedConversionFailuresCannotPostponeOrRearmRetry() {
        let now = Date(timeIntervalSince1970: 100)
        var health = CaptureSourceHealth()
        health.begin(generation: 1, now: now)
        health.fail("bad packet", now: now)
        health.fail("another bad packet", now: now.addingTimeInterval(0.9))
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(1), requireContinuousCallbacks: true))
        health.fail("still bad", now: now.addingTimeInterval(2))
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(10), requireContinuousCallbacks: true))
    }

    @MainActor
    func testNativeInvalidationStormSchedulesOnlyOneGenerationChange() async {
        var deliveries = 0
        let delivered = TaskCompletion()
        let mailbox = CaptureInvalidationMailbox { deliveries += 1; delivered.markCompleted() }
        let callback = mailbox.callback()
        let produced = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<10_000 { callback() }
            produced.signal()
        }
        XCTAssertEqual(produced.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(deliveries, 0)
        let outcome = await delivered.wait(timeoutSeconds: 2)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(deliveries, 1)
        callback()
        await Task.yield()
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testLifecycleDeadlineReportsSourceFailureBeforeUICanResume() async {
        let owner = CaptureOperationOwner()
        let nativeReturn = TaskCompletion()
        let recorded = DispatchSemaphore(value: 0)
        let operation = Task.detached {
            try? await owner.perform(timeoutSeconds: 0.02, onFailure: { _ in recorded.signal() }) {
                _ = await nativeReturn.wait(timeoutSeconds: 10)
            }
        }
        XCTAssertEqual(recorded.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(owner.isBusy)
        nativeReturn.markCompleted()
        await operation.value
    }

    func testUnchangedDevicePolicyChangeKeepsActiveGenerationSupervised() {
        let now = Date(timeIntervalSince1970: 100)
        var health = CaptureSourceHealth()
        health.begin(generation: 42, now: now)
        XCTAssertTrue(health.progress(frames: 1, generation: 42, at: now))
        for _ in ["Follow to Pin", "Pin to Follow", "unchanged output intent"] {
            health.resetRecoveryBudget(now: now)
            XCTAssertEqual(health.generation, 42)
            XCTAssertEqual(health.phase, .healthy)
        }
        XCTAssertTrue(health.progress(frames: 2, generation: 42, at: now.addingTimeInterval(1)))
        XCTAssertTrue(health.invalidate(generation: 42, now: now.addingTimeInterval(2)))
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(2), requireContinuousCallbacks: true))
    }

    @MainActor
    func testStopRetiresDesiredRequestWhileRecoveryStillOwnsNativeStop() async {
        var intent = CaptureRequestIntent()
        let original = intent.begin()
        let owner = CaptureOperationOwner()
        let stopStarted = TaskCompletion()
        let stopReturned = TaskCompletion()
        var restarted = false
        let recovery = Task { @MainActor in
            try? await owner.perform {
                stopStarted.markCompleted()
                _ = await stopReturned.wait(timeoutSeconds: 10)
            }
            if intent.matches(original) { restarted = true }
        }
        let started = await stopStarted.wait(timeoutSeconds: 1)
        XCTAssertEqual(started, .completed)
        intent.retire()
        XCTAssertTrue(owner.isBusy)
        XCTAssertFalse(intent.matches(original))
        stopReturned.markCompleted()
        await recovery.value
        XCTAssertFalse(restarted, "An old recovery continuation cannot restore stopped intent")
        let next = intent.begin()
        XCTAssertTrue(intent.matches(next))
        XCTAssertFalse(intent.matches(original), "Starting preview cannot revive an old meeting recovery")
    }

    func testMeetingStartRetiresPreviewDespiteDelayedStartNotification() {
        XCTAssertTrue(CapturePreviewPolicy.wantsPreview(isCapturing: false, isStarting: false,
                                                       isFinalizing: false, isStartScreenActive: true, onboarding: false))
        XCTAssertFalse(CapturePreviewPolicy.wantsPreview(isCapturing: false, isStarting: true,
                                                        isFinalizing: false, isStartScreenActive: true, onboarding: false))
        XCTAssertFalse(CapturePreviewPolicy.wantsPreview(isCapturing: false, isStarting: false,
                                                        isFinalizing: true, isStartScreenActive: true, onboarding: false))
    }

    func testBusyOperationReportsRequestedSourceFailureWithoutTakingOwnership() async {
        let owner = CaptureOperationOwner()
        let entered = TaskCompletion()
        let release = TaskCompletion()
        let existing = Task {
            try? await owner.perform {
                entered.markCompleted()
                _ = await release.wait(timeoutSeconds: 10)
            }
        }
        let started = await entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(started, .completed)
        let reported = TaskCompletion()
        do {
            try await owner.perform(onFailure: { _ in reported.markCompleted() }) { XCTFail("Competing native start") }
            XCTFail("Expected busy")
        } catch { }
        let failure = await reported.wait(timeoutSeconds: 0.1)
        XCTAssertEqual(failure, .completed)
        XCTAssertTrue(owner.isBusy)
        release.markCompleted()
        await existing.value
    }

    func testBusyOwnerDoesNotConsumePendingRecovery() {
        let now = Date(timeIntervalSince1970: 100)
        var health = CaptureSourceHealth()
        health.begin(generation: 1, now: now)
        health.fail("Native source failed", now: now)
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(5), requireContinuousCallbacks: true,
                                           canStartRecovery: false))
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(6), requireContinuousCallbacks: true))
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(7), requireContinuousCallbacks: true))
    }

    func testRefreshDoesNotTreatUnverifiedOrFailedSourceAsSuccess() {
        XCTAssertFalse(AudioRefreshResult(microphone: .healthy, system: .unverified).verified)
        XCTAssertFalse(AudioRefreshResult(microphone: .failed, system: .healthy).verified)
        XCTAssertTrue(AudioRefreshResult(microphone: .notRequested, system: .healthy).verified)
        XCTAssertTrue(AudioRefreshResult(microphone: .healthy, system: .healthy).verified)
    }
}

nonisolated private enum TestCaptureFailure: Error { case injected }
