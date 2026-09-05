import XCTest
import Foundation

final class ArchiveProcessingEvidenceTests: XCTestCase {
    private let sourceID = "ABEA3E61-2D0A-4AE4-9003-EB7953975E6C"
    private let pcmHash = String(repeating: "a", count: 64)
    private let wavHash = String(repeating: "b", count: 64)
    private let manifestHash = String(repeating: "c", count: 64)
    private var expected: [ArchiveProcessingEvidence.Session] {
        [.init(id: sourceID, audioFolder: "audio", offsetUs: 0, manifestSHA256: manifestHash,
               manifestRevision: 2, streams: [
                "mic": .init(pcmBytes: 32_000, pcmSHA256: pcmHash, modelWAVSHA256: wavHash),
                "system": .init(pcmBytes: 0, pcmSHA256: pcmHash, modelWAVSHA256: wavHash)])]
    }
    private func emptyRecovery(_ outcome: String) -> [String: Any] {
        ["outcome": outcome, "planned_window_count": 0, "attempted_window_count": 0, "failed_window_count": 0,
         "empty_window_count": 0, "recovered_window_count": 0, "recovered_word_count": 0,
         "failure_code": NSNull(), "windows": []]
    }
    private func model(frames: Int = 16_000) -> [String: Any] {
        ["format": "wav_pcm_s16le", "sample_rate": 16_000, "channels": 1, "frame_count": frames,
         "byte_count": frames * 2 + 44, "sha256": wavHash]
    }
    private func fixture() -> [String: Any] {
        let entries: [[String: Any]] = ["mic", "system"].map { stream in
            let empty = stream == "system"
            return ["source_session_id": sourceID, "audio_folder": "audio", "stream": stream,
                    "status": empty ? "empty" : "processed", "availability": empty ? "empty" : "present",
                    "source_input": ["relative_path": "audio/\(stream).pcm", "storage_kind": "committed_pcm",
                        "byte_count": empty ? 0 : 32_000, "sha256": pcmHash, "manifest_sha256": manifestHash,
                        "manifest_revision": 2, "committed_bytes": empty ? 0 : 32_000, "session_id": sourceID,
                        "timeline_offset_us": 0, "completed": true, "sample_rate": 16_000, "channels": 1,
                        "frame_count": empty ? 0 : 16_000, "encoding": "PCM_16"],
                    "model_input": empty ? NSNull() : model(), "asr_word_count": empty ? NSNull() : 1,
                    "diarization_segment_count": empty ? NSNull() : 1, "turn_count": empty ? NSNull() : 1,
                    "failure_code": NSNull(), "recovery": emptyRecovery(empty ? "not_run" : "not_needed")]
        }
        return ["type": "result", "duration": 1.0,
                "sources": [["source_session_id": sourceID, "audio_folder": "audio", "timeline_offset_seconds": 0.0,
                             "duration_seconds": 1.0, "storage_kind": "committed_pcm"]],
                "turns": [["source_session_id": sourceID, "stream": "mic", "speaker_id": "mic:SPEAKER_00",
                           "t0": 0.0, "t1": 0.5, "text": "Synthetic fixture"]], "speakers": ["mic:SPEAKER_00"],
                "processing": ["schema_version": 1, "complete": true, "requested_streams": ["system", "mic"],
                               "recovery_requested": true, "entries": entries]]
    }
    private func encoded(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); return data
    }
    private func changeEntry(_ root: inout [String: Any], _ index: Int = 0, _ body: (inout [String: Any]) -> Void) {
        var processing = root["processing"] as! [String: Any]
        var entries = processing["entries"] as! [[String: Any]]
        body(&entries[index]); processing["entries"] = entries; root["processing"] = processing
    }
    private func assertRejected(_ value: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try ArchiveProcessingEvidence.validate(log: encoded(value), observedExitCode: 0, expected: expected), file: file, line: line)
    }
    func testCompleteBothStreamsWithProvenEmptyStream() throws {
        let result = try ArchiveProcessingEvidence.validate(log: encoded(fixture()), observedExitCode: 0, expected: expected)
        XCTAssertEqual(result.sessionCount, 1); XCTAssertEqual(result.streamCount, 2); XCTAssertEqual(result.turnCount, 1)
    }
    func testActualExitErrorEventsDuplicateFinalAndTrailingRecordsRefuse() throws {
        let log = try encoded(fixture())
        XCTAssertThrowsError(try ArchiveProcessingEvidence.validate(log: log, observedExitCode: 2, expected: expected))
        for bad in [log + log, log + Data("{\"type\":\"status\",\"stage\":\"complete\"}\n".utf8),
                    Data("{\"type\":\"error\",\"message\":\"failed\"}\n".utf8) + log,
                    Data("unexpected library stdout\n".utf8) + log, log.dropLast(), Data([0xff, 10])] {
            XCTAssertThrowsError(try ArchiveProcessingEvidence.validate(log: Data(bad), observedExitCode: 0, expected: expected))
        }
    }
    func testMissingOrDuplicateSourceStreamCoverageRefuses() throws {
        for mutation in 0..<3 {
            var value = fixture(), processing = value["processing"] as! [String: Any]
            var entries = processing["entries"] as! [[String: Any]]
            if mutation == 0 { entries.removeLast() }
            if mutation == 1 { entries[1] = entries[0] }
            if mutation == 2 { processing["requested_streams"] = ["mic"] }
            processing["entries"] = entries; value["processing"] = processing
            try assertRejected(value)
        }
    }
    func testChangedPCMManifestRevisionAndActualModelBytesRefuse() throws {
        for field in ["sha256", "manifest_sha256", "manifest_revision", "timeline_offset_us", "committed_bytes"] {
            var value = fixture()
            changeEntry(&value) { entry in
                var input = entry["source_input"] as! [String: Any]
                input[field] = field.contains("sha") ? String(repeating: "d", count: 64) : 3
                entry["source_input"] = input
            }
            try assertRejected(value)
        }
        var value = fixture()
        changeEntry(&value) { entry in
            var input = entry["model_input"] as! [String: Any]; input["sha256"] = pcmHash; entry["model_input"] = input
        }
        try assertRejected(value)
    }
    func testNoTurnsDoesNotMeanEmptyAndRecoveryFailureDoesNotMeanComplete() throws {
        for state in ["processed_without_turns", "empty", "not_requested", "failed"] {
            var value = fixture(); changeEntry(&value) { $0["status"] = state }; try assertRejected(value)
        }
        for state in ["not_run", "partial_failure", "failed", "not_requested"] {
            var value = fixture(); changeEntry(&value) { $0["recovery"] = emptyRecovery(state) }; try assertRejected(value)
        }
        var value = fixture(); changeEntry(&value, 1) { $0["model_input"] = model() }; try assertRejected(value)
    }
    func testTurnCountTimeAndSpeakerInventoryMustMatch() throws {
        var value = fixture(); changeEntry(&value) { $0["turn_count"] = 2 }; try assertRejected(value)
        value = fixture(); value["speakers"] = ["mic:UNKNOWN"]; try assertRejected(value)
        value = fixture()
        var turns = value["turns"] as! [[String: Any]]; turns[0]["t1"] = 2.0; value["turns"] = turns; try assertRejected(value)
        value = fixture(); value["duration"] = 42; try assertRejected(value)
    }
    func testRecoveryWindowRecordsAndTotalsAreChecked() throws {
        var value = fixture()
        var recovery = emptyRecovery("completed")
        recovery["planned_window_count"] = 1; recovery["attempted_window_count"] = 1
        recovery["recovered_window_count"] = 1; recovery["recovered_word_count"] = 1
        recovery["windows"] = [["start_seconds": 0.0, "end_seconds": 0.5, "status": "recovered",
                                "model_input": model(frames: 8000), "asr_word_count": 1,
                                "recovered_word_count": 1, "failure_code": NSNull()]]
        changeEntry(&value) { $0["recovery"] = recovery }
        let expectedHash = wavHash
        XCTAssertNoThrow(try ArchiveProcessingEvidence.validate(log: encoded(value), observedExitCode: 0, expected: expected,
            recoveryInputHash: { _, stream, range in
                XCTAssertEqual(stream, "mic"); XCTAssertEqual(range, 0..<8000)
                return expectedHash
            }))
        try assertRejected(value) // No independent source-range verification.
        recovery["recovered_word_count"] = 2; changeEntry(&value) { $0["recovery"] = recovery }; try assertRejected(value)
        recovery["recovered_word_count"] = 1; recovery["failed_window_count"] = 1
        changeEntry(&value) { $0["recovery"] = recovery }; try assertRejected(value)
    }
    func testUnknownSchemaMissingEvidenceAndOversizedJournalRefuse() throws {
        var value = fixture(), processing = value["processing"] as! [String: Any]
        processing["schema_version"] = 2; value["processing"] = processing; try assertRejected(value)
        value = fixture(); value.removeValue(forKey: "processing"); try assertRejected(value)
        var bytes = Data(repeating: 32, count: 4 * 1024 * 1024 + 1); bytes.append(10)
        XCTAssertThrowsError(try ArchiveProcessingEvidence.validate(log: bytes, observedExitCode: 0, expected: expected))
    }
}
