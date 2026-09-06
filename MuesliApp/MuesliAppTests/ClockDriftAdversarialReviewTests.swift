import AVFoundation
import XCTest

final class ClockDriftAdversarialReviewTests: XCTestCase {
    private func buffer(start: Int, count: Int = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, count)))!
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 1000 * Double(start+i) / 48000)) }
        return buffer
    }
    private func recording(reset: Bool) async throws -> LocalAudioRecorder.Manifest {
        let directory = URL(fileURLWithPath: "/private/tmp/muesli-clock-accounting-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try LocalAudioRecorder(directory: directory)
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .mic)
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: 0))
        await forwarder.beginGeneration(1, writer: recorder, outputEnabled: true)
        let report = await forwarder.captureFailureHandler()
        let processor = MicCaptureProcessor(generation: 1, onProblem: report) { packet in
            recorder.record(source: .mic, ptsUs: packet.captureTimeUs, payload: packet.data)
        }
        for index in 0..<20 {
            let hostIndex = index * 480 + (!reset && index >= 10 ? 480 : 0)
            let sampleIndex = reset
                ? (index < 10 ? 8 * 3600 * 48000 + index * 480 : (index-10) * 480)
                : hostIndex
            processor.receive(buffer(start: index*480), captureTimeUs: Int64(hostIndex) * 1_000_000 / 48000,
                              nativeSampleTime: Int64(sampleIndex))
        }
        processor.finish()
        let result = await recorder.finish(timeoutSeconds: 5)
        return try XCTUnwrap(result)
    }
    func testNativeCounterResetMustNotInventEightHoursOfDroppedAudio() async throws {
        let manifest = try await recording(reset: true)
        let mic = try XCTUnwrap(manifest.streams["mic"])
        print("REVIEW reset captured=\(mic.captured_frames) dropped=\(mic.dropped_frames) gap=\(mic.gap_frames) losses=\(manifest.losses)")
        XCTAssertEqual(mic.captured_frames, 3200)
        XCTAssertEqual(mic.gap_frames, 0)
        XCTAssertEqual(mic.dropped_frames, 0, "Native counter reset changes origin; it does not prove eight hours of missing audio")
    }
    func testOneNativeGapMustNotBeCountedAsBothDroppedAndSparseGap() async throws {
        let manifest = try await recording(reset: false)
        let mic = try XCTUnwrap(manifest.streams["mic"])
        print("REVIEW gap captured=\(mic.captured_frames) dropped=\(mic.dropped_frames) gap=\(mic.gap_frames) losses=\(manifest.losses)")
        XCTAssertEqual(mic.gap_frames, 160)
        XCTAssertEqual(mic.dropped_frames + mic.gap_frames, 160, "One ten-millisecond omission must not become twenty milliseconds across loss counters")
    }
    func testInverseClockTimestampIsNotADeviceSampleCounter() throws {
        let processor = MicCaptureProcessor(generation: 1) { _ in }
        // Apple permits port.clock not to be the actual device clock. A host
        // clock is therefore a valid stand-in for this limitation. These are
        // contiguous 48kHz buffers on a device running 100ppm off host time.
        for index in 0..<300 {
            let pcm = buffer(start: index * 480)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                presentationTimeStamp: CMTime(value: Int64(index) * 10001, timescale: 1_000_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
                sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let ready = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(ready, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
            CMSampleBufferSetDataReady(ready)
            processor.receive(ready, sourceClock: CMClockGetHostTimeClock())
        }
        processor.finish()
        let state = processor.snapshot()
        print("REVIEW inverse_clock epochs=\(state.formatEpoch) uncertain=\(state.uncertainIntervals) observed=\(state.observedIntervals)")
        XCTAssertEqual(state.formatEpoch, 1, "Inverse clock conversion cannot turn continuous drift into native sample gaps")
        XCTAssertGreaterThan(state.uncertainIntervals, 0, "A port clock is not guaranteed to expose exact sample-counter continuity")
    }

}
