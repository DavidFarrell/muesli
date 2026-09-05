import Foundation
import XCTest

final class LocalAudioRecorderTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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
        let result = await recorder.finish()
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
        let result = await recorder.finish()
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
        let one = await recorder.finish()
        let two = await recorder.finish()
        XCTAssertEqual(one.streams["mic"]?.committed_bytes, 6400)
        XCTAssertEqual(one.revision, two.revision)
        XCTAssertFalse(recorder.record(source: .mic, ptsUs: 200_000, payload: samples(16)))
    }

    func testRecordsSourceGapAndOverlapWithExactRanges() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        recorder.record(source: .mic, ptsUs: 0, payload: samples(1600))
        recorder.record(source: .mic, ptsUs: 200_000, payload: samples(1600))
        recorder.record(source: .mic, ptsUs: 250_000, payload: samples(1600))
        let result = await recorder.finish()
        XCTAssertEqual(result.streams["mic"]?.gap_frames, 1600)
        XCTAssertEqual(result.streams["mic"]?.overlap_frames, 800)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 11_200)
        XCTAssertEqual(result.losses.first?.start_frame, 1600)
        XCTAssertEqual(result.losses.first?.end_frame, 3200)
    }

    func testOversizedPacketIsRejectedAndPersistedAsLoss() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), maxPendingBytes: 32)
        XCTAssertFalse(recorder.record(source: .mic, ptsUs: 0, payload: samples(17)))
        let result = await recorder.finish()
        XCTAssertEqual(result.streams["mic"]?.dropped_frames, 17)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.losses.first?.reason, "ingress_overflow")
    }

    func testInvalidTimestampCannotAllocateSilenceOrOverflowArithmetic() async throws {
        let recorder = try LocalAudioRecorder(directory: folder())
        XCTAssertFalse(recorder.record(source: .system, ptsUs: Int64.max, payload: samples(16)))
        XCTAssertFalse(recorder.record(source: .system, ptsUs: -1, payload: samples(16)))
        let result = await recorder.finish()
        XCTAssertEqual(result.streams["system"]?.committed_bytes, 0)
        XCTAssertEqual(result.streams["system"]?.dropped_frames, 32)
    }

    func testWriteFailureNeverCommitsFailedPacket() async throws {
        let recorder = try LocalAudioRecorder(directory: folder(), beforeIO: { checkpoint in
            if case .write(.mic) = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
        })
        recorder.record(source: .mic, ptsUs: 0, payload: samples(1600))
        let result = await recorder.finish()
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
        let result = await recorder.finish()
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
        let result = await recorder.finish()
        XCTAssertFalse(result.completed)
        XCTAssertNotNil(result.last_problem)
        XCTAssertGreaterThan(result.problem_count, 0)
        XCTAssertEqual(result.streams["mic"]?.committed_bytes, 0)
    }

    func testWAVFailurePreservesPCMAndMarksCompatibilityIncomplete() async throws {
        let url = try folder()
        let recorder = try LocalAudioRecorder(directory: url, beforeIO: { checkpoint in
            if case .export = checkpoint { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
        })
        let data = samples(1600)
        recorder.record(source: .mic, ptsUs: 0, payload: data)
        let result = await recorder.finish()
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
        _ = await recorder.finish()
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
        _ = await recorder.finish()
        XCTAssertThrowsError(try LocalAudioRecorder(directory: url))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("mic.pcm")).count, 320)
    }
}
