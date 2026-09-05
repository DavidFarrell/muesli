import XCTest

final class OrphanedMeetingRecoveryTests: XCTestCase {
    private func metadata(status: MeetingStatus = .recording, oldDuration: Double = 0) -> MeetingMetadata {
        let created = Date(timeIntervalSince1970: 1_000_000)
        return MeetingMetadata(version: 1, title: "Interrupted session", createdAt: created,
                               updatedAt: created, durationSeconds: oldDuration, lastTimestamp: 0,
                               status: status, sessions: [MeetingSessionMetadata(
                                sessionID: 1, startedAt: created, endedAt: nil, audioFolder: "audio", streams: [:])],
                               segmentCount: 5, speakerNames: [:])
    }

    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }

    func testNeedsRecoveryOnlyForUnclosedRecording() {
        XCTAssertTrue(OrphanedMeetingRecovery.needsRecovery(metadata()))
        for status in [MeetingStatus.completed, .interrupted, .degraded] {
            XCTAssertFalse(OrphanedMeetingRecovery.needsRecovery(metadata(status: status)))
        }
    }

    func testRecoveryRemainsInterruptedAndCannotAddDaysOfIdleTime() {
        let original = metadata(oldDuration: 900_000)
        let evidence = OrphanedMeetingRecovery.Evidence(sessions: [.init(
            sessionID: 1, timelineOffsetSeconds: 0, durationSeconds: 60)], durationSeconds: 60, problems: [])
        let recovered = OrphanedMeetingRecovery.finalize(original, evidence: evidence,
                                                         now: original.createdAt.addingTimeInterval(20 * 86400))
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertEqual(recovered.durationSeconds, 60, "only actual media supplies the duration")
        XCTAssertEqual(recovered.sessions[0].durationSeconds, 60)
        XCTAssertNil(recovered.sessions[0].endedAt, "recovery does not observe an actual stop time")
        XCTAssertEqual(recovered.title, original.title)
        XCTAssertEqual(recovered.segmentCount, original.segmentCount)
    }

    func testMissingMediaUsesOnlyKnownTranscriptTime() {
        XCTAssertEqual(OrphanedMeetingRecovery.recoveredDuration(mediaDurationSeconds: nil, lastTranscriptTimestamp: 42), 42)
        XCTAssertEqual(OrphanedMeetingRecovery.recoveredDuration(mediaDurationSeconds: nil, lastTranscriptTimestamp: .nan), 0)
    }

    func testOldMetadataDecodesWithoutNewPerSessionDurationFields() throws {
        let original = metadata()
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(MeetingMetadata.self, from: encoded)
        XCTAssertNil(restored.sessions[0].durationSeconds)
        XCTAssertNil(restored.sessions[0].timelineOffsetSeconds)
    }

    func testInterruptedPCMRecoveryUsesCommittedPrefixAndPreservesOriginals() async throws {
        let root = try folder()
        let audio = root.appendingPathComponent("audio")
        let recorder = try LocalAudioRecorder(directory: audio, timelineOffsetUs: 10_000_000)
        let committed = Data(repeating: 1, count: 3200)
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 0, payload: committed))
        _ = await recorder.finish()
        let manifestURL = audio.appendingPathComponent(LocalAudioRecorder.manifestName)
        var manifest = try LocalAudioRecorder.readManifest(directory: audio)
        manifest.completed = false
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let pcmURL = audio.appendingPathComponent("mic.pcm")
        let handle = try FileHandle(forWritingTo: pcmURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 77, count: 640))
        try handle.close()
        let pcmBefore = try Data(contentsOf: pcmURL)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let original = metadata()
        let evidence = await Task.detached {
            OrphanedMeetingRecovery.inspectAndRecover(folderURL: root, metadata: original)
        }.value
        XCTAssertEqual(evidence.durationSeconds, 10.1)
        XCTAssertTrue(evidence.problems.isEmpty)
        XCTAssertEqual(try Data(contentsOf: audio.appendingPathComponent("mic.wav")).dropFirst(44), committed)
        XCTAssertEqual(try Data(contentsOf: pcmURL), pcmBefore)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        let recovered = OrphanedMeetingRecovery.finalize(original, evidence: evidence, now: Date())
        XCTAssertEqual(recovered.status, .interrupted)
    }

    func testResumeTwiceUsesExplicitOffsetsAndBothStreamsForDuration() async throws {
        let root = try folder()
        var original = metadata()
        original.sessions = []
        for id in 1...3 {
            let name = id == 1 ? "audio" : "audio-session-\(id)"
            let offset = Int64((id - 1) * 10_000_000)
            let recorder = try LocalAudioRecorder(directory: root.appendingPathComponent(name), timelineOffsetUs: offset)
            recorder.record(source: .mic, ptsUs: 0, payload: Data(repeating: 1, count: 3200))
            recorder.record(source: .system, ptsUs: 0, payload: Data(repeating: 1, count: id * 6400))
            _ = await recorder.finish()
            original.sessions.append(MeetingSessionMetadata(sessionID: id, startedAt: original.createdAt,
                                                            endedAt: nil, audioFolder: name, streams: [:]))
        }
        let snapshot = original
        let evidence = await Task.detached {
            OrphanedMeetingRecovery.inspectAndRecover(folderURL: root, metadata: snapshot)
        }.value
        XCTAssertEqual(evidence.sessions.compactMap(\.timelineOffsetSeconds), [0, 10, 20])
        XCTAssertEqual(evidence.sessions.compactMap(\.durationSeconds), [0.2, 0.4, 0.6])
        XCTAssertEqual(evidence.durationSeconds, 20.6)
    }

    func testTruncatedCommittedPCMNeverFallsBackToStaleWav() async throws {
        let root = try folder()
        let audio = root.appendingPathComponent("audio")
        let recorder = try LocalAudioRecorder(directory: audio)
        recorder.record(source: .mic, ptsUs: 0, payload: Data(repeating: 1, count: 3200))
        _ = await recorder.finish()
        try Data().write(to: audio.appendingPathComponent("mic.pcm"))
        let original = metadata()
        let evidence = await Task.detached {
            OrphanedMeetingRecovery.inspectAndRecover(folderURL: root, metadata: original)
        }.value
        XCTAssertNil(evidence.durationSeconds)
        XCTAssertFalse(evidence.problems.isEmpty)
    }
}
