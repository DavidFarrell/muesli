import Foundation
import ScreenCaptureKit
import XCTest

nonisolated private final class SyntheticSystemStream: NativeSystemStream, @unchecked Sendable {
    private let lock = NSLock()
    let startError: Error?
    let stopError: Error?
    let blocksStop: Bool
    let stopEntered = TaskCompletion()
    private var pendingStop: (@Sendable (Error?) -> Void)?
    private var starts = 0, stops = 0, removals = 0
    init(startError: Error? = nil, stopError: Error? = nil, blocksStop: Bool = false) {
        self.startError = startError; self.stopError = stopError; self.blocksStop = blocksStop
    }
    func startCapture(completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { starts += 1 }
        completionHandler(startError)
    }
    func stopCapture(completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { stops += 1; if blocksStop { pendingStop = completionHandler } }
        stopEntered.markCompleted()
        if !blocksStop { completionHandler(stopError) }
    }
    func returnStop() {
        let callback = lock.withLock { let callback = pendingStop; pendingStop = nil; return callback }
        callback?(stopError)
    }
    func removeOutputs(_ relay: SystemAudioCaptureRelay) { lock.withLock { removals += 1 } }
    func counts() -> (starts: Int, stops: Int, removals: Int) { lock.withLock { (starts, stops, removals) } }
}

final class NativeSystemCaptureTests: XCTestCase {
    private let failedStart = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)
    private let alreadyStopped = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.attemptToStopStreamState.rawValue)
    private let uncertainStop = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStopAudioCapture.rawValue)

    private func makeRelay() async -> SystemAudioCaptureRelay {
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting()
        await forwarder.beginGeneration(1, writer: nil)
        return SystemAudioCaptureRelay(generation: 1, forwarder: forwarder,
            display: MicDeliveryDisplayMailbox { _ in }, onStopped: { _ in })
    }
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/muesli-native-system-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
    private func waitForRetirement(_ native: NativeSystemCapture) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !native.isRetired, ContinuousClock.now < deadline { await Task.yield() }
    }

    func testFailedStartAndAlreadyStoppedErrorRetireActualOwnerAndLease() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let stream = SyntheticSystemStream(startError: failedStart, stopError: alreadyStopped)
        let registry = ShutdownWorkRegistry(), relay = await makeRelay()
        let native = try NativeSystemCapture(stream: stream, relay: relay,
            meetingAccess: MeetingFileAccess.acquire(in: folder), preservesRecording: true, shutdown: registry)
        do { try await native.start(); XCTFail("Synthetic start must fail") } catch { }
        registry.beginQuit()
        do { try await native.stop() } catch { XCTFail("Already-stopped native cleanup threw: \(error)") }
        XCTAssertTrue(native.isRetired)
        XCTAssertEqual(stream.counts().removals, 1)
        XCTAssertTrue(registry.sealIfFinished(), "The actual native token must finish")
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder, mode: .archive).validate(),
                         "The actual shared file lease must close before native retirement is published")
    }

    func testSetupFailureBeforeAnyStartSkipsNativeStopAndRetires() async throws {
        let stream = SyntheticSystemStream(stopError: uncertainStop)
        let registry = ShutdownWorkRegistry(), relay = await makeRelay()
        let native = try NativeSystemCapture(stream: stream, relay: relay, meetingAccess: nil,
                                             preservesRecording: true, shutdown: registry)
        do { try await native.stop() } catch { XCTFail("A never-started stream needs no native stop: \(error)") }
        XCTAssertTrue(native.isRetired)
        XCTAssertEqual(stream.counts().stops, 0)
        XCTAssertEqual(stream.counts().removals, 1)
        registry.beginQuit(); XCTAssertTrue(registry.sealIfFinished())
    }

    func testUnknownFailedStartAndStopRetainLeaseUntilDelayedDelegateWithoutUI() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let stream = SyntheticSystemStream(startError: failedStart, stopError: uncertainStop)
        let registry = ShutdownWorkRegistry(), relay = await makeRelay()
        let native = try NativeSystemCapture(stream: stream, relay: relay,
            meetingAccess: MeetingFileAccess.acquire(in: folder), preservesRecording: true, shutdown: registry)
        do { try await native.start(); XCTFail("Synthetic start must fail") } catch { }
        do { try await native.stop(); XCTFail("Unknown stop failure must remain uncertain") } catch { }
        XCTAssertFalse(native.isRetired)
        XCTAssertEqual(stream.counts().removals, 0)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder, mode: .archive))
        registry.beginQuit(); XCTAssertFalse(registry.sealIfFinished())
        let actuallyClosed = DispatchSemaphore(value: 0)
        registry.observe { if registry.snapshot().pending.isEmpty { actuallyClosed.signal() } }
        DispatchQueue.global().async { relay.recordNativeStop(NSError(domain: "Synthetic terminal delegate", code: 1)) }
        // The UI is deliberately blocked. A native terminal event must finish
        // the original cleanup without a supervisor/UI retry or replacement.
        XCTAssertEqual(actuallyClosed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(native.isRetired)
        XCTAssertEqual(stream.counts().stops, 1)
        XCTAssertEqual(stream.counts().removals, 1)
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder, mode: .archive).validate())
        XCTAssertTrue(registry.sealIfFinished())
        // Releases the baseline implementation after recording red evidence.
        try? await native.stop()
    }

    func testRunningStopErrorKeepsOwnershipAndWrongDomainCodeIsNotTerminal() async throws {
        for error in [uncertainStop, NSError(domain: "Unrelated domain", code: alreadyStopped.code)] {
            let stream = SyntheticSystemStream(stopError: error)
            let registry = ShutdownWorkRegistry(), relay = await makeRelay()
            let native = try NativeSystemCapture(stream: stream, relay: relay, meetingAccess: nil,
                                                 preservesRecording: true, shutdown: registry)
            try await native.start()
            do { try await native.stop(); XCTFail("Running source has no terminal evidence") } catch { }
            XCTAssertFalse(native.isRetired)
            XCTAssertEqual(stream.counts().removals, 0)
            registry.beginQuit(); XCTAssertFalse(registry.sealIfFinished())
            relay.recordNativeStop(error)
            try await native.stop()
            XCTAssertTrue(native.isRetired)
            XCTAssertTrue(registry.sealIfFinished())
        }
    }

    func testDelegateDuringBlockedStopCannotReleaseOriginalOperationOrLease() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let stream = SyntheticSystemStream(stopError: uncertainStop, blocksStop: true)
        let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry), relay = await makeRelay()
        let native = try NativeSystemCapture(stream: stream, relay: relay,
            meetingAccess: MeetingFileAccess.acquire(in: folder), preservesRecording: true, shutdown: registry)
        try await native.start()
        let stop = Task {
            let request = CaptureOperationOwner.Request(operation: { try await native.stop() })
            do { try await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true); XCTFail("Stop should time out") }
            catch { }
        }
        let entered = await stream.stopEntered.wait(timeoutSeconds: 1); XCTAssertEqual(entered, .completed)
        await stop.value
        relay.recordNativeStop(uncertainStop)
        XCTAssertTrue(owner.isBusy)
        XCTAssertFalse(native.isRetired)
        XCTAssertEqual(stream.counts().removals, 0)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder, mode: .archive))
        registry.beginQuit(); XCTAssertFalse(registry.sealIfFinished())
        stream.returnStop()
        await waitForRetirement(native)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.isBusy || !registry.snapshot().pending.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(native.isRetired)
        XCTAssertFalse(owner.isBusy)
        XCTAssertEqual(stream.counts().stops, 1)
        XCTAssertEqual(stream.counts().removals, 1)
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder, mode: .archive).validate())
        XCTAssertTrue(registry.sealIfFinished())
    }

    func testAlreadyStoppedCleanupAllowsNextNativeGenerationOnSameOperationOwner() async throws {
        let registry = ShutdownWorkRegistry(), owner = CaptureOperationOwner(shutdown: registry)
        let oldStream = SyntheticSystemStream(startError: failedStart, stopError: alreadyStopped)
        let old = try NativeSystemCapture(stream: oldStream, relay: await makeRelay(), meetingAccess: nil,
                                          preservesRecording: true, shutdown: registry)
        do { try await owner.perform(CaptureOperationOwner.Request(operation: { try await old.start() })); XCTFail("Must fail") } catch { }
        do { try await owner.perform(CaptureOperationOwner.Request(operation: { try await old.stop() })) }
        catch { XCTFail("Retirement must finish: \(error)") }
        XCTAssertTrue(old.isRetired)
        XCTAssertFalse(owner.isBusy)
        let newStream = SyntheticSystemStream()
        let next = try NativeSystemCapture(stream: newStream, relay: await makeRelay(), meetingAccess: nil,
                                           preservesRecording: true, shutdown: registry)
        try await owner.perform(CaptureOperationOwner.Request(operation: { try await next.start() }))
        XCTAssertEqual(newStream.counts().starts, 1)
        try await owner.perform(CaptureOperationOwner.Request(operation: { try await next.stop() }))
        registry.beginQuit(); XCTAssertTrue(registry.sealIfFinished())
    }

    func testSealedQuitAdmissionCreatesNoNativeCallOrRetainedFileLease() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let registry = ShutdownWorkRegistry(), stream = SyntheticSystemStream(), relay = await makeRelay()
        registry.beginQuit(); XCTAssertTrue(registry.sealIfFinished())
        XCTAssertThrowsError(try NativeSystemCapture(stream: stream, relay: relay,
            meetingAccess: MeetingFileAccess.acquire(in: folder), preservesRecording: true, shutdown: registry))
        XCTAssertEqual(stream.counts().starts, 0)
        XCTAssertEqual(stream.counts().stops, 0)
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder, mode: .archive).validate())
    }
}
