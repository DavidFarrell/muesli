import Foundation
import XCTest

/// Which timestamp displacements raise the persistent "Audio preservation
/// problem" (6 Nov 2026 incident: a correct route-silence restart left a
/// 366 ms gap that latched the banner for 55 minutes and marked the meeting
/// degraded; earlier, one-frame quantization jitter did the same).
final class LocalAudioRecorderGapClassificationTests: XCTestCase {
    private typealias Recorder = LocalAudioRecorder

    // MARK: Route-silence restart exemption

    func testRouteSilenceRestartGapAtTheBoundaryIsEvidenceNotAProblem() async throws {
        let url = try folder()
        let recorder = try Recorder(directory: url)
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))       // frames 0..<16000
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: 400_000, restartUs: 1_010_000)
        recorder.record(source: .system, ptsUs: 1_366_000, payload: samples(1_600)) // 366 ms gap
        let result = try await finish(recorder)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.problem_count, 0)
        XCTAssertNil(result.last_problem)
        XCTAssertNil(recorder.status().error)
        XCTAssertEqual(result.streams["system"]?.gap_frames, 5_856, "The interruption stays truthfully counted")
        let loss = try XCTUnwrap(result.losses.first { $0.reason == "route_silence_restart_gap" })
        XCTAssertEqual(loss.start_frame, 16_000)
        XCTAssertEqual(loss.end_frame, 21_856)
        XCTAssertEqual(result.recovery_events, [Recorder.RecoveryEvent(kind: "system_route_silence_restart", source: "system",
            suspected_silence_start_frame: 6_400, restart_frame: 16_160)])
        XCTAssertEqual(try Recorder.readManifest(directory: url).recovery_events?.count, 1)
    }

    func testRouteSilenceEvidenceCommitsDuringRecordingWithoutClearingCompletion() async throws {
        let url = try folder()
        let recorder = try Recorder(directory: url, commitInterval: 0.05)
        recorder.record(source: .system, ptsUs: 0, payload: samples(160))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 20_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try Recorder.readManifest(directory: url).recovery_events == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let live = try Recorder.readManifest(directory: url)
        let events = try XCTUnwrap(live.recovery_events, "The event must commit before stop")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.restart_frame, 320)
        XCTAssertNil(events.first?.suspected_silence_start_frame)
        XCTAssertEqual(live.problem_count, 0)
        let result = try await finish(recorder)
        XCTAssertTrue(result.completed)
    }

    func testRestartGapLongerThanTheBoundStaysAProblem() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_000_000)
        recorder.record(source: .system, ptsUs: 2_100_000, payload: samples(160)) // 1.1 s gap
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "source_timestamp_gap")
        XCTAssertNotNil(recorder.status().error)
    }

    func testSameGapWithoutARestartNoteStaysAProblem() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.record(source: .system, ptsUs: 1_366_000, payload: samples(1_600))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "source_timestamp_gap")
    }

    func testArmIsConsumedByAContiguousFirstPacketSoALaterGapIsAProblem() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_000_000)
        recorder.record(source: .system, ptsUs: 1_000_000, payload: samples(160))
        recorder.record(source: .system, ptsUs: 1_200_000, payload: samples(160)) // 190 ms gap, no longer at a restart
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "source_timestamp_gap")
    }

    func testStaleArmFromAFailedStartCannotBlessALaterGeneration() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_000_000)
        // The replacement start failed; a much later generation's first
        // sample is outside both the gap bound and the restart window.
        recorder.record(source: .system, ptsUs: 30_000_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "source_timestamp_gap")
    }

    func testFirstSampleBeforeTheRestartIsNotExempt() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_500_000)
        recorder.record(source: .system, ptsUs: 1_300_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
    }

    func testRestartPacketIsClassifiedAgainstAFreshJitterBaseline() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(160))                  // -> 160
        recorder.record(source: .system, ptsUs: 159 * 1_000_000 / 16_000 + 1, payload: samples(160)) // -1: balance -1, -> 319
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 318 * 1_000_000 / 16_000)
        recorder.record(source: .system, ptsUs: 318 * 1_000_000 / 16_000, payload: samples(160))     // -1 again, new stream
        recorder.record(source: .system, ptsUs: 479 * 1_000_000 / 16_000 + 1, payload: samples(160)) // +1 on the new grid
        let result = try await finish(recorder)
        XCTAssertEqual(result.problem_count, 0)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.streams["system"]?.jitter_events, 3)
    }

    func testPostRestartBaselineIsZeroAndStillCatchesDrift() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(160))
        recorder.record(source: .system, ptsUs: 159 * 1_000_000 / 16_000 + 1, payload: samples(160)) // balance -1, -> 319
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 318 * 1_000_000 / 16_000)
        recorder.record(source: .system, ptsUs: 318 * 1_000_000 / 16_000, payload: samples(160))     // stamped -1 -> 478, balance 0
        recorder.record(source: .system, ptsUs: 477 * 1_000_000 / 16_000 + 1, payload: samples(160)) // -1: balance -1 (tolerated only if reset to 0)
        let tolerated = recorder.status().error
        recorder.record(source: .system, ptsUs: 637 * 1_000_000 / 16_000 + 1, payload: samples(160)) // contiguous
        recorder.record(source: .system, ptsUs: 796 * 1_000_000 / 16_000 + 1, payload: samples(160)) // -1 again: drift
        let result = try await finish(recorder)
        XCTAssertNil(tolerated)
        XCTAssertEqual(result.streams["system"]?.jitter_events, 3)
        XCTAssertFalse(result.completed, "Same-direction drift after the new baseline is still loss")
        XCTAssertEqual(result.losses.last?.reason, "overlapping_source_timestamp")
    }

    func testRestartOverlapIsStillAProblem() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 900_000)
        recorder.record(source: .system, ptsUs: 950_000, payload: samples(1_600))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "overlapping_source_timestamp")
    }

    func testRejectedFirstPacketLeavesTheArmForTheNextAdmittedPacket() async throws {
        let recorder = try Recorder(directory: folder(), maxPendingBytes: 4_000, commitInterval: 60)
        recorder.record(source: .system, ptsUs: 0, payload: samples(1_000))
        try await waitForDrain(recorder)
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 100_000)
        XCTAssertFalse(recorder.record(source: .system, ptsUs: 300_000, payload: samples(4_000)), "oversized: rejected")
        recorder.record(source: .system, ptsUs: 400_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertTrue(result.losses.contains { $0.reason == "ingress_overflow" })
        XCTAssertTrue(result.losses.contains { $0.reason == "route_silence_restart_gap" })
        XCTAssertFalse(result.completed, "The rejection itself is still a real loss")
    }

    func testSystemArmDoesNotExemptAMicrophoneGap() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_000_000)
        recorder.record(source: .mic, ptsUs: 1_366_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "source_timestamp_gap")
    }

    func testExistingRealProblemStaysVisibleAfterATolerantRestart() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.reportFailure(stream: .system, message: "native positions show missing frames")
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_000_000)
        recorder.record(source: .system, ptsUs: 1_300_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(recorder.status().error)
    }

    // MARK: Quantization jitter

    /// Reproduces the producer's grid exactly: AudioConverterHelper.emit
    /// stamps `epochUs + outputFrames * 1_000_000 / 16000` (integer
    /// truncation), the forwarder subtracts the meeting epoch, and the
    /// recorder rounds to frames. With an epoch offset whose frame fraction
    /// sits just above .5, odd frame positions round down and even ones up.
    func testProducerTimestampFormulaQuantizationNeverRaisesAProblem() async throws {
        for offsetUs: Int64 in [0, 31, 94, 1_094, 2_531, 62_594] {
            let recorder = try Recorder(directory: folder())
            var outputFrames: Int64 = 0
            for size in sequence(first: 441, next: { $0 == 441 ? 160 : ($0 == 160 ? 333 : 441) }).prefix(600) {
                let pts = offsetUs + outputFrames * 1_000_000 / 16_000
                recorder.record(source: .system, ptsUs: pts, payload: samples(size))
                outputFrames += Int64(size)
            }
            let result = try await finish(recorder)
            XCTAssertEqual(result.problem_count, 0, "offset \(offsetUs)")
            XCTAssertTrue(result.completed, "offset \(offsetUs)")
            XCTAssertTrue(result.losses.allSatisfy { $0.reason == "initial_source_alignment" }, "offset \(offsetUs)")
            if offsetUs == 94 { XCTAssertGreaterThan(result.streams["system"]?.jitter_events ?? 0, 100) }
        }
    }

    func testAlternatingOneFrameJitterIsCountedWithoutLossRows() async throws {
        let recorder = try Recorder(directory: folder())
        var position: Int64 = 0
        for index in 0..<1_200 { // 600 gap/overlap pairs: more than the 512-row loss budget
            let displacement: Int64 = index == 0 ? 0 : (index % 2 == 1 ? 1 : -1)
            let start = position + displacement
            recorder.record(source: .mic, ptsUs: start * 1_000_000 / 16_000, payload: samples(160))
            position = start + 160
        }
        let result = try await finish(recorder)
        XCTAssertTrue(result.completed)
        XCTAssertTrue(result.losses.isEmpty)
        XCTAssertEqual(result.loss_details_omitted, 0)
        XCTAssertEqual(result.streams["mic"]?.jitter_events, 1_199)
        XCTAssertEqual(result.streams["mic"]?.gap_frames, 600)
        XCTAssertEqual(result.streams["mic"]?.overlap_frames, 599)
    }

    func testSustainedOneFrameLossInOneDirectionIsAProblem() async throws {
        let recorder = try Recorder(directory: folder())
        var position: Int64 = 0
        for index in 0..<4 {
            let start = position + (index == 0 ? 0 : 1)
            recorder.record(source: .mic, ptsUs: start * 1_000_000 / 16_000, payload: samples(160))
            position = start + 160
        }
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.first?.reason, "source_timestamp_gap")
    }

    func testContiguousPacketsDoNotResetTheJitterBalance() async throws {
        let recorder = try Recorder(directory: folder())
        var position: Int64 = 0
        for displacement: Int64 in [0, 1, 0, 0, 1] {
            let start = position + displacement
            recorder.record(source: .mic, ptsUs: start * 1_000_000 / 16_000, payload: samples(160))
            position = start + 160
        }
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed, "+1, 0, 0, +1 nets two frames of real loss")
    }

    func testTwoFrameDisplacementIsAProblem() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        recorder.record(source: .mic, ptsUs: 162 * 1_000_000 / 16_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
    }

    func testLargeBackwardJumpWithASmallPacketIsClassifiedByFullDisplacement() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(16_000 * 21))
        recorder.record(source: .mic, ptsUs: 1_000_000, payload: samples(1)) // 20 s behind, one frame
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.last?.reason, "overlapping_source_timestamp")
        XCTAssertEqual(result.streams["mic"]?.jitter_events ?? 0, 0)
    }

    func testJitterDoesNotHideANativeFailure() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        recorder.record(source: .mic, ptsUs: 161 * 1_000_000 / 16_000 + 1, payload: samples(160))
        recorder.reportFailure(stream: .mic, message: "Native sample positions show 3 missing native frames.")
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(recorder.status().error)
    }

    // MARK: Pure classifier

    func testClassifierTable() {
        typealias C = Recorder.DisplacementClass
        func c(_ d: Int64, position: Int64 = 1_000, balance: Int64 = 0, restart: Int64? = nil) -> C {
            Recorder.classifyDisplacement(d, position: position, start: position + d, jitterBalance: balance,
                                          routeSilenceRestartFrame: restart)
        }
        XCTAssertEqual(c(0), .contiguous)
        XCTAssertEqual(c(500, position: 0), .contiguous)
        XCTAssertEqual(c(1), .jitter)
        XCTAssertEqual(c(-1), .jitter)
        XCTAssertEqual(c(1, balance: 1), .problem)
        XCTAssertEqual(c(-1, balance: 1), .jitter)
        XCTAssertEqual(c(-1, balance: -1), .problem)
        XCTAssertEqual(c(2), .problem)
        XCTAssertEqual(c(5_856, restart: 1_100), .routeSilenceRestartGap)
        XCTAssertEqual(c(16_000, restart: 1_000), .routeSilenceRestartGap)
        XCTAssertEqual(c(16_001, restart: 1_000), .problem)
        XCTAssertEqual(c(-50, restart: 900), .problem)
        XCTAssertEqual(c(100, restart: 1_200), .problem, "first sample before the committed restart")
        XCTAssertEqual(c(5_000, position: 40_000, restart: 1_000), .problem, "outside the restart window")
    }

    // MARK: Compatibility

    func testManifestWithoutNewOptionalFieldsDecodesAndRoundTrips() async throws {
        let url = try folder()
        let recorder = try Recorder(directory: url)
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        _ = try await finish(recorder)
        let manifestURL = url.appendingPathComponent(Recorder.manifestName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertNil(json["recovery_events"], "Absent unless a recovery happened")
        json.removeValue(forKey: "recovery_events_omitted")
        var streams = try XCTUnwrap(json["streams"] as? [String: [String: Any]])
        for key in streams.keys { streams[key]?.removeValue(forKey: "jitter_events") }
        json["streams"] = streams
        let decoded = try Recorder.decodeManifest(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.recovery_events)
        XCTAssertNil(decoded.streams["mic"]?.jitter_events)
        XCTAssertTrue(decoded.completed)
    }

    func testRestartGapManifestSatisfiesTheRecorderCompletionCriteria() async throws {
        let recorder = try Recorder(directory: folder())
        recorder.record(source: .system, ptsUs: 0, payload: samples(16_000))
        recorder.noteRouteSilenceRestart(stream: .system, suspectedSilenceStartUs: nil, restartUs: 1_000_000)
        recorder.record(source: .system, ptsUs: 1_366_000, payload: samples(160))
        let manifest = try await finish(recorder)
        XCTAssertTrue(manifest.completed)
        XCTAssertEqual(manifest.problem_count, 0)
        XCTAssertTrue(manifest.streams.values.allSatisfy { $0.dropped_frames == 0 })
    }

    // MARK: Helpers

    private func waitForDrain(_ recorder: Recorder) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.status().queuedBytes > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-gap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func finish(_ recorder: Recorder) async throws -> Recorder.Manifest {
        let result = await recorder.finish(timeoutSeconds: 5)
        return try XCTUnwrap(result)
    }

    private func samples(_ count: Int, value: Int16 = 9) -> Data {
        var sample = value.littleEndian
        let frame = withUnsafeBytes(of: &sample) { Data($0) }
        return Data((0..<count).flatMap { _ in frame })
    }
}
