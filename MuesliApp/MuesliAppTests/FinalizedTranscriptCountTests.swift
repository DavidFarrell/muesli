import Foundation
import XCTest

@MainActor
final class FinalizedTranscriptCountTests: XCTestCase {
    private static var retainedModels: [TranscriptModel] = []

    private func batchFixture() async throws -> (root: URL, folder: URL, jsonl: Data) {
        let root = URL(fileURLWithPath: "/private/tmp/muesli-finalized-count-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recorder = try LocalAudioRecorder(directory: folder.appendingPathComponent("audio"), sessionID: "original-source")
        for source in LocalAudioRecorder.Source.allCases {
            XCTAssertTrue(recorder.record(source: source, ptsUs: 0, payload: Data(repeating: 0, count: 96000)))
        }
        let source = await recorder.finish(timeoutSeconds: 3)
        XCTAssertEqual(source?.completed, true)
        let metadata = MeetingMetadata(version: 1, title: "Meeting", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 3, lastTimestamp: 3, status: .completed,
            sessions: [MeetingSessionMetadata(sessionID: 1, startedAt: Date(), endedAt: Date(),
                audioFolder: "audio", streams: [:], timelineOffsetSeconds: 0, durationSeconds: 3,
                finalizationStatus: "completed", sourceSessionID: "original-source")],
            segmentCount: 0, speakerNames: [:])
        let batch = BatchRediarizer.Result(turns: [
            .init(speakerId: "system:0", stream: "system", t0: 0, t1: 0.8,
                  text: "Discuss the release plan", sourceSessionID: "original-source"),
            .init(speakerId: "mic:0", stream: "mic", t0: 0.1, t1: 0.9,
                  text: "Discuss the release plan", sourceSessionID: "original-source"),
            .init(speakerId: "system:0", stream: "system", t0: 2, t1: 2.8,
                  text: "Confirm next month's budget", sourceSessionID: "original-source"),
            .init(speakerId: "mic:0", stream: "mic", t0: 2.1, t1: 2.9,
                  text: "Confirm next month's budget", sourceSessionID: "original-source")
        ], speakers: ["system:0", "mic:0"], duration: 3)
        // Use the actual batch replacement encoder/transaction. The inference
        // result is generated; no backend, model, native capture or UI is run.
        let replacement = try TranscriptReplacement(result: batch, metadata: metadata)
        XCTAssertEqual(replacement.metadata.segmentCount, 4)
        let save = try TranscriptPersistenceStore.shared.start(in: folder) { context in
            try context.commit(files: replacement.files)
            return true
        }
        _ = try await save.value(timeoutSeconds: 3)
        return (root, folder, try XCTUnwrap(replacement.files["transcript.jsonl"]))
    }

    private func resume(_ folder: URL) async throws -> MeetingStartPreparationOwner.Prepared {
        let owner = MeetingStartPreparationOwner()
        guard case .ready(let prepared) = await owner.prepare(.init(title: "Meeting", resumeFolder: folder), timeoutSeconds: 3) else {
            XCTFail("Actual Resume storage preparation did not finish")
            throw CocoaError(.fileReadUnknown)
        }
        return prepared
    }

    private func assertExport(source: URL, destination: URL, count: Int, jsonl: Data,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let attempt = try TranscriptExportOwner().start(sourceDirectory: source, destinationDirectory: destination)
        guard case .completed(let result) = await attempt.wait(timeoutSeconds: 3) else {
            return XCTFail("Actual export did not complete", file: file, line: line)
        }
        switch result {
        case .failure(let error): XCTFail("Saved transcript must remain exportable: \(error.localizedDescription)", file: file, line: line)
        case .success(let receipt):
            XCTAssertEqual(receipt.segmentCount, count, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("transcript.jsonl")), jsonl, file: file, line: line)
            let text = try String(contentsOf: destination.appendingPathComponent("transcript.txt"), encoding: .utf8)
            XCTAssertEqual(text.split(separator: "\n").count, count, file: file, line: line)
        }
    }

    func testBatchEchoRowsResumeStopAndExportUseExactlyTheCommittedRecordCount() async throws {
        for hasNewFinal in [false, true] {
            let fixture = try await batchFixture(), prepared = try await resume(fixture.folder)
            defer { try? prepared.logHandle.close() }
            XCTAssertEqual(prepared.priorMetadata?.segmentCount, 4)
            XCTAssertEqual(prepared.transcriptData, fixture.jsonl)
            let model = TranscriptModel(); Self.retainedModels.append(model)
            model.resetForNewMeeting(keepSpeakerNames: false)
            model.speakerNames = prepared.priorMetadata?.speakerNames ?? [:]
            // This is the actual Resume load/ingest sequence in AppModel.
            for line in String(decoding: try XCTUnwrap(prepared.transcriptData), as: UTF8.self).split(whereSeparator: \.isNewline) {
                model.ingest(jsonLine: String(line))
            }
            model.timestampOffset = prepared.timestampOffset
            XCTAssertEqual(model.segments.count, 2, "Resume suppresses the two microphone echoes")
            if hasNewFinal {
                XCTAssertTrue(prepared.recorder.record(source: .mic, ptsUs: 0, payload: Data(repeating: 0, count: 32000)))
            }
            let source = await prepared.recorder.finish(timeoutSeconds: 3)
            let newSegment = TranscriptSegment(speakerID: "mic:1", stream: "mic", sourceSessionID: prepared.sourceID,
                t0: 0.1, t1: 0.9, text: "The resumed session adds a decision", isPartial: false)
            let journal = hasNewFinal ? try TranscriptModel.jsonLines(from: [newSegment]) + "\n" : ""
            try Data(journal.utf8).write(to: prepared.eventsURL)
            var status = BackendStdoutStatus(); status.durableBytes = UInt64(journal.utf8.count)
            let frozenStatus = status, initialSegments = model.segments, names = model.speakerNames
            let save = try TranscriptPersistenceStore.shared.startAfterCurrent(in: fixture.folder) { context in
                try TranscriptReplacement.commitStoppedMeeting(context: context,
                    timestampOffset: prepared.timestampOffset, segments: initialSegments, speakerNames: names,
                    journalURL: prepared.eventsURL, journalStatus: frozenStatus, sourceManifest: source,
                    artifactResult: nil, incomplete: false)
            }
            let metadata = try await save.value(timeoutSeconds: 3)
            let saved = try Data(contentsOf: fixture.folder.appendingPathComponent("transcript.jsonl"))
            let expected = hasNewFinal ? 3 : 2
            XCTAssertEqual(String(decoding: saved, as: UTF8.self).split(separator: "\n").count, expected)
            XCTAssertEqual(metadata.segmentCount, expected, "Metadata must describe the records in the same stopped-session transaction")
            let read = try TranscriptPersistenceStore.shared.start(in: fixture.folder) { try $0.readMetadata() }
            let diskMetadata = try await read.value(timeoutSeconds: 3)
            XCTAssertEqual(diskMetadata.segmentCount, expected)
            try await assertExport(source: fixture.folder, destination: fixture.root.appendingPathComponent("Export"), count: expected, jsonl: saved)
        }
    }

    func testMetadataOnlyFailedResumePreservesCountOfUntouchedBatchTranscript() async throws {
        let fixture = try await batchFixture(), prepared = try await resume(fixture.folder)
        defer { try? prepared.logHandle.close() }
        let source = await prepared.recorder.finish(timeoutSeconds: 3)
        // Failed startup uses the same helper but commits metadata only. Empty
        // finalizedSegments here does not mean an empty canonical transcript.
        let save = try TranscriptPersistenceStore.shared.startAfterCurrent(in: fixture.folder) { context in
            let metadata = try context.readMetadata().finalized(segments: [], sourceManifest: source,
                artifactResult: nil, incomplete: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try context.commit(files: ["meeting.json": encoder.encode(metadata)])
            return metadata
        }
        let metadata = try await save.value(timeoutSeconds: 3)
        XCTAssertEqual(metadata.segmentCount, 4)
        XCTAssertEqual(metadata.status, .degraded)
        XCTAssertEqual(try Data(contentsOf: fixture.folder.appendingPathComponent("transcript.jsonl")), fixture.jsonl)
        try await assertExport(source: fixture.folder, destination: fixture.root.appendingPathComponent("Export"), count: 4, jsonl: fixture.jsonl)
    }
}
