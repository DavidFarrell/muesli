import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import CoreGraphics

/// SCK's per-generation audio owner. Native sample buffers never cross onto
/// MainActor. Conversion, bounded admission and sending share the same source
/// clock as microphone capture; only a latest-only display snapshot crosses.
nonisolated final class SystemAudioCaptureRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let processor: MicCaptureProcessor
    private let ingress: MicAudioIngress
    private let forwarder: MicAudioForwarder
    private let onStopped: @Sendable (Error) -> Void
    let generation: Int

    init(generation: Int, forwarder: MicAudioForwarder, display: MicDeliveryDisplayMailbox,
         onRejected: (@Sendable (CapturedMicAudio, MicAudioIngress.RejectionReason) -> Void)? = nil,
         onStopped: @escaping @Sendable (Error) -> Void) {
        self.generation = generation
        self.forwarder = forwarder
        self.onStopped = onStopped
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: display, onRejected: onRejected)
        self.ingress = ingress
        processor = MicCaptureProcessor(generation: generation, mixPolicy: .meanOfAllChannels, output: ingress.callback())
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        receive(sampleBuffer)
    }

    func receive(_ sampleBuffer: CMSampleBuffer) {
        processor.receive(sampleBuffer, sourceClock: CMClockGetHostTimeClock())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error)
    }

    func finish() async {
        processor.finish()
        await ingress.finish()
        await forwarder.stop()
    }

    func snapshot() -> MicCaptureProcessor.Snapshot { processor.snapshot() }
    func ingressSnapshot() -> MicAudioIngress.Snapshot { ingress.snapshot() }
}

@MainActor
final class CaptureEngine: NSObject {
    private var stream: SCStream?
    private var relay: SystemAudioCaptureRelay?
    private var forwarder: MicAudioForwarder?
    private var generation = 0
    private var recordingOutput: SCRecordingOutput?
    private var recordingDelegate: RecordingDelegate?
    private(set) var meetingStartPTS: CMTime?

    var systemLevel: Float = 0
    var debugSystemBuffers = 0
    var debugSystemFrames = 0
    var debugSystemPTS: Double = 0
    var debugSystemFormat = "-"
    var debugSystemErrorMessage = "-"
    var debugAudioErrors = 0
    var metersModel: AudioMetersModel?
    var onStreamStopped: ((Error) -> Void)?

    func startCapture(contentFilter: SCContentFilter, writer: FrameSending?, recordTo url: URL?,
                      timeline: CaptureTimeline = CaptureTimeline(), audioOutputEnabled: Bool = false) async throws {
        generation += 1
        let currentGeneration = generation
        meetingStartPTS = timeline.epochPTS
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting(epoch: timeline)
        await forwarder.beginGeneration(currentGeneration, writer: writer, outputEnabled: audioOutputEnabled)
        let display = MicDeliveryDisplayMailbox { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            self.systemLevel = result.level
            self.debugSystemBuffers = result.totalFrameCount
            self.debugSystemFrames = result.frameSampleCount
            self.debugSystemPTS = result.elapsedSeconds
            self.debugSystemFormat = "s16le sr=16000 ch=1"
            self.metersModel?.updateSystem(level: result.level, buffers: result.totalFrameCount,
                                          frames: result.frameSampleCount, pts: result.elapsedSeconds,
                                          format: self.debugSystemFormat)
        }
        let relay = SystemAudioCaptureRelay(generation: currentGeneration, forwarder: forwarder, display: display,
            onRejected: { packet, reason in
                writer?.reportLoss(stream: .system, ptsUs: timeline.relativeMicroseconds(packet.captureTimeUs),
                                   frames: Int64(packet.outputFrameCount), reason: String(describing: reason))
            }) { [weak self] error in
            AudioLog.error("stream.stopped", ["generation": currentGeneration, "error": String(describing: error)])
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.debugAudioErrors += 1
                self.debugSystemErrorMessage = String(describing: error)
                self.metersModel?.setSystemError(message: self.debugSystemErrorMessage, errorCount: self.debugAudioErrors)
                self.onStreamStopped?(error)
            }
        }
        self.forwarder = forwarder
        self.relay = relay

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: contentFilter, configuration: config, delegate: relay)
        self.stream = stream
        var attemptedRecordingDelegate: RecordingDelegate?
        do {
            try stream.addStreamOutput(relay, type: .audio, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.system", qos: .userInitiated))
            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: DispatchQueue(label: "muesli.video.drop", qos: .userInitiated))
            if #available(macOS 15.0, *), let recordURL = url {
                let configuration = SCRecordingOutputConfiguration()
                configuration.outputURL = recordURL
                configuration.outputFileType = .mp4
                let recordingDelegate = RecordingDelegate(url: recordURL)
                attemptedRecordingDelegate = recordingDelegate
                self.recordingDelegate = recordingDelegate
                let output = SCRecordingOutput(configuration: configuration, delegate: recordingDelegate)
                try stream.addRecordingOutput(output)
                recordingOutput = output
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.startCapture { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            attemptedRecordingDelegate?.recordingSetupFailed(error)
            try? stream.removeStreamOutput(relay, type: .audio)
            try? stream.removeStreamOutput(relay, type: .screen)
            await relay.finish()
            if generation == currentGeneration {
                self.stream = nil
                self.relay = nil
                self.forwarder = nil
                recordingOutput = nil
            }
            throw error
        }
    }

    func stopCapture() async {
        guard let stream else { return }
        let stoppedGeneration = generation
        let relay = self.relay
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in continuation.resume() }
        }
        if let relay {
            try? stream.removeStreamOutput(relay, type: .audio)
            try? stream.removeStreamOutput(relay, type: .screen)
            await relay.finish()
        }
        guard generation == stoppedGeneration else { return }
        // Retire display/error callbacks as well as native audio callbacks.
        generation += 1
        self.stream = nil
        self.relay = nil
        forwarder = nil
        recordingOutput = nil
        meetingStartPTS = nil
    }

    struct AudioFormats {
        var systemSampleRate: Int?
        var systemChannels: Int?
        var isComplete: Bool { systemSampleRate != nil }
    }

    func waitForAudioFormats(timeoutSeconds: Double) async -> AudioFormats {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if (relay?.snapshot().convertedFrames ?? 0) > 0 {
                return AudioFormats(systemSampleRate: 16000, systemChannels: 1)
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        return AudioFormats(systemSampleRate: nil, systemChannels: nil)
    }

    func setAudioOutputEnabled(_ enabled: Bool) async {
        await forwarder?.setOutputEnabled(enabled)
    }

    /// Raw callback/conversion evidence is available independently of meters.
    func sourceSnapshot() -> MicCaptureProcessor.Snapshot? { relay?.snapshot() }
    func ingressSnapshot() -> MicAudioIngress.Snapshot? { relay?.ingressSnapshot() }

    func streamConfigurationForScreenshots() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        return configuration
    }
}
