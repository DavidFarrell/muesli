import AVFoundation
import Accelerate

enum AudioConverterHelper {
    static func convertToInt16(
        buffer: AVAudioPCMBuffer,
        targetSampleRate: Double = 16000
    ) -> Data? {
        let sourceRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channels = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved

        // Read sample (frame, channel) as a Float in [-1, 1], abstracting over the
        // buffer's layout (interleaved vs planar) and sample type.
        //   planar:      data[channel][frame]
        //   interleaved: data[0][frame * channels + channel]
        let read: (Int, Int) -> Float
        if let floatData = buffer.floatChannelData {
            read = { f, c in interleaved ? floatData[0][f * channels + c] : floatData[c][f] }
        } else if let int16Data = buffer.int16ChannelData {
            read = { f, c in
                let v = interleaved ? int16Data[0][f * channels + c] : int16Data[c][f]
                return Float(v) / 32768.0
            }
        } else if let int32Data = buffer.int32ChannelData {
            read = { f, c in
                let v = interleaved ? int32Data[0][f * channels + c] : int32Data[c][f]
                return Float(v) / 2147483648.0
            }
        } else {
            return nil
        }

        // Downmix across channels rather than blindly taking channel 0. Some
        // multi-channel USB mics (e.g. the DJI wireless receiver, 4 channels)
        // leave channel 0 permanently silent and carry the voice on another
        // channel. Mix only the channels that actually carry signal in this
        // buffer: mean-of-active preserves level when one channel is live
        // (divide by 1) and behaves as a standard mono downmix for genuine
        // stereo, while a mean can never clip beyond its loudest input.
        let silenceFloor: Float = 1e-4  // ~ -80 dBFS; digital-silent channels are exactly 0
        var activeChannels: [Int] = []
        for c in 0..<channels {
            var peak: Float = 0
            for f in 0..<frameCount {
                peak = max(peak, abs(read(f, c)))
                if peak >= silenceFloor { break }
            }
            if peak >= silenceFloor { activeChannels.append(c) }
        }
        let mixChannels = activeChannels.isEmpty ? Array(0..<channels) : activeChannels
        let invCount = 1.0 / Float(mixChannels.count)

        var sourceFloats = [Float](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            var acc: Float = 0
            for c in mixChannels { acc += read(f, c) }
            sourceFloats[f] = acc * invCount
        }

        let step = Float(sourceRate / targetSampleRate)
        guard step > 0 else { return nil }

        let maxIndex = Float(frameCount - 1)
        let outputFrames = Int(floor(maxIndex / step)) + 1
        guard outputFrames > 0 else { return nil }

        var indices = [Float](repeating: 0, count: outputFrames)
        var start: Float = 0
        var stride = step
        vDSP_vramp(&start, &stride, &indices, 1, vDSP_Length(outputFrames))

        var resampled = [Float](repeating: 0, count: outputFrames)
        guard !sourceFloats.isEmpty else { return nil }
        indices.withUnsafeBufferPointer { idxPtr in
            resampled.withUnsafeMutableBufferPointer { outPtr in
                sourceFloats.withUnsafeBufferPointer { srcPtr in
                    vDSP_vlint(
                        srcPtr.baseAddress!,
                        idxPtr.baseAddress!,
                        1,
                        outPtr.baseAddress!,
                        1,
                        vDSP_Length(outputFrames),
                        vDSP_Length(frameCount)
                    )
                }
            }
        }

        var clipped = [Float](repeating: 0, count: outputFrames)
        var minVal: Float = -1.0
        var maxVal: Float = 1.0
        vDSP_vclip(resampled, 1, &minVal, &maxVal, &clipped, 1, vDSP_Length(outputFrames))

        var scaled = [Float](repeating: 0, count: outputFrames)
        var scale: Float = 32767
        vDSP_vsmul(clipped, 1, &scale, &scaled, 1, vDSP_Length(outputFrames))

        var int16Samples = [Int16](repeating: 0, count: outputFrames)
        scaled.withUnsafeBufferPointer { src in
            int16Samples.withUnsafeMutableBufferPointer { dst in
                vDSP_vfix16(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(outputFrames))
            }
        }

        return int16Samples.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }
}
