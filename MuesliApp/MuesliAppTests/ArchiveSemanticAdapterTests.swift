import XCTest
import Foundation
import CryptoKit
import Darwin

final class ArchiveSemanticAdapterTests: XCTestCase {
    private let date = "2026-09-05T12:00:00Z"
    private struct Fixture {
        let root: URL; let source: URL; let vault: URL; let output: URL; let journal: URL; let destination: URL
        let command: [String]
        var config: ArchiveSemanticAdapter.Configuration { .init(backendRoot: root, outputRoot: output, journalRoot: journal) }
        var begin: ArchiveSemanticAdapter.Workflow.Begin { .init(sourcePath: source.path, vaultPath: vault.path) }
        func adapter(checkpoint: (@Sendable (ArchiveSemanticAdapter.Checkpoint) throws -> Void)? = nil,
                     journalCheckpoint: (@Sendable (ArchiveMoveJournal.Checkpoint) throws -> Void)? = nil) -> ArchiveSemanticAdapter {
            ArchiveSemanticAdapter(configuration: config, fixtureRoot: root, fixtureCommand: command,
                fixtureDestination: destination, checkpoint: checkpoint, journalCheckpoint: journalCheckpoint)
        }
    }
    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    private func write(_ root: URL, _ path: String, _ data: Data = Data()) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func json(_ root: URL, _ path: String, _ object: Any) throws {
        try write(root, path, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
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
                let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
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
    private func setup() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/muesli-semantic-test-" + UUID().uuidString)
        try directory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting"), vault = root.appendingPathComponent("vault")
        let output = root.appendingPathComponent("native"), journal = root.appendingPathComponent("journal")
        for path in [folder, vault, output, journal] { try directory(path) }
        try fixture(folder)
        let event = try eventBytes(folder)
        let log = root.appendingPathComponent("synthetic-event.jsonl"); try event.write(to: log)
        return Fixture(root: root, source: folder, vault: vault, output: output, journal: journal,
            destination: root.appendingPathComponent("synthetic-moved"), command: ["/bin/cat", log.path])
    }
    private func eventBytes(_ folder: URL) throws -> Data {
        let source = try ArchiveSourceEligibility.inspect(access: MeetingFileAccess.acquire(in: folder, mode: .archive)).sessions[0]
        let entries: [[String: Any]] = ["mic", "system"].map { name in
            let pcm = source.streams[name]!, model = source.modelInputs[name]!
            return ["source_session_id": source.sourceSessionID, "audio_folder": "audio", "stream": name,
                "status": "processed", "availability": "present", "failure_code": NSNull(),
                "asr_word_count": 1, "diarization_segment_count": 1, "turn_count": 1,
                "source_input": ["relative_path": pcm.path, "storage_kind": "committed_pcm", "byte_count": pcm.bytes,
                    "sha256": pcm.sha256, "manifest_sha256": source.manifest.sha256, "manifest_revision": source.manifestRevision,
                    "committed_bytes": pcm.bytes, "session_id": source.sourceSessionID, "timeline_offset_us": 0,
                    "completed": true, "sample_rate": 16000, "channels": 1, "frame_count": pcm.bytes / 2, "encoding": "PCM_16"],
                "model_input": ["format": "wav_pcm_s16le", "sample_rate": 16000, "channels": 1, "frame_count": pcm.bytes / 2,
                    "byte_count": model.bytes, "sha256": model.sha256],
                "recovery": ["outcome": "not_needed", "planned_window_count": 0, "attempted_window_count": 0,
                    "failed_window_count": 0, "empty_window_count": 0, "recovered_window_count": 0, "recovered_word_count": 0,
                    "failure_code": NSNull(), "windows": []]]
        }
        let event: [String: Any] = ["type": "result", "duration": 0.01, "sources": [["source_session_id": source.sourceSessionID,
            "audio_folder": "audio", "storage_kind": "committed_pcm", "timeline_offset_seconds": 0, "duration_seconds": 0.01]],
            "speakers": ["mic:0", "system:0"],
            "turns": ["mic", "system"].map { ["source_session_id": source.sourceSessionID, "stream": $0,
                "speaker_id": $0 + ":0", "t0": 0, "t1": 0.005, "text": "Synthetic"] },
            "processing": ["schema_version": 1, "complete": true, "requested_streams": ["mic", "system"],
                "recovery_requested": true, "entries": entries]]
        var data = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys); data.append(10); return data
    }
    private func saveReceipt(_ f: Fixture, _ p: ArchiveSemanticAdapter.Prepared) throws -> ArchiveReceipt {
        let raw = Data("Synthetic words.\n".utf8)
        var outputs: [ArchiveReceipt.Output] = []
        func save(_ role: ArchiveReceipt.Output.Role, _ name: String, _ data: Data, note: String? = nil) throws {
            let url = f.vault.appendingPathComponent(name); try data.write(to: url)
            outputs.append(.init(role: role, file: try ArchiveReceipt.readFingerprint(at: url, maximumBytes: 64 * 1024 * 1024), noteID: note))
        }
        try save(.rawNote, "raw.md", raw, note: "one"); try save(.officialNote, "official.md", raw, note: "one")
        try save(.redactionReport, "edits.json", JSONEncoder().encode(ByteEditEvidence(raw: .init(data: raw), official: .init(data: raw), edits: [])), note: "one")
        let id = p.original.source.sessionIDs[0]
        let claims: [[String: Any]] = ["mic", "system"].map { ["source_session_id": id, "stream": $0,
            "speaker_id": $0 + ":0", "name": NSNull(), "basis": "inferred", "evidence": "", "uncertainty": "Identity is unresolved."] }
        try save(.speakerProvenance, "provenance.json", JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "operation_id": p.operationID.uuidString,
            "notes": [["note_id": "one", "source_session_ids": [id]]], "speaker_claims": claims, "images": []]))
        outputs.append(.init(role: .reprocessEvents, file: p.nativeEvents, noteID: nil))
        outputs.append(.init(role: .reprocessDiagnostics, file: p.nativeDiagnostics, noteID: nil))
        let receipt = ArchiveReceipt(schemaVersion: 2, operationID: p.operationID, source: p.original.source, outputs: outputs,
            checks: .init(reprocessExitCode: 0, finalResultCount: 1, errorEventCount: 0, coveredSessionIDs: [id],
                deterministicRedactionsVerified: true, imageLinksVerified: true, sourceIntegrityProblems: []), cleanup: .retained)
        try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: p.bundle.receiptPath))
        return receipt
    }
    private func status(_ outcome: ArchiveSemanticAdapter.Workflow.FinalOutcome) -> String {
        switch outcome { case .needsCorrection: "correction"; case .retained: "retained"; case .trashed: "trashed"; case .uncertain: "uncertain" }
    }
    private nonisolated static func wait(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    private func names(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path) }
    func testActualChildClosureReleasesSourceWhileNativeManifestRemainsAnchored() async throws {
        let f = try setup(), adapter = f.adapter(), id = UUID()
        let prepared = try await adapter.prepare(f.begin, operationID: id)
        let access = try MeetingFileAccess.acquire(in: f.source, mode: .archive)
        XCTAssertEqual(access.identity, prepared.context.original.identity)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: prepared.context.nativeEvents.path)), try Data(contentsOf: f.root.appendingPathComponent("synthetic-event.jsonl")))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: prepared.outputManifestPath))) as? [String: Any])
        XCTAssertEqual(manifest["receipt_path"] as? String, prepared.context.bundle.receiptPath)
        XCTAssertEqual(manifest["vault_path"] as? String, f.vault.path)
        XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
    }
    func testCompletePipelineDurablyPreservesBytesStagesAndMovesOnlyTemporaryFixture() async throws {
        let f = try setup(), adapter = f.adapter(), id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        let outcome = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(outcome), "trashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("audio/mic.pcm").path))
        let journal = try ArchiveMoveJournal.inspect(rootURL: f.journal, sourceIdentity: p.original.identity)
        XCTAssertEqual(journal.phase, .moved); XCTAssertEqual(journal.destination, f.destination.path)
        XCTAssertNotNil(journal.plannedStagingPath)
        let preserved = try XCTUnwrap(journal.validationSnapshot)
        XCTAssertEqual(try ArchiveReceipt.readFingerprint(at: URL(fileURLWithPath: preserved.path), maximumBytes: 8 * 1024 * 1024), preserved)
        let snapshots = try names(URL(fileURLWithPath: p.bundle.directory.path)).filter { $0.hasPrefix("validation-") }
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = URL(fileURLWithPath: p.bundle.directory.path).appendingPathComponent(snapshots[0])
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("output-0000.bin")), Data("Synthetic words.\n".utf8))
        try Data("later editor change".utf8).write(to: f.vault.appendingPathComponent("raw.md"))
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("output-0000.bin")), Data("Synthetic words.\n".utf8))
        let duplicate = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(duplicate), "uncertain")
    }
    func testSourceChangedBetweenNativeChildAndReadmissionCannotPublishProof() async throws {
        let f = try setup(), adapter = f.adapter { if case .afterProcessing = $0 {
            try Data(repeating: 2, count: 320).write(to: f.source.appendingPathComponent("audio/mic.pcm"))
        } }
        do { _ = try await adapter.prepare(f.begin, operationID: UUID()); XCTFail("Changed source must fail") } catch {}
        XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
        let bundles = try names(f.output)
        XCTAssertEqual(bundles.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.appendingPathComponent(bundles[0] + "/native-manifest.json").path))
    }
    func testByteIdenticalSourceReplacementAndAddedEmptyDirectoryPreventFinalize() async throws {
        for replacement in [true, false] {
            let f = try setup(), adapter = f.adapter(), id = UUID()
            let p = try await adapter.prepare(f.begin, operationID: id).context
            _ = try saveReceipt(f, p)
            if replacement {
                let pcm = f.source.appendingPathComponent("audio/mic.pcm"), bytes = try Data(contentsOf: pcm)
                try FileManager.default.moveItem(at: pcm, to: f.root.appendingPathComponent("original-pcm")); try bytes.write(to: pcm)
            } else { try directory(f.source.appendingPathComponent("unindexed-empty")) }
            let outcome = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
            XCTAssertEqual(status(outcome), "correction")
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
            XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
        }
    }
    func testChangedOutputFailsBeforePendingThenCorrectedReceiptCanBeReviewed() async throws {
        let f = try setup(), adapter = f.adapter(), id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        try Data("altered".utf8).write(to: f.vault.appendingPathComponent("official.md"))
        let failed = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(failed), "correction")
        XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
        _ = try saveReceipt(f, p)
        let corrected = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(corrected), "trashed")
    }
    func testPendingSyncFailureIsTerminalEvenWhenSourceDidNotMove() async throws {
        let f = try setup(), adapter = f.adapter(journalCheckpoint: { if case .fileSync = $0 { throw CocoaError(.fileWriteUnknown) } }), id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(result), "uncertain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertThrowsError(try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: f.journal, sourceIdentity: p.original.identity))
        let before = try names(f.journal)
        let duplicate = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(duplicate), "uncertain"); XCTAssertEqual(try names(f.journal), before)
    }
    func testOriginalPathSubstitutionIsCapturedButNeverSentToMover() async throws {
        let f = try setup(), saved = f.root.appendingPathComponent("retained-original")
        let adapter = f.adapter { if case .beforeStagingRename = $0 {
            try FileManager.default.moveItem(at: f.source, to: saved)
            try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: false)
            try Data("foreign-preserved".utf8).write(to: f.source.appendingPathComponent("foreign.txt"))
        } }, id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(result), "uncertain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        let intent = try ArchiveMoveJournal.inspect(rootURL: f.journal, sourceIdentity: p.original.identity)
        let staged = URL(fileURLWithPath: try XCTUnwrap(intent.plannedStagingPath))
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("foreign.txt")), Data("foreign-preserved".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("audio/mic.pcm").path))
    }
    func testChangedStagedSourceCannotReachSyntheticMover() async throws {
        let f = try setup(), adapter = f.adapter { if case .beforeTrash = $0 {
            let stages = try FileManager.default.contentsOfDirectory(atPath: f.root.path).filter { $0.hasPrefix(".muesli-archive-") }
            let path = f.root.appendingPathComponent(stages[0] + "/source/audio/mic.pcm")
            try Data(repeating: 3, count: 320).write(to: path)
        } }, id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(result), "uncertain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
    }
    @MainActor
    func testBlockedNativeStageRetainsWorkflowOwnerAndShutdownTokenWithResponsiveUI() async throws {
        let f = try setup(), reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let adapter = f.adapter { if case .beforeTrash = $0 { reached.signal(); release.wait() } }
        let owner = ArchiveSemanticAdapter.Workflow(acquireWorkToken: { UUID() },
            prepare: { try await adapter.prepare($0, operationID: $1) },
            finalize: { await adapter.finalize($0, receiptPath: $1, operationID: $2) })
        let started = owner.handle(.begin(sourcePath: f.source.path, vaultPath: f.vault.path))
        let id = try XCTUnwrap(started.operationID)
        var ready = started
        for _ in 0..<500 {
            ready = owner.handle(.operation(.status, id: id))
            if ready.state == .awaitingOutputs { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ready.state, .awaitingOutputs)
        // This seam observes the actual preparation returned to the workflow
        // through its immutable manifest, while receipt authority stays native.
        let manifestPath = try XCTUnwrap(ready.outputManifestPath)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath))) as? [String: Any])
        let sourceObject = try JSONSerialization.data(withJSONObject: manifest["source"]!)
        let original = try JSONDecoder().decode(ArchiveSemanticAdapter.Original.self, from: sourceObject)
        let nativeEvents = try JSONDecoder().decode(ArchiveReceipt.FileRecord.self, from: JSONSerialization.data(withJSONObject: manifest["native_events"]!))
        let nativeDiagnostics = try JSONDecoder().decode(ArchiveReceipt.FileRecord.self, from: JSONSerialization.data(withJSONObject: manifest["native_diagnostics"]!))
        // Build model-written receipt directly; never fabricate a Prepared.
        let raw = Data("Synthetic words.\n".utf8)
        var outputs: [ArchiveReceipt.Output] = []
        func output(_ role: ArchiveReceipt.Output.Role, _ leaf: String, _ bytes: Data, _ note: String? = nil) throws {
            let url = f.vault.appendingPathComponent(leaf); try bytes.write(to: url)
            outputs.append(.init(role: role, file: try ArchiveReceipt.readFingerprint(at: url, maximumBytes: 1_000_000), noteID: note))
        }
        try output(.rawNote, "raw.md", raw, "one"); try output(.officialNote, "official.md", raw, "one")
        try output(.redactionReport, "edits.json", JSONEncoder().encode(ByteEditEvidence(raw: .init(data: raw), official: .init(data: raw), edits: [])), "one")
        let claims: [[String: Any]] = ["mic", "system"].map { ["source_session_id": original.source.sessionIDs[0], "stream": $0,
            "speaker_id": $0 + ":0", "name": NSNull(), "basis": "inferred", "evidence": "", "uncertainty": "Unresolved."] }
        try output(.speakerProvenance, "provenance.json", JSONSerialization.data(withJSONObject: ["schema_version": 1, "operation_id": id.uuidString,
            "notes": [["note_id": "one", "source_session_ids": original.source.sessionIDs]], "speaker_claims": claims, "images": []]))
        outputs += [.init(role: .reprocessEvents, file: nativeEvents, noteID: nil), .init(role: .reprocessDiagnostics, file: nativeDiagnostics, noteID: nil)]
        let receipt = ArchiveReceipt(schemaVersion: 2, operationID: id, source: original.source, outputs: outputs,
            checks: .init(reprocessExitCode: 0, finalResultCount: 1, errorEventCount: 0, coveredSessionIDs: original.source.sessionIDs,
                deterministicRedactionsVerified: true, imageLinksVerified: true, sourceIntegrityProblems: []), cleanup: .retained)
        let receiptPath = try XCTUnwrap(manifest["receipt_path"] as? String)
        try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: receiptPath))
        _ = owner.handle(.operation(.finalize, id: id, receiptPath: receiptPath))
        let didReach = await Task.detached { Self.wait(reached) }.value
        defer { release.signal() }
        XCTAssertTrue(didReach)
        XCTAssertEqual(owner.handle(.operation(.status, id: id)).state, .finalizing)
        _ = owner.closeAdmissionForQuit()
        XCTAssertTrue(owner.hasActualWork)
        var heartbeat = false; Task { @MainActor in heartbeat = true }
        await Task.yield(); XCTAssertTrue(heartbeat)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        release.signal()
        for _ in 0..<500 { if !owner.hasActualWork { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(owner.hasActualWork)
    }
    func testPrivateOutputInsideSourceIsRejectedBeforeAnyNativeCreation() async throws {
        let f = try setup(), config = ArchiveSemanticAdapter.Configuration(backendRoot: f.root, outputRoot: f.source, journalRoot: f.journal)
        let adapter = ArchiveSemanticAdapter(configuration: config, fixtureRoot: f.root, fixtureCommand: f.command, fixtureDestination: f.destination)
        let before = try names(f.source)
        do { _ = try await adapter.prepare(f.begin, operationID: UUID()); XCTFail("Source cannot contain native output") } catch {}
        XCTAssertEqual(try names(f.source), before)
        XCTAssertTrue(try names(f.journal).isEmpty)
    }
    func testReplacedJournalRootCannotHideOldIntentOrReceiveNewFiles() async throws {
        let f = try setup(), adapter = f.adapter(), id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        try FileManager.default.moveItem(at: f.journal, to: f.root.appendingPathComponent("original-journal"))
        try directory(f.journal)
        let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(result), "uncertain")
        XCTAssertTrue(try names(f.journal).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
    }
    func testValidationCopyReplacementBeforePendingIsRefusedAndOriginalNotesPreserved() async throws {
        let f = try setup(), adapter = f.adapter { if case .beforePending = $0 {
            let bundle = try FileManager.default.contentsOfDirectory(at: f.output, includingPropertiesForKeys: nil)[0]
            let snapshot = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("validation-") }!
            let file = snapshot.appendingPathComponent("output-0000.bin"), original = snapshot.appendingPathComponent("original-copy")
            let bytes = try Data(contentsOf: file)
            try FileManager.default.moveItem(at: file, to: original); try bytes.write(to: file)
        } }, id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(result), "correction")
        XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
        XCTAssertEqual(try Data(contentsOf: f.vault.appendingPathComponent("raw.md")), Data("Synthetic words.\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
    }
    func testFailedPrependingSnapshotsHaveFiniteAttemptBudgetAndAreNeverSwept() async throws {
        let f = try setup(), adapter = f.adapter { if case .beforePending = $0 { throw CocoaError(.fileWriteUnknown) } }, id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        _ = try saveReceipt(f, p)
        for _ in 0..<3 {
            let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
            XCTAssertEqual(status(result), "correction")
        }
        let snapshots = try names(URL(fileURLWithPath: p.bundle.directory.path)).filter { $0.hasPrefix("validation-") }
        XCTAssertEqual(snapshots.count, 2)
        for snapshot in snapshots {
            XCTAssertTrue(FileManager.default.fileExists(atPath: p.bundle.directory.path + "/" + snapshot + "/snapshot.json"))
        }
        XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
    }
    func testDuplicateKeyReceiptAndReboundNativeLogFailBeforeAnyPendingMarker() async throws {
        let f = try setup(), adapter = f.adapter(), id = UUID()
        let p = try await adapter.prepare(f.begin, operationID: id).context
        let receipt = try saveReceipt(f, p)
        let receiptURL = URL(fileURLWithPath: p.bundle.receiptPath)
        var bytes = try JSONEncoder().encode(receipt)
        bytes.removeFirst(); bytes = Data("{\"schema_version\":2,".utf8) + bytes
        try bytes.write(to: receiptURL)
        let duplicate = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(duplicate), "correction")
        let foreign = f.vault.appendingPathComponent("same-native-events.jsonl")
        try Data(contentsOf: URL(fileURLWithPath: p.nativeEvents.path)).write(to: foreign)
        let outputs = receipt.outputs.map { output -> ArchiveReceipt.Output in
            if output.role != .reprocessEvents { return output }
            return .init(role: output.role, file: .init(path: foreign.path, bytes: output.file.bytes, sha256: output.file.sha256), noteID: nil)
        }
        let rebound = ArchiveReceipt(schemaVersion: 2, operationID: id, source: receipt.source, outputs: outputs, checks: receipt.checks, cleanup: .retained)
        try JSONEncoder().encode(rebound).write(to: receiptURL)
        let result = await adapter.finalize(p, receiptPath: p.bundle.receiptPath, operationID: id)
        XCTAssertEqual(status(result), "correction")
        XCTAssertFalse(try names(f.journal).contains { $0.hasSuffix(".json") })
    }

}
