import AVFoundation
import XCTest

final class StreamingAudioConverterTests: XCTestCase {
    nonisolated private func makeBuffer(rate: Double, channels: Int, start: Int, count: Int,
                                        sample: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            for frame in 0..<count { buffer.floatChannelData![channel][frame] = sample(start + frame, channel) }
        }
        return buffer
    }

    nonisolated private func render(rate: Double, count: Int, partitions: [Int], channels: Int = 1,
                                    sample: (Int, Int) -> Float) throws -> Data {
        let converter = AudioConverterHelper()
        var output = Data()
        var offset = 0
        var partition = 0
        while offset < count {
            let length = min(count - offset, partitions[partition % partitions.count])
            output.append(try converter.convertToInt16(buffer: makeBuffer(rate: rate, channels: channels, start: offset, count: length, sample: sample)))
            offset += length
            partition += 1
        }
        output.append(try converter.finish())
        return output
    }

    func testPartitioningPreservesExactSampleSequenceAndDurationAt44100And48000() throws {
        for rate in [44_100.0, 48_000.0] {
            let source: (Int, Int) -> Float = { index, _ in Float(0.5 * sin(Double(index) * 2 * .pi * 700 / rate)) }
            let whole = try render(rate: rate, count: Int(rate), partitions: [Int(rate)], sample: source)
            let partitioned = try render(rate: rate, count: Int(rate), partitions: [17, 511, 63, 4096, 257], sample: source)
            XCTAssertEqual(whole.count / 2, 16_000)
            XCTAssertEqual(partitioned, whole, "SRC output must be independent of callback partitions at \(rate) Hz")
        }
    }

    func testAntiAliasFilterRejectsToneAboveOutputNyquist() throws {
        let rate = 48_000.0
        func rms(_ data: Data) -> Double {
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let settled = samples.dropFirst(500).dropLast(500)
            return sqrt(settled.reduce(0) { $0 + pow(Double($1) / 32768, 2) } / Double(settled.count))
        }
        let passband = try render(rate: rate, count: 48_000, partitions: [997]) { index, _ in
            Float(0.5 * sin(Double(index) * 2 * .pi * 1000 / rate))
        }
        let stopband = try render(rate: rate, count: 48_000, partitions: [997]) { index, _ in
            Float(0.5 * sin(Double(index) * 2 * .pi * 12000 / rate))
        }
        XCTAssertGreaterThan(rms(passband), 0.3)
        XCTAssertLessThan(rms(stopband), rms(passband) * 0.01, "At least 40 dB rejection of the 12 kHz alias")
    }

    func testConverterCompensatesFilterDelayInSourceTimestampDomain() throws {
        let data = try render(rate: 48000, count: 48000, partitions: [480]) { index, _ in index == 4800 ? 0.8 : 0 }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let peak = samples.indices.max { abs(Int(samples[$0])) < abs(Int(samples[$1])) }
        XCTAssertEqual(peak, 1600, "Filter delay must not shift audio away from native capture timestamps")
    }

    func testSilentReceiverChannelsPreserveLiveChannelAndStereoAverages() throws {
        let single = try render(rate: 16000, count: 1600, partitions: [97]) { _, _ in 0.4 }
        let receiver = try render(rate: 16000, count: 1600, partitions: [17, 143], channels: 4) { _, channel in channel == 2 ? 0.4 : 0 }
        XCTAssertEqual(receiver, single)
        let stereo = try render(rate: 16000, count: 1600, partitions: [160], channels: 2) { _, channel in channel == 0 ? 0.6 : 0.2 }
        XCTAssertEqual(stereo, single)
    }

    func testActiveStereoZeroCrossingsUseStableDivisorAcrossPartitions() throws {
        let count = 16017 // exercise the final partial analysis window too
        let source: (Int, Int) -> Float = { index, channel in
            channel == 0 ? 0.4 : Float(0.2 * sin(2 * .pi * 1000 * Double(index) / 16000))
        }
        let whole = try render(rate: 16000, count: count, partitions: [count], channels: 2, sample: source)
        let partitioned = try render(rate: 16000, count: count, partitions: [1, 17, 997, 53], channels: 2, sample: source)
        XCTAssertEqual(whole, partitioned)
        let samples = whole.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples.count, count)
        for index in samples.indices {
            let expected = Double((source(index, 0) + source(index, 1)) / 2)
            XCTAssertEqual(Double(samples[index]) / 32767, expected, accuracy: 0.00005,
                           "Stereo must not double the remaining lane at zero crossing \(index)")
        }
    }

    func testProcessorPreservesSourceGapAndResetsOnlyAtFormatEpoch() {
        let store = ConverterPacketStore()
        let processor = MicCaptureProcessor(generation: 7) { store.append($0) }
        for index in 0..<10 {
            let buffer = makeBuffer(rate: 48000, channels: 1, start: index * 480, count: 480) { _, _ in 0.25 }
            processor.receive(buffer, captureTimeUs: 1_000_000 + Int64(index) * 10_000)
        }
        let changed = makeBuffer(rate: 16000, channels: 1, start: 0, count: 160) { _, _ in 0.25 }
        processor.receive(changed, captureTimeUs: 2_000_000)
        processor.finish()
        let packets = store.snapshot()
        XCTAssertEqual(packets.reduce(0) { $0 + $1.outputFrameCount }, 1760)
        XCTAssertTrue(packets.allSatisfy { $0.generation == 7 })
        XCTAssertEqual(packets.first?.captureTimeUs, 1_000_000)
        XCTAssertEqual(packets.last?.captureTimeUs, 2_000_000)
        XCTAssertEqual(processor.snapshot().formatEpoch, 2)
        // Retirement rejects late native callbacks and does not flush twice.
        processor.receive(changed, captureTimeUs: 2_010_000)
        processor.finish()
        XCTAssertEqual(store.snapshot().count, packets.count)
    }
}

nonisolated private final class ConverterPacketStore: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [CapturedMicAudio] = []
    func append(_ packet: CapturedMicAudio) { lock.withLock { packets.append(packet) } }
    func snapshot() -> [CapturedMicAudio] { lock.withLock { packets } }
}
