import Foundation
import IOKit
import XCTest

final class CapturePowerLifecycleTests: XCTestCase {
    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var host: Int64 = 100_000, continuous: Int64 = 1_000_000
        func set(host: Int64, continuous: Int64) { lock.withLock { self.host = host; self.continuous = continuous } }
        func read() -> CapturePowerLifecycle.Observation { lock.withLock { .init(hostTimeUs: host, continuousTimeUs: continuous) } }
    }
    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    nonisolated private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        func arm() { lock.withLock { armed = true } }
        func beforeIO(_ checkpoint: LocalAudioRecorder.Checkpoint) {
            guard case .manifest = checkpoint else { return }
            let block = lock.withLock { let old = armed; armed = false; return old }
            if block { entered.markCompleted(); _ = release.wait(timeout: .now() + 5) }
        }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("power-lifecycle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func finished(_ recorder: LocalAudioRecorder) async throws -> LocalAudioRecorder.Manifest {
        let result = await recorder.finish(timeoutSeconds: 5)
        return try XCTUnwrap(result)
    }

    @MainActor
    func testPowerEvidenceCommitsWhileMainActorIsBlocked() async throws {
        let url = try folder(), clock = Clock(), published = Counter()
        let recorder = try LocalAudioRecorder(directory: url, commitInterval: 0.05)
        let lifecycle = CapturePowerLifecycle(now: clock.read)
        let binding = lifecycle.bind(recorder: recorder, timeline: CaptureTimeline(epochMicroseconds: 0), sourceSessionID: "source-one")
        lifecycle.setWakeHandler {
            Task { @MainActor in if lifecycle.takeWake() != nil { published.increment() } }
        }
        let durable = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            lifecycle.willSleep()
            clock.set(host: 100_000, continuous: 61_000_000)
            lifecycle.didWake()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if let manifest = try? LocalAudioRecorder.readManifest(directory: url),
                   manifest.power_events?.count == 2, manifest.problem_count > 0, !manifest.completed {
                    durable.signal(); return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        XCTAssertEqual(durable.wait(timeout: .now() + 4), .success)
        XCTAssertEqual(published.value, 0, "Durability must precede the blocked UI wake delivery")
        lifecycle.retire(binding)
        let manifest = try await finished(recorder)
        XCTAssertFalse(manifest.completed)
        XCTAssertEqual(manifest.power_events?.last?.observed_pause_us, 60_000_000)
    }

    func testPauseDoesNotInventPCMSamplesOrClearOnNewFrames() async throws {
        let clock = Clock(), recorder = try LocalAudioRecorder(directory: folder())
        let lifecycle = CapturePowerLifecycle(now: clock.read)
        let token = lifecycle.bind(recorder: recorder, timeline: CaptureTimeline(epochMicroseconds: 0), sourceSessionID: "source")
        recorder.record(source: .mic, ptsUs: 0, payload: Data(repeating: 1, count: 3200))
        lifecycle.willSleep()
        clock.set(host: 100_000, continuous: 61_000_000)
        lifecycle.didWake()
        recorder.record(source: .mic, ptsUs: 100_000, payload: Data(repeating: 2, count: 3200))
        let wake = try XCTUnwrap(lifecycle.takeWake())
        XCTAssertEqual(wake.bindingID, token)
        XCTAssertEqual(wake.sourceSessionID, "source")
        let manifest = try await finished(recorder)
        XCTAssertFalse(manifest.completed)
        XCTAssertEqual(manifest.streams["mic"]?.committed_bytes, 6400)
        XCTAssertEqual(manifest.streams["mic"]?.gap_frames, 0)
        XCTAssertEqual(manifest.power_events?.map(\.source_time_us), [100_000, 100_000])
        XCTAssertEqual(manifest.power_events?.last?.observed_pause_us, 60_000_000)
    }

    func testStopAndResumeBeforeOldWakeCannotTouchNewSource() async throws {
        let clock = Clock()
        let lifecycle = CapturePowerLifecycle(now: clock.read)
        let first = try LocalAudioRecorder(directory: folder()), second = try LocalAudioRecorder(directory: folder())
        let one = lifecycle.bind(recorder: first, timeline: CaptureTimeline(epochMicroseconds: 0), sourceSessionID: "first")
        lifecycle.willSleep()
        lifecycle.retire(one)
        let firstManifest = try await finished(first)
        _ = lifecycle.bind(recorder: second, timeline: CaptureTimeline(epochMicroseconds: 0), sourceSessionID: "second")
        clock.set(host: 100_000, continuous: 61_000_000)
        lifecycle.didWake()
        XCTAssertNil(lifecycle.takeWake())
        let secondManifest = try await finished(second)
        XCTAssertEqual(firstManifest.power_events?.map(\.kind), [.willSleep])
        XCTAssertFalse(firstManifest.completed)
        XCTAssertNil(secondManifest.power_events)
        XCTAssertTrue(secondManifest.completed)
    }

    func testRetiredPreviewAndCoalescedWakeMailbox() {
        let lifecycle = CapturePowerLifecycle(), count = Counter()
        lifecycle.setWakeHandler { count.increment() }
        let first = lifecycle.bind()
        lifecycle.willSleep()
        lifecycle.retire(first)
        let second = lifecycle.bind()
        lifecycle.didWake()
        XCTAssertEqual(count.value, 0)
        for _ in 0..<500 { lifecycle.willSleep(); lifecycle.willSleep(); lifecycle.didWake(); lifecycle.didWake() }
        XCTAssertEqual(count.value, 1, "Only one UI mailbox delivery may be queued")
        XCTAssertEqual(lifecycle.takeWake()?.bindingID, second)
        XCTAssertNil(lifecycle.takeWake())
        lifecycle.willSleep(); lifecycle.didWake()
        XCTAssertEqual(count.value, 2)
    }

    func testBoundedPowerEvidenceReportsOmittedReceipts() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), commitInterval: 3600)
        let lifecycle = CapturePowerLifecycle()
        lifecycle.bind(recorder: recorder, timeline: CaptureTimeline())
        for _ in 0..<512 { lifecycle.willSleep(); lifecycle.didWake() }
        let manifest = try await finished(recorder)
        XCTAssertFalse(manifest.completed)
        XCTAssertEqual(manifest.power_events?.count, 128)
        XCTAssertEqual(manifest.power_events_omitted, 896)
    }

    func testUnavailableRegistrationIsExplicitAndOldManifestStillDecodes() async throws {
        let lifecycle = CapturePowerLifecycle(monitorAvailable: false)
        let recorder = try LocalAudioRecorder(directory: folder())
        lifecycle.bind(recorder: recorder, timeline: CaptureTimeline())
        lifecycle.setMonitorAvailable(true)
        let manifest = try await finished(recorder)
        XCTAssertFalse(manifest.completed)
        XCTAssertEqual(manifest.power_events?.map(\.kind), [.monitorUnavailable])
        var old = manifest
        old.power_events = nil; old.power_events_omitted = nil
        let decoded = try LocalAudioRecorder.decodeManifest(JSONEncoder().encode(old))
        XCTAssertNil(decoded.power_events)
    }

    func testStalledPowerCommitKeepsOriginalEvidenceThroughExpiredFinish() async throws {
        let gate = Gate(), url = try folder()
        defer { gate.release.signal() }
        let recorder = try LocalAudioRecorder(directory: url, commitInterval: 3600, beforeIO: gate.beforeIO)
        let lifecycle = CapturePowerLifecycle()
        let id = lifecycle.bind(recorder: recorder, timeline: CaptureTimeline())
        gate.arm()
        lifecycle.willSleep()
        lifecycle.retire(id)
        recorder.requestFinish()
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        let expired = await recorder.finish(timeoutSeconds: 0.01)
        XCTAssertNil(expired)
        XCTAssertFalse(try LocalAudioRecorder.readManifest(directory: url).completed)
        XCTAssertThrowsError(try LocalAudioRecorder.withInactiveSource(directory: url) {})
        gate.release.signal()
        let manifest = try await finished(recorder)
        XCTAssertFalse(manifest.completed)
        XCTAssertEqual(manifest.power_events?.map(\.kind), [.willSleep])
        XCTAssertEqual(try LocalAudioRecorder.readManifest(directory: url).power_events, manifest.power_events)
    }

    func testWakeInvalidationSurvivesFreshOldGenerationSamplesAndWaitsForNativeOwner() {
        let now = Date(timeIntervalSince1970: 10)
        var health = CaptureSourceHealth()
        health.begin(generation: 1, now: now)
        XCTAssertTrue(health.progress(frames: 10, generation: 1, at: now))
        health.invalidateAfterSystemWake(now: now)
        XCTAssertFalse(health.progress(frames: 100, generation: 1, at: now))
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(3), requireContinuousCallbacks: false, canStartRecovery: false))
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(3), requireContinuousCallbacks: false))
        XCTAssertFalse(health.shouldRecover(now: now.addingTimeInterval(3), requireContinuousCallbacks: false))
        health.begin(generation: 2, now: now.addingTimeInterval(3))
        XCTAssertTrue(health.progress(frames: 10, generation: 2, at: now.addingTimeInterval(3)))
    }

    func testNativeAcknowledgmentPrecedesReceiptAndNeverAcknowledgesWake() {
        let acknowledgments = Counter(), observations = Counter()
        let lifecycle = CapturePowerLifecycle(now: {
            XCTAssertGreaterThan(acknowledgments.value, 0)
            observations.increment()
            return .init(hostTimeUs: 0, continuousTimeUs: 0)
        })
        SystemPowerNotificationDelivery.receive(MuesliPowerCanSystemSleep(), argument: 2, lifecycle: lifecycle) { value in
            XCTAssertEqual(value, 2); acknowledgments.increment()
        }
        XCTAssertEqual(observations.value, 0)
        SystemPowerNotificationDelivery.receive(MuesliPowerSystemWillSleep(), argument: 3, lifecycle: lifecycle) { value in
            XCTAssertEqual(value, 3); acknowledgments.increment()
        }
        XCTAssertEqual(acknowledgments.value, 2)
        XCTAssertEqual(observations.value, 1)
        SystemPowerNotificationDelivery.receive(MuesliPowerSystemHasPoweredOn(), argument: 4, lifecycle: lifecycle) { _ in XCTFail("Wake must not be acknowledged") }
        XCTAssertEqual(observations.value, 2)
    }
}
