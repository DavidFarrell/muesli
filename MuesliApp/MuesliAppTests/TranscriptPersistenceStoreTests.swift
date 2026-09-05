import XCTest

@MainActor
final class TranscriptPersistenceStoreTests: XCTestCase {
    private static var keepAlive: [TranscriptModel] = []
    private func makeModel() -> TranscriptModel {
        let model = TranscriptModel()
        Self.keepAlive.append(model)
        return model
    }
    private func fixture() throws -> (URL, [String: Data], TranscriptReplacement) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let metadata = MeetingMetadata(version: 1, title: "Meeting", createdAt: Date(), updatedAt: Date(), durationSeconds: 600, lastTimestamp: 800, status: .interrupted, sessions: [], segmentCount: 1, speakerNames: ["system:0": "Stale name"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let old: [String: Data] = ["meeting.json": try encoder.encode(metadata), "transcript.txt": Data("old text".utf8), "transcript.jsonl": Data(#"{"speaker_id":"system:0","stream":"system","t0":0,"t1":1,"text":"old text"}"#.utf8)]
        for (name, data) in old { try data.write(to: folder.appendingPathComponent(name)) }
        let result = try JSONDecoder().decode(BatchRediarizer.Result.self, from: Data(#"{"turns":[{"speaker_id":"system:0","stream":"system","source_session_id":"A","t0":0,"t1":2,"text":"Alex"},{"speaker_id":"system:0","stream":"system","source_session_id":"B","t0":5,"t1":7,"text":"Blair"}],"speakers":["system:0"],"duration":8,"sources":[{"source_session_id":"A","audio_folder":"audio","timeline_offset_seconds":0,"duration_seconds":3,"storage_kind":"committed_pcm"},{"source_session_id":"B","audio_folder":"audio_2","timeline_offset_seconds":5,"duration_seconds":3,"storage_kind":"committed_pcm"},{"source_session_id":"silent","audio_folder":"audio_3","timeline_offset_seconds":8,"duration_seconds":3,"storage_kind":"committed_pcm"}]}"#.utf8))
        return (folder, old, try TranscriptReplacement(result: result, metadata: metadata))
    }
    private func assertOld(_ old: [String: Data], in folder: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, data) in old { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data, file: file, line: line) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript_sources.json").path), file: file, line: line)
    }

    func testFinalSavePublicationRejectsLateTimeoutAndOlderFolderCompletion() {
        let folder = URL(fileURLWithPath: "/synthetic-meeting")
        var gate = MeetingSavePublicationGate()
        let first = gate.begin(folder: folder)
        XCTAssertTrue(gate.isPending(folder: folder, id: first))
        XCTAssertTrue(gate.markTerminal(folder: folder, id: first))
        XCTAssertFalse(gate.isPending(folder: folder, id: first), "late timeout cannot restore pending notice")
        let second = gate.begin(folder: folder)
        XCTAssertFalse(gate.markTerminal(folder: folder, id: first), "old completion cannot replace newer metadata")
        XCTAssertTrue(gate.isPending(folder: folder, id: second))
        XCTAssertTrue(gate.markTerminal(folder: folder, id: second))
    }

    func testStopRetainsFinalizationBehindStalledMetadataEditWithoutCompetingOwners() async throws {
        let (folder, _, _) = try fixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = TranscriptPersistenceStore()
        let edit = try store.start(in: folder) { context in
            var metadata = try context.readMetadata()
            metadata.title = "Saved before Stop"
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try context.commit(files: ["meeting.json": encoder.encode(metadata)])
            return true
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let journal = folder.appendingPathComponent("events.jsonl")
        let line = #"{"type":"segment","speaker_id":"system:0","stream":"system","source_session_id":"original","t0":0,"t1":1,"text":"durable final word"}"# + "\n"
        try Data(line.utf8).write(to: journal)
        var status = BackendStdoutStatus(); status.durableBytes = UInt64(line.utf8.count)
        let frozenStatus = status
        let finalization = try store.startAfterCurrent(in: folder) { context in
            try TranscriptReplacement.commitStoppedMeeting(context: context, timestampOffset: 0,
                segments: [], speakerNames: [:], journalURL: journal, journalStatus: frozenStatus,
                sourceManifest: nil, artifactResult: nil, incomplete: true)
        }
        switch await finalization.wait(timeoutSeconds: 0.02) {
        case .timedOut: break
        default: XCTFail("Blocked finalization must retain a pending result")
        }
        XCTAssertThrowsError(try store.start(in: folder) { _ in true })
        XCTAssertThrowsError(try store.startAfterCurrent(in: folder) { _ in true }, "only one terminal intent is retained")
        let cancelledWait = Task { await finalization.wait(timeoutSeconds: 3) }
        cancelledWait.cancel()
        if case .cancelled = await cancelledWait.value {} else { XCTFail("Wait cancellation must be observed") }
        release.signal()
        let saved = try await finalization.value(timeoutSeconds: 3)
        XCTAssertEqual(saved.title, "Saved before Stop")
        XCTAssertEqual(saved.status, .degraded)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8).contains("durable final word"))
        let originalCompleted = try await edit.value(timeoutSeconds: 1)
        XCTAssertTrue(originalCompleted)
        let next = try store.start(in: folder) { _ in true }
        let admitted = try await next.value(timeoutSeconds: 1)
        XCTAssertTrue(admitted)
    }

    func testStoppedFinalizerReplaysOnlyDurableJournalAndCommitsAllFilesTogether() async throws {
        for fail in [false, true] {
            let (folder, old, _) = try fixture()
            let recorder = try LocalAudioRecorder(directory: folder.appendingPathComponent("audio"))
            let source = await recorder.finish(timeoutSeconds: 3)
            let journal = folder.appendingPathComponent("events.jsonl")
            let line = #"{"type":"segment","speaker_id":"system:0","stream":"system","source_session_id":"original","t0":0,"t1":1,"text":"durable word"}"# + "\n"
            try Data((line + #"{"type":"segment","text":"not committed"}"# + "\n").utf8).write(to: journal)
            var status = BackendStdoutStatus()
            status.durableBytes = UInt64(line.utf8.count)
            let frozenStatus = status
            let store = TranscriptPersistenceStore { step in
                if fail && step == .replace("transcript.txt") { throw CocoaError(.fileWriteOutOfSpace) }
            }
            let operation = try store.start(in: folder) { context in
                try TranscriptReplacement.commitStoppedMeeting(context: context, timestampOffset: 30,
                    segments: [], speakerNames: [:], journalURL: journal, journalStatus: frozenStatus,
                    sourceManifest: source, artifactResult: nil, incomplete: false)
            }
            switch await operation.wait(timeoutSeconds: 3) {
            case .completed(let metadata):
                XCTAssertFalse(fail)
                XCTAssertEqual(metadata.status, .degraded, "missing indexed source history must not be certified")
                let text = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
                XCTAssertTrue(text.contains("durable word"))
                XCTAssertTrue(text.contains("t=30.00s"))
                XCTAssertFalse(text.contains("not committed"))
                let json = try String(contentsOf: folder.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
                XCTAssertTrue(json.contains("original"))
            case .failed:
                XCTAssertTrue(fail)
                try assertOld(old, in: folder)
            default: XCTFail("Finalizer did not reach a terminal result")
            }
        }
    }

    func testSuccessfulReplacementPersistsRawProvenanceInventoryAndMetadataBeforePublishing() async throws {
        let (folder, _, replacement) = try fixture()
        let model = makeModel()
        try await model.applyReplacement(replacement, in: folder)
        XCTAssertEqual(model.segments.map(\.sourceSessionID), ["A", "B"])
        XCTAssertEqual(model.segments.map(\.speakerID), ["system:0", "system:0"])
        XCTAssertEqual(Set(model.segments.map(\.speakerKey)).count, 2)
        for (name, data) in replacement.files { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
        XCTAssertEqual(metadata.status, .interrupted, "batch inference cannot certify capture completeness")
        XCTAssertEqual(metadata.segmentCount, 2)
        XCTAssertEqual(metadata.durationSeconds, 11)
        let sources = try decoder.decode([BatchRediarizer.SourceInventory].self, from: Data(contentsOf: folder.appendingPathComponent("transcript_sources.json")))
        XCTAssertEqual(sources.map(\.sourceSessionID), ["A", "B", "silent"])
    }

    func testDiskStagingMetadataRenameAndLateCommitFailureLeaveOldFilesAndUI() async throws {
        for step in [TranscriptPersistenceStore.Step.stage("meeting.json"), .replace("meeting.json"), .replace("transcript.txt"), .commitJournal] {
            let (folder, old, replacement) = try fixture()
            let model = makeModel()
            model.ingest(jsonLine: #"{"speaker_id":"old","stream":"mic","t0":0,"t1":1,"text":"Previous"}"#)
            model.speakerNames = ["old": "Reviewed"]
            let priorID = model.segments[0].id
            let store = TranscriptPersistenceStore { candidate in if candidate == step { throw POSIXError(.ENOSPC) } }
            do {
                try await model.applyReplacement(replacement, in: folder, store: store)
                XCTFail("Expected disk failure")
            } catch { }
            XCTAssertEqual(model.segments[0].id, priorID)
            XCTAssertEqual(model.lastTranscriptText, "Previous")
            XCTAssertEqual(model.speakerNames, ["old": "Reviewed"])
            try assertOld(old, in: folder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName).path))
        }
    }

    func testRollbackFailureRetainsJournalAndNextLoadRecoversEntireOldSnapshot() async throws {
        let (folder, old, replacement) = try fixture()
        let store = TranscriptPersistenceStore { step in
            if step == .replace("transcript.txt") || step == .restore("meeting.json") { throw POSIXError(.EIO) }
        }
        do {
            try await store.start(in: folder) { try $0.commit(files: replacement.files) }.value()
            XCTFail("Expected recovery failure")
        } catch {
            guard case TranscriptPersistenceStore.Failure.recoveryRequired = error else { return XCTFail("Expected explicit recoverable failure") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName).path))
        try await TranscriptPersistenceStore.shared.start(in: folder) { _ in () }.value()
        try assertOld(old, in: folder)
        try await TranscriptPersistenceStore.shared.start(in: folder) { _ in () }.value()
        try await TranscriptPersistenceStore.shared.start(in: folder) { try $0.commit(files: replacement.files) }.value()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcript.txt")), replacement.files["transcript.txt"])
    }

    func testInvalidJSONTimestampFailsBeforeAnyFileCanChange() throws {
        let (folder, old, _) = try fixture()
        let segment = TranscriptSegment(speakerID: "0", stream: "mic", t0: .nan, t1: 2, text: "Bad clock", isPartial: false)
        XCTAssertThrowsError(try TranscriptModel.jsonLines(from: [segment]))
        try assertOld(old, in: folder)
    }
}

nonisolated private final class TranscriptDiskStall: @unchecked Sendable {
    let entered = TaskCompletion()
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func block() {
        lock.withLock { calls += 1 }
        entered.markCompleted()
        release.wait()
    }
}

extension TranscriptPersistenceStoreTests {
    func testStalledSaveLeavesUIResponsiveAndRetainsOwnerUntilRealCompletion() async throws {
        let (folder, _, replacement) = try fixture()
        let (otherFolder, _, _) = try fixture()
        let model = makeModel()
        model.ingest(jsonLine: #"{"speaker_id":"old","stream":"mic","t0":0,"t1":1,"text":"Previous"}"#)
        let stall = TranscriptDiskStall()
        let store = TranscriptPersistenceStore { step in
            if step == .stage("meeting.json") { stall.block() }
        }
        // Safety release makes the test fail, rather than hang, if a regression
        // accidentally puts the disk wait back on MainActor.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { stall.release.signal() }
        let began = Date()
        let save = Task { @MainActor in
            do {
                try await model.applyReplacement(replacement, in: folder, store: store, timeoutSeconds: 0.03)
                XCTFail("Expected a pending outcome")
            } catch {
                guard case TranscriptPersistenceStore.Failure.timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
            }
        }
        let entered = await stall.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        let heartbeat = TaskCompletion()
        Task { @MainActor in heartbeat.markCompleted() }
        let heartbeatResult = await heartbeat.wait(timeoutSeconds: 0.1)
        XCTAssertEqual(heartbeatResult, .completed)
        await save.value
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "UI progress and timeout must not wait for the blocked disk")
        XCTAssertEqual(model.lastTranscriptText, "Previous")
        XCTAssertThrowsError(try store.start(in: folder) { _ in () })
        XCTAssertThrowsError(try store.assertReadable(in: folder))
        // No global I/O lock: an unrelated folder can recover and read now.
        let metadata = try await store.start(in: otherFolder) { try $0.readMetadata() }.value(timeoutSeconds: 0.2)
        XCTAssertEqual(metadata.title, "Meeting")
        let original = try XCTUnwrap(model.pendingReplacement?.operation)
        stall.release.signal()
        _ = try await original.value(timeoutSeconds: 1)
        XCTAssertEqual(model.lastTranscriptText, "Previous", "late disk completion is not optimistic UI completion")
        XCTAssertThrowsError(try model.assertNoPendingReplacement(in: folder), "title/name edits wait for observed completion even after disk ownership ends")
        try await model.applyReplacement(replacement, in: folder, store: store, timeoutSeconds: 1)
        XCTAssertEqual(model.segments.map(\.sourceSessionID), ["A", "B"])
        XCTAssertEqual(stall.count, 1, "retry must observe the original completed owner rather than write again")
        XCTAssertNoThrow(try model.assertNoPendingReplacement(in: folder))
    }

    func testViewerChangeFencesLateSavePublication() async throws {
        let (folder, _, replacement) = try fixture()
        let model = makeModel()
        let stall = TranscriptDiskStall()
        let store = TranscriptPersistenceStore { step in
            if step == .stage("meeting.json") { stall.block() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { stall.release.signal() }
        let save = Task { @MainActor in
            do {
                try await model.applyReplacement(replacement, in: folder, store: store, timeoutSeconds: 2)
                XCTFail("A retired viewer must not receive the result")
            } catch {
                guard case TranscriptPersistenceStore.Failure.superseded = error else { return XCTFail("Expected superseded, got \(error)") }
            }
        }
        let entered = await stall.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        model.resetForNewMeeting(keepSpeakerNames: false)
        model.ingest(jsonLine: #"{"speaker_id":"new","stream":"mic","t0":0,"t1":1,"text":"Different meeting"}"#)
        stall.release.signal()
        await save.value
        XCTAssertEqual(model.lastTranscriptText, "Different meeting")
    }

    func testInterruptedCleanupAfterRollbackOrStagingPreservesReadableCanonicalSnapshot() async throws {
        for trigger in [TranscriptPersistenceStore.Step.replace("transcript.txt"), .stagingPublished] {
            let (folder, old, replacement) = try fixture()
            let store = TranscriptPersistenceStore { step in
                if step == trigger || step == .cleanupResolved { throw POSIXError(.EIO) }
            }
            do {
                try await store.start(in: folder) { try $0.commit(files: replacement.files) }.value()
                XCTFail("Expected interrupted cleanup")
            } catch { }
            let root = folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName)
            let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [String: Any])
            XCTAssertEqual(journal["committed"] as? Bool, true, "restored/untouched canonical files need a durable keep marker before cleanup")
            // Reproduce recursive cleanup deleting a backup, then process death
            // before it deletes the journal. The next owner needs no backup.
            try FileManager.default.removeItem(at: root.appendingPathComponent("old-meeting.json"))
            try await TranscriptPersistenceStore.shared.start(in: folder) { _ in () }.value()
            try assertOld(old, in: folder)
        }
    }

    func testInterruptedRecoveryCleanupAlsoPublishesResolvedMarker() async throws {
        let (folder, old, replacement) = try fixture()
        let failing = TranscriptPersistenceStore { step in
            if step == .replace("transcript.txt") || step == .restore("meeting.json") { throw POSIXError(.EIO) }
        }
        do { try await failing.start(in: folder) { try $0.commit(files: replacement.files) }.value(); XCTFail() }
        catch { }
        let cleanupFailure = TranscriptPersistenceStore { if $0 == .cleanupResolved { throw POSIXError(.EIO) } }
        do { try await cleanupFailure.start(in: folder) { _ in () }.value(); XCTFail() }
        catch { }
        let root = folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName)
        try FileManager.default.removeItem(at: root.appendingPathComponent("old-transcript.txt"))
        try await TranscriptPersistenceStore.shared.start(in: folder) { _ in () }.value()
        try assertOld(old, in: folder)
    }
}

extension TranscriptPersistenceStoreTests {
    func testOwnedCommitAndTerminalCallbackFinishWhileMainActorIsBlocked() async throws {
        let (folder, _, replacement) = try fixture()
        let completion = DispatchSemaphore(value: 0)
        let operation = try TranscriptPersistenceStore.shared.start(in: folder, onCompletion: { _ in completion.signal() }) { context in
            let metadata = try context.readMetadata()
            try context.commit(files: replacement.files)
            return metadata.title
        }
        // Deliberately block the actual UI executor. Both disk work and its
        // terminal callback must complete without hopping back to MainActor.
        XCTAssertEqual(completion.wait(timeout: .now() + 1), .success)
        let title = try await operation.value(timeoutSeconds: 0)
        XCTAssertEqual(title, "Meeting")
    }

    func testRecoveryFailureInvokesTerminalCallbackAndReleasesAdmission() async throws {
        let (folder, _, _) = try fixture()
        let root = folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("invalid journal".utf8).write(to: root.appendingPathComponent("journal.json"))
        let completion = DispatchSemaphore(value: 0)
        let operation = try TranscriptPersistenceStore.shared.start(in: folder, onCompletion: { _ in completion.signal() }) { _ in
            XCTFail("Recovery failure must prevent the operation body")
        }
        XCTAssertEqual(completion.wait(timeout: .now() + 1), .success)
        switch await operation.wait(timeoutSeconds: 0) {
        case .failed: break
        default: XCTFail("Expected recovery failure")
        }
        // A malformed journal requires repair, but must not leak its owner.
        let retry = try TranscriptPersistenceStore.shared.start(in: folder) { _ in () }
        switch await retry.wait(timeoutSeconds: 1) {
        case .failed: break
        default: XCTFail("Expected the same recoverable journal error")
        }
    }
}

extension TranscriptPersistenceStoreTests {
    func testOlderReadSnapshotCannotPublishAfterSameViewerReplacement() async throws {
        let (folder, _, replacement) = try fixture()
        let model = makeModel()
        model.resetForNewMeeting(keepSpeakerNames: false)
        let readGeneration = model.contentGeneration
        // Complete the old disk read, but delay its UI delivery. The save may
        // acquire the now-free folder while this snapshot waits for MainActor.
        let oldSnapshot = try await TranscriptPersistenceStore.shared.start(in: folder) { context in
            (String(decoding: try context.readData(named: "transcript.jsonl"), as: UTF8.self),
             try context.readMetadata().speakerNames)
        }.value()
        try await model.applyReplacement(replacement, in: folder)
        XCTAssertFalse(model.applyLoadedTranscript(content: oldSnapshot.0, names: oldSnapshot.1, expectedGeneration: readGeneration))
        XCTAssertEqual(model.segments.map(\.text), ["Alex", "Blair"])
        XCTAssertTrue(model.speakerNames.isEmpty)
        model.resetForNewMeeting(keepSpeakerNames: false)
        XCTAssertTrue(model.applyLoadedTranscript(content: oldSnapshot.0, names: oldSnapshot.1, expectedGeneration: model.contentGeneration))
        XCTAssertEqual(model.segments.map(\.text), ["old text"])
    }
}
