import AVFoundation
import Foundation

/// One streaming converter per native format epoch. The owner serializes calls.
/// AVAudioConverter retains SRC phase and anti-alias filter history between
/// input buffers. Explicit end-of-stream draining preserves its buffered tail.
nonisolated final class AudioConverterHelper {
    enum ChannelMixPolicy: Sendable { case meanOfActiveChannels, meanOfAllChannels }
    private let mixPolicy: ChannelMixPolicy
    private let targetSampleRate: Double
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var inputFrameCount: Int64 = 0
    private var emittedFrameCount: Int64 = 0
    private var pendingOutput = Data()
    private var pendingChannels: [[Float]] = []
    private var pendingSourceOffset = 0
    private var analysisWindowFrames = 1

    init(targetSampleRate: Double = 16000, mixPolicy: ChannelMixPolicy = .meanOfActiveChannels) {
        self.targetSampleRate = targetSampleRate
        self.mixPolicy = mixPolicy
    }

    func matches(_ format: AVAudioFormat) -> Bool { nativeFormat == format }

    func convertToInt16(buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        if !matches(buffer.format) { try configure(buffer.format) }
        try appendSource(buffer)
        inputFrameCount += Int64(buffer.frameLength)
        let useActivityWindow = mixPolicy == .meanOfActiveChannels && buffer.format.channelCount > 1
        var produced = Data()
        while pendingSourceFrames >= (useActivityWindow ? analysisWindowFrames : 1) {
            let count = useActivityWindow ? analysisWindowFrames : pendingSourceFrames
            produced.append(try convert(takeMixedSource(count: count), ending: false))
        }
        return takeSourceDurationOutput(produced)
    }

    func finish() throws -> Data {
        guard converter != nil else { return Data() }
        defer {
            converter = nil; nativeFormat = nil; monoFormat = nil; outputFormat = nil
            inputFrameCount = 0; emittedFrameCount = 0; pendingOutput.removeAll()
            pendingChannels.removeAll(); pendingSourceOffset = 0
        }
        var produced = Data()
        if pendingSourceFrames > 0 {
            produced.append(try convert(takeMixedSource(count: pendingSourceFrames), ending: false))
        }
        produced.append(try convert(nil, ending: true))
        return takeSourceDurationOutput(produced)
    }

    /// SRC end-of-stream includes filter padding. Deliver only the original
    /// source duration, with cumulative integer accounting independent of
    /// callback partitioning. Keep any fractional-frame surplus until later
    /// input can justify it; never delete a sample in the middle of an epoch.
    private func takeSourceDurationOutput(_ produced: Data) -> Data {
        pendingOutput.append(produced)
        guard let nativeFormat else { return Data() }
        let justified = Int64((Double(inputFrameCount) * targetSampleRate / nativeFormat.sampleRate).rounded(.down))
        let count = min(pendingOutput.count / 2, Int(max(0, justified - emittedFrameCount)))
        let result = Data(pendingOutput.prefix(count * 2))
        pendingOutput.removeFirst(count * 2)
        emittedFrameCount += Int64(count)
        return result
    }

    private func configure(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw ConversionError.invalidFormat }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        self.converter = converter
        nativeFormat = format
        monoFormat = input
        outputFormat = output
        pendingChannels = Array(repeating: [], count: Int(format.channelCount))
        pendingSourceOffset = 0
        analysisWindowFrames = max(1, Int((format.sampleRate * 0.020).rounded()))
    }

    private func convert(_ input: AVAudioPCMBuffer?, ending: Bool) throws -> Data {
        guard let converter, let outputFormat,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw ConversionError.invalidFormat }
        let supply = ConverterInput(input: input, ending: ending)
        var result = Data()
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                supply.next(status: inputStatus)
            }
            if let error { throw error }
            if let samples = output.floatChannelData?[0] {
                var converted = [Int16](repeating: 0, count: Int(output.frameLength))
                for index in converted.indices {
                    let sample = samples[index].isFinite ? samples[index] : 0
                    converted[index] = Int16((min(1, max(-1, sample)) * 32767).rounded(.towardZero))
                }
                result.append(converted.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return result
            case .error: throw ConversionError.converterFailed
            @unknown default: throw ConversionError.converterFailed
            }
        }
    }

    /// AVAudioConverter calls this synchronously during convert. The buffer
    /// remains owned by this conversion, never shared with another worker;
    /// the enclosing processor lock serializes every converter invocation.
    private final class ConverterInput: @unchecked Sendable {
        private let input: AVAudioPCMBuffer?
        private let ending: Bool
        private var supplied = false
        init(input: AVAudioPCMBuffer?, ending: Bool) { self.input = input; self.ending = ending }
        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if let input, !supplied {
                supplied = true
                status.pointee = .haveData
                return input
            }
            status.pointee = ending ? .endOfStream : .noDataNow
            return nil
        }
    }

    private var pendingSourceFrames: Int { (pendingChannels.first?.count ?? 0) - pendingSourceOffset }

    private func appendSource(_ buffer: AVAudioPCMBuffer) throws {
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let read: (Int, Int) -> Float
        if let values = buffer.floatChannelData {
            read = { frame, channel in interleaved ? values[0][frame * channels + channel] : values[channel][frame] }
        } else if let values = buffer.int16ChannelData {
            read = { frame, channel in Float(interleaved ? values[0][frame * channels + channel] : values[channel][frame]) / 32768 }
        } else if let values = buffer.int32ChannelData {
            read = { frame, channel in Float(interleaved ? values[0][frame * channels + channel] : values[channel][frame]) / 2147483648 }
        } else { throw ConversionError.unsupportedPCM }
        for channel in 0..<channels {
            for frame in 0..<Int(buffer.frameLength) {
                let value = read(frame, channel)
                pendingChannels[channel].append(value.isFinite ? value : 0)
            }
        }
    }

    /// Determine active lanes across fixed 20 ms source-frame windows, then
    /// use one divisor for that entire window. A genuine stereo lane remains
    /// active at its zero crossings; a silent receiver lane never attenuates
    /// another lane. Retaining incomplete windows makes analysis independent
    /// of native callback partitioning. Mono/system mixing needs no lookahead.
    private func takeMixedSource(count: Int) throws -> AVAudioPCMBuffer {
        guard let monoFormat,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count)),
              let destination = mono.floatChannelData?[0] else { throw ConversionError.invalidFormat }
        mono.frameLength = AVAudioFrameCount(count)
        let range = pendingSourceOffset..<(pendingSourceOffset + count)
        let allChannels = Array(pendingChannels.indices)
        var activeChannels = allChannels
        if mixPolicy == .meanOfActiveChannels {
            activeChannels = allChannels.filter { channel in
                range.contains { abs(pendingChannels[channel][$0]) >= 1e-4 }
            }
            if activeChannels.isEmpty { activeChannels = allChannels }
        }
        for frame in 0..<count {
            var total: Float = 0
            for channel in activeChannels { total += pendingChannels[channel][pendingSourceOffset + frame] }
            destination[frame] = total / Float(activeChannels.count)
        }
        pendingSourceOffset += count
        if pendingSourceOffset == pendingChannels[0].count {
            for channel in pendingChannels.indices { pendingChannels[channel].removeAll(keepingCapacity: true) }
            pendingSourceOffset = 0
        } else if pendingSourceOffset >= analysisWindowFrames * 4 {
            for channel in pendingChannels.indices { pendingChannels[channel].removeFirst(pendingSourceOffset) }
            pendingSourceOffset = 0
        }
        return mono
    }

    enum ConversionError: Error { case invalidFormat, unsupportedPCM, converterFailed, invalidTimestamp }
}

/// Native callbacks call synchronously into this small serialized owner; no
/// actor task is created before timestamping, conversion, or bounded ingress.
/// Stop takes the same lock, making the final SRC flush and callback retirement
/// atomic with respect to late native callbacks. Native buffers never escape.
nonisolated final class MicCaptureProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AudioConverterHelper
    private let generation: Int
    private let output: @Sendable (CapturedMicAudio) -> Void
    private let onProblem: (@Sendable (CapturedSourceProblem) -> Void)?
    private var currentTimeUs: Int64?
    private var currentRate: Double?
    private var currentFrameCount = 0
    private var stopped = false
    private var epochUs: Int64?
    private var nativeFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    private var nativeRate: Double = 0
    private var nativeChannels = 0
    private var conversionFailures = 0
    private var callbackCount = 0
    private var convertedFrames = 0
    private var formatEpoch = 0
    private var lastCaptureTimeUs: Int64?

    struct Snapshot: Sendable {
        let callbackCount: Int
        let convertedFrames: Int
        let conversionFailures: Int
        let formatEpoch: Int
        let lastCaptureTimeUs: Int64?
        let nativeSampleRate: Double
        let nativeChannels: Int
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(callbackCount: callbackCount, convertedFrames: convertedFrames,
                     conversionFailures: conversionFailures, formatEpoch: formatEpoch,
                     lastCaptureTimeUs: lastCaptureTimeUs, nativeSampleRate: nativeRate,
                     nativeChannels: nativeChannels)
        }
    }

    init(generation: Int, mixPolicy: AudioConverterHelper.ChannelMixPolicy = .meanOfActiveChannels, onProblem: (@Sendable (CapturedSourceProblem) -> Void)? = nil, output: @escaping @Sendable (CapturedMicAudio) -> Void) {
        self.converter = AudioConverterHelper(mixPolicy: mixPolicy)
        self.generation = generation
        self.output = output
        self.onProblem = onProblem
    }

    func receive(_ buffer: AVAudioPCMBuffer, captureTimeUs: Int64?) {
        lock.withLock {
            guard !stopped else { return }
            callbackCount += 1
            setProblemContext(timeUs: captureTimeUs, rate: buffer.format.sampleRate, frames: Int(buffer.frameLength))
            processPCM(buffer, captureTimeUs: captureTimeUs)
        }
    }

    /// Requires the processor lock, including during CMSampleBuffer copying.
    /// finish() therefore cannot retire a callback halfway through conversion.
    private func processPCM(_ buffer: AVAudioPCMBuffer, captureTimeUs: Int64?) {
        lastCaptureTimeUs = captureTimeUs
        do {
            guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { throw AudioConverterHelper.ConversionError.invalidFormat }
            guard let captureTimeUs else { throw AudioConverterHelper.ConversionError.invalidTimestamp }
            let expected = epochUs.map { $0 + Int64((Double(nativeFrames) * 1_000_000 / nativeRate).rounded()) }
            // Source gaps and native format changes are real SRC epochs;
            // queue latency is never a reason to reset filter/phase.
            if !converter.matches(buffer.format) || expected.map({ abs(captureTimeUs - $0) > 2_000 }) == true {
                try flush()
                formatEpoch += 1
                epochUs = captureTimeUs
                nativeFrames = 0
                outputFrames = 0
                nativeRate = buffer.format.sampleRate
                nativeChannels = Int(buffer.format.channelCount)
            }
            let data = try converter.convertToInt16(buffer: buffer)
            emit(data, nativeFrameCount: Int(buffer.frameLength))
            nativeFrames += Int64(buffer.frameLength)
        } catch { noteFailure(error) }
    }

    func receive(_ sampleBuffer: CMSampleBuffer, sourceClock: CMClock?) {
        lock.withLock {
            guard !stopped else { return }
            callbackCount += 1
            let timeUs = sourceClock.flatMap {
                CaptureTimeline.microseconds(CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: $0, to: CMClockGetHostTimeClock()))
            }
            setProblemContext(timeUs: timeUs, rate: nil, frames: CMSampleBufferGetNumSamples(sampleBuffer))
            guard sourceClock != nil else {
                noteFailure(AudioConverterHelper.ConversionError.invalidTimestamp); return
            }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                noteFailure(AudioConverterHelper.ConversionError.unsupportedPCM); return
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            setProblemContext(timeUs: timeUs, rate: format.sampleRate, frames: count)
            guard count > 0, count <= Int(Int32.max),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                noteFailure(AudioConverterHelper.ConversionError.unsupportedPCM); return
            }
            buffer.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else {
                noteFailure(AudioConverterHelper.ConversionError.unsupportedPCM); return
            }
            processPCM(buffer, captureTimeUs: timeUs)
        }
    }

    func finish() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            let remaining = max(0, Int(nativeFrames) - Int((Double(outputFrames) * nativeRate / 16000).rounded(.down)))
            setProblemContext(timeUs: epochUs.map { $0 + outputFrames * 1_000_000 / 16000 },
                              rate: nativeRate, frames: remaining)
            do { try flush() } catch { noteFailure(error) }
        }
    }

    private func flush() throws { emit(try converter.finish(), nativeFrameCount: 0) }

    private func emit(_ data: Data, nativeFrameCount: Int) {
        guard !data.isEmpty, let epochUs else { return }
        let timestamp = epochUs + outputFrames * 1_000_000 / 16000
        outputFrames += Int64(data.count / 2)
        convertedFrames += data.count / 2
        output(CapturedMicAudio(data: data, captureTimeUs: timestamp, generation: generation,
                                nativeSampleRate: nativeRate, nativeChannels: nativeChannels,
                                nativeFrameCount: nativeFrameCount, formatEpoch: formatEpoch, outputSampleRate: 16000))
    }

    private func setProblemContext(timeUs: Int64?, rate: Double?, frames: Int) {
        currentTimeUs = timeUs
        currentRate = rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        currentFrameCount = max(0, frames)
    }

    private func noteFailure(_ error: Error) {
        conversionFailures += 1
        let missing = currentRate.map { Int((Double(currentFrameCount) * 16000 / $0).rounded(.up)) } ?? 0
        onProblem?(CapturedSourceProblem(generation: generation, captureTimeUs: currentTimeUs,
                                        nativeSampleRate: currentRate, nativeFrameCount: currentFrameCount,
                                        missingOutputFrames: missing, message: "Audio conversion failed: \(error)"))
        if conversionFailures == 1 || conversionFailures % 256 == 0 {
            AudioLog.error("capture.convert.fail", ["generation": generation, "failures": conversionFailures, "error": String(describing: error)])
        }
    }
}
