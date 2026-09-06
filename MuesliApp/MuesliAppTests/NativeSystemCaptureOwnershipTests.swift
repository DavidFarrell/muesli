import Foundation
import ScreenCaptureKit
import XCTest

nonisolated private final class GatedSystemStream: NativeSystemStream, @unchecked Sendable {
    private let lock = NSLock()
    let blocksStart: Bool, blocksRemoval: Bool
    let enteredStart = TaskCompletion(), enteredRemoval = TaskCompletion()
    let removalReturn = DispatchSemaphore(value: 0)
    private var startReturn: (@Sendable (Error?) -> Void)?
    private var removals = 0, starts = 0, stops = 0
    init(blocksStart: Bool = false, blocksRemoval: Bool = false) {
        self.blocksStart = blocksStart; self.blocksRemoval = blocksRemoval
    }
    func startCapture(completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { starts += 1; if blocksStart { startReturn = completionHandler } }
        enteredStart.markCompleted()
        if !blocksStart { completionHandler(nil) }
    }
    func returnStart() {
        let callback = lock.withLock { let callback = startReturn; startReturn = nil; return callback }
        callback?(nil)
    }
    func stopCapture(completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { stops += 1 }; completionHandler(nil)
    }
    func removeOutputs(_ relay: SystemAudioCaptureRelay) {
        lock.withLock { removals += 1 }; enteredRemoval.markCompleted()
        if blocksRemoval { _ = removalReturn.wait(timeout: .now() + 10) }
    }
    func counts() -> (starts: Int, stops: Int, removals: Int) { lock.withLock { (starts, stops, removals) } }
}

final class NativeSystemCaptureOwnershipTests: XCTestCase {
    private func makeNative(stream: GatedSystemStream, registry: ShutdownWorkRegistry,
                            folder: URL? = nil) async throws -> NativeSystemCapture {
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting(); await forwarder.beginGeneration(1, writer: nil)
        let relay = SystemAudioCaptureRelay(generation: 1, forwarder: forwarder,
            display: MicDeliveryDisplayMailbox { _ in }, onStopped: { _ in })
        return try NativeSystemCapture(stream: stream, relay: relay,
            meetingAccess: folder.map { try MeetingFileAccess.acquire(in: $0) }, preservesRecording: true, shutdown: registry)
    }
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/muesli-native-system-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
    private func waitForFinish(native: NativeSystemCapture, owner: CaptureOperationOwner,
                               registry: ShutdownWorkRegistry) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !native.isRetired || owner.isBusy || !registry.snapshot().pending.isEmpty,
              ContinuousClock.now < deadline { await Task.yield() }
    }

    func testTerminalDelegateDuringBlockedStartWaitsForOriginalStartReturn() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let stream = GatedSystemStream(blocksStart: true), registry = ShutdownWorkRegistry()
        let owner = CaptureOperationOwner(shutdown: registry)
        let native = try await makeNative(stream: stream, registry: registry, folder: folder)
        let start = Task {
            let request = CaptureOperationOwner.Request(operation: { try await native.start() }, cleanupIfAbandoned: { try? await native.stop() })
            try? await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true)
        }
        let entered = await stream.enteredStart.wait(timeoutSeconds: 1); XCTAssertEqual(entered, .completed)
        await start.value
        native.relay.recordNativeStop(NSError(domain: "Synthetic terminal delegate", code: 1))
        XCTAssertTrue(owner.isBusy); XCTAssertFalse(native.isRetired)
        XCTAssertEqual(stream.counts().removals, 0)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder, mode: .archive))
        registry.beginQuit(); XCTAssertFalse(registry.sealIfFinished())
        stream.returnStart()
        await waitForFinish(native: native, owner: owner, registry: registry)
        XCTAssertTrue(native.isRetired); XCTAssertFalse(owner.isBusy)
        XCTAssertEqual(stream.counts().stops, 0)
        XCTAssertEqual(stream.counts().removals, 1)
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder, mode: .archive).validate())
        XCTAssertTrue(registry.sealIfFinished())
    }

    func testOutputDetachmentMustReturnBeforeActualLeaseAndQuitRelease() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let stream = GatedSystemStream(blocksRemoval: true), registry = ShutdownWorkRegistry()
        let owner = CaptureOperationOwner(shutdown: registry)
        let native = try await makeNative(stream: stream, registry: registry, folder: folder)
        try await native.start()
        let stop = Task {
            let request = CaptureOperationOwner.Request(operation: { try await native.stop() })
            try? await owner.perform(request, timeoutSeconds: 0.03, preservesRecording: true)
        }
        let entered = await stream.enteredRemoval.wait(timeoutSeconds: 1); XCTAssertEqual(entered, .completed)
        await stop.value
        XCTAssertTrue(owner.isBusy); XCTAssertFalse(native.isRetired)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder, mode: .archive))
        registry.beginQuit(); XCTAssertFalse(registry.sealIfFinished())
        stream.removalReturn.signal()
        await waitForFinish(native: native, owner: owner, registry: registry)
        XCTAssertTrue(native.isRetired); XCTAssertFalse(owner.isBusy)
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder, mode: .archive).validate())
        XCTAssertTrue(registry.sealIfFinished())
    }

    func testRetirementIsOnceOnlyAndOldGenerationCannotStartAgain() async throws {
        let stream = GatedSystemStream(), registry = ShutdownWorkRegistry()
        let native = try await makeNative(stream: stream, registry: registry)
        try await native.start(); try await native.stop()
        for _ in 0..<100 { native.relay.recordNativeStop(NSError(domain: "Duplicate terminal delegate", code: 1)) }
        try await native.stop(); try await native.stop()
        do { try await native.start(); XCTFail("A retired generation must never restart") } catch { }
        XCTAssertEqual(stream.counts().starts, 1)
        XCTAssertEqual(stream.counts().stops, 1)
        XCTAssertEqual(stream.counts().removals, 1)
        registry.beginQuit(); XCTAssertTrue(registry.sealIfFinished())
    }
}
