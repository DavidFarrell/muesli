import Foundation
import XCTest

final class LocalAudioRecorderTests: XCTestCase {
    func testForwardedClockSummariesPreserveGenerationsAndIndependentSourcesWithoutChangingAudio() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url)
        let microphone = MicAudioForwarder(sampleRate: 16000, channels: 1)
        let system = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        let epoch = CaptureTimeline(epochMicroseconds: 1_000_000)
        await microphone.beginMeeting(epoch: epoch)
        await system.beginMeeting(epoch: epoch)
        await microphone.beginGeneration(4, writer: recorder, outputEnabled: true)
        await system.beginGeneration(4, writer: recorder, outputEnabled: true)
        let first = clockCorrection(generation: 4, native: 480, nominal: 160, host: 160, observed: 1)
        _ = await microphone.deliver(clockPacket(generation: 4, time: 1_000_000, correction: first))
        recorder.reportClockCorrection(stream: .mic, correction: first) // Same cumulative observation is idempotent.
        _ = await system.deliver(clockPacket(generation: 4, time: 1_000_000,
            correction: clockCorrection(generation: 4, native: 480, nominal: 159, host: 160, observed: 2, uncertain: 1)))

        await microphone.beginGeneration(7, writer: recorder, outputEnabled: true)
        let next = clockCorrection(generation: 7, native: 480, nominal: 160, host: 160, observed: 1, uncertain: 1)
        _ = await microphone.deliver(clockPacket(generation: 7, time: 1_010_000, correction: next))
        // The actual forwarder rejects both audio and diagnostics from a retired packet.
        _ = await microphone.deliver(clockPacket(generation: 4, time: 1_020_000,
            correction: clockCorrection(generation: 4, native: 9999, nominal: 9999, host: 9999, observed: 9999)))
        // A correction with a different generation cannot hitchhike on current audio.
        _ = await microphone.deliver(clockPacket(generation: 7, time: 1_020_000, correction: first))
        let finalObservation = clockCorrection(generation: 7, native: 1440, nominal: 479, host: 480, observed: 3, uncertain: 2)
        _ = await microphone.deliver(clockPacket(generation: 7, time: 1_030_000, correction: finalObservation))
        let result = try await finish(recorder)
        let saved = try LocalAudioRecorder.readManifest(directory: url)
        XCTAssertEqual(result.clock_corrections, saved.clock_corrections)
        XCTAssertEqual(saved.clock_corrections?.count, 2)
        let mic = try XCTUnwrap(saved.clock_corrections?["mic"])
        XCTAssertEqual(mic.generation_count, 2)
        XCTAssertEqual(mic.native_frames, 1920)
        XCTAssertEqual(mic.nominal_output_frames, 639)
        XCTAssertEqual(mic.host_output_frames, 640)
        XCTAssertEqual(mic.observed_intervals, 4)
        XCTAssertEqual(mic.uncertain_intervals, 2)
        XCTAssertEqual(mic.latest, finalObservation)
        XCTAssertEqual(saved.clock_corrections?["system"]?.generation_count, 1)
        XCTAssertEqual(saved.clock_corrections?["system"]?.uncertain_intervals, 1)
        XCTAssertTrue(saved.completed, "Clock correction and uncertainty are diagnostics, not capture loss")
        XCTAssertEqual(saved.problem_count, 0)
        XCTAssertTrue(saved.losses.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.pcm")), samples(640))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("system.pcm")), samples(160))
    }

    func testClockDiagnosticsCommitBeforeStopAndRejectLateOrRegressingObservations() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, commitInterval: 0.05)
        let accepted = clockCorrection(generation: 8, native: 480, nominal: 160, host: 160, observed: 2, uncertain: 1)
        recorder.reportClockCorrection(stream: .mic, correction: accepted)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try LocalAudioRecorder.readManifest(directory: url).clock_corrections == nil,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try LocalAudioRecorder.readManifest(directory: url).clock_corrections?["mic"]?.latest, accepted)
        recorder.reportClockCorrection(stream: .mic, correction: clockCorrection(generation: 7, native: 9999, nominal: 9999, host: 9999, observed: 9999))
        recorder.reportClockCorrection(stream: .mic, correction: clockCorrection(generation: 8, native: 479, nominal: 160, host: 160, observed: 2))
        for ratio in [Double.nan, Double.infinity, -1, 0, 2.01] {
            recorder.reportClockCorrection(stream: .mic, correction: clockCorrection(generation: 9, native: 1000, nominal: 1000, host: 1000, observed: 10, ratio: ratio))
        }
        recorder.requestFinish()
        recorder.reportClockCorrection(stream: .mic, correction: clockCorrection(generation: 9, native: 1000, nominal: 1000, host: 1000, observed: 10))
        let result = try await finish(recorder)
        XCTAssertEqual(result.clock_corrections?["mic"]?.latest, accepted)
        XCTAssertEqual(result.clock_corrections?["mic"]?.generation_count, 1)
        XCTAssertTrue(result.completed)
        let bytes = try Data(contentsOf: url.appendingPathComponent(LocalAudioRecorder.manifestName))
        recorder.reportClockCorrection(stream: .system, correction: accepted)
        _ = await recorder.finish()
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(LocalAudioRecorder.manifestName)), bytes)
    }

    func testClockSummaryStorageRemainsBoundedAcrossManyGenerationsAndSaturatesExplicitly() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url)
        for generation in 0..<5000 {
            recorder.reportClockCorrection(stream: .mic, correction: clockCorrection(generation: generation,
                native: 480, nominal: 160, host: 160, observed: 1, uncertain: 1))
        }
        recorder.reportClockCorrection(stream: .system, correction: clockCorrection(generation: 1,
            native: Int64.max, nominal: Int64.max, host: Int64.max, observed: Int64.max, uncertain: Int64.max))
        recorder.reportClockCorrection(stream: .system, correction: clockCorrection(generation: 2,
            native: 1, nominal: 1, host: 1, observed: 1, uncertain: 1))
        let result = try await finish(recorder)
        XCTAssertEqual(result.clock_corrections?["mic"]?.generation_count, 5000)
        XCTAssertEqual(result.clock_corrections?["mic"]?.native_frames, 2_400_000)
        XCTAssertEqual(result.clock_corrections?["mic"]?.latest.generation, 4999)
        let system = try XCTUnwrap(result.clock_corrections?["system"])
        XCTAssertTrue(system.counters_saturated)
        XCTAssertEqual(system.native_frames, Int64.max)
        XCTAssertEqual(system.nominal_output_frames, Int64.max)
        XCTAssertEqual(system.host_output_frames, Int64.max)
        XCTAssertEqual(system.observed_intervals, Int64.max)
        XCTAssertEqual(system.uncertain_intervals, Int64.max)
        XCTAssertLessThan(try JSONEncoder().encode(result.clock_corrections).count, 4096)
        XCTAssertTrue(try LocalAudioRecorder.readManifest(directory: url).completed)
    }

    func testOldManifestWithoutClockDiagnosticsStillDecodesAndInvalidSummaryIsRejected() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url)
        let result = try await finish(recorder)
        let oldBytes = try JSONEncoder().encode(result)
        XCTAssertNil(try LocalAudioRecorder.decodeManifest(oldBytes).clock_corrections)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        XCTAssertNil(object["clock_corrections"], "Unused additive diagnostics are omitted from old-shaped manifests")
        let valid = LocalAudioRecorder.ClockCorrectionSummary(clockCorrection(generation: 1, native: 1, nominal: 1, host: 1, observed: 1))
        var summary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        summary["native_frames"] = -1
        object["clock_corrections"] = ["mic": summary]
        XCTAssertThrowsError(try LocalAudioRecorder.decodeManifest(JSONSerialization.data(withJSONObject: object)))
        object["clock_corrections"] = ["unknown": try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))]
        XCTAssertThrowsError(try LocalAudioRecorder.decodeManifest(JSONSerialization.data(withJSONObject: object)))
    }

    private func clockCorrection(generation: Int, native: Int64, nominal: Int64, host: Int64,
                                 observed: Int64, uncertain: Int64 = 0, ratio: Double = 1.0001) -> CapturedClockCorrection {
        CapturedClockCorrection(native_frames: native, nominal_output_frames: nominal, host_output_frames: host,
            observed_intervals: observed, uncertain_intervals: uncertain, min_rate_ratio: ratio,
            max_rate_ratio: ratio, generation: generation)
    }

    private func clockPacket(generation: Int, time: Int64, correction: CapturedClockCorrection) -> CapturedMicAudio {
        CapturedMicAudio(data: samples(160), captureTimeUs: time, generation: generation, nativeSampleRate: 48000,
            nativeChannels: 1, nativeFrameCount: 480, formatEpoch: 1, outputSampleRate: 16000, clockCorrection: correction)
    }

    func testPerStreamWriteFailurePreservesLaterHealthySourcePackets() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, commitInterval: 0.01, beforeIO: { checkpoint in
            if case .write(.mic) = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        })
        XCTAssertTrue(recorder.record(source: .system, ptsUs: 0, payload: samples(160)))
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 0, payload: samples(160)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.status().error == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(recorder.status().error)
        let accepted = recorder.record(source: .system, ptsUs: 10_000, payload: samples(160))
        let result = try await finish(recorder)
        print("per_stream_mic_write_failure: later_system_accepted=\(accepted), system_committed=\(result.streams["system"]?.committed_bytes ?? -1), system_dropped=\(result.streams["system"]?.dropped_frames ?? -1)")
        XCTAssertTrue(accepted, "A mic-only write error must not disable the still-writable system track")
        XCTAssertEqual(result.streams["system"]?.committed_bytes, 640)
        XCTAssertEqual(result.streams["system"]?.dropped_frames, 0)
        XCTAssertFalse(result.completed, "The failed mic must remain degraded")
    }

    func testSystemWriteFailureRejectsOnlySystemAndNewSessionCannotEraseIt() async throws {
        let oldFolder = try folder()
        let recorder = try LocalAudioRecorder(directory: oldFolder, beforeIO: { checkpoint in
            if case .write(.system) = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        })
        XCTAssertTrue(recorder.record(source: .system, ptsUs: 0, payload: samples(160)))
        try await waitForFailure(recorder)
        XCTAssertTrue(recorder.status().accepting, "The shared store remains available to the healthy stream")
        XCTAssertFalse(recorder.record(source: .system, ptsUs: 10_000, payload: samples(160)))
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 0, payload: samples(160)))
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 10_000, payload: samples(160)))
        let old = try await finish(recorder)
        XCTAssertFalse(old.completed)
        XCTAssertEqual(old.streams["mic"]?.committed_bytes, 640)
        XCTAssertEqual(old.streams["mic"]?.dropped_frames, 0)
        XCTAssertEqual(old.streams["system"]?.dropped_frames, 320)
        XCTAssertTrue(old.losses.contains { $0.source == "system" && $0.reason == "source_failed" && $0.frames == 160 })
        XCTAssertFalse(recorder.status().error?.contains("queue is full") ?? true)
        XCTAssertEqual(try Data(contentsOf: oldFolder.appendingPathComponent("mic.wav")).dropFirst(44), samples(320))

        // Resume creates a separate source. Its healthy completion cannot
        // mutate or upgrade the failed predecessor's persisted source outcome.
        let next = try LocalAudioRecorder(directory: folder())
        XCTAssertTrue(next.record(source: .mic, ptsUs: 0, payload: samples(160)))
        XCTAssertTrue(next.record(source: .system, ptsUs: 0, payload: samples(160)))
        let nextResult = try await finish(next)
        XCTAssertTrue(nextResult.completed)
        XCTAssertFalse(try LocalAudioRecorder.readManifest(directory: oldFolder).completed)
    }

    func testStreamFailureDrainsHealthyAcceptedQueueThroughFinish() async throws {
        let entered = TaskCompletion(), release = DispatchSemaphore(value: 0)
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, maxPendingBytes: 1280, beforeIO: { checkpoint in
            if case .write(.system) = checkpoint {
                entered.markCompleted()
                _ = release.wait(timeout: .now() + 3)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        })
        XCTAssertTrue(recorder.record(source: .system, ptsUs: 0, payload: samples(160)))
        let started = await entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(started, .completed)
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 0, payload: samples(160)))
        XCTAssertTrue(recorder.record(source: .system, ptsUs: 10_000, payload: samples(160)))
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 10_000, payload: samples(160)))
        XCTAssertEqual(recorder.status().queuedBytes, 1280, "The in-flight packet remains inside the shared cap")
        recorder.requestFinish()
        release.signal()
        let final = try await finish(recorder)
        XCTAssertFalse(final.completed)
        XCTAssertEqual(final.streams["mic"]?.committed_bytes, 640)
        XCTAssertEqual(final.streams["mic"]?.dropped_frames, 0)
        XCTAssertEqual(final.streams["system"]?.committed_bytes, 0)
        XCTAssertEqual(final.streams["system"]?.dropped_frames, 320)
        XCTAssertEqual(recorder.status().queuedBytes, 0)
        XCTAssertEqual(recorder.status().uncommittedPackets, 0)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.pcm")), samples(320))
        let repeated = try await finish(recorder)
        XCTAssertEqual(repeated.revision, final.revision, "Repeated Finish does not republish or lose the accepted prefix")
    }

    func testSharedCommitFailureStillClosesBothAdmissionGates() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), commitInterval: 0.01, beforeIO: { checkpoint in
            if case .manifest = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        })
        XCTAssertTrue(recorder.record(source: .mic, ptsUs: 0, payload: samples(160)))
        XCTAssertTrue(recorder.record(source: .system, ptsUs: 0, payload: samples(160)))
        try await waitForFailure(recorder)
        XCTAssertFalse(recorder.status().accepting)
        XCTAssertFalse(recorder.record(source: .mic, ptsUs: 10_000, payload: samples(160)))
        XCTAssertFalse(recorder.record(source: .system, ptsUs: 10_000, payload: samples(160)))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
    }

    func testInvalidSharedInventoryStillClosesBothAdmissionGates() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), beforeIO: { checkpoint in
            if case .write(.system) = checkpoint { throw LocalAudioRecorder.RecorderError.invalidManifest }
        })
        XCTAssertTrue(recorder.record(source: .system, ptsUs: 0, payload: samples(160)))
        try await waitForFailure(recorder)
        XCTAssertFalse(recorder.status().accepting)
        XCTAssertFalse(recorder.record(source: .mic, ptsUs: 0, payload: samples(160)))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
    }

    private func waitForFailure(_ recorder: LocalAudioRecorder) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.status().error == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(recorder.status().error)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func finish(_ recorder: LocalAudioRecorder) async throws -> LocalAudioRecorder.Manifest {
        let result = await recorder.finish(timeoutSeconds: 5)
        return try XCTUnwrap(result)
    }

    private func samples(_ count: Int, value: Int16 = 9) -> Data {
        var sample = value.littleEndian
        let frame = withUnsafeBytes(of: &sample) { Data($0) }
        return (0..<count).reduce(into: Data()) { data, _ in data.append(frame) }
    }

    func testPreservesBothSourcesWithoutAnInferenceProcess() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url)
        let data = samples(1600)
        for i in 0..<3 {
            XCTAssertTrue(recorder.record(source: .mic, ptsUs: Int64(i * 100_000), payload: data))
            XCTAssertTrue(recorder.record(source: .system, ptsUs: Int64(i * 100_000), payload: data))
        }
        let result = try await finish(recorder)
        XCTAssertTrue(result.completed)
        for source in ["mic", "system"] {
            XCTAssertEqual(result.streams[source]?.committed_bytes, 9600)
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(source + ".pcm")), data + data + data)
            let wav = try Data(contentsOf: url.appendingPathComponent(source + ".wav"))
            XCTAssertEqual(wav.count, 9644)
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(wav.dropFirst(44), data + data + data)
        }
    }

    @MainActor
    func testProductionIngressPersistsWhileUIBlockedAndInferenceIsKilled() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, commitInterval: 0.05)
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: 0))
        await forwarder.beginGeneration(1, writer: recorder, outputEnabled: true)
        let display = MicDeliveryDisplayMailbox { _ in }
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: display)
        let callback = ingress.callback()
        // This deliberately unresponsive child stands in for inference. It
        // never reads audio: the production sink now owns PCM independently.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for index in 0..<200 {
                if index == 100 { child.terminate() }
                let pcm = Data(repeating: 7, count: 320)
                callback(CapturedMicAudio(data: pcm, captureTimeUs: Int64(index * 10_000), generation: 1,
                    nativeSampleRate: 16000, nativeChannels: 1, nativeFrameCount: 160, formatEpoch: 1, outputSampleRate: 16000))
                recorder.send(type: .audio, stream: .system, ptsUs: Int64(index * 10_000), payload: pcm)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while ProcessInfo.processInfo.systemUptime < deadline {
                if recorder.status().committedBytes == 128_000 { done.signal(); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        await ingress.finish()
        let result = try await finish(recorder)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 64_000)
        XCTAssertEqual(result.streams["system"]?.committed_bytes, 64_000)
        XCTAssertEqual(result.streams["mic"]?.gap_frames, 0)
        XCTAssertEqual(result.streams["mic"]?.overlap_frames, 0)
    }

    func testDrainRetainsAcceptedPacketsAcrossFinishAndRepeatedFinish() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        for i in 0..<200 {
            XCTAssertTrue(recorder.record(source: .mic, ptsUs: Int64(i * 1000), payload: samples(16)))
        }
        let one = try await finish(recorder)
        let two = try await finish(recorder)
        XCTAssertEqual(one.streams["mic"]?.committed_bytes, 6400)
        XCTAssertEqual(one.revision, two.revision)
        XCTAssertFalse(recorder.record(source: .mic, ptsUs: 200_000, payload: samples(16)))
    }

    func testRecordsSourceGapAndOverlapWithExactRanges() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(1600))
        recorder.record(source: .mic, ptsUs: 200_000, payload: samples(1600))
        recorder.record(source: .mic, ptsUs: 250_000, payload: samples(1600))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(result.last_problem)
        XCTAssertEqual(result.streams["mic"]?.gap_frames, 1600)
        XCTAssertEqual(result.streams["mic"]?.overlap_frames, 800)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 11_200)
        XCTAssertEqual(result.losses.first?.start_frame, 1600)
        XCTAssertEqual(result.losses.first?.end_frame, 3200)
    }

    func testOversizedPacketIsRejectedAndPersistedAsLoss() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), maxPendingBytes: 32)
        XCTAssertFalse(recorder.record(source: .mic, ptsUs: 0, payload: samples(17)))
        let result = try await finish(recorder)
        XCTAssertEqual(result.streams["mic"]?.dropped_frames, 17)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.first?.reason, "ingress_overflow")
    }

    func testInvalidTimestampCannotAllocateSilenceOrOverflowArithmetic() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        XCTAssertFalse(recorder.record(source: .system, ptsUs: Int64.max, payload: samples(16)))
        XCTAssertFalse(recorder.record(source: .system, ptsUs: -1, payload: samples(16)))
        let result = try await finish(recorder)
        XCTAssertEqual(result.streams["system"]?.committed_bytes, 0)
        XCTAssertEqual(result.streams["system"]?.dropped_frames, 32)
    }

    func testWriteFailureNeverCommitsFailedPacket() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), beforeIO: { checkpoint in
            if case .write(.mic) = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
        })
        recorder.record(source: .mic, ptsUs: 0, payload: samples(1600))
        let result = try await finish(recorder)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 0)
        XCTAssertEqual(result.streams["mic"]?.dropped_frames, 1600)
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(result.last_problem)
        XCTAssertNotNil(recorder.status().error)
    }

    func testManifestFailureRetainsOldCommittedPrefixAndReportsUncleanClose() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, beforeIO: { checkpoint in
            if case .manifest = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
        })
        recorder.record(source: .system, ptsUs: 0, payload: samples(1600))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(try LocalAudioRecorder.readManifest(directory: url).streams["system"]?.committed_bytes, 0)
        XCTAssertEqual(recorder.status().committedBytes, 0)
        XCTAssertNotNil(result.last_problem)
        XCTAssertGreaterThan(result.problem_count, 0)
        XCTAssertNotNil(recorder.status().error)
    }

    func testSyncFailureIsReturnedEvenWhenDiskCannotSaveItsDiagnostic() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), beforeIO: { checkpoint in
            if case .sync(.mic) = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
        })
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(result.last_problem)
        XCTAssertGreaterThan(result.problem_count, 0)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 0)
    }

    func testBlockedDiskCloseExpiresWithoutClosingAnotherOwnersHandle() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let recorder = try LocalAudioRecorder(directory: folder(), beforeIO: { checkpoint in
            if case .sync(.mic) = checkpoint {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        })
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        let result = await recorder.finish(timeoutSeconds: 0.05)
        XCTAssertNil(result)
        XCTAssertFalse(recorder.status().accepting)
        XCTAssertNotNil(recorder.status().error)
        XCTAssertEqual(recorder.status().committedBytes, 0)
        XCTAssertEqual(recorder.status().uncommittedPackets, 1)
        release.signal()
        release.signal()
        let later = await recorder.finish(timeoutSeconds: 5)
        XCTAssertNotNil(later)
        XCTAssertTrue(later?.completed ?? false, "A later verified close may be clean; the deadline described only the earlier wait")
    }

    func testDeadlineDuringFinalManifestDoesNotPretendOwnerHasClosed() async throws {
        let url = try folder()
        let counter = RecorderTestCounter()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let recorder = try LocalAudioRecorder(directory: url, commitInterval: 60, beforeIO: { checkpoint in
            if case .manifest = checkpoint, counter.next() == 2 {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        })
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        let closing = Task.detached { await recorder.finish(timeoutSeconds: 0.1) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let initial = await closing.value
        XCTAssertNil(initial)
        XCTAssertFalse(try LocalAudioRecorder.readManifest(directory: url).completed)
        release.signal()
        let eventual = try await finish(recorder)
        XCTAssertTrue(eventual.completed)
        XCTAssertTrue(try LocalAudioRecorder.readManifest(directory: url).completed)
        XCTAssertNil(recorder.status().error)
    }

    func testInitialSourceAlignmentIsDistinctFromMidstreamLoss() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 1_000_000, payload: samples(160))
        recorder.record(source: .mic, ptsUs: 1_010_000, payload: samples(160))
        let result = try await finish(recorder)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.losses.first?.reason, "initial_source_alignment")
    }

    func testTerminalConversionFailureDegradesWithoutAnyLaterBuffer() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        recorder.reportFailure(stream: .mic, message: "final buffer conversion failed")
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 320)
        XCTAssertEqual(result.losses.last?.reason, "source_failure_unknown_range")
    }

    func testWAVFailurePreservesPCMAndMarksCompatibilityIncomplete() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, beforeIO: { checkpoint in
            if case .export = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
        })
        let data = samples(1600)
        recorder.record(source: .mic, ptsUs: 0, payload: data)
        let result = try await finish(recorder)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 3200)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.pcm")), data)
        XCTAssertNotNil(result.last_problem)
        let recovered = try LocalAudioRecorder.recoverWAVs(directory: url)
        XCTAssertFalse(recovered.completed, "Export must not rewrite historical interruption status")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.wav")).dropFirst(44), data)
    }

    func testRecoveryIgnoresUncommittedTail() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url)
        let data = samples(160)
        recorder.record(source: .mic, ptsUs: 0, payload: data)
        _ = try await finish(recorder)
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent("mic.pcm"))
        try handle.seekToEnd()
        try handle.write(contentsOf: samples(100, value: 77))
        try handle.close()
        _ = try LocalAudioRecorder.recoverWAVs(directory: url)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.wav")).dropFirst(44), data)
    }

    func testNeverTruncatesAnExistingRecording() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url)
        recorder.record(source: .mic, ptsUs: 0, payload: samples(160))
        _ = try await finish(recorder)
        XCTAssertThrowsError(try LocalAudioRecorder(directory: url))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.pcm")).count, 320)
    }
}

nonisolated private final class RecorderTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
