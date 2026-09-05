import XCTest
import Foundation
import CryptoKit
import Darwin

final class ArchiveSourceEligibilityTests: XCTestCase {
    private let date = "2026-09-05T12:00:00Z"
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/muesli-eligibility-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ root: URL, _ path: String, _ data: Data = Data()) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func json(_ root: URL, _ path: String, _ object: Any) throws {
        try write(root, path, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    private func change(_ root: URL, _ path: String, _ edit: (inout [String: Any]) -> Void) throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String: Any])
        edit(&value); try json(root, path, value)
    }
    private func ledger(_ root: URL, _ source: String, _ edit: (inout [[String: Any]]) -> Void) throws {
        let path = "artifacts/\(source)/assets.jsonl"
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        var records = try data.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        edit(&records)
        var updated = Data()
        for value in records { updated.append(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)); updated.append(10) }
        try write(root, path, updated)
    }
    @discardableResult
    private func fixture(_ root: URL, sessions count: Int = 1, artifacts: Bool = false) throws -> [String] {
        try write(root, ".backend-owner.lock")
        try write(root, ".meeting-transaction.lock")
        var sessions: [[String: Any]] = [], ids: [String] = []
        for index in 1...count {
            let source = UUID().uuidString, audio = index == 1 ? "audio" : "audio-session-\(index)"
            ids.append(source)
            let duration = artifacts ? 0.02 : 0.01, offset = Double(index - 1) * duration
            var session: [String: Any] = ["session_id": index, "source_session_id": source, "audio_folder": audio,
                "started_at": date, "ended_at": date, "timeline_offset_seconds": offset,
                "duration_seconds": duration, "finalization_status": "completed",
                "streams": ["mic": ["sample_rate": 16000, "channels": 1], "system": ["sample_rate": 16000, "channels": 1]]]
            try write(root, audio + "/.capture-owner.lock"); try write(root, audio + "/transcript_events.jsonl")
            try write(root, audio + "/backend.log")
            for stream in ["mic", "system"] { try write(root, audio + "/\(stream).pcm", Data(repeating: 1, count: 320)) }
            let state: [String: Any] = ["sample_rate": 16000, "channels": 1, "committed_bytes": 320,
                "captured_frames": 160, "gap_frames": 0, "overlap_frames": 0, "dropped_frames": 0]
            try json(root, audio + "/source-recording.json", ["schema_version": 1, "session_id": source,
                "timeline_offset_us": Int64((offset * 1_000_000).rounded()), "committed_at": 1, "revision": 1,
                "completed": true, "streams": ["mic": state, "system": state], "problem_count": 0,
                "losses": [], "loss_details_omitted": 0])
            if artifacts {
                let base = "artifacts/\(source)", screenshot = base + "/screenshots/\(UUID().uuidString).png"
                let video = base + "/video/\(UUID().uuidString).mp4"
                let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4d8AAAAASUVORK5CYII=")!
                try write(root, screenshot, png); try write(root, video, Data("synthetic SDK-finished video".utf8))
                try write(root, base + "/.artifact-owner.lock")
                let records: [[String: Any]] = [
                    ["type": "session", "source_session_id": source, "timeline_offset_us": Int64((offset * 1_000_000).rounded())],
                    ["type": "video", "source_session_id": source, "status": "requested", "path": video, "requested_t": offset],
                    ["type": "screenshot", "source_session_id": source, "path": screenshot, "t": offset + 0.005],
                    ["type": "capture_stopped", "source_session_id": source, "t": offset + duration],
                    ["type": "video", "source_session_id": source, "status": "finished", "path": video,
                     "requested_t": offset, "duration_seconds": 0.015, "file_size": 28]]
                var lines = Data()
                for record in records { lines.append(try JSONSerialization.data(withJSONObject: record)); lines.append(10) }
                try write(root, base + "/assets.jsonl", lines)
                session["artifacts_folder"] = base
                session["artifact_finalization"] = ["outcome": "completed", "source_session_id": source, "pending_videos": 0,
                    "finished_videos": 1, "committed_screenshots": 1, "media_end_seconds": offset + 0.005,
                    "capture_end_seconds": offset + duration, "closed": true]
            }
            sessions.append(session)
        }
        try json(root, "meeting.json", ["version": 1, "title": "Synthetic", "created_at": date, "updated_at": date,
            "duration_seconds": Double(count) * (artifacts ? 0.02 : 0.01), "last_timestamp": 0,
            "status": "completed", "sessions": sessions, "segment_count": 0, "speaker_names": [:]])
        return ids
    }
    private func inspect(_ root: URL) throws -> ArchiveSourceEligibility.VerifiedSource {
        try ArchiveSourceEligibility.inspect(access: MeetingFileAccess.acquire(in: root, mode: .archive))
    }
    private func rejected(_ root: URL, contains: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try inspect(root), file: file, line: line) { error in
            if let contains { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription, file: file, line: line) }
        }
    }

    func testCompleteAudioOnlyAndResumedArtifactSourcesRemainDistinct() throws {
        for artifacts in [false, true] {
            let root = try folder(), ids = try fixture(root, sessions: 2, artifacts: artifacts)
            let result = try inspect(root)
            XCTAssertEqual(result.sessions.map(\.sourceSessionID), ids)
            XCTAssertEqual(result.sessions.map(\.audioFolder), ["audio", "audio-session-2"])
            XCTAssertTrue(result.inventory.files.contains { $0.path == ".backend-owner.lock" })
            XCTAssertEqual(result.inventory.canonicalFolderURL.path, root.path)
        }
    }
    func testRealRecorderWAVsMatchAndChangedCopyIsRefused() async throws {
        let root = try folder(), id = try fixture(root)[0]
        try FileManager.default.removeItem(at: root.appendingPathComponent("audio"))
        var recorder: LocalAudioRecorder? = try LocalAudioRecorder(directory: root.appendingPathComponent("audio"), sessionID: id)
        for stream in [LocalAudioRecorder.Source.mic, .system] {
            XCTAssertTrue(recorder!.record(source: stream, ptsUs: 0, payload: Data(repeating: 1, count: 320)))
        }
        let manifest = await recorder!.finish(timeoutSeconds: 5)
        XCTAssertEqual(manifest?.completed, true); recorder = nil
        try write(root, "audio/transcript_events.jsonl")
        var result: ArchiveSourceEligibility.VerifiedSource? = try inspect(root)
        let actualWAV = try Data(contentsOf: root.appendingPathComponent("audio/mic.wav"))
        XCTAssertEqual(result?.sessions[0].modelInputs["mic"]?.sha256,
                       SHA256.hash(data: actualWAV).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(result?.sessions[0].manifestRevision, manifest?.revision)
        result = nil
        let wav = root.appendingPathComponent("audio/mic.wav")
        var bytes = try Data(contentsOf: wav); bytes[bytes.count - 1] ^= 1; try bytes.write(to: wav)
        rejected(root, contains: "compatibility WAV")
    }
    func testInitialAlignmentIsExplicitReviewWithoutLostSpeechClaim() throws {
        let root = try folder(); try fixture(root)
        try change(root, "audio/source-recording.json") { $0["losses"] = [["source": "mic", "reason": "initial_source_alignment", "frames": 1]] }
        rejected(root, contains: "alignment requires review")
    }
    func testEveryLossCounterAndIncompleteManifestRefuseCompletedMetadata() throws {
        for key in ["problem_count", "loss_details_omitted", "last_problem", "losses", "completed", "revision"] {
            let root = try folder(); try fixture(root)
            try change(root, "audio/source-recording.json") {
                switch key {
                case "last_problem": $0[key] = "failure"
                case "losses": $0[key] = [["source": "system", "reason": "drop", "frames": 1]]
                case "completed": $0[key] = false
                case "revision": $0[key] = 0
                default: $0[key] = 1
                }
            }
            rejected(root)
        }
        for key in ["gap_frames", "overlap_frames", "dropped_frames", "captured_frames", "sample_rate", "channels", "committed_bytes"] {
            let root = try folder(); try fixture(root)
            try change(root, "audio/source-recording.json") {
                var streams = $0["streams"] as! [String: [String: Any]]; streams["mic"]![key] = key == "channels" ? 2 : 1; $0["streams"] = streams
            }
            rejected(root)
        }
    }
    func testTruncatedMissingAndUncommittedPCMRefuse() throws {
        for size in [-1, 318, 322] {
            let root = try folder(); try fixture(root)
            if size < 0 { try FileManager.default.removeItem(at: root.appendingPathComponent("audio/system.pcm")) }
            else { try write(root, "audio/system.pcm", Data(repeating: 1, count: size)) }
            rejected(root)
        }
    }
    func testDuplicateForeignLegacyAndMismatchedSessionIdentityRefuse() throws {
        for kind in ["duplicate_index", "duplicate_uuid", "legacy_uuid", "foreign_manifest", "offset", "duration", "outcome", "stream"] {
            let root = try folder(); try fixture(root, sessions: 2)
            if kind == "foreign_manifest" {
                try change(root, "audio/source-recording.json") { $0["session_id"] = UUID().uuidString }
            } else {
                try change(root, "meeting.json") {
                    var sessions = $0["sessions"] as! [[String: Any]]
                    switch kind {
                    case "duplicate_index": sessions[1]["session_id"] = 1
                    case "duplicate_uuid": sessions[1]["source_session_id"] = sessions[0]["source_session_id"]
                    case "legacy_uuid": sessions[0].removeValue(forKey: "source_session_id")
                    case "offset": sessions[1]["timeline_offset_seconds"] = 0
                    case "duration": sessions[1]["duration_seconds"] = 0.03
                    case "outcome": sessions[0]["finalization_status"] = "unknown"
                    default: sessions[0]["streams"] = ["mic": ["sample_rate": 16000, "channels": 1]]
                    }
                    $0["sessions"] = sessions
                }
            }
            rejected(root)
        }
    }
    func testUnindexedEmptyDirectoriesAndUncommittedMaterialRefuse() throws {
        for path in ["audio-session-9", "artifacts/unindexed-empty", "audio/orphan-empty", "attachments", "screenshots", "unknown"] {
            let root = try folder(); try fixture(root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            rejected(root, contains: "Unindexed")
        }
        for path in ["audio/leftover.tmp", "audio/mystery.pcm", "unindexed.wav"] {
            let root = try folder(); try fixture(root); try write(root, path)
            rejected(root, contains: "Unindexed")
        }
    }
    func testLedgerFailurePendingDuplicateForeignUnknownAndMissingClosureRefuse() throws {
        for kind in ["failed", "pending", "duplicate", "foreign", "unknown", "no_stop", "wrong_stop", "size", "missing", "duration", "count", "header_offset"] {
            let root = try folder(), id = try fixture(root, artifacts: true)[0]
            try ledger(root, id) {
                switch kind {
                case "failed": $0[4]["status"] = "failed"
                case "pending": $0.removeLast()
                case "duplicate": $0.append($0[4])
                case "foreign": $0[2]["source_session_id"] = UUID().uuidString
                case "unknown": $0.append(["type": "unknown", "source_session_id": id])
                case "no_stop": $0.remove(at: 3)
                case "wrong_stop": $0[3]["t"] = 0.5
                case "size": $0[4]["file_size"] = 29
                case "missing": $0[2]["path"] = "artifacts/\(id)/screenshots/\(UUID().uuidString).png"
                case "duration": $0[4].removeValue(forKey: "duration_seconds")
                case "count": $0.remove(at: 2)
                default: $0[0]["timeline_offset_us"] = 1
                }
            }
            rejected(root)
        }
    }
    func testArtifactTornTailEmptyOrphanAndTerminalMetadataLieRefuse() throws {
        for kind in ["tail", "empty", "orphan", "closed", "outcome"] {
            let root = try folder(), id = try fixture(root, artifacts: true)[0]
            switch kind {
            case "tail":
                let url = root.appendingPathComponent("artifacts/\(id)/assets.jsonl")
                var bytes = try Data(contentsOf: url); bytes.removeLast(); try bytes.write(to: url)
            case "empty": try write(root, "artifacts/\(id)/assets.jsonl")
            case "orphan": try write(root, "artifacts/\(id)/screenshots/\(UUID().uuidString).png", Data([1]))
            default:
                try change(root, "meeting.json") {
                    var sessions = $0["sessions"] as! [[String: Any]], final = sessions[0]["artifact_finalization"] as! [String: Any]
                    if kind == "closed" { final["closed"] = false } else { final["outcome"] = "timed_out" }
                    sessions[0]["artifact_finalization"] = final; $0["sessions"] = sessions
                }
            }
            rejected(root)
        }
    }
    func testModernAttachmentHashAndSourceBoundWhileLegacyIsRetained() throws {
        let root = try folder(), source = try fixture(root)[0], id = UUID(), content = Data("synthetic note".utf8)
        let name = "attachment-\(id.uuidString).txt"
        try write(root, "attachments/" + name, content)
        let item = Attachment(id: id, type: .text, timestamp: 0.005, filename: name,
            sourceSessionID: source, byteCount: content.count, sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try write(root, "attachments.json", encoder.encode(AttachmentsManifest(attachments: [item])))
        XCTAssertNoThrow(try inspect(root))
        try write(root, "attachments/" + name, Data("mutated note!!".utf8)); rejected(root, contains: "attachment")
        try write(root, "attachments/" + name, content)
        try json(root, "attachments.json", ["attachments": [["id": id.uuidString, "type": "text", "timestamp": 0.005, "filename": name, "createdAt": date]]])
        rejected(root, contains: "Legacy")
    }
    func testEveryExistingSecondaryLeaseBlocksAndMissingLeaseRetains() throws {
        let root = try folder(), id = try fixture(root, artifacts: true)[0]
        for path in [".backend-owner.lock", ".meeting-transaction.lock", "audio/.capture-owner.lock", "audio/transcript_events.jsonl", "artifacts/\(id)/.artifact-owner.lock"] {
            let fd = open(root.appendingPathComponent(path).path, O_RDONLY)
            XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            rejected(root, contains: "still active")
            Darwin.close(fd)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("audio/.capture-owner.lock"))
        rejected(root, contains: "ownership evidence is missing")
    }
    func testUnindexedOwnersAreAcquiredBeforeInventoryOrSemanticRefusal() throws {
        let root = try folder(); try fixture(root)
        try write(root, "audio-session-99/.capture-owner.lock")
        let fd = open(root.appendingPathComponent("audio-session-99/.capture-owner.lock").path, O_RDONLY)
        defer { Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        rejected(root, contains: "still active")
    }
    func testMissingIndexedScreenshotOrVideoIsNotCoveredByCompletedLedger() throws {
        for suffix in [".png", ".mp4"] {
            let root = try folder(); try fixture(root, artifacts: true)
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            let asset = try XCTUnwrap(enumerator.allObjects.compactMap { $0 as? URL }.first { $0.path.hasSuffix(suffix) })
            try FileManager.default.removeItem(at: asset)
            rejected(root, contains: "material is missing")
        }
    }
    func testMillionsOfEmptyLedgerLinesRefuseWithoutMaterializingLineArray() throws {
        let root = try folder(), id = try fixture(root, artifacts: true)[0]
        try write(root, "artifacts/\(id)/assets.jsonl", Data(repeating: 10, count: 1024 * 1024))
        rejected(root, contains: "empty record")
    }
    func testResultRetainsOuterAndSecondaryOwnersUntilActualRelease() throws {
        let root = try folder(); try fixture(root)
        var result: ArchiveSourceEligibility.VerifiedSource? = try inspect(root)
        XCTAssertNotNil(result)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: root))
        let fd = open(root.appendingPathComponent("audio/transcript_events.jsonl").path, O_RDONLY)
        defer { Darwin.close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        result = nil
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: root)); XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testChangedLeaseAndTopologyAfterAdmissionRefuse() throws {
        for path in ["audio/.capture-owner.lock", "audio/unindexed"] {
            let root = try folder(); try fixture(root)
            let access = try MeetingFileAccess.acquire(in: root, mode: .archive)
            XCTAssertThrowsError(try ArchiveSourceEligibility.inspect(access: access, beforeInventory: {
                try Data("new".utf8).write(to: root.appendingPathComponent(path), options: .atomic)
            }))
        }
    }
    func testFreshSemanticBytesCannotBeSubstitutedAfterInventory() throws {
        let root = try folder(); try fixture(root)
        let access = try MeetingFileAccess.acquire(in: root, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceEligibility.inspect(access: access, beforeSemanticRead: {
            let url = root.appendingPathComponent("meeting.json")
            var bytes = try Data(contentsOf: url); bytes.append(32); try bytes.write(to: url)
        })) { error in XCTAssertTrue(error.localizedDescription.contains("changed after inventory")) }
    }
    func testAncestorAndRootReplacementDuringInspectionRefuse() throws {
        for rootSwap in [false, true] {
            let parent = try folder(), root = parent.appendingPathComponent("meeting"), other = parent.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try fixture(root)
            let access = try MeetingFileAccess.acquire(in: root, mode: .archive)
            XCTAssertThrowsError(try ArchiveSourceEligibility.inspect(access: access, beforeSemanticRead: {
                if rootSwap {
                    try FileManager.default.moveItem(at: root, to: other)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                } else {
                    try FileManager.default.moveItem(at: root.appendingPathComponent("audio"), to: other)
                    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("audio"), withDestinationURL: other)
                }
            }))
        }
    }
    func testRecoveryTransactionIsNeverRepairedIncludingCaseAlias() throws {
        let root = try folder(); try fixture(root)
        try write(root, ".TRANSCRIPT-TRANSACTION/journal.json", Data("unresolved".utf8))
        rejected(root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".TRANSCRIPT-TRANSACTION/journal.json")), Data("unresolved".utf8))
    }
    func testDuplicateEscapedKeysAndReadBudgetsRefuse() throws {
        let root = try folder(); try fixture(root)
        let url = root.appendingPathComponent("audio/source-recording.json")
        let data = try Data(contentsOf: url)
        var duplicate = Data("{\"completed\":false,\"co\\u006dpleted\":true,".utf8); duplicate.append(data.dropFirst())
        try duplicate.write(to: url); rejected(root, contains: "ambiguous")
        try data.write(to: url)
        try write(root, "meeting.json", Data(repeating: 32, count: 4 * 1024 * 1024 + 1))
        rejected(root, contains: "read limit")
    }
    func testPowerEvidenceCannotBeHiddenByCompletedAndHealthyCounters() throws {
        for key in ["power_events", "power_events_omitted"] {
            let root = try folder(); try fixture(root)
            try change(root, "audio/source-recording.json") {
                if key == "power_events" { $0[key] = [["kind": "did_wake", "process_continuous_us": 1000]] }
                else { $0[key] = 1 }
            }
            rejected(root, contains: "power interruption")
        }
    }
    func testCombinedSemanticBudgetIsNotResetPerSession() throws {
        let root = try folder(); try fixture(root, sessions: 2)
        let access = try MeetingFileAccess.acquire(in: root, mode: .archive)
        let metadata = try Data(contentsOf: root.appendingPathComponent("meeting.json")).count
        let first = try Data(contentsOf: root.appendingPathComponent("audio/source-recording.json")).count
        XCTAssertThrowsError(try ArchiveSourceEligibility.inspect(access: access, semanticByteLimit: Int64(metadata + first))) {
            XCTAssertTrue($0.localizedDescription.contains("combined semantic"))
        }
    }
    func testDerivedModelInputsRemainAvailableWhenWAVsAreAbsent() throws {
        let root = try folder(); try fixture(root)
        let result = try inspect(root)
        XCTAssertEqual(result.sessions[0].modelInputs["mic"]?.bytes, 364)
        XCTAssertEqual(result.sessions[0].modelInputs["mic"], result.sessions[0].modelInputs["system"])
        XCTAssertEqual(result.sessions[0].manifest.path, "audio/source-recording.json")
        XCTAssertFalse(result.inventory.files.contains { $0.path.hasSuffix(".wav") })
    }
    func testChangedCompatibilityWAVIsRefusedIndependentlyOfPCM() throws {
        let root = try folder(); try fixture(root)
        try write(root, "audio/mic.wav", Data(repeating: 1, count: 364))
        rejected(root, contains: "compatibility WAV")
    }
    @MainActor
    func testActualInspectionWorkerKeepsLeasesWhileUIWaitExpires() throws {
        let root = try folder(); try fixture(root)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var result: ArchiveSourceEligibility.VerifiedSource?
            var error: String?
        }
        let box = Box()
        DispatchQueue.global().async {
            do {
                let value = try ArchiveSourceEligibility.inspect(access: MeetingFileAccess.acquire(in: root, mode: .archive), beforeSemanticRead: {
                    entered.signal(); resume.wait()
                })
                box.lock.withLock { box.result = value }
            } catch { box.lock.withLock { box.error = error.localizedDescription } }
            returned.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(returned.wait(timeout: .now() + 0.02), .timedOut)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: root))
        let fd = open(root.appendingPathComponent("audio/transcript_events.jsonl").path, O_RDONLY)
        defer { Darwin.close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        resume.signal()
        XCTAssertEqual(returned.wait(timeout: .now() + 3), .success)
        XCTAssertNil(box.lock.withLock { box.error })
        XCTAssertNotNil(box.lock.withLock { box.result })
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        box.lock.withLock { box.result = nil }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: root))
    }
}
