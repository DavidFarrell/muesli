import XCTest
import Foundation
import Darwin

@MainActor
final class BatchSourceSnapshotTests: XCTestCase {
    private static var models: [TranscriptModel] = []
    private func model() -> TranscriptModel {
        let value = TranscriptModel(); Self.models.append(value); return value
    }
    private func fixture(legacy: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batch-source-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio")
        try Self.writeSource(audio, id: "source-a", offset: 0)
        if legacy {
            _ = try LocalAudioRecorder.recoverWAVs(directory: audio)
            try FileManager.default.removeItem(at: audio.appendingPathComponent(LocalAudioRecorder.manifestName))
            for name in ["mic", "system"] { try FileManager.default.removeItem(at: audio.appendingPathComponent(name + ".pcm")) }
        }
        var session = MeetingSessionMetadata(sessionID: 1, startedAt: Date(timeIntervalSince1970: 100),
            audioFolder: "audio", streams: [:])
        session.sourceSessionID = legacy ? nil : "source-a"
        let metadata = MeetingMetadata(version: 1, title: "Original", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 4, lastTimestamp: 3, status: .interrupted, sessions: [session],
            segmentCount: 1, speakerNames: ["mic:0": "Reviewed person"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("meeting.json"))
        try Data("old transcript\n".utf8).write(to: folder.appendingPathComponent("transcript.txt"))
        try Data(#"{"speaker_id":"mic:0","stream":"mic","t0":0,"t1":1,"text":"old transcript"}"#.utf8)
            .write(to: folder.appendingPathComponent("transcript.jsonl"))
        return folder
    }
    nonisolated private static func writeSource(_ audio: URL, id: String, offset: Int64) throws {
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let mic = LocalAudioRecorder.StreamState(committed_bytes: 64_000)
        let system = LocalAudioRecorder.StreamState(committed_bytes: 128_000)
        let manifest = LocalAudioRecorder.Manifest(session_id: id, timeline_offset_us: offset,
            completed: true, streams: ["mic": mic, "system": system])
        try JSONEncoder().encode(manifest).write(to: audio.appendingPathComponent(LocalAudioRecorder.manifestName))
        try Data(repeating: 0, count: 64_000).write(to: audio.appendingPathComponent("mic.pcm"))
        try Data(repeating: 0, count: 128_000).write(to: audio.appendingPathComponent("system.pcm"))
    }
    private func snapshot(_ folder: URL, stream: BatchRediarizer.Stream = .both) async throws -> BatchSourceSnapshot {
        let operation = try TranscriptPersistenceStore.shared.start(in: folder) {
            try BatchSourceSnapshot.capture(context: $0, stream: stream)
        }
        return try await operation.value(timeoutSeconds: 3)
    }
    private func result(_ snapshot: BatchSourceSnapshot, legacy: Bool = false) throws -> BatchRediarizer.Result {
        let source = snapshot.sources[0].inventory
        let turn = BatchRediarizer.Turn(speakerId: "mic:new", stream: "mic", t0: source.timelineOffsetSeconds,
            t1: source.timelineOffsetSeconds + 1, text: "new transcript", sourceSessionID: legacy ? nil : source.sourceSessionID)
        let value = BatchRediarizer.Result(turns: [turn], speakers: ["mic:new"],
            duration: snapshot.sources.map { $0.inventory.timelineOffsetSeconds + $0.inventory.durationSeconds }.max()!,
            sources: legacy ? nil : snapshot.sources.map(\.inventory))
        return try snapshot.validatedResult(value)
    }
    private func edit(_ folder: URL, _ mutate: @escaping @Sendable (inout MeetingMetadata) throws -> Void) async throws {
        let operation = try TranscriptPersistenceStore.shared.start(in: folder) { context in
            var metadata = try context.readMetadata(); try mutate(&metadata)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try context.commit(files: ["meeting.json": encoder.encode(metadata)])
            return true
        }
        _ = try await operation.value(timeoutSeconds: 3)
    }
    private func assertRejected(_ result: BatchRediarizer.Result, folder: URL,
                                contains: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let names = ["meeting.json", "transcript.jsonl", "transcript.txt"]
        let original = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        do {
            _ = try await model().applyBatchResult(result, requestID: UUID(), in: folder)
            XCTFail("stale or unverified result was saved", file: file, line: line)
        } catch { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription, file: file, line: line) }
        for (name, bytes) in zip(names, original) {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bytes, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript_sources.json").path))
    }

    func testResumedAndClosedNewSessionRejectsEarlierBatchWithoutCanonicalChanges() async throws {
        let folder = try fixture(), captured = try await snapshot(folder)
        let value = try result(captured)
        try await edit(folder) { metadata in
            try Self.writeSource(folder.appendingPathComponent("audio-session-2"), id: "source-b", offset: 4_000_000)
            var next = MeetingSessionMetadata(sessionID: 2, startedAt: Date(), audioFolder: "audio-session-2", streams: [:])
            next.sourceSessionID = "source-b"
            metadata.sessions.append(next); metadata.durationSeconds = 8
        }
        try await assertRejected(value, folder: folder, contains: "source audio or sessions changed")
    }
    func testFreshTitlePreservedAndOriginalNamesClearOnlyOnSuccessfulReplacement() async throws {
        let folder = try fixture(), value = try result(await snapshot(folder))
        try await edit(folder) { $0.title = "New title" }
        let replacement = try await model().applyBatchResult(value, requestID: UUID(), in: folder)
        XCTAssertEqual(replacement.metadata.title, "New title")
        XCTAssertTrue(replacement.metadata.speakerNames.isEmpty)
        XCTAssertEqual(replacement.metadata.status, .interrupted)
        XCTAssertEqual(replacement.segments.first?.sourceSessionID, "source-a")
    }
    func testReprocessDoesNotShortenVerifiedCaptureOrVideoExtent() async throws {
        let folder = try fixture(), value = try result(await snapshot(folder))
        try await edit(folder) { metadata in
            let data = Data(#"{"outcome":"completed","source_session_id":"source-a","pending_videos":0,"finished_videos":1,"committed_screenshots":1,"media_end_seconds":9,"capture_end_seconds":10,"closed":true}"#.utf8)
            metadata.sessions[0].artifactFinalization = try JSONDecoder().decode(MeetingArtifactFinalization.self, from: data)
            metadata.durationSeconds = 10
        }
        let replacement = try await model().applyBatchResult(value, requestID: UUID(), in: folder)
        XCTAssertEqual(replacement.metadata.durationSeconds, 10)
        XCTAssertEqual(replacement.metadata.sessions[0].artifactFinalization?.captureEndSeconds, 10)
    }
    func testReviewedNameEditRejectsWithoutErasingOrRebindingIt() async throws {
        let folder = try fixture(), value = try result(await snapshot(folder))
        try await edit(folder) { $0.speakerNames["mic:0"] = "Newly reviewed person" }
        try await assertRejected(value, folder: folder, contains: "Speaker names changed")
    }
    func testPCMContentChangeAndCommittedBoundaryChangeEachReject() async throws {
        for boundary in [false, true] {
            let folder = try fixture(), value = try result(await snapshot(folder))
            let change = try TranscriptPersistenceStore.shared.start(in: folder) { _ in
                let audio = folder.appendingPathComponent("audio")
                if boundary {
                    var manifest = try LocalAudioRecorder.readManifest(directory: audio)
                    manifest.streams["mic"]!.committed_bytes = 32_000
                    try JSONEncoder().encode(manifest).write(to: audio.appendingPathComponent(LocalAudioRecorder.manifestName))
                } else {
                    let handle = try FileHandle(forWritingTo: audio.appendingPathComponent("mic.pcm"))
                    try handle.write(contentsOf: Data([1, 2])); try handle.close()
                }
                return true
            }
            _ = try await change.value(timeoutSeconds: 3)
            try await assertRejected(value, folder: folder, contains: "source audio or sessions changed")
        }
    }
    func testActiveSourceLeaseAndRecordingStatusRejectEvenUnchangedPrefix() async throws {
        let folder = try fixture(), value = try result(await snapshot(folder))
        let descriptor = open(folder.appendingPathComponent("audio/.capture-owner.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0); XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { Darwin.close(descriptor) }
        try await assertRejected(value, folder: folder, contains: "still being saved")
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try await edit(folder) { $0.status = .recording }
        try await assertRejected(value, folder: folder, contains: "Stop this meeting")
    }
    func testSingleLegacyResultGetsExplicitSourceScopeAndMissingInventoryCannotAuthorizePCM() async throws {
        let folder = try fixture(legacy: true), captured = try await snapshot(folder, stream: .mic)
        let value = try result(captured, legacy: true)
        XCTAssertEqual(value.sources?.first?.sourceSessionID, "audio")
        XCTAssertEqual(value.duration, 4, "omitted system stream still establishes the full source timeline")
        _ = try await model().applyBatchResult(value, requestID: UUID(), in: folder)
        let modern = try fixture(), modernSnapshot = try await snapshot(modern)
        var unscoped = try result(modernSnapshot); unscoped.sources = nil
        XCTAssertThrowsError(try modernSnapshot.validatedResult(unscoped))
        let encoded = try JSONEncoder().encode(try result(modernSnapshot))
        let decoded = try JSONDecoder().decode(BatchRediarizer.Result.self, from: encoded)
        XCTAssertNil(decoded.sourceSnapshot, "a serialized event cannot manufacture app-owned source evidence")
        try await assertRejected(decoded, folder: modern, contains: "no verified source snapshot")
    }
    func testWholeInventoryAndEachSelectedStreamIntervalAreRequired() async throws {
        let folder = try fixture(), captured = try await snapshot(folder, stream: .mic)
        var value = try result(captured)
        value.turns[0] = .init(speakerId: "mic:new", stream: "mic", t0: 1, t1: 3, text: "past mic EOF", sourceSessionID: "source-a")
        XCTAssertThrowsError(try captured.validatedResult(value), "session end 4 cannot authorize a mic turn after its EOF 2")
        value.turns[0] = .init(speakerId: "system:new", stream: "system", t0: 1, t1: 2, text: "wrong stream", sourceSessionID: "source-a")
        XCTAssertThrowsError(try captured.validatedResult(value))
        value.sources = []
        XCTAssertThrowsError(try captured.validatedResult(value))
    }
    func testValidSubsetResultCannotOmitASilentIndexedSession() async throws {
        let folder = try fixture()
        let oldResult = try result(await snapshot(folder))
        try await edit(folder) { metadata in
            let audio = folder.appendingPathComponent("audio-session-2")
            try Self.writeSource(audio, id: "silent-b", offset: 10_000_000)
            var manifest = try LocalAudioRecorder.readManifest(directory: audio)
            manifest.streams["mic"]!.committed_bytes = 0
            manifest.streams["system"]!.committed_bytes = 0
            try JSONEncoder().encode(manifest).write(to: audio.appendingPathComponent(LocalAudioRecorder.manifestName))
            var next = MeetingSessionMetadata(sessionID: 2, startedAt: Date(), audioFolder: "audio-session-2", streams: [:])
            next.sourceSessionID = "silent-b"; metadata.sessions.append(next)
        }
        let allSources = try await snapshot(folder, stream: .mic)
        XCTAssertEqual(allSources.sources.count, 2)
        XCTAssertThrowsError(try allSources.validatedResult(oldResult))
        let complete = try result(allSources)
        XCTAssertEqual(complete.duration, 10)
        XCTAssertEqual(complete.sources?.last?.durationSeconds, 0)
        _ = try await model().applyBatchResult(complete, requestID: UUID(), in: folder)
    }
    func testMissingManifestCannotTurnCommittedPCMIntoLegacyFallback() async throws {
        let folder = try fixture()
        try await edit(folder) { metadata in
            metadata.sessions[0].sourceSessionID = nil // Pre-provenance metadata.
            _ = try LocalAudioRecorder.recoverWAVs(directory: folder.appendingPathComponent("audio"))
            try FileManager.default.removeItem(at: folder.appendingPathComponent("audio/source-recording.json"))
        }
        do { _ = try await snapshot(folder); XCTFail("compatibility WAV must not hide lost commit evidence") }
        catch { XCTAssertTrue(error.localizedDescription.contains("without its commit manifest")) }
    }
    func testUnindexedSourceCannotBeSilentlyOmittedAndSinglePreIndexLegacyRemainsReadable() async throws {
        let legacy = try fixture(legacy: true)
        try await edit(legacy) { $0.sessions = [] }
        let legacySnapshot = try await snapshot(legacy)
        XCTAssertEqual(legacySnapshot.sources.first?.inventory.storageKind, "legacy_wav")
        let folder = try fixture(), value = try result(await snapshot(folder))
        try Self.writeSource(folder.appendingPathComponent("audio-session-2"), id: "orphan", offset: 4_000_000)
        try await assertRejected(value, folder: folder, contains: "Unindexed source audio")
    }
    func testUncommittedPCMTailIsPreservedAndNotPresentedAsACommittedChange() async throws {
        let folder = try fixture(), value = try result(await snapshot(folder))
        let source = folder.appendingPathComponent("audio/mic.pcm")
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([42, 43])); try handle.close()
        _ = try await model().applyBatchResult(value, requestID: UUID(), in: folder)
        XCTAssertEqual(try Data(contentsOf: source).suffix(2), Data([42, 43]))
        XCTAssertEqual(value.sourceSnapshot?.sources.first?.streamDurations["mic"], 2)
    }
    private func eventScript(_ folder: URL, exitCode: Int = 0) async throws -> String {
        let output = try result(await snapshot(folder))
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        event["type"] = "result"
        let encoded = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys).base64EncodedString()
        return "import base64,sys; print(base64.b64decode('\(encoded)').decode(),flush=True); sys.exit(\(exitCode))"
    }
    func testNativeCompletionEvidenceComesFromActualChildAndCannotDecodeFromStdout() async throws {
        let folder = try fixture(), expected = try await snapshot(folder), script = try await eventScript(folder)
        let result = try await BatchRediarizer(timeoutSeconds: 8).runCommand(["/usr/bin/python3", "-c", script], backendRoot: folder,
            sourceMeetingDirectory: folder, collectProcessingEvidence: true)
        let evidence = try XCTUnwrap(result.nativeProcessingEvidence)
        XCTAssertEqual(evidence.sourceIdentity, expected.folderIdentity)
        XCTAssertEqual(evidence.events.last, 10)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: evidence.events) as? [String: Any])["type"] as? String, "result")
        let serialized = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BatchRediarizer.Result.self, from: serialized)
        XCTAssertNil(decoded.nativeProcessingEvidence)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
        forged["nativeProcessingEvidence"] = ["observedExitCode": 0, "events": evidence.events.base64EncodedString()]
        XCTAssertNil(try JSONDecoder().decode(BatchRediarizer.Result.self,
            from: JSONSerialization.data(withJSONObject: forged)).nativeProcessingEvidence)
    }
    func testNativeCompletionDigestBindsSourceBytesStreamsAndIdentityButNotDisplayNames() async throws {
        let folder = try fixture(), original = try await snapshot(folder)
        let digest = try original.completionSHA256()
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, try original.completionSHA256())
        let renamed = BatchSourceSnapshot(folderIdentity: original.folderIdentity, selectedStream: original.selectedStream,
            sessions: original.sessions, sources: original.sources, reviewedNames: ["mic:0": "New display name"])
        XCTAssertEqual(digest, try renamed.completionSHA256())
        let mic = try await snapshot(folder, stream: .mic)
        XCTAssertNotEqual(digest, try mic.completionSHA256())
        let changedIdentity = MeetingFileAccess.Identity(directoryDevice: original.folderIdentity.directoryDevice,
            directoryInode: original.folderIdentity.directoryInode + 1,
            lockDevice: original.folderIdentity.lockDevice, lockInode: original.folderIdentity.lockInode)
        let replaced = BatchSourceSnapshot(folderIdentity: changedIdentity, selectedStream: original.selectedStream,
            sessions: original.sessions, sources: original.sources, reviewedNames: original.reviewedNames)
        XCTAssertNotEqual(digest, try replaced.completionSHA256())
        let file = try FileHandle(forWritingTo: folder.appendingPathComponent("audio/mic.pcm"))
        try file.write(contentsOf: Data([1, 0])); try file.close()
        let changedBytes = try await snapshot(folder)
        XCTAssertNotEqual(digest, try changedBytes.completionSHA256())
    }
    func testNonzeroActualExitAndBoundedEvidenceOverflowCannotReturnProof() async throws {
        for nonzero in [true, false] {
            let folder = try fixture(), script = try await eventScript(folder, exitCode: nonzero ? 7 : 0)
            do {
                _ = try await BatchRediarizer(timeoutSeconds: 8).runCommand(["/usr/bin/python3", "-c", script], backendRoot: folder,
                    sourceMeetingDirectory: folder, collectProcessingEvidence: true, evidenceByteLimit: nonzero ? 4096 : 64)
                XCTFail("An unsuccessful or incomplete native run returned evidence")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(nonzero ? "failed" : "budget"), error.localizedDescription)
            }
        }
    }
    func testEvidenceWaitDeadlineDoesNotReleaseActuallyStalledNativeClose() async throws {
        let folder = try fixture(), script = try await eventScript(folder), closing = TaskCompletion()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let runner = BatchRediarizer(timeoutSeconds: 8)
        let task = Task {
            try await runner.runCommand(["/usr/bin/python3", "-c", script], backendRoot: folder,
                sourceMeetingDirectory: folder, collectProcessingEvidence: true,
                onResourcesClosed: { closing.markCompleted(); gate.wait() })
        }
        let closeStarted = await closing.wait(timeoutSeconds: 5)
        XCTAssertEqual(closeStarted, .completed)
        do { _ = try await task.value; XCTFail("A caller timeout manufactured completed native evidence") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still closing"), error.localizedDescription) }
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder, mode: .archive), "Actual closing still owns the source")
    }
    func testActualSubprocessCapturesBeforeLaunchAndResumeDuringChildWaitCannotPublish() async throws {
        let folder = try fixture(), launched = TaskCompletion()
        let output = try result(await snapshot(folder))
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        event["type"] = "result"
        try JSONSerialization.data(withJSONObject: event).write(to: folder.appendingPathComponent("batch-event"))
        // The child waits for a synthetic control file, with its own fail-safe.
        let script = "import pathlib,time; p=pathlib.Path('.'); end=time.monotonic()+5\nwhile not (p/'release').exists() and time.monotonic()<end: time.sleep(.01)\nprint((p/'batch-event').read_text(),flush=True)"
        let runner = BatchRediarizer(timeoutSeconds: 10)
        let task = Task { try await runner.runCommand(["/usr/bin/python3", "-c", script], backendRoot: folder,
            sourceMeetingDirectory: folder, launchCheckpoint: { checkpoint in
                if case .afterRun = checkpoint { launched.markCompleted() }
            }) }
        let launchOutcome = await launched.wait(timeoutSeconds: 3)
        XCTAssertEqual(launchOutcome, .completed)
        try await edit(folder) { metadata in
            try Self.writeSource(folder.appendingPathComponent("audio-session-2"), id: "source-b", offset: 4_000_000)
            var next = MeetingSessionMetadata(sessionID: 2, startedAt: Date(), audioFolder: "audio-session-2", streams: [:])
            next.sourceSessionID = "source-b"; metadata.sessions.append(next)
        }
        try Data().write(to: folder.appendingPathComponent("release"))
        let stale = try await task.value
        XCTAssertEqual(stale.sourceSnapshot?.sources.count, 1, "the reader cannot replace the launch snapshot with a fresh one")
        try await assertRejected(stale, folder: folder, contains: "source audio or sessions changed")
    }
    func testSnapshotDeadlineRetainsOriginalFolderAndLateReadNeverLaunchesChild() async throws {
        let folder = try fixture(), entered = TaskCompletion(), release = DispatchSemaphore(value: 0)
        let actualSnapshotFinished = TaskCompletion(), resourcesClosed = TaskCompletion()
        defer { release.signal() }
        let runner = BatchRediarizer(timeoutSeconds: 1)
        let command = ["/bin/sh", "-c", "touch must-not-launch"]
        let task = Task {
            try await runner.runCommand(command, backendRoot: folder, sourceMeetingDirectory: folder,
                beforeSourceSnapshot: {
                    entered.markCompleted()
                    _ = release.wait(timeout: .now() + 10)
                }, onResourcesClosed: { resourcesClosed.markCompleted() })
        }
        let enteredOutcome = await entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(enteredOutcome, .completed)
        do { _ = try await task.value; XCTFail("the startup deadline must be observable") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in true })
        do {
            _ = try await runner.runCommand(command, backendRoot: folder, sourceMeetingDirectory: folder)
            XCTFail("the same runner cannot admit repeated work after a snapshot timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("still")) }
        // Queue one terminal observer behind the actual snapshot owner. It
        // cannot run until the original read and reservation really finish.
        let after = try TranscriptPersistenceStore.shared.startAfterCurrent(in: folder,
            onCompletion: { _ in actualSnapshotFinished.markCompleted() }) { _ in true }
        release.signal()
        let afterOutcome = await actualSnapshotFinished.wait(timeoutSeconds: 3)
        XCTAssertEqual(afterOutcome, .completed)
        _ = try after.completedValue()
        let closedOutcome = await resourcesClosed.wait(timeoutSeconds: 3)
        XCTAssertEqual(closedOutcome, .completed)
        // Admission checks its expired deadline after factory return and can
        // never run the child, even if the source read eventually succeeded.
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("must-not-launch").path))
    }
}
