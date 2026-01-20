import AVFoundation
import Accelerate

enum AudioConverterHelper {
    static func convertToInt16(
        buffer: AVAudioPCMBuffer,
        targetSampleRate: Double = 16000
    ) -> Data? {
        guard let floatData = buffer.floatChannelData else { return nil }

        let sourceRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let sourcePtr = floatData[0]
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
        indices.withUnsafeBufferPointer { idxPtr in
            resampled.withUnsafeMutableBufferPointer { outPtr in
                vDSP_vlint(sourcePtr, idxPtr.baseAddress!, 1, outPtr.baseAddress!, 1, vDSP_Length(outputFrames), vDSP_Length(frameCount))
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
