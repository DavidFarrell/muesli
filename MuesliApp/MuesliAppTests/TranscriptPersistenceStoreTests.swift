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
        let metadata = MeetingMetadata(version: 1, title: "Meeting", createdAt: Date(), updatedAt: Date(), durationSeconds: 11, lastTimestamp: 8, status: .interrupted, sessions: [], segmentCount: 1, speakerNames: ["system:0": "Stale name"])
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

    func testSuccessfulReplacementPersistsRawProvenanceInventoryAndMetadataBeforePublishing() throws {
        let (folder, _, replacement) = try fixture()
        let model = makeModel()
        try model.applyReplacement(replacement, in: folder)
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

    func testDiskStagingMetadataRenameAndLateCommitFailureLeaveOldFilesAndUI() throws {
        for step in [TranscriptPersistenceStore.Step.stage("meeting.json"), .replace("meeting.json"), .replace("transcript.txt"), .commitJournal] {
            let (folder, old, replacement) = try fixture()
            let model = makeModel()
            model.ingest(jsonLine: #"{"speaker_id":"old","stream":"mic","t0":0,"t1":1,"text":"Previous"}"#)
            model.speakerNames = ["old": "Reviewed"]
            let priorID = model.segments[0].id
            let store = TranscriptPersistenceStore { candidate in if candidate == step { throw POSIXError(.ENOSPC) } }
            XCTAssertThrowsError(try model.applyReplacement(replacement, in: folder, store: store))
            XCTAssertEqual(model.segments[0].id, priorID)
            XCTAssertEqual(model.lastTranscriptText, "Previous")
            XCTAssertEqual(model.speakerNames, ["old": "Reviewed"])
            try assertOld(old, in: folder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName).path))
        }
    }

    func testRollbackFailureRetainsJournalAndNextLoadRecoversEntireOldSnapshot() throws {
        let (folder, old, replacement) = try fixture()
        let store = TranscriptPersistenceStore { step in
            if step == .replace("transcript.txt") || step == .restore("meeting.json") { throw POSIXError(.EIO) }
        }
        XCTAssertThrowsError(try store.commit(files: replacement.files, in: folder)) { error in
            guard case TranscriptPersistenceStore.Failure.recoveryRequired = error else { return XCTFail("Expected explicit recoverable failure") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptPersistenceStore.journalDirectoryName).path))
        try TranscriptPersistenceStore.shared.recover(in: folder)
        try assertOld(old, in: folder)
        try TranscriptPersistenceStore.shared.recover(in: folder)
        try TranscriptPersistenceStore.shared.commit(files: replacement.files, in: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcript.txt")), replacement.files["transcript.txt"])
    }

    func testInvalidJSONTimestampFailsBeforeAnyFileCanChange() throws {
        let (folder, old, _) = try fixture()
        let segment = TranscriptSegment(speakerID: "0", stream: "mic", t0: .nan, t1: 2, text: "Bad clock", isPartial: false)
        XCTAssertThrowsError(try TranscriptModel.jsonLines(from: [segment]))
        try assertOld(old, in: folder)
    }
}
