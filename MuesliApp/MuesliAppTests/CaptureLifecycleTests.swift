import XCTest

final class CaptureLifecycleTests: XCTestCase {
    func testDelayedMicrophoneObservationCannotResetRetriesOrVerifyRefresh() {
        var health = CaptureSourceHealth()
        let received = Date(timeIntervalSince1970: 100), delivered = Date(timeIntervalSince1970: 115)
        health.begin(generation: 7, now: received)
        XCTAssertFalse(health.observeMicrophoneProgress(frames: 1, generation: 7, receivedAt: received, now: delivered))
        XCTAssertEqual(health.phase, .recovering)
        XCTAssertEqual(health.attempts, 1, "An old packet is not successful recovery")
        XCTAssertFalse(health.observeMicrophoneProgress(frames: 1, generation: 7, receivedAt: received, now: delivered))
        XCTAssertFalse(health.observeMicrophoneProgress(frames: 1, generation: 7, receivedAt: nil, now: delivered))
        XCTAssertEqual(health.attempts, 1)
        health.observeExpectedProgress(now: delivered)
        XCTAssertNotEqual(health.phase, .healthy, "Refresh must not verify the delayed final packet")
        XCTAssertTrue(health.shouldRecover(now: delivered.addingTimeInterval(1), requireContinuousCallbacks: true))
        XCTAssertFalse(health.shouldRecover(now: delivered.addingTimeInterval(2), requireContinuousCallbacks: true), "Stale repeated observations must not rearm reserved recovery")
        XCTAssertTrue(health.observeMicrophoneProgress(frames: 2, generation: 7, receivedAt: delivered, now: delivered))
        XCTAssertEqual(health.phase, .healthy, "Fresh digital silence can recover the same generation")
        XCTAssertEqual(health.lastProgressAt, delivered)
    }

    func testMicrophoneReceiptRetainsGenerationAndInvalidationFences() {
        var health = CaptureSourceHealth()
        let received = Date(timeIntervalSince1970: 100)
        health.begin(generation: 7, now: received)
        XCTAssertFalse(health.observeMicrophoneProgress(frames: 9, generation: 6, receivedAt: received, now: received))
        XCTAssertEqual(health.frameCount, 0)
        XCTAssertTrue(health.observeMicrophoneProgress(frames: 2, generation: 7, receivedAt: received, now: received.addingTimeInterval(1)))
        XCTAssertEqual(health.lastProgressAt, received, "UI observation time is not source receipt time")
        XCTAssertFalse(health.observeMicrophoneProgress(frames: 1, generation: 7, receivedAt: received.addingTimeInterval(2), now: received.addingTimeInterval(2)))
        XCTAssertEqual(health.lastProgressAt, received)
        XCTAssertTrue(health.invalidate(generation: 7, now: received))
        XCTAssertFalse(health.observeMicrophoneProgress(frames: 3, generation: 7, receivedAt: received, now: received))
        XCTAssertEqual(health.phase, .recovering)
    }

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
                let request = CaptureOperationOwner.Request(operation: { throw TestCaptureFailure.injected })
                try await owner.perform(request)
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
            let request = CaptureOperationOwner.Request(operation: {
                _ = await nativeReturn.wait(timeoutSeconds: 10)
            }, cleanupIfAbandoned: {
                cleanupStarted.markCompleted()
                _ = await cleanupReturn.wait(timeoutSeconds: 10)
            })
            try await owner.perform(request, timeoutSeconds: 0.02)
            XCTFail("Expected deadline")
        } catch {
            guard case CaptureOperationOwner.Failure.timedOut = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertTrue(owner.isBusy)
        do {
            let request = CaptureOperationOwner.Request(operation: { XCTFail("A competing owner must never start") })
            try await owner.perform(request); XCTFail("Expected busy")
        }
        catch { guard case CaptureOperationOwner.Failure.busy = error else { return XCTFail("Unexpected \(error)") } }
        nativeReturn.markCompleted()
        let cleanup = await cleanupStarted.wait(timeoutSeconds: 1)
        XCTAssertEqual(cleanup, .completed)
        XCTAssertTrue(owner.isBusy, "Native start returning is insufficient until late-start stop completes")
        cleanupReturn.markCompleted()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(owner.isBusy)
        do {
            let request = CaptureOperationOwner.Request(operation: {})
            try await owner.perform(request)
        } catch { XCTFail("Confirmed retirement permits a new owner: \(error)") }
    }

    func testTimedOutMicrophoneDoesNotBlockIndependentSystemOwner() async {
        let microphone = CaptureOperationOwner()
        let system = CaptureOperationOwner()
        let returnFromMic = TaskCompletion()
        do {
            let request = CaptureOperationOwner.Request(operation: { _ = await returnFromMic.wait(timeoutSeconds: 10) })
            try await microphone.perform(request, timeoutSeconds: 0.01)
        }
        catch { }
        XCTAssertTrue(microphone.isBusy)
        do {
            let request = CaptureOperationOwner.Request(operation: {})
            try await system.perform(request)
        } catch { XCTFail("System source must remain independent") }
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
            let request = CaptureOperationOwner.Request(onFailure: { _ in recorded.signal() }, operation: {
                _ = await nativeReturn.wait(timeoutSeconds: 10)
            })
            try? await owner.perform(request, timeoutSeconds: 0.02)
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
            let request = CaptureOperationOwner.Request(operation: {
                stopStarted.markCompleted()
                _ = await stopReturned.wait(timeoutSeconds: 10)
            })
            try? await owner.perform(request)
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
            let request = CaptureOperationOwner.Request(operation: {
                entered.markCompleted()
                _ = await release.wait(timeoutSeconds: 10)
            })
            try? await owner.perform(request)
        }
        let started = await entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(started, .completed)
        let reported = TaskCompletion()
        do {
            let request = CaptureOperationOwner.Request(onFailure: { _ in reported.markCompleted() }, operation: { XCTFail("Competing native start") })
            try await owner.perform(request)
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
    @MainActor
    func testInitialMicStartStoppedBeforeAdoptionRetainsOwnerThroughCleanup() async {
        let owner = CaptureOperationOwner()
        let entered = TaskCompletion(), nativeReturn = TaskCompletion()
        let cleanupEntered = TaskCompletion(), cleanupReturn = TaskCompletion()
        var source = UUID(), adopted: UUID?
        let original = source
        let start = Task {
            let request = CaptureOperationOwner.Request(operation: {
                entered.markCompleted()
                _ = await nativeReturn.wait(timeoutSeconds: 10)
            }, adoption: { claim in
                guard source == original, claim.claim() else { return }
                adopted = original
            }, cleanupIfAbandoned: {
                cleanupEntered.markCompleted()
                _ = await cleanupReturn.wait(timeoutSeconds: 10)
            })
            try? await owner.perform(request)
        }
        let didEnter = await entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(didEnter, .completed)
        // Stop and finalization have both finished; the mutable UI flags could
        // be open again and a distinct recording can now be desired.
        source = UUID()
        nativeReturn.markCompleted()
        let cleanup = await cleanupEntered.wait(timeoutSeconds: 1)
        XCTAssertEqual(cleanup, .completed)
        XCTAssertNil(adopted)
        XCTAssertTrue(owner.isBusy)
        do {
            let request = CaptureOperationOwner.Request(operation: { XCTFail("A new source competed with old microphone cleanup") })
            try await owner.perform(request); XCTFail("Expected busy")
        }
        catch { }
        cleanupReturn.markCompleted(); await start.value
        XCTAssertFalse(owner.isBusy)
        let replacement = source
        do {
            let request = CaptureOperationOwner.Request(operation: {}, adoption: { claim in
                guard source == replacement, claim.claim() else { return }
                adopted = replacement
            })
            try await owner.perform(request)
        } catch { XCTFail("Fresh source could not start after actual cleanup: \(error)") }
        XCTAssertEqual(adopted, replacement)
    }

    @MainActor
    func testMicAdoptionClaimTransfersOwnerBeforeImmediateStop() async {
        let owner = CaptureOperationOwner()
        var claimed = false
        do {
            let startRequest = CaptureOperationOwner.Request(operation: {}, adoption: { claim in
                XCTAssertTrue(owner.isBusy)
                claimed = claim.claim()
                XCTAssertTrue(claimed)
                XCTAssertFalse(owner.isBusy, "Stop must be able to reserve the lane immediately after engine assignment")
                XCTAssertFalse(claim.claim())
            }, cleanupIfAbandoned: { XCTFail("An adopted microphone was cleaned up by its old start") })
            try await owner.perform(startRequest)
            let stopRequest = CaptureOperationOwner.Request(operation: { })
            try await owner.perform(stopRequest)
        } catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(claimed)
    }

    @MainActor
    func testMicAdoptionExpiryCleansNativeOwnerWhileUIIsBlocked() async {
        let owner = CaptureOperationOwner()
        let nativeEntered = DispatchSemaphore(value: 0), cleanupEntered = DispatchSemaphore(value: 0)
        let cleanupReturn = TaskCompletion()
        var adopted = false
        let start = Task.detached {
            let request = CaptureOperationOwner.Request(operation: {
                nativeEntered.signal()
            }, adoption: { claim in
                if claim.claim() { adopted = true }
            }, cleanupIfAbandoned: {
                cleanupEntered.signal()
                _ = await cleanupReturn.wait(timeoutSeconds: 10)
            })
            try? await owner.perform(request, timeoutSeconds: 0.03)
        }
        XCTAssertEqual(nativeEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cleanupEntered.wait(timeout: .now() + 2), .success,
                       "Native cleanup cannot require the queued MainActor adoption to execute")
        XCTAssertFalse(adopted)
        XCTAssertTrue(owner.isBusy)
        cleanupReturn.markCompleted(); await start.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(owner.isBusy)
        await Task.yield()
        XCTAssertFalse(adopted, "A late UI offer cannot reclaim a retired start")
    }

    @MainActor
    func testQuitThenCancelCannotReviveOfferedMicrophoneStart() async {
        let owner = CaptureOperationOwner()
        let entered = TaskCompletion(), nativeReturn = TaskCompletion(), cleanup = TaskCompletion()
        var quitIntent = UUID(), adopted = false
        let originalQuitIntent = quitIntent
        let start = Task {
            let request = CaptureOperationOwner.Request(operation: {
                entered.markCompleted(); _ = await nativeReturn.wait(timeoutSeconds: 10)
            }, adoption: { claim in
                guard quitIntent == originalQuitIntent, claim.claim() else { return }
                adopted = true
            }, cleanupIfAbandoned: { cleanup.markCompleted() })
            try? await owner.perform(request)
        }
        _ = await entered.wait(timeoutSeconds: 1)
        quitIntent = UUID() // Accepted Quit retires this even if Cancel follows immediately.
        nativeReturn.markCompleted(); await start.value
        let closed = await cleanup.wait(timeoutSeconds: 1)
        XCTAssertEqual(closed, .completed)
        XCTAssertFalse(adopted)
        XCTAssertFalse(owner.isBusy)
    }

    @MainActor
    func testRejectedMicAdoptionKeepsQuitPendingUntilActualCleanup() async {
        let registry = ShutdownWorkRegistry(), cleanupEntered = TaskCompletion(), cleanupReturn = TaskCompletion()
        let owner = CaptureOperationOwner(shutdown: registry)
        let start = Task {
            let request = CaptureOperationOwner.Request(operation: {}, adoption: { _ in }, cleanupIfAbandoned: {
                    cleanupEntered.markCompleted()
                    _ = await cleanupReturn.wait(timeoutSeconds: 10)
                })
            try? await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true)
        }
        _ = await cleanupEntered.wait(timeoutSeconds: 1)
        registry.beginQuit()
        await start.value
        XCTAssertTrue(owner.isBusy)
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        XCTAssertFalse(registry.sealIfFinished())
        cleanupReturn.markCompleted()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.isBusy || !registry.snapshot().pending.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(owner.isBusy)
        XCTAssertTrue(registry.sealIfFinished())
    }

    @MainActor
    func testExpiredMicUIOfferReleasesActualSourceLeaseWhileUIRemainsBlocked() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/muesli-mic-offer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry)
        let cleanup = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let start = Task.detached {
            do {
                let request = CaptureOperationOwner.Request(operation: {}, adoption: try makeOwnedMicOffer(folder: folder, released: released, registry: registry), cleanupIfAbandoned: { cleanup.signal() })
                try await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true)
            } catch { }
            returned.signal()
        }
        XCTAssertEqual(cleanup.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success,
                       "The queued UI notification must not retain the source lease after original cleanup")
        // This is a real independent kernel lock acquisition, still before the
        // queued MainActor offer can execute. No original source owner remains.
        let exclusive = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        try exclusive.validate()
        await start.value
    }

    @MainActor
    func testExecutingMicOfferRetainsSourceAndQuitOwnershipThroughActualCallbackReturn() async throws {
        // Both a rejected offer and an already-claimed offer may still be
        // executing when the caller's deadline expires. Claim transfers the
        // native lane; neither outcome permits premature callback disposal.
        for accepts in [false, true] {
            let folder = URL(fileURLWithPath: "/private/tmp/muesli-running-mic-offer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry)
            let entered = TaskCompletion(), returned = TaskCompletion(), empty = TaskCompletion()
            let callbackReturn = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
            // Install the empty observer after actual admission, from the
            // callback, so the initial empty snapshot is not mistaken for close.
            registry.observe { _ = registry.snapshot() }
            let monitor = Task.detached {
                _ = await entered.wait(timeoutSeconds: 2)
                registry.observe {
                    if registry.snapshot().pending.isEmpty { empty.markCompleted() }
                }
                _ = await returned.wait(timeoutSeconds: 2)
                registry.beginQuit()
                let closedWhileExecuting = await empty.wait(timeoutSeconds: 0.2)
                XCTAssertEqual(closedWhileExecuting, .timedOut,
                    "The callback is still executing with its actual source lease")
                XCTAssertFalse(registry.sealIfFinished())
                XCTAssertEqual(owner.isBusy, !accepts)
                let next = CaptureOperationOwner.Request(operation: {
                    XCTAssertTrue(accepts, "An unclaimed source must keep its lane")
                })
                do {
                    try await owner.perform(next, preservesRecording: true)
                    XCTAssertTrue(accepts, "Only a successful Claim permits the next native operation")
                } catch {
                    XCTAssertFalse(accepts)
                    guard case CaptureOperationOwner.Failure.busy = error else {
                        callbackReturn.signal(); return XCTFail("Unexpected \(error)")
                    }
                }
                XCTAssertFalse(registry.snapshot().pending.isEmpty)
                callbackReturn.signal()
            }
            let start = Task.detached {
                do {
                    let request = CaptureOperationOwner.Request(operation: {},
                        adoption: try makeExecutingMicOffer(folder: folder, released: released, registry: registry,
                            entered: entered, callbackReturn: callbackReturn, accepts: accepts))
                    try await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true)
                } catch { }
                returned.markCompleted()
            }
            await start.value
            await monitor.value
            XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
            let exclusive = try MeetingFileAccess.acquire(in: folder, mode: .archive)
            try exclusive.validate()
            let finished = await empty.wait(timeoutSeconds: 2)
            XCTAssertEqual(finished, .completed)
        }
    }

    func testAcceptedNativeFailureAndCleanupCapturesCloseBeforeWorkToken() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/muesli-all-mic-captures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry)
        let nativeReturn = TaskCompletion(), failureEntered = TaskCompletion(), cleanupEntered = TaskCompletion()
        let failureReturn = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let request = try makeAllOwnedMicCallbacks(folder: folder, registry: registry, released: released,
            nativeReturn: nativeReturn, failureEntered: failureEntered, failureReturn: failureReturn,
            cleanupEntered: cleanupEntered)
        let start = Task.detached {
            do { try await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true) }
            catch { }
        }
        let failing = await failureEntered.wait(timeoutSeconds: 2)
        XCTAssertEqual(failing, .completed)
        nativeReturn.markCompleted()
        let cleanup = await cleanupEntered.wait(timeoutSeconds: 2)
        XCTAssertEqual(cleanup, .completed)
        registry.beginQuit()
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        XCTAssertFalse(registry.sealIfFinished())
        failureReturn.signal()
        await start.value
        for _ in 0..<3 { XCTAssertEqual(released.wait(timeout: .now() + 2), .success) }
        let exclusive = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        try exclusive.validate()
        // Retaining the emptied Request, or its completed caller Task, does not
        // retain the original callback captures or native source descriptors.
        withExtendedLifetime(request) { XCTAssertFalse(owner.isBusy) }
    }

    func testBusyAndThrownRequestsDisposeEveryUninvokedCaptureBeforeTokenClose() async throws {
        for busy in [false, true] {
            let folder = URL(fileURLWithPath: "/private/tmp/muesli-refused-mic-captures-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry)
            let entered = TaskCompletion(), nativeReturn = TaskCompletion()
            let blocker = Task {
                if busy {
                    let request = CaptureOperationOwner.Request(operation: {
                        entered.markCompleted(); _ = await nativeReturn.wait(timeoutSeconds: 5)
                    })
                    try? await owner.perform(request)
                } else { entered.markCompleted() }
            }
            _ = await entered.wait(timeoutSeconds: 2)
            let released = DispatchSemaphore(value: 0)
            let request = try makeRejectedOwnedMicCallbacks(folder: folder, registry: registry, released: released)
            do { try await owner.perform(request, preservesRecording: true); XCTFail("Expected rejection") }
            catch { }
            for _ in 0..<4 { XCTAssertEqual(released.wait(timeout: .now() + 2), .success) }
            XCTAssertTrue(registry.snapshot().pending.isEmpty)
            let exclusive = try MeetingFileAccess.acquire(in: folder, mode: .archive)
            try exclusive.validate()
            nativeReturn.markCompleted(); await blocker.value
            withExtendedLifetime(request) { XCTAssertFalse(owner.isBusy) }
        }
    }

    func testActualCaptureDisposalStallRetainsLaneAndShutdownWork() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/muesli-mic-disposal-stall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry)
        let closing = TaskCompletion(), closed = TaskCompletion(), closeReturn = DispatchSemaphore(value: 0)
        let request = try makeDisposalGatedMicRequest(folder: folder, registry: registry,
            closing: closing, closed: closed, closeReturn: closeReturn)
        let start = Task { () -> Result<Void, Error> in
            do { try await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true); return .success(()) }
            catch { return .failure(error) }
        }
        let entered = await closing.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed, "Disposal begins only after the native action returned")
        let nativeResult = await start.value
        XCTAssertNoThrow(try nativeResult.get(), "Known native completion remains successful while its callback captures close")
        XCTAssertTrue(owner.isBusy)
        let competing = CaptureOperationOwner.Request(operation: { XCTFail("Disposal must retain the native lane") })
        do { try await owner.perform(competing); XCTFail("Expected busy") }
        catch { guard case CaptureOperationOwner.Failure.busy = error else { return XCTFail("Unexpected \(error)") } }
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder, mode: .archive))
        closeReturn.signal()
        let finished = await closed.wait(timeoutSeconds: 2)
        XCTAssertEqual(finished, .completed)
        let exclusive = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        try exclusive.validate()
    }

}

nonisolated private enum TestCaptureFailure: Error { case injected }


nonisolated private final class MicOfferLease: @unchecked Sendable {
    private var access: MeetingFileAccess?
    private let released: DispatchSemaphore
    private let registry: ShutdownWorkRegistry
    init(folder: URL, released: DispatchSemaphore, registry: ShutdownWorkRegistry) throws {
        self.registry = registry
        access = try MeetingFileAccess.acquire(in: folder)
        self.released = released
    }
    deinit {
        XCTAssertFalse(registry.snapshot().pending.isEmpty, "Actual offer source close must precede its native work token release.")
        access = nil
        released.signal()
    }
}

nonisolated private func makeOwnedMicOffer(folder: URL, released: DispatchSemaphore, registry: ShutdownWorkRegistry) throws
    -> @MainActor @Sendable (CaptureOperationOwner.Claim) -> Void {
    let lease = try MicOfferLease(folder: folder, released: released, registry: registry)
    return { claim in withExtendedLifetime(lease) { _ = claim.claim() } }
}

nonisolated private func makeExecutingMicOffer(folder: URL, released: DispatchSemaphore,
    registry: ShutdownWorkRegistry, entered: TaskCompletion, callbackReturn: DispatchSemaphore,
    accepts: Bool) throws -> @MainActor @Sendable (CaptureOperationOwner.Claim) -> Void {
    let lease = try MicOfferLease(folder: folder, released: released, registry: registry)
    return { claim in
        withExtendedLifetime(lease) {
            if accepts { XCTAssertTrue(claim.claim()) }
            entered.markCompleted()
            XCTAssertEqual(callbackReturn.wait(timeout: .now() + 5), .success, "Fail-safe releases blocked UI")
        }
    }
}

nonisolated private func makeAllOwnedMicCallbacks(folder: URL, registry: ShutdownWorkRegistry,
    released: DispatchSemaphore, nativeReturn: TaskCompletion, failureEntered: TaskCompletion,
    failureReturn: DispatchSemaphore, cleanupEntered: TaskCompletion) throws -> CaptureOperationOwner.Request {
    let operationLease = try MicOfferLease(folder: folder, released: released, registry: registry)
    let failureLease = try MicOfferLease(folder: folder, released: released, registry: registry)
    let cleanupLease = try MicOfferLease(folder: folder, released: released, registry: registry)
    return CaptureOperationOwner.Request(onFailure: { _ in
        withExtendedLifetime(failureLease) {
            failureEntered.markCompleted()
            XCTAssertEqual(failureReturn.wait(timeout: .now() + 5), .success)
        }
    }, operation: {
        defer { withExtendedLifetime(operationLease) {} }
        _ = await nativeReturn.wait(timeoutSeconds: 5)
    }, cleanupIfAbandoned: {
        withExtendedLifetime(cleanupLease) { cleanupEntered.markCompleted() }
    })
}

nonisolated private func makeRejectedOwnedMicCallbacks(folder: URL, registry: ShutdownWorkRegistry,
    released: DispatchSemaphore) throws -> CaptureOperationOwner.Request {
    let operation = try MicOfferLease(folder: folder, released: released, registry: registry)
    let adoption = try MicOfferLease(folder: folder, released: released, registry: registry)
    let failure = try MicOfferLease(folder: folder, released: released, registry: registry)
    let cleanup = try MicOfferLease(folder: folder, released: released, registry: registry)
    return CaptureOperationOwner.Request(onFailure: { _ in withExtendedLifetime(failure) {} },
        operation: { withExtendedLifetime(operation) {}; throw TestCaptureFailure.injected },
        adoption: { _ in withExtendedLifetime(adoption) { XCTFail("Failed native start cannot offer ownership") } },
        cleanupIfAbandoned: { withExtendedLifetime(cleanup) {} })
}

nonisolated private final class MicDisposalGate: @unchecked Sendable {
    private var access: MeetingFileAccess?
    private let registry: ShutdownWorkRegistry
    private let closing: TaskCompletion, closed: TaskCompletion
    private let closeReturn: DispatchSemaphore
    init(folder: URL, registry: ShutdownWorkRegistry, closing: TaskCompletion,
         closed: TaskCompletion, closeReturn: DispatchSemaphore) throws {
        access = try MeetingFileAccess.acquire(in: folder)
        self.registry = registry; self.closing = closing; self.closed = closed; self.closeReturn = closeReturn
    }
    deinit {
        XCTAssertFalse(Thread.isMainThread)
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        closing.markCompleted()
        XCTAssertEqual(closeReturn.wait(timeout: .now() + 5), .success)
        access = nil
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        closed.markCompleted()
    }
}
nonisolated private func makeDisposalGatedMicRequest(folder: URL, registry: ShutdownWorkRegistry,
    closing: TaskCompletion, closed: TaskCompletion, closeReturn: DispatchSemaphore) throws -> CaptureOperationOwner.Request {
    let lease = try MicDisposalGate(folder: folder, registry: registry,
        closing: closing, closed: closed, closeReturn: closeReturn)
    return CaptureOperationOwner.Request(operation: { withExtendedLifetime(lease) {} })
}
