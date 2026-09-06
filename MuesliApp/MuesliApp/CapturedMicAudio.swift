import AVFoundation
import CoreMedia
import Foundation

/// The native host-clock domain shared by AVAudioTime, capture-session audio,
/// ScreenCaptureKit and screenshot sample buffers. Establish before starting
/// either source and retain across source generations. This clock suspends
/// during machine sleep: lifecycle supervision must journal sleep as a pause,
/// rather than pretending that sleeping hardware continued to capture.
nonisolated struct CaptureTimeline: Sendable {
    let epochMicroseconds: Int64

    init(epochMicroseconds: Int64 = CaptureTimeline.hostNowMicroseconds()) {
        self.epochMicroseconds = epochMicroseconds
    }

    var epochPTS: CMTime { CMTime(value: epochMicroseconds, timescale: 1_000_000) }

    func relativeMicroseconds(_ sourceMicroseconds: Int64) -> Int64 {
        sourceMicroseconds - epochMicroseconds
    }

    static func hostNowMicroseconds() -> Int64 {
        microseconds(CMClockGetTime(CMClockGetHostTimeClock()))!
    }

    static func microseconds(_ time: CMTime) -> Int64? {
        guard time.isNumeric else { return nil }
        return CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }

    static func microseconds(hostTime: UInt64) -> Int64 {
        Int64((AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000).rounded())
    }
}

/// Timestamp names the first OUTPUT sample; native metadata describes the
/// input callback that produced it. A converter's buffered tail has zero
/// native frames. Generation is assigned before the native tap can fire.
nonisolated struct CapturedMicAudio: Sendable {
    let data: Data
    let captureTimeUs: Int64
    let generation: Int
    let nativeSampleRate: Double
    let nativeChannels: Int
    let nativeFrameCount: Int
    let formatEpoch: Int
    let outputSampleRate: Int
    var clockCorrection: CapturedClockCorrection? = nil

    var outputFrameCount: Int { data.count / MemoryLayout<Int16>.size }
}

/// Cumulative observations within one native generation. These describe clock
/// conversion, not committed audio or missing source samples. Keep the native
/// generation when forwarding so late observations cannot replace its successor.
nonisolated struct CapturedClockCorrection: Codable, Sendable, Equatable {
    let native_frames: Int64
    let nominal_output_frames: Int64
    let host_output_frames: Int64
    let observed_intervals: Int64
    let uncertain_intervals: Int64
    let min_rate_ratio: Double?
    let max_rate_ratio: Double?
    let generation: Int

    var isValid: Bool {
        guard generation >= 0, native_frames >= 0, nominal_output_frames >= 0,
              host_output_frames >= 0, observed_intervals >= 0, uncertain_intervals >= 0 else { return false }
        // A broad diagnostic input bound, not the retimer's supported drift
        // range. The retimer owns its tighter correction/uncertainty policy.
        for ratio in [min_rate_ratio, max_rate_ratio].compactMap({ $0 }) {
            guard ratio.isFinite, (0.5...2).contains(ratio) else { return false }
        }
        if let minimum = min_rate_ratio, let maximum = max_rate_ratio, minimum > maximum { return false }
        return true
    }
}

/// A native failure is evidence even if it is the final callback. Unknown
/// timestamp/format failures still degrade the source; they never borrow the
/// previous callback's range. Stored metadata is bounded to the latest problem.
nonisolated struct CapturedSourceProblem: Sendable {
    let generation: Int
    let captureTimeUs: Int64?
    let nativeSampleRate: Double?
    let nativeFrameCount: Int
    let missingOutputFrames: Int
    let message: String

    static func unknown(generation: Int, message: String) -> CapturedSourceProblem {
        CapturedSourceProblem(generation: generation, captureTimeUs: nil, nativeSampleRate: nil,
                              nativeFrameCount: 0, missingOutputFrames: 0, message: message)
    }
}
