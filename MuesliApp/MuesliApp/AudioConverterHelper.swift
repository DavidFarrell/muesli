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

    init(targetSampleRate: Double = 16000, mixPolicy: ChannelMixPolicy = .meanOfActiveChannels) {
        self.targetSampleRate = targetSampleRate
        self.mixPolicy = mixPolicy
    }

    func matches(_ format: AVAudioFormat) -> Bool { nativeFormat == format }

    func convertToInt16(buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        if !matches(buffer.format) { try configure(buffer.format) }
        guard let monoFormat,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { throw ConversionError.invalidFormat }
        mono.frameLength = buffer.frameLength
        try Self.downmix(buffer, into: destination, policy: mixPolicy)
        inputFrameCount += Int64(buffer.frameLength)
        return try takeSourceDurationOutput(convert(mono, ending: false))
    }

    func finish() throws -> Data {
        guard converter != nil else { return Data() }
        defer {
            converter = nil; nativeFormat = nil; monoFormat = nil; outputFormat = nil
            inputFrameCount = 0; emittedFrameCount = 0; pendingOutput.removeAll()
        }
        return try takeSourceDurationOutput(convert(nil, ending: true))
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

    /// Preserve the intentional mean-of-active-channel microphone policy:
    /// silent USB receiver channels never attenuate a live channel. Evaluate
    /// activity per sample, so changing callback partitions cannot change the
    /// downmix or duration. Genuine stereo is averaged where both channels
    /// carry signal; the mean never exceeds the loudest input.
    private static func downmix(_ buffer: AVAudioPCMBuffer, into destination: UnsafeMutablePointer<Float>, policy: ChannelMixPolicy) throws {
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
        for frame in 0..<Int(buffer.frameLength) {
            var total: Float = 0
            var active = 0
            for channel in 0..<channels {
                let value = read(frame, channel)
                guard value.isFinite else { continue }
                if policy == .meanOfAllChannels || abs(value) >= 1e-4 { total += value; active += 1 }
            }
            destination[frame] = active == 0 ? 0 : total / Float(active)
        }
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

    init(generation: Int, mixPolicy: AudioConverterHelper.ChannelMixPolicy = .meanOfActiveChannels, output: @escaping @Sendable (CapturedMicAudio) -> Void) {
        self.converter = AudioConverterHelper(mixPolicy: mixPolicy)
        self.generation = generation
        self.output = output
    }

    func receive(_ buffer: AVAudioPCMBuffer, captureTimeUs: Int64?) {
        lock.withLock {
            guard !stopped else { return }
            callbackCount += 1
            processPCM(buffer, captureTimeUs: captureTimeUs)
        }
    }

    /// Requires the processor lock, including during CMSampleBuffer copying.
    /// finish() therefore cannot retire a callback halfway through conversion.
    private func processPCM(_ buffer: AVAudioPCMBuffer, captureTimeUs: Int64?) {
        lastCaptureTimeUs = captureTimeUs
        do {
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
            guard let sourceClock else {
                noteFailure(AudioConverterHelper.ConversionError.invalidTimestamp); return
            }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                noteFailure(AudioConverterHelper.ConversionError.unsupportedPCM); return
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            guard count > 0, count <= Int(Int32.max),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                noteFailure(AudioConverterHelper.ConversionError.unsupportedPCM); return
            }
            buffer.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else {
                noteFailure(AudioConverterHelper.ConversionError.unsupportedPCM); return
            }
            let hostPTS = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: sourceClock, to: CMClockGetHostTimeClock())
            processPCM(buffer, captureTimeUs: CaptureTimeline.microseconds(hostPTS))
        }
    }

    func finish() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
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

    private func noteFailure(_ error: Error) {
        conversionFailures += 1
        if conversionFailures == 1 || conversionFailures % 256 == 0 {
            AudioLog.error("capture.convert.fail", ["generation": generation, "failures": conversionFailures, "error": String(describing: error)])
        }
    }
}
