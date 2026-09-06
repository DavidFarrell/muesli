import AVFoundation
import XCTest

nonisolated private final class BoundaryReviewStore: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [CapturedMicAudio] = []
    func append(_ packet: CapturedMicAudio) { lock.withLock { packets.append(packet) } }
    func values() -> [CapturedMicAudio] { lock.withLock { packets } }
}

final class ClockDriftBoundaryReviewTests: XCTestCase {
    private func buffer(rate: Double, start: Int, count: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1,count)))!
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 1000 * Double(start+i) / rate)) }
        return buffer
    }
    func testEmptyNativeCallbacksDoNotResetFilterOrLoseFractionalOutput() {
        let store = BoundaryReviewStore(), processor = MicCaptureProcessor(generation: 1) { store.append($0) }
        let count = 147, rate = 44100.0, callbacks = 120
        for index in 0..<callbacks {
            let start = index * count
            processor.receive(buffer(rate: rate, start: start, count: count),
                captureTimeUs: Int64((Double(start) * 1_000_000 / rate).rounded()), nativeSampleTime: Int64(start))
            if index < callbacks-1 {
                let next = start + count
                processor.receive(buffer(rate: rate, start: next, count: 0),
                    captureTimeUs: Int64((Double(next) * 1_000_000 / rate).rounded()), nativeSampleTime: Int64(next))
            }
        }
        processor.finish()
        let state = processor.snapshot(), frames = store.values().reduce(0) { $0+$1.outputFrameCount }
        print("REVIEW empty_callbacks epochs=\(state.formatEpoch) frames=\(frames) expected=6400")
        XCTAssertEqual(state.formatEpoch, 1)
        XCTAssertEqual(frames, 6400, "Empty native callbacks cannot discard actual audio through repeated epoch rounding")
    }
    func testMicrosecondQuantizationAndIrregularNativePartitionsStayBoundedAndContinuous() {
        for ratio in [0.995, 1.0, 1.005] {
            let store = BoundaryReviewStore(), processor = MicCaptureProcessor(generation: 1) { store.append($0) }
            let rate = 48000.0, total = 48000
            let parts = [1,2,17,479,997,53]
            var position = 0, part = 0
            while position < total {
                let count = min(parts[part % parts.count], total-position)
                processor.receive(buffer(rate: rate, start: position, count: count),
                    captureTimeUs: Int64((Double(position) * 1_000_000 / rate * ratio).rounded()), nativeSampleTime: Int64(position))
                position += count; part += 1
            }
            processor.finish()
            let packets = store.values(), state = processor.snapshot()
            var priorEnd: Int64 = 0
            for packet in packets {
                XCTAssertEqual(packet.captureTimeUs, priorEnd * 1_000_000 / 16000)
                priorEnd += Int64(packet.outputFrameCount)
            }
            print("REVIEW quantization ratio=\(ratio) epochs=\(state.formatEpoch) frames=\(priorEnd) min=\(String(describing: state.minimumClockRatio)) max=\(String(describing: state.maximumClockRatio))")
            XCTAssertEqual(state.formatEpoch, 1)
            XCTAssertEqual(Double(priorEnd), 16000 * ratio, accuracy: 1)
        }
    }
}
