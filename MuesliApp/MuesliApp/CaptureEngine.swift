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
    private let stoppedLock = NSLock()
    private var stoppedByFramework = false
    var hasStopped: Bool { stoppedLock.withLock { stoppedByFramework } }
    let generation: Int

    init(generation: Int, forwarder: MicAudioForwarder, display: MicDeliveryDisplayMailbox,
         onRejected: (@Sendable (CapturedMicAudio, MicAudioIngress.RejectionReason) -> Void)? = nil,
         onProblem: (@Sendable (CapturedSourceProblem) -> Void)? = nil,
         onStopped: @escaping @Sendable (Error) -> Void) {
        self.generation = generation
        self.forwarder = forwarder
        self.onStopped = onStopped
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: display, onRejected: onRejected, onProblem: onProblem)
        self.ingress = ingress
        processor = MicCaptureProcessor(generation: generation, mixPolicy: .meanOfAllChannels, onProblem: ingress.problemCallback(), output: ingress.callback())
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        receive(sampleBuffer)
    }

    func receive(_ sampleBuffer: CMSampleBuffer) {
        processor.receive(sampleBuffer, sourceClock: CMClockGetHostTimeClock())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stoppedLock.withLock { stoppedByFramework = true }
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

/// Immutable handle whose framework operations are serialized by a
/// CaptureOperationOwner; ownership survives a caller's deadline.
nonisolated private final class NativeSystemCapture: @unchecked Sendable {
    let stream: SCStream
    let relay: SystemAudioCaptureRelay
    private let lock = NSLock()
    private var retired = false
    var isRetired: Bool { lock.withLock { retired } }
    init(stream: SCStream, relay: SystemAudioCaptureRelay) { self.stream = stream; self.relay = relay }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func stop() async throws {
        if !relay.hasStopped {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    stream.stopCapture { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            } catch {
                guard relay.hasStopped else { throw error }
            }
        }
        try? stream.removeStreamOutput(relay, type: .audio)
        try? stream.removeStreamOutput(relay, type: .screen)
        await relay.finish()
        lock.withLock { retired = true }
    }
}

@MainActor
final class CaptureEngine: NSObject {
    private var nativeSource: NativeSystemCapture?
    private(set) var lastRetiredIngress: MicAudioIngress.Snapshot?
    private var stream: SCStream?
    private var relay: SystemAudioCaptureRelay?
    private var forwarder: MicAudioForwarder?
    private var generation = 0
    private let operationOwner = CaptureOperationOwner()
    private var retirementPending = false
    private var stopping = false
    private var lastConversionFailures = 0
    private(set) var health = CaptureSourceHealth()
    var recoveryRecordingURLProvider: (() -> URL?)?
    private struct Request {
        let filter: SCContentFilter
        let writer: FrameSending?
        let recordingURL: URL?
        let timeline: CaptureTimeline
        var outputEnabled: Bool
    }
    private var request: Request?
    var isPreviewSource: Bool { request != nil && request?.writer == nil }
    private var recordingOutput: SCRecordingOutput?
    private var recordingDelegate: RecordingDelegate?
    private var retainedRecordingDelegates: [UUID: RecordingDelegate] = [:]
    var onRecordingOutputCreated: ((RecordingDelegate) -> Void)?
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
        guard !operationOwner.isBusy, stream == nil else {
            writer?.reportFailure(stream: .system, message: "The requested system source could not start while a previous capture was still owned by macOS.")
            throw CaptureOperationOwner.Failure.busy
        }
        if request?.timeline.epochMicroseconds != timeline.epochMicroseconds { health.reset() }
        request = Request(filter: contentFilter, writer: writer, recordingURL: url, timeline: timeline, outputEnabled: audioOutputEnabled)
        generation += 1
        health.begin(generation: generation)
        lastConversionFailures = 0
        stopping = false
        let currentGeneration = generation
        meetingStartPTS = timeline.epochPTS
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting(epoch: timeline)
        await forwarder.beginGeneration(currentGeneration, writer: writer, outputEnabled: audioOutputEnabled)
        let display = MicDeliveryDisplayMailbox { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            guard !self.health.invalidated else { return }
            _ = self.health.progress(frames: self.relay?.snapshot().convertedFrames ?? 0, generation: currentGeneration)
            self.debugSystemErrorMessage = "-"
            self.metersModel?.setSystemError(message: "-", errorCount: self.debugAudioErrors)
            self.systemLevel = result.level
            self.debugSystemBuffers = result.totalFrameCount
            self.debugSystemFrames = result.frameSampleCount
            self.debugSystemPTS = result.elapsedSeconds
            self.debugSystemFormat = "s16le sr=16000 ch=1"
            self.metersModel?.updateSystem(level: result.level, buffers: result.totalFrameCount,
                                          frames: result.frameSampleCount, pts: result.elapsedSeconds,
                                          format: self.debugSystemFormat)
        }
        let reportProblem = await forwarder.captureFailureHandler()
        let relay = SystemAudioCaptureRelay(generation: currentGeneration, forwarder: forwarder, display: display,
            onRejected: { packet, reason in
                writer?.reportLoss(stream: .system, ptsUs: timeline.relativeMicroseconds(packet.captureTimeUs),
                                   frames: Int64(packet.outputFrameCount), reason: String(describing: reason))
            }, onProblem: reportProblem) { [weak self] error in
            reportProblem(.unknown(generation: currentGeneration, message: "System audio stopped: \(error.localizedDescription)"))
            AudioLog.error("stream.stopped", ["generation": currentGeneration, "error": String(describing: error)])
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, !self.stopping else { return }
                self.health.fail(error.localizedDescription)
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
        let native = NativeSystemCapture(stream: stream, relay: relay)
        nativeSource = native
        do {
            try stream.addStreamOutput(relay, type: .audio, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.system", qos: .userInitiated))
            try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: DispatchQueue(label: "muesli.video.drop", qos: .userInitiated))
            if #available(macOS 15.0, *), let recordURL = url {
                let configuration = SCRecordingOutputConfiguration()
                configuration.outputURL = recordURL
                configuration.outputFileType = .mp4
                let recordingDelegate = RecordingDelegate(url: recordURL)
                attemptedRecordingDelegate = recordingDelegate
                retainedRecordingDelegates = retainedRecordingDelegates.filter {
                    let status = $0.value.snapshot().status
                    return status != .finished && status != .failed
                }
                retainedRecordingDelegates[recordingDelegate.id] = recordingDelegate
                onRecordingOutputCreated?(recordingDelegate)
                self.recordingDelegate = recordingDelegate
                let output = SCRecordingOutput(configuration: configuration, delegate: recordingDelegate)
                try stream.addRecordingOutput(output)
                recordingOutput = output
            }
            try await operationOwner.perform(onFailure: { error in
                reportProblem(.unknown(generation: currentGeneration, message: "System audio start failed: \(error.localizedDescription)"))
            }, operation: { try await native.start() }, cleanupIfAbandoned: { try? await native.stop() })
        } catch {
            if !(error is CaptureOperationOwner.Failure) {
                attemptedRecordingDelegate?.recordingSetupFailed(error)
                reportProblem(.unknown(generation: currentGeneration, message: "System audio setup failed: \(error.localizedDescription)"))
            }
            if error is CaptureOperationOwner.Failure {
                retirementPending = true
                health.fail(error.localizedDescription, quarantined: true)
            } else {
                do { try await operationOwner.perform { try await native.stop() } }
                catch { retirementPending = true }
                if !retirementPending { clearRetiredSource() }
                health.fail(error.localizedDescription, quarantined: retirementPending)
            }
            debugSystemErrorMessage = error.localizedDescription
            debugAudioErrors += 1
            metersModel?.setSystemError(message: debugSystemErrorMessage, errorCount: debugAudioErrors)
            throw error
        }
    }

    @discardableResult
    func stopCapture(preserveRequest: Bool = false) async -> Bool {
        guard let native = nativeSource else { return !operationOwner.isBusy }
        guard !operationOwner.isBusy else { return false }
        stopping = true
        let writer = request?.writer
        do {
            try await operationOwner.perform(onFailure: { error in
                writer?.reportFailure(stream: .system, message: "System audio stop failed: \(error.localizedDescription)")
            }) { try await native.stop() }
            clearRetiredSource()
            if !preserveRequest { request = nil; health.reset() }
            return true
        } catch {
            retirementPending = true
            health.fail(error.localizedDescription, quarantined: true)
            return false
        }
    }

    private func clearRetiredSource() {
        lastRetiredIngress = relay?.ingressSnapshot() ?? lastRetiredIngress
        nativeSource = nil
        generation += 1
        stream = nil
        relay = nil
        forwarder = nil
        recordingOutput = nil
        meetingStartPTS = nil
        retirementPending = false
        stopping = false
    }

    /// Observe successful conversions even during digital silence. No callback
    /// absence test is applied to SCK, whose silence cadence is OS dependent.
    func supervise(allowRecovery: Bool = true) -> Bool {
        if retirementPending, !operationOwner.isBusy, nativeSource?.isRetired == true {
            clearRetiredSource()
            health.fail("The previous system capture operation has finished.")
        }
        if let snapshot = relay?.snapshot() {
            if snapshot.conversionFailures > lastConversionFailures {
                lastConversionFailures = snapshot.conversionFailures
                health.fail("System audio conversion failed.")
                debugSystemErrorMessage = "System audio conversion failed."
                debugAudioErrors = snapshot.conversionFailures
                metersModel?.setSystemError(message: debugSystemErrorMessage, errorCount: debugAudioErrors)
            }
            _ = health.progress(frames: snapshot.convertedFrames, generation: generation)
        }
        return allowRecovery && !operationOwner.isBusy && health.shouldRecover(requireContinuousCallbacks: false)
    }

    func resetRecoveryBudget() {
        guard !operationOwner.isBusy else { return }
        health.reset()
    }

    func restartCapture() async -> Bool {
        guard let request, !operationOwner.isBusy else { return false }
        let recordingURL: URL?
        if request.recordingURL != nil {
            guard let nextURL = recoveryRecordingURLProvider?() else {
                health.fail("System capture needs a new video segment before it can restart.", retryable: false)
                return false
            }
            recordingURL = nextURL
        } else { recordingURL = nil }
        guard await stopCapture(preserveRequest: true) else { return false }
        do {
            try await startCapture(contentFilter: request.filter, writer: request.writer, recordTo: recordingURL,
                                   timeline: request.timeline, audioOutputEnabled: request.outputEnabled)
            return true
        } catch { return false }
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
        request?.outputEnabled = enabled
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
