import XCTest
import ScreenCaptureKit

@MainActor
final class CooperativeQuitTests: XCTestCase {
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var blockedOnce = false
        func blockOnce() {
            guard lock.withLock({ if blockedOnce { return false }; blockedOnce = true; return true }) else { return }
            block()
        }
        func block() {
            XCTAssertFalse(Thread.isMainThread)
            entered.markCompleted()
            XCTAssertEqual(release.wait(timeout: .now() + 8), .success)
        }
    }
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func drained(_ registry: ShutdownWorkRegistry) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !registry.snapshot().pending.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(registry.snapshot().pending.isEmpty)
    }
    func testEmptySealAndAdmissionAreAtomic() throws {
        for _ in 0..<200 {
            let registry = ShutdownWorkRegistry()
            registry.beginQuit()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                if let work = try? registry.begin("racing acceptance") {
                    XCTAssertFalse(registry.sealIfFinished())
                    work.finish()
                }
                group.leave()
            }
            let sealed = registry.sealIfFinished()
            group.wait()
            if sealed { XCTAssertThrowsError(try registry.begin("late")) }
            else { XCTAssertTrue(registry.sealIfFinished()) }
        }
    }
    func testDeadlineOnlyShowsPendingAndActualCompletionRepliesOnce() async throws {
        let registry = ShutdownWorkRegistry(), work = try registry.begin("original source")
        let coordinator = ApplicationQuitCoordinator(registry: registry, pendingAfter: .milliseconds(15))
        var replies: [Bool] = []
        coordinator.requestQuit { replies.append($0) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(coordinator.showsPending)
        XCTAssertEqual(replies, [])
        work.finish()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(replies, [true])
        XCTAssertThrowsError(try registry.begin("after approval"))
        work.finish()
        XCTAssertEqual(replies, [true])
    }
    func testCancelBeforePreparationDoesNotStopLaterWork() async throws {
        let registry = ShutdownWorkRegistry()
        let coordinator = ApplicationQuitCoordinator(registry: registry, pendingAfter: .milliseconds(10))
        var prepared = 0, replies: [Bool] = []
        coordinator.configure(prepare: { prepared += 1 }, cancelled: {})
        coordinator.requestQuit { replies.append($0) }
        coordinator.cancelQuit()
        let new = try registry.begin("new accepted work")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(coordinator.showsPending)
        XCTAssertTrue(registry.acceptsUserWork)
        new.finish()
    }
    func testTerminalSaveFailureNeedsExplicitChoiceEvenWhenOwnerEnded() async throws {
        let registry = ShutdownWorkRegistry(), work = try registry.begin("save")
        let coordinator = ApplicationQuitCoordinator(registry: registry, pendingAfter: .seconds(2))
        var replies: [Bool] = []
        coordinator.requestQuit { replies.append($0) }
        work.finish(failure: "Disk full")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(coordinator.showsPending)
        XCTAssertEqual(replies, [])
        XCTAssertTrue(coordinator.failures.contains { $0.contains("Disk full") })
        coordinator.quitAnyway()
        XCTAssertEqual(replies, [true])
    }
    func testRealRecorderFinalManifestStallKeepsQuitPendingAfterFinishDeadline() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate()
        let recorder = try LocalAudioRecorder(directory: try folder().appendingPathComponent("audio"), shutdown: registry,
            beforeIO: { if case .manifest = $0 { gate.block() } })
        let finish = Task { await recorder.finish(timeoutSeconds: 0.02) }
        let observed4471 = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(observed4471, .completed)
        let expired = await finish.value
        XCTAssertNil(expired)
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        gate.release.signal()
        try await drained(registry)
        XCTAssertTrue(registry.sealIfFinished())
    }
    func testRealFolderOwnerAndQueuedFinalizerRemainTrackedAcrossDeadlines() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), directory = try folder()
        let store = TranscriptPersistenceStore(shutdown: registry)
        let edit = try store.start(in: directory) { context in
            gate.block()
            try context.commit(files: ["transcript.txt": Data("edit".utf8)])
        }
        let observed5212 = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(observed5212, .completed)
        let final = try store.startAfterCurrent(in: directory) { context in
            try context.commit(files: ["transcript.txt": Data("terminal".utf8)])
        }
        registry.beginQuit()
        if case .timedOut = await final.wait(timeoutSeconds: 0.01) {} else { XCTFail("deadline") }
        XCTAssertFalse(registry.sealIfFinished())
        gate.release.signal()
        _ = try await edit.value(timeoutSeconds: 2)
        _ = try await final.value(timeoutSeconds: 2)
        try await drained(registry)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.txt")), Data("terminal".utf8))
        XCTAssertTrue(registry.sealIfFinished())
    }
    func testPreviewReadIsDispensableAndCannotWriteOrRecoverAfterSeal() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), directory = try folder()
        let store = TranscriptPersistenceStore(shutdown: registry)
        let read = try store.start(in: directory, purpose: .previewRead) { context in
            gate.block()
            XCTAssertThrowsError(try context.commit(files: ["transcript.txt": Data("bad".utf8)]))
        }
        let observed6442 = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(observed6442, .completed)
        registry.beginQuit()
        XCTAssertTrue(registry.sealIfFinished())
        gate.release.signal()
        _ = try await read.value(timeoutSeconds: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.txt").path))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName), withIntermediateDirectories: true)
        let refused = try store.start(in: directory, purpose: .previewRead) { _ in XCTFail("cannot recover") }
        do { _ = try await refused.value(timeoutSeconds: 2); XCTFail("unresolved journal") } catch {}
    }
    func testNativeRecordingOwnerRemainsThroughAbandonedCleanup() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), cleanup = Gate()
        let owner = CaptureOperationOwner(shutdown: registry)
        let pending = Task {
            try await owner.perform(timeoutSeconds: 0.02, preservesRecording: true,
                                    operation: { gate.block() }, cleanupIfAbandoned: { cleanup.block() })
        }
        let observed7641 = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(observed7641, .completed)
        do { try await pending.value; XCTFail("deadline") } catch {}
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        gate.release.signal()
        let observed7898 = await cleanup.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(observed7898, .completed)
        XCTAssertFalse(registry.sealIfFinished())
        cleanup.release.signal()
        try await drained(registry)
        XCTAssertTrue(registry.sealIfFinished())
    }
    func testActualLogQueueCloseKeepsOwnerAfterCallerReturns() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), directory = try folder()
        let url = directory.appendingPathComponent("backend.log")
        try Data().write(to: url)
        let writer = BackendLogWriter(ringBufferLimit: 4, shutdown: registry, beforeWrite: { gate.block() })
        writer.reset(handle: try FileHandle(forWritingTo: url))
        writer.append("accepted log", toTail: true)
        let observed8644 = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(observed8644, .completed)
        writer.close()
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        gate.release.signal()
        try await drained(registry)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "accepted log\n")
        XCTAssertTrue(registry.sealIfFinished())
    }
    func testArtifactSDKFinishRemainsOwnedAfterStopDeadline() async throws {
        let registry = ShutdownWorkRegistry()
        let store = try SessionArtifactStore(meetingDirectory: folder(), sourceSessionID: UUID().uuidString,
            timeline: CaptureTimeline(), timelineOffsetUs: 0, shutdown: registry)
        let url = try XCTUnwrap(store.nextVideoURL())
        try Data([1, 2, 3]).write(to: url)
        let delegate = RecordingDelegate(url: url)
        let configuration = SCRecordingOutputConfiguration(); configuration.outputURL = url
        let output = SCRecordingOutput(configuration: configuration, delegate: delegate)
        store.retainRecording(delegate)
        if case .timedOut = await store.finish(timeoutSeconds: 0.01) {} else { XCTFail("no native completion") }
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        delegate.recordingOutputDidFinishRecording(output)
        _ = await store.finish(timeoutSeconds: 2)
        try await drained(registry)
        XCTAssertTrue(registry.sealIfFinished())
    }
    func testUnadoptedReadyStartClosesAndPersistsInterruptedState() async throws {
        let registry = ShutdownWorkRegistry(), base = try folder()
        let store = TranscriptPersistenceStore(shutdown: registry)
        let owner = MeetingStartPreparationOwner(store: store, shutdown: registry)
        let startBridge = try registry.begin("start handoff")
        guard case .ready(let prepared) = await owner.prepare(.init(title: "Not adopted", meetingsDirectory: base, video: true)) else {
            return XCTFail("ready fixture")
        }
        registry.beginQuit()
        owner.discardUnadopted(prepared)
        startBridge.finish()
        try await drained(registry)
        XCTAssertTrue(registry.sealIfFinished())
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: prepared.folderURL.appendingPathComponent("meeting.json")))
        XCTAssertEqual(metadata.status, .interrupted)
        XCTAssertEqual(metadata.sessions.last?.finalizationStatus, "interrupted")
        XCTAssertThrowsError(try prepared.logHandle.write(contentsOf: Data([1])))
    }
    func testBackendJournalStallAndClaimedBatchCancellationTrackActualCleanup() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), directory = try folder()
        let scopeClosed = DispatchSemaphore(value: 0)
        let owner = BackendAdmissionOwner(shutdown: registry, cancelClaimedOnQuit: true)
        let attempt = try owner.start(timeoutSeconds: 3) {
            .init(backend: try BackendProcess(command: ["/bin/sleep", "30"],
                eventJournalURL: directory.appendingPathComponent("events"), beforeEventJournalIO: {
                    if case .prepare = $0 { gate.block() }
                }), onClosed: { scopeClosed.signal() })
        }
        let entered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed)
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        // Hold the real UI executor; abandonment itself must not need it.
        gate.release.signal()
        XCTAssertEqual(scopeClosed.wait(timeout: .now() + 3), .success)
        let closed = await attempt.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(closed, .completed)
        XCTAssertThrowsError(try attempt.claim())
        try await drained(registry)
        XCTAssertTrue(registry.sealIfFinished())

        let batchRegistry = ShutdownWorkRegistry()
        let batchOwner = BackendAdmissionOwner(shutdown: batchRegistry, cancelClaimedOnQuit: true)
        let batch = try batchOwner.start { .init(backend: try BackendProcess(command: ["/bin/sleep", "30"])) }
        guard case .ready = await batch.waitUntilReady() else { return XCTFail("batch ready") }
        let resources = try batch.claim()
        batchRegistry.beginQuit()
        let actualClosed = await batch.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(actualClosed, .completed)
        XCTAssertFalse(resources.backend.isRunning)
        XCTAssertTrue(resources.backend.stdoutStatus().closed)
        XCTAssertTrue(batchRegistry.sealIfFinished())
    }

    nonisolated private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MeetingMetadataEdits.Publication] = []
        let enqueued = DispatchSemaphore(value: 0)
        func submit(_ value: @escaping MeetingMetadataEdits.Publication) {
            lock.withLock { values.append(value) }; enqueued.signal()
        }
        func take() -> MeetingMetadataEdits.Publication? { lock.withLock { values.isEmpty ? nil : values.removeFirst() } }
    }
    func testCoalescedAcceptedNamesKeepTokenBetweenActualDiskAndDelayedUICallbacks() async throws {
        let registry = ShutdownWorkRegistry(), directory = try folder(), mailbox = Mailbox()
        let metadata = MeetingMetadata(version: 1, title: "fixture", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 0, lastTimestamp: 0, status: .interrupted, sessions: [], segmentCount: 0, speakerNames: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("meeting.json"))
        let store = TranscriptPersistenceStore(shutdown: registry)
        let edits = MeetingMetadataEdits(store: store, timeoutSeconds: 30, shutdown: registry,
            deliver: mailbox.submit, onEvent: { _ in })
        edits.submitNames(["first": "Alex"], in: directory, contentGeneration: 1)
        edits.submitNames(["second": "Blair"], in: directory, contentGeneration: 1)
        // The original disk completion arrives while the actual UI executor is
        // held. Its successor has not been admitted yet; accepted intent still
        // needs an owner, independent of the completed Store operation.
        XCTAssertEqual(mailbox.enqueued.wait(timeout: .now() + 2), .success)
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished())
        try XCTUnwrap(mailbox.take())()
        XCTAssertEqual(mailbox.enqueued.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(registry.sealIfFinished())
        try XCTUnwrap(mailbox.take())()
        try await drained(registry)
        XCTAssertTrue(registry.sealIfFinished())
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
        XCTAssertEqual(saved.speakerNames, ["first": "Alex", "second": "Blair"])
    }

    func testImmediateCancelCannotReviveAlreadyClaimedStartHandoff() async throws {
        let registry = ShutdownWorkRegistry(), directory = try folder()
        let coordinator = ApplicationQuitCoordinator(registry: registry)
        let store = TranscriptPersistenceStore(shutdown: registry)
        let owner = MeetingStartPreparationOwner(store: store, shutdown: registry)
        let bridge = try registry.begin("Start handoff")
        let oldIntent = coordinator.startIntent
        guard case .ready(let prepared) = await owner.prepare(.init(title: "Old start", meetingsDirectory: directory)) else {
            return XCTFail("actual owner must have claimed the ready fixture")
        }
        var asyncPreparations = 0, replies: [Bool] = []
        coordinator.configure(prepare: { asyncPreparations += 1 }, cancelled: {})
        // This is the real immediate-panel ordering, without yielding MainActor
        // to the coordinator's queued asynchronous preparation task.
        registry.recordFailure("Earlier save needs review")
        coordinator.requestQuit { replies.append($0) }
        XCTAssertTrue(coordinator.showsPending)
        coordinator.cancelQuit()
        XCTAssertTrue(registry.acceptsUserWork)
        XCTAssertFalse(coordinator.canContinueStart(oldIntent), "reopening admission must not restore the old generation")
        XCTAssertThrowsError(try coordinator.requireCurrentStart(oldIntent))
        let nextIntent = coordinator.startIntent
        XCTAssertTrue(coordinator.canContinueStart(nextIntent), "a newly requested Start remains usable")
        XCTAssertNoThrow(try coordinator.requireCurrentStart(nextIntent))
        // Use the same production admission predicate and cleanup owner as
        // AppModel's post-prepare handoff; no hardware-backed AppModel needed.
        if coordinator.canContinueStart(oldIntent) { XCTFail("old capture would be adopted") }
        else { owner.discardUnadopted(prepared) }
        bridge.finish()
        try await drained(registry)
        XCTAssertEqual(asyncPreparations, 0, "Cancel skipped async prepare, but intent was already retired")
        XCTAssertEqual(replies, [false])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: prepared.folderURL.appendingPathComponent("meeting.json")))
        XCTAssertEqual(metadata.status, .interrupted)
        XCTAssertEqual(metadata.sessions.last?.sourceSessionID, prepared.sourceID)
        XCTAssertThrowsError(try prepared.logHandle.write(contentsOf: Data([1])))
    }

    func testRetiredInitialContinuationRetainsRealSourceUntilActualClose() async throws {
        let registry = ShutdownWorkRegistry(), coordinator = ApplicationQuitCoordinator(registry: registry)
        let source = try folder().appendingPathComponent("audio"), gate = Gate()
        defer { gate.release.signal() }
        let recorder = try LocalAudioRecorder(directory: source, commitInterval: 60, shutdown: registry,
            beforeIO: { if case .manifest = $0 { gate.blockOnce() } })
        let bytes = Data(repeating: 7, count: 320)
        recorder.send(type: .audio, stream: .system, ptsUs: 0, payload: bytes)
        let startWork = try registry.begin("Original initial continuation")
        let originalIntent = coordinator.startIntent, entered = TaskCompletion(), release = TaskCompletion()
        var admittedNextStage = false, asyncQuitPreparations = 0
        coordinator.configure(prepare: { asyncQuitPreparations += 1 }, cancelled: {})
        let pending = Task { @MainActor in
            defer { startWork.finish() }
            entered.markCompleted(); _ = await release.wait(timeoutSeconds: 3)
            do {
                try coordinator.requireCurrentStart(originalIntent)
                admittedNextStage = true
            } catch {
                // This is the actual source owner used by failed initial setup.
                // Its own work token must survive a bounded cleanup waiter.
                recorder.reportFailure(stream: .mic, message: "Initial setup was retired before microphone admission.")
                return await recorder.finish(timeoutSeconds: 0.02)
            }
            return nil
        }
        let didEnter = await entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(didEnter, .completed)
        coordinator.requestQuit { _ in }; coordinator.cancelQuit()
        release.markCompleted()
        let didStartClose = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(didStartClose, .completed)
        let boundedResult = await pending.value
        XCTAssertNil(boundedResult)
        XCTAssertFalse(admittedNextStage)
        XCTAssertEqual(asyncQuitPreparations, 0)
        XCTAssertThrowsError(try LocalAudioRecorder.withInactiveSource(directory: source) {})
        registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished(), "Actual recorder close remains owned after the initial continuation returns")
        gate.release.signal()
        try await drained(registry)
        try LocalAudioRecorder.withInactiveSource(directory: source) {}
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("system.pcm")), bytes)
        let manifest = try LocalAudioRecorder.readManifest(directory: source)
        XCTAssertFalse(manifest.completed)
        XCTAssertGreaterThan(manifest.problem_count, 0)
        XCTAssertEqual(manifest.streams["system"]?.committed_bytes, Int64(bytes.count))
    }

}
