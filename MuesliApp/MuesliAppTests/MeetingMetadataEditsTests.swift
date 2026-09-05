import XCTest

@MainActor
final class MeetingMetadataEditsTests: XCTestCase {
    private static var retainedModels: [TranscriptModel] = []
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        var visits: Int { lock.withLock { count } }
        func first() {
            XCTAssertFalse(Thread.isMainThread)
            if lock.withLock({ count += 1; return count == 1 }) {
                entered.markCompleted(); _ = release.wait(timeout: .now() + 5)
            }
        }
    }
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var source = MeetingSessionMetadata(sessionID: 4, startedAt: Date(timeIntervalSince1970: 1), audioFolder: "audio-session-4", streams: ["mic": .init(sampleRate: 16_000, channels: 1)])
        source.timelineOffsetSeconds = 12; source.durationSeconds = 7; source.artifactsFolder = "assets-source-4"; source.finalizationStatus = "interrupted"
        let metadata = MeetingMetadata(version: 1, title: "Original", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), durationSeconds: 19, lastTimestamp: 15, status: .degraded, sessions: [source], segmentCount: 3, speakerNames: ["untouched": "Prior review"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("meeting.json"))
        return folder
    }
    private func read(_ folder: URL) async throws -> MeetingMetadata {
        try await TranscriptPersistenceStore.shared.start(in: folder) { try $0.readMetadata() }.value()
    }
    private func idle(_ edits: MeetingMetadataEdits, folder: URL) async throws {
        for _ in 0..<200 where edits.isPending(in: folder) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(edits.isPending(in: folder))
    }

    func testNameEditsCoalesceUntilActualSaveAndPreserveSourceMetadata() async throws {
        let folder = try fixture(), gate = Gate(), before = try await read(folder)
        let store = TranscriptPersistenceStore { if $0 == .stage("meeting.json") { gate.first() } }
        var events: [String] = [], committedNames: [[String: String]] = []
        let edits = MeetingMetadataEdits(store: store, timeoutSeconds: 0.03) { event in
            switch event {
            case .committed(_, let metadata, _): events.append("saved"); committedNames.append(metadata.speakerNames)
            case .pending: events.append("pending")
            case .failed: events.append("failed")
            }
        }
        edits.submitNames(["a": "First"], in: folder, contentGeneration: 1)
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        for n in 0..<100 { edits.submitNames(["a": "Final \(n)", "b": "Second"], in: folder, contentGeneration: 1) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(committedNames.count, 0)
        XCTAssertEqual(events, ["pending"])
        XCTAssertEqual(gate.visits, 1)
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in 1 })
        gate.release.signal()
        try await idle(edits, folder: folder)
        XCTAssertEqual(committedNames.count, 2)
        XCTAssertEqual(gate.visits, 2)
        XCTAssertEqual(events.last, "saved", "A late deadline cannot replace terminal UI publication")
        let after = try await read(folder)
        XCTAssertEqual(after.speakerNames, ["a": "Final 99", "b": "Second", "untouched": "Prior review"])
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.durationSeconds, before.durationSeconds)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.title, before.title)
    }

    func testFailureNeverPublishesNameAndOldMetadataRemains() async throws {
        for fail in [TranscriptPersistenceStore.Step.stage("meeting.json"), .replace("meeting.json"), .commitJournal] {
            let folder = try fixture(), before = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))
            var saved = false, failed = false
            let edits = MeetingMetadataEdits(store: TranscriptPersistenceStore { step in
                if step == fail { throw POSIXError(.ENOSPC) }
            }) { event in
                switch event {
                case .committed: saved = true
                case .failed: failed = true
                default: break
                }
            }
            edits.submitNames(["a": "Unsaved"], in: folder, contentGeneration: 1)
            try await idle(edits, folder: folder)
            XCTAssertFalse(saved); XCTAssertTrue(failed)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("meeting.json")), before)
        }
    }

    func testLateNameCommitCannotRenameReopenedOrReplacedSpeakerGeneration() async throws {
        let folder = try fixture(), gate = Gate(), model = TranscriptModel()
        Self.retainedModels.append(model)
        model.ingest(jsonLine: #"{"stream":"mic","speaker_id":"mic:0","source_session_id":"A","t0":0,"t1":1,"text":"First"}"#)
        let key = try XCTUnwrap(model.segments.first?.speakerKey)
        let generation = model.contentGeneration
        let edits = MeetingMetadataEdits(store: TranscriptPersistenceStore {
            if $0 == .stage("meeting.json") { gate.first() }
        }) { event in
            if case .committed(_, _, let patch) = event {
                model.applyCommittedSpeakerNames(patch.names, expectedGeneration: patch.contentGeneration)
            }
        }
        edits.submitNames([key: "Reviewed A"], in: folder, contentGeneration: generation)
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        model.resetForNewMeeting(keepSpeakerNames: false)
        model.ingest(jsonLine: #"{"stream":"mic","speaker_id":"mic:0","source_session_id":"B","t0":0,"t1":1,"text":"Reopened"}"#)
        gate.release.signal()
        try await idle(edits, folder: folder)
        XCTAssertTrue(model.speakerNames.isEmpty)
        let saved = try await read(folder)
        XCTAssertEqual(saved.speakerNames[key], "Reviewed A", "Original accepted edit still completes on its owned source metadata")
    }

    func testRenameTimeoutDoesNotReleaseOrAdmitCompetingEditor() async throws {
        let folder = try fixture(), gate = Gate()
        var titles: [String] = [], pending = false
        let edits = MeetingMetadataEdits(store: TranscriptPersistenceStore {
            if $0 == .stage("meeting.json") { gate.first() }
        }, timeoutSeconds: 0.02) { event in
            if case .committed(_, let metadata, _) = event { titles.append(metadata.title); pending = false }
            if case .pending = event { pending = true }
        }
        let rename = Task { try await edits.rename(in: folder, to: "Late title") }
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        do { _ = try await rename.value; XCTFail("Expected timeout") }
        catch { guard case .timedOut = error as? TranscriptPersistenceStore.Failure else { return XCTFail("Wrong error") } }
        XCTAssertTrue(edits.isPending(in: folder))
        do { _ = try await edits.rename(in: folder, to: "Competing"); XCTFail("Competing edit") }
        catch { }
        gate.release.signal()
        try await idle(edits, folder: folder)
        XCTAssertEqual(titles, ["Late title"])
        XCTAssertFalse(pending)
    }

    func testStopTransfersQueuedNamesAndFencesNewEditsThroughOriginalCompletion() async throws {
        let folder = try fixture(), gate = Gate()
        let edits = MeetingMetadataEdits(store: TranscriptPersistenceStore {
            if $0 == .stage("meeting.json") { gate.first() }
        }, timeoutSeconds: 0.02) { _ in }
        edits.submitNames(["source-A": "Initial"], in: folder, contentGeneration: 1)
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        edits.submitNames(["source-A": "Reviewed A", "source-B": "Reviewed B"], in: folder, contentGeneration: 1)
        let accepted = edits.retire(in: folder)
        XCTAssertEqual(accepted, ["source-A": "Reviewed A", "source-B": "Reviewed B"])
        edits.submitNames(["source-A": "After Stop"], in: folder, contentGeneration: 1)
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in 1 })
        gate.release.signal()
        // The original callback may complete, but only the terminal finalizer
        // can reopen admission. No queued edit starts ahead of that finalizer.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(edits.isPending(in: folder))
        XCTAssertEqual(gate.visits, 1)
        let finalized = try await TranscriptPersistenceStore.shared.start(in: folder) { context in
            var metadata = try context.readMetadata()
            metadata.speakerNames.merge(accepted) { _, latest in latest }
            metadata.status = .completed
            try MeetingCatalogOwner.commit(metadata, context: context)
            return metadata
        }.value()
        XCTAssertEqual(finalized.speakerNames["source-A"], "Reviewed A")
        XCTAssertEqual(finalized.speakerNames["source-B"], "Reviewed B")
        edits.completeRetirement(in: folder)
        try await idle(edits, folder: folder)
    }

    func testSourceScopedAssignmentsNeverMatchAnotherResumedSpeaker() {
        let model = TranscriptModel(); Self.retainedModels.append(model)
        for source in ["A", "B"] {
            model.ingest(jsonLine: "{\"stream\":\"mic\",\"speaker_id\":\"mic:0\",\"source_session_id\":\"\(source)\",\"t0\":0,\"t1\":1,\"text\":\"\(source)\"}")
        }
        XCTAssertTrue(model.speakerNameAssignments(id: "mic:0", name: "Unscoped").isEmpty)
        let first = model.segments[0].speakerKey
        XCTAssertEqual(model.speakerNameAssignments(id: first, name: "Exact"), [first: "Exact"])
        XCTAssertTrue(model.speakerNames.isEmpty, "Building a patch does not optimistically publish it")
    }
}
