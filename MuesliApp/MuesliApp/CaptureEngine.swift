import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import CoreGraphics
import AudioToolbox

// MARK: - Audio Extraction

enum AudioExtractError: Error {
    case missingFormat
    case unsupportedFormat
    case failedToGetBufferList(OSStatus)
}

struct PCMChunk {
    let pts: CMTime
    let data: Data
    let frameCount: Int
}

struct PendingAudio {
    let ptsUs: Int64
    let payload: Data
    let sampleRate: Int
    let channels: Int
}

final class AudioSampleExtractor {
    func extractInt16Mono(from sampleBuffer: CMSampleBuffer) throws -> PCMChunk {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioExtractError.missingFormat
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            throw AudioExtractError.missingFormat
        }
        let asbd = asbdPtr.pointee

        var blockBuffer: CMBlockBuffer?
        var bufferListSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        if status != noErr {
            throw AudioExtractError.failedToGetBufferList(status)
        }

        if bufferListSizeNeeded <= 0 {
            bufferListSizeNeeded = MemoryLayout<AudioBufferList>.size
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        if status != noErr {
            throw AudioExtractError.failedToGetBufferList(status)
        }

        let dataPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let pts = sampleBuffer.presentationTimeStamp
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        let bufferCount = Int(dataPointer.count)
        if bufferCount < 1 {
            throw AudioExtractError.unsupportedFormat
        }

        var mono = [Float](repeating: 0, count: frames)
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channelsPerFrame = Int(asbd.mChannelsPerFrame)

        for b in 0..<bufferCount {
            guard let mData = dataPointer[b].mData else { continue }
            let byteSize = Int(dataPointer[b].mDataByteSize)

            if isFloat && bitsPerChannel == 32 {
                let sampleCount = byteSize / MemoryLayout<Float>.size
                let floats = mData.bindMemory(to: Float.self, capacity: sampleCount)
                if isInterleaved && channelsPerFrame > 1 {
                    let framesAvailable = sampleCount / channelsPerFrame
                    let count = min(frames, framesAvailable)
                    for i in 0..<count {
                        var sum: Float = 0
                        let base = i * channelsPerFrame
                        for ch in 0..<channelsPerFrame {
                            sum += floats[base + ch]
                        }
                        mono[i] += sum / Float(channelsPerFrame)
                    }
                } else {
                    let count = min(frames, sampleCount)
                    for i in 0..<count {
                        mono[i] += floats[i]
                    }
                }
            } else if isSignedInt && bitsPerChannel == 16 {
                let sampleCount = byteSize / MemoryLayout<Int16>.size
                let ints = mData.bindMemory(to: Int16.self, capacity: sampleCount)
                if isInterleaved && channelsPerFrame > 1 {
                    let framesAvailable = sampleCount / channelsPerFrame
                    let count = min(frames, framesAvailable)
                    for i in 0..<count {
                        var sum: Float = 0
                        let base = i * channelsPerFrame
                        for ch in 0..<channelsPerFrame {
                            sum += Float(ints[base + ch]) / 32768.0
                        }
                        mono[i] += sum / Float(channelsPerFrame)
                    }
                } else {
                    let count = min(frames, sampleCount)
                    for i in 0..<count {
                        mono[i] += Float(ints[i]) / 32768.0
                    }
                }
            } else if isSignedInt && bitsPerChannel == 32 {
                let sampleCount = byteSize / MemoryLayout<Int32>.size
                let ints = mData.bindMemory(to: Int32.self, capacity: sampleCount)
                if isInterleaved && channelsPerFrame > 1 {
                    let framesAvailable = sampleCount / channelsPerFrame
                    let count = min(frames, framesAvailable)
                    for i in 0..<count {
                        var sum: Float = 0
                        let base = i * channelsPerFrame
                        for ch in 0..<channelsPerFrame {
                            sum += Float(ints[base + ch]) / 2147483648.0
                        }
                        mono[i] += sum / Float(channelsPerFrame)
                    }
                } else {
                    let count = min(frames, sampleCount)
                    for i in 0..<count {
                        mono[i] += Float(ints[i]) / 2147483648.0
                    }
                }
            } else {
                throw AudioExtractError.unsupportedFormat
            }
        }

        let denom = Float(bufferCount)
        var out = Data(count: frames * MemoryLayout<Int16>.size)

        out.withUnsafeMutableBytes { rawBuf in
            let outPtr = rawBuf.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = mono[i] / max(1, denom)
                let clamped = max(-1.0, min(1.0, v))
                outPtr[i] = Int16(clamped * 32767.0)
            }
        }

        return PCMChunk(pts: pts, data: out, frameCount: frames)
    }
}

// MARK: - Capture Engine

@MainActor
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sampleRate = 16000
    private let channelCount = 1

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let recordingDelegate = RecordingDelegate()

    private let extractor = AudioSampleExtractor()
    private(set) var meetingStartPTS: CMTime?
    private var writer: FramedWriter?
    private struct AudioState {
        var audioOutputEnabled = false
        var pendingSystemAudio: [PendingAudio] = []
        var systemSampleRate: Int?
        var systemChannelCount: Int?
    }
    private final class AudioStateStore {
        private var state: AudioState
        private let queue = DispatchQueue(label: "muesli.audio.state")

        init(_ state: AudioState) {
            self.state = state
        }

        func withState<T>(_ body: (inout AudioState) -> T) -> T {
            queue.sync { body(&state) }
        }
    }

    private let audioState = AudioStateStore(AudioState())
    private let maxPendingAudio = 200

    var systemLevel: Float = 0

    var debugSystemBuffers: Int = 0
    var debugSystemFrames: Int = 0
    var debugSystemPTS: Double = 0
    var debugSystemFormat: String = "-"
    var debugSystemErrorMessage: String = "-"
    var debugAudioErrors: Int = 0

    var onLevelsUpdated: (() -> Void)?

    func startCapture(
        contentFilter: SCContentFilter,
        writer: FramedWriter,
        recordTo url: URL?
    ) async throws {
        audioState.withState { state in
            state.audioOutputEnabled = false
            state.pendingSystemAudio.removeAll()
            state.systemSampleRate = nil
            state.systemChannelCount = nil
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: contentFilter, configuration: config, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.system"))
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "muesli.video.drop"))

        self.writer = writer

        if #available(macOS 15.0, *), let recordURL = url {
            let roConfig = SCRecordingOutputConfiguration()
            roConfig.outputURL = recordURL
            roConfig.outputFileType = .mp4
            let ro = SCRecordingOutput(configuration: roConfig, delegate: recordingDelegate)
            try stream.addRecordingOutput(ro)
            self.recordingOutput = ro
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func stopCapture() async {
        guard let stream else { return }

        await withCheckedContinuation { cont in
            stream.stopCapture { _ in cont.resume() }
        }

        self.stream = nil
        self.recordingOutput = nil
        self.writer = nil
        self.meetingStartPTS = nil
        audioState.withState { state in
            state.audioOutputEnabled = false
            state.pendingSystemAudio.removeAll()
            state.systemSampleRate = nil
            state.systemChannelCount = nil
        }
    }

    struct AudioFormats {
        var systemSampleRate: Int?
        var systemChannels: Int?

        var isComplete: Bool {
            systemSampleRate != nil
        }
    }

    func waitForAudioFormats(timeoutSeconds: Double) async -> AudioFormats {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let formats = audioState.withState { state in
                AudioFormats(
                    systemSampleRate: state.systemSampleRate,
                    systemChannels: state.systemChannelCount
                )
            }
            if formats.isComplete {
                return formats
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let formats = audioState.withState { state in
            AudioFormats(
                systemSampleRate: state.systemSampleRate,
                systemChannels: state.systemChannelCount
            )
        }
        return formats
    }

    func setAudioOutputEnabled(_ enabled: Bool) {
        var systemPending: [PendingAudio] = []
        audioState.withState { state in
            state.audioOutputEnabled = enabled
            if enabled {
                systemPending = state.pendingSystemAudio
                state.pendingSystemAudio.removeAll()
            }
        }

        guard enabled else { return }
        for item in systemPending {
            writer?.send(type: .audio, stream: .system, ptsUs: item.ptsUs, payload: item.payload)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            return
        }
        guard sampleBuffer.isValid else { return }

        do {
            let pcm = try extractor.extractInt16Mono(from: sampleBuffer)

            if meetingStartPTS == nil {
                meetingStartPTS = pcm.pts
            }
            guard let start = meetingStartPTS else { return }

            let delta = CMTimeSubtract(pcm.pts, start)
            let seconds = CMTimeGetSeconds(delta)
            let ptsUs = Int64(seconds * 1_000_000.0)

            let level = rmsLevelInt16(pcm.data)
            let ptsSeconds = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
            let formatInfo = formatString(from: sampleBuffer) ?? "-"

            DispatchQueue.main.async {
                if type == .audio {
                    self.systemLevel = level
                    self.debugSystemBuffers += 1
                    self.debugSystemFrames = pcm.frameCount
                    self.debugSystemPTS = ptsSeconds
                    self.debugSystemFormat = formatInfo
                }
                self.onLevelsUpdated?()
            }

            if type == .screen {
                return
            }

            var detectedSampleRate: Int?
            var detectedChannels: Int?
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                let asbd = asbdPtr.pointee
                detectedSampleRate = Int(asbd.mSampleRate)
                detectedChannels = Int(asbd.mChannelsPerFrame)
            }

            let canWrite = audioState.withState { state -> Bool in
                if type == .audio {
                    if state.systemSampleRate == nil, let detectedSampleRate {
                        state.systemSampleRate = detectedSampleRate
                        state.systemChannelCount = detectedChannels
                    }
                }

                let canWrite = state.audioOutputEnabled
                if !canWrite, type == .audio {
                    state.pendingSystemAudio.append(PendingAudio(
                        ptsUs: ptsUs,
                        payload: pcm.data,
                        sampleRate: detectedSampleRate ?? sampleRate,
                        channels: detectedChannels ?? channelCount
                    ))
                    if state.pendingSystemAudio.count > maxPendingAudio {
                        state.pendingSystemAudio.removeFirst(state.pendingSystemAudio.count - maxPendingAudio)
                    }
                }
                return canWrite
            }

            guard canWrite else { return }
            if type == .audio {
                writer?.send(type: .audio, stream: .system, ptsUs: ptsUs, payload: pcm.data)
            }
        } catch {
            let formatInfo = formatString(from: sampleBuffer) ?? "-"
            let errorMessage = describeError(error)
            DispatchQueue.main.async {
                if type == .audio {
                    self.debugAudioErrors += 1
                    self.debugSystemFormat = formatInfo
                    self.debugSystemErrorMessage = errorMessage
                }
            }
            return
        }
    }

    func streamConfigurationForScreenshots() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.showsCursor = true
        return c
    }

    private func rmsLevelInt16(_ data: Data) -> Float {
        let count = data.count / 2
        if count == 0 { return 0 }

        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Double(p[i]) / 32768.0
                sumSquares += v * v
            }
        }
        let rms = sqrt(sumSquares / Double(count))
        return Float(min(1.0, rms))
    }

    private func formatString(from sampleBuffer: CMSampleBuffer) -> String? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let rate = Int(asbd.mSampleRate)
        let channels = asbd.mChannelsPerFrame
        let bits = asbd.mBitsPerChannel
        let formatID = fourCC(asbd.mFormatID)
        let flags = String(format: "0x%08X", asbd.mFormatFlags)
        return "id=\(formatID) sr=\(rate) ch=\(channels) bits=\(bits) flags=\(flags)"
    }

    private func describeError(_ error: Error) -> String {
        if let audioError = error as? AudioExtractError {
            switch audioError {
            case .missingFormat:
                return "missing_format"
            case .unsupportedFormat:
                return "unsupported_format"
            case .failedToGetBufferList(let status):
                return "buffer_list_error=\(status)"
            }
        }
        return String(describing: error)
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return bytes.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
    }
}

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {}
