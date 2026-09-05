import XCTest

@MainActor
final class BuildIdentityTests: XCTestCase {
    private func runtime() -> ObservedRuntimeIdentity {
        ObservedRuntimeIdentity(schemaVersion: 1, observation: "process_preflight", pythonVersion: "3.12.13",
            executableSHA256: String(repeating: "a", count: 64), backendSHA256: String(repeating: "b", count: 64),
            packageVersions: ["mlx": "0.30.3"], modelAssetsSHA256: ["asr_weights": String(repeating: "c", count: 64)],
            modelObservation: "selected_files_hashed")
    }

    func testGeneratedBuildIdentityHasExpectedInputsButNoAssumedRuntime() throws {
        let current = BuildIdentity.current
        XCTAssertEqual(current.schemaVersion, 1)
        XCTAssertEqual(current.buildID.count, 64)
        XCTAssertNotNil(current.expectedInputSHA256["runtime_lock"] ?? nil)
        XCTAssertEqual(current.schemas["source_manifest"], 1)
        let text = BuildDiagnostic.summary(runtime: nil, counters: ["system_frames": 12], sandboxed: false)
        XCTAssertTrue(text.contains(current.buildID))
        XCTAssertFalse(text.contains("python_version"), "expected lock must not invent observed runtime")
    }

    func testLegacyMetadataDecodesUnknownThenRoundTripsSeparateSessionIdentities() throws {
        let old = """
        {"version":1,"title":"Private meeting","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","duration_seconds":0,"last_timestamp":0,"status":"interrupted","sessions":[{"session_id":1,"started_at":"2026-01-01T00:00:00Z","audio_folder":"audio","streams":{}}],"segment_count":0,"speaker_names":{}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(MeetingMetadata.self, from: Data(old.utf8))
        XCTAssertNil(metadata.buildIdentity)
        XCTAssertNil(metadata.sessions[0].buildIdentity)
        XCTAssertNil(metadata.sessions[0].observedRuntimeIdentity)
        metadata.sessions.append(MeetingSessionMetadata(sessionID: 2, startedAt: Date(), audioFolder: "audio-session-2", streams: [:],
            buildIdentity: .current, sourceSessionID: "new-source", observedRuntimeIdentity: runtime()))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder.decode(MeetingMetadata.self, from: encoder.encode(metadata))
        XCTAssertNil(restored.buildIdentity, "Resume must preserve an unknown original build")
        XCTAssertNil(restored.sessions[0].buildIdentity)
        XCTAssertEqual(restored.sessions[1].buildIdentity, .current)
        XCTAssertEqual(restored.sessions[1].observedRuntimeIdentity, runtime())
    }

    func testRuntimeEventIsSourceScopedAndDefaultDiagnosticRejectsPrivateFields() throws {
        let encoder = JSONEncoder()
        let identity = try JSONSerialization.jsonObject(with: encoder.encode(runtime()))
        let line = String(data: try JSONSerialization.data(withJSONObject: ["type": "runtime_identity",
            "source_session_id": "source-2", "identity": identity]), encoding: .utf8)!
        XCTAssertEqual(ObservedRuntimeIdentity.event(line, sourceSessionID: "source-2"), runtime())
        XCTAssertNil(ObservedRuntimeIdentity.event(line, sourceSessionID: "source-1"))
        let malicious = line.replacingOccurrences(of: "0.30.3", with: "/Users/Private/meeting contents")
        XCTAssertNil(ObservedRuntimeIdentity.event(malicious, sourceSessionID: "source-2"))
        let summary = BuildDiagnostic.summary(runtime: runtime(), counters: ["system_frames": 1], sandboxed: false)
        XCTAssertTrue(summary.contains("process_preflight"))
        for prohibited in ["/Users/", "meeting contents", "source-2", "Backend log tail", "Private meeting"] {
            XCTAssertFalse(summary.contains(prohibited))
        }
    }

    func testBatchRuntimePersistsWithoutReplacingCaptureBuildOrRuntime() throws {
        var metadata = MeetingMetadata(version: 1, title: "Private", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 0, lastTimestamp: 0, status: .interrupted, sessions: [], segmentCount: 0, speakerNames: [:])
        metadata.buildIdentity = .current
        let replacement = try TranscriptReplacement(result: BatchRediarizer.Result(turns: [], speakers: [], duration: 0,
            runtimeIdentity: runtime()), metadata: metadata)
        XCTAssertEqual(replacement.metadata.buildIdentity, .current)
        XCTAssertEqual(replacement.metadata.lastReprocessIdentity, runtime())
    }

    func testDurableJournalPersistsRuntimeWithoutUIAndRejectsUnacknowledgedTail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try LocalAudioRecorder(directory: folder.appendingPathComponent("audio"), sessionID: "source-A")
        let source = await recorder.finish(timeoutSeconds: 3)
        let metadata = MeetingMetadata(version: 1, title: "Private", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 0, lastTimestamp: 0, status: .recording,
            sessions: [.init(sessionID: 1, startedAt: Date(), audioFolder: "audio", streams: [:],
                             buildIdentity: .current, sourceSessionID: "source-A")], segmentCount: 0, speakerNames: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("meeting.json"))
        let value = try JSONSerialization.jsonObject(with: encoder.encode(runtime()))
        let data = try JSONSerialization.data(withJSONObject: ["type": "runtime_identity", "source_session_id": "source-A", "identity": value])
        let line = String(data: data, encoding: .utf8)! + "\n"
        let tail = line.replacingOccurrences(of: "3.12.13", with: "9.99.99")
        let journal = folder.appendingPathComponent("events.jsonl")
        try Data((line + tail).utf8).write(to: journal)
        let status = BackendStdoutStatus(durableBytes: UInt64(line.utf8.count))
        let saved = try await TranscriptPersistenceStore.shared.start(in: folder) { context in
            try TranscriptReplacement.commitStoppedMeeting(context: context, timestampOffset: 0,
                segments: [], speakerNames: [:], journalURL: journal, journalStatus: status,
                sourceManifest: source, artifactResult: nil, incomplete: false)
        }.value(timeoutSeconds: 3)
        XCTAssertEqual(saved.sessions[0].observedRuntimeIdentity, runtime())
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
        XCTAssertEqual(reloaded.sessions[0].observedRuntimeIdentity, runtime())
    }

    func testActualBatchReaderKeepsObservedIdentitySeparateFromBuild() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var observed = runtime()
        observed.packageSourceCommits = ["senko": String(repeating: "d", count: 40)]
        observed.selectedToolsSHA256 = ["ffmpeg": String(repeating: "e", count: 64)]
        let identity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed))
        let data = try JSONSerialization.data(withJSONObject: ["type": "result", "turns": [],
            "speakers": [], "duration": 0, "runtime_identity": identity])
        let output = folder.appendingPathComponent("output")
        try data.write(to: output)
        let result = try await BatchRediarizer(timeoutSeconds: 3).runCommand(["/bin/cat", output.path], backendRoot: folder)
        XCTAssertEqual(result.runtimeIdentity, observed)
        XCTAssertTrue(result.runtimeIdentity?.isSafeDiagnosticValue == true)
    }
}
