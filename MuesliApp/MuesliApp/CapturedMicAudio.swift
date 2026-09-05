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

    var outputFrameCount: Int { data.count / MemoryLayout<Int16>.size }
}
