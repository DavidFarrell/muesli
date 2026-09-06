import AVFoundation
import XCTest

final class StreamingAudioConverterTests: XCTestCase {
    func testClockDriftAndTimestampJitterThroughActualIngressPersistCorrectionWithoutLoss() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try LocalAudioRecorder(directory: directory)
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        let epoch: Int64 = 50_000_000
        await forwarder.beginMeeting(epoch: CaptureTimeline(epochMicroseconds: epoch))
        await forwarder.beginGeneration(7, writer: recorder, outputEnabled: true)
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: MicDeliveryDisplayMailbox { _ in },
            onRejected: { packet, reason in
                recorder.noteLoss(source: .mic, ptsUs: packet.captureTimeUs - epoch,
                    frames: Int64(packet.outputFrameCount), reason: reason.rawValue)
            }, onProblem: await forwarder.captureFailureHandler())
        let processor = MicCaptureProcessor(generation: 7, onProblem: ingress.problemCallback(), output: ingress.callback())
        for index in 0..<80 {
            let start = index * 4800
            let buffer = makeBuffer(rate: 48000, channels: 1, start: start, count: 4800) { sample, _ in
                Float(0.2 * sin(Double(sample) * 2 * .pi * 700 / 48000))
            }
            let jitter = index == 0 ? 0 : (index % 2 == 0 ? 10 : -10)
            processor.receive(buffer, captureTimeUs: epoch + Int64(index * 100010 + jitter), nativeSampleTime: Int64(start + 100000))
        }
        processor.finish()
        await ingress.finish()
        let completion = await recorder.finish(timeoutSeconds: 5)
        let manifest = try XCTUnwrap(completion)
        let persisted = try LocalAudioRecorder.readManifest(directory: directory)
        let correction = try XCTUnwrap(persisted.clock_corrections?["mic"])
        XCTAssertEqual(processor.snapshot().formatEpoch, 1)
        XCTAssertEqual(ingress.snapshot().droppedSamples, 0)
        XCTAssertTrue(manifest.losses.isEmpty)
        XCTAssertTrue(manifest.completed)
        XCTAssertEqual(correction.native_frames, 384000)
        XCTAssertEqual(correction.nominal_output_frames, 128000)
        XCTAssertEqual(correction.host_output_frames, manifest.streams["mic"]?.captured_frames)
        XCTAssertEqual(Double(correction.host_output_frames), 128000 * 1.0001, accuracy: 1)
        XCTAssertEqual(correction.observed_intervals, 79)
        XCTAssertEqual(correction.uncertain_intervals, 1, "Only the final callback endpoint is extrapolated")
        await forwarder.stop()
    }

    func testRetimerMaintainsHostAlignmentAndPassbandAcrossPartitionsAndDrift() {
        for ratio in [0.995, 0.9999, 1.0, 1.0001, 1.005] {
            let retimer = HostAudioRetimer()
            var output = Data()
            let count = 160_000
            var source = 0, part = 0, maximumBuffered = 0
            let partitions = [17, 997, 1600, 53, 4096]
            while source < count {
                if source > 0 { retimer.addAnchor(sourceFrame: Double(source), hostFrame: Double(source) * ratio) }
                let size = min(count - source, partitions[part % partitions.count])
                let samples = (source..<(source + size)).map { index in Int16((12000 * sin(2 * .pi * 1000 * Double(index) / 16000)).rounded()) }
                retimer.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })
                output.append(retimer.render(endingAtSourceFrame: nil))
                maximumBuffered = max(maximumBuffered, retimer.bufferedFrames)
                source += size; part += 1
            }
            output.append(retimer.render(endingAtSourceFrame: Double(count)))
            let samples = output.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            XCTAssertEqual(samples.count, Int((Double(count) * ratio + 1e-7).rounded(.down)))
            XCTAssertLessThan(maximumBuffered, 10_000, "History must not grow with recording length")
            var squaredError = 0.0, energy = 0.0
            for index in 100..<(samples.count - 100) {
                let expected = 12000 * sin(2 * .pi * 1000 * Double(index) / (16000 * ratio))
                squaredError += pow(Double(samples[index]) - expected, 2)
                energy += expected * expected
            }
            let snr = 10 * log10(energy / squaredError)
            print("host_retimer ratio=\(ratio) frames=\(samples.count) snr_db=\(snr) maximum_buffer=\(maximumBuffered)")
            XCTAssertGreaterThan(snr, 65, "Waveform stays aligned with the host clock across packet boundaries")
        }
    }

    func testRetimerRejectsNearNyquistAliasingAtFastestSupportedClock() {
        func rms(frequency: Double) -> Double {
            let retimer = HostAudioRetimer()
            let count = 32000
            let samples = (0..<count).map { Int16((12000 * sin(2 * .pi * frequency * Double($0) / 16000)).rounded()) }
            retimer.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })
            retimer.addAnchor(sourceFrame: Double(count), hostFrame: Double(count) * 0.995)
            let output = retimer.render(endingAtSourceFrame: Double(count)).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let settled = output.dropFirst(200).dropLast(200)
            return sqrt(settled.reduce(0) { $0 + pow(Double($1), 2) } / Double(settled.count))
        }
        let rejection = 20 * log10(rms(frequency: 7990) / rms(frequency: 1000))
        let passband = 20 * log10(rms(frequency: 7000) / rms(frequency: 1000))
        print("host_retimer alias_db=\(rejection)")
        XCTAssertLessThan(rejection, -35)
        XCTAssertEqual(passband, 0, accuracy: 0.1, "Preserve the speech passband through 7 kHz")
    }

    func testNativeFrameEvidenceReportsOneFrameGapAndDuplicateDespiteClockDrift() {
        for missing in [-1, 1] {
            let store = ConverterPacketStore(), problems = ConverterProblemStore()
            let processor = MicCaptureProcessor(generation: 4, onProblem: { problems.append($0) }) { store.append($0) }
            for index in 0..<20 {
                let nativeStart = index * 480 + (index >= 10 ? missing : 0)
                let buffer = makeBuffer(rate: 48000, channels: 1, start: nativeStart, count: 480) { _, _ in 0.2 }
                processor.receive(buffer, captureTimeUs: Int64((Double(nativeStart) * 1_000_000 / 48000 * 1.0001).rounded()), nativeSampleTime: Int64(nativeStart))
            }
            processor.finish()
            XCTAssertEqual(processor.snapshot().formatEpoch, 2)
            XCTAssertEqual(processor.snapshot().uncertainIntervals, 2, "Each epoch retains its final-callback extrapolation uncertainty")
            XCTAssertEqual(problems.snapshot().count, 1)
            XCTAssertEqual(problems.snapshot().first?.nativeFrameCount, missing > 0 ? 1 : 0)
            XCTAssertEqual(problems.snapshot().first?.missingOutputFrames, 0, "The recorder accounts for host-grid gaps once; native evidence does not duplicate it")
            XCTAssertTrue(problems.snapshot().first?.message.contains(missing > 0 ? "1 missing native frames" : "duration is unknown") == true)
        }
    }

    func testNativeContinuityAndClockRatioChangeKeepOneConverterEpoch() {
        let store = ConverterPacketStore()
        let processor = MicCaptureProcessor(generation: 2) { store.append($0) }
        var hostUs = 0.0
        for index in 0..<400 {
            let buffer = makeBuffer(rate: 48000, channels: 1, start: index * 480, count: 480) { _, _ in 0.2 }
            processor.receive(buffer, captureTimeUs: Int64(hostUs.rounded()), nativeSampleTime: Int64(index * 480))
            hostUs += 10000 * (0.999 + Double(index) / 399 * 0.002)
        }
        processor.finish()
        let packets = store.snapshot()
        XCTAssertEqual(processor.snapshot().formatEpoch, 1)
        XCTAssertEqual(processor.snapshot().uncertainIntervals, 1, "The final callback has no observed end timestamp")
        XCTAssertEqual(processor.snapshot().observedIntervals, 399)
        var frames: Int64 = 0
        for packet in packets {
            XCTAssertEqual(packet.captureTimeUs, frames * 1_000_000 / 16000)
            frames += Int64(packet.outputFrameCount)
        }
        XCTAssertEqual(Double(frames), hostUs * 16000 / 1_000_000, accuracy: 1)
    }

    func testContinuousNativeClockDriftDoesNotBecomeRecordedSourceLoss() async throws {
        for ppm in [-100.0, 100.0] {
            let store = ConverterPacketStore()
            let processor = MicCaptureProcessor(generation: 1) { store.append($0) }
            let callbackFrames = 4800
            for index in 0..<600 {
                let buffer = makeBuffer(rate: 48_000, channels: 1,
                    start: index * callbackFrames, count: callbackFrames) { sample, _ in
                    Float(0.2 * sin(Double(sample) * 2 * .pi * 700 / 48_000))
                }
                let nativeHostTime = Int64((Double(index) * 100_000 * (1 + ppm / 1_000_000)).rounded())
                processor.receive(buffer, captureTimeUs: nativeHostTime)
            }
            processor.finish()
            let packets = store.snapshot()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let recorder = try LocalAudioRecorder(directory: directory, maxPendingBytes: 8 * 1024 * 1024)
            for packet in packets {
                XCTAssertTrue(recorder.record(source: .mic, ptsUs: packet.captureTimeUs, payload: packet.data))
            }
            let completion = await recorder.finish(timeoutSeconds: 10)
            let manifest = try XCTUnwrap(completion)
            let gap = manifest.streams["mic"]?.gap_frames ?? -1
            let overlap = manifest.streams["mic"]?.overlap_frames ?? -1
            print("clock_drift_ppm=\(ppm) epochs=\(processor.snapshot().formatEpoch) loss_count=\(manifest.losses.count) gap=\(gap) overlap=\(overlap)")
            XCTAssertEqual(processor.snapshot().formatEpoch, 1, "Continuous native buffers must retain SRC history through smooth clock drift")
            XCTAssertTrue(manifest.losses.isEmpty, "No source callback was missing or overlapped")
            XCTAssertTrue(manifest.completed, "Clock drift must not manufacture an incomplete source")
        }
    }

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

nonisolated private final class ConverterProblemStore: @unchecked Sendable {
    private let lock = NSLock()
    private var problems: [CapturedSourceProblem] = []
    func append(_ problem: CapturedSourceProblem) { lock.withLock { problems.append(problem) } }
    func snapshot() -> [CapturedSourceProblem] { lock.withLock { problems } }
}
