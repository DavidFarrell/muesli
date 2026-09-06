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
    private var nativeStopError: Error?
    private var nativeStopObserver: (@Sendable () -> Void)?
    private var nativeStopObserverInstalled = false
    var stopError: Error? { stoppedLock.withLock { nativeStopError } }
    var hasStopped: Bool { stopError != nil }
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
        recordNativeStop(error)
    }

    /// Retain terminal native evidence before scheduling any UI notification.
    /// Duplicate framework callbacks cannot repeatedly notify or rearm recovery.
    func recordNativeStop(_ error: Error) {
        let delivery: (Bool, (@Sendable () -> Void)?) = stoppedLock.withLock {
            guard nativeStopError == nil else { return (false, nil) }
            nativeStopError = error
            let observer = nativeStopObserver
            nativeStopObserver = nil
            return (true, observer)
        }
        guard delivery.0 else { return }
        // Admit source-failure evidence before cleanup can close its lease.
        onStopped(error)
        delivery.1?()
    }

    /// The native owner receives terminal evidence independently of UI tasks.
    /// Registration and delivery share the evidence lock, including a callback
    /// that arrived before the native owner was installed.
    func observeNativeStop(_ observer: @escaping @Sendable () -> Void) {
        let callNow = stoppedLock.withLock {
            precondition(!nativeStopObserverInstalled)
            nativeStopObserverInstalled = true
            if nativeStopError != nil { return true }
            nativeStopObserver = observer
            return false
        }
        if callNow { observer() }
    }

    func finish() async {
        processor.finish()
        await ingress.finish()
        await forwarder.stop()
    }

    func snapshot() -> MicCaptureProcessor.Snapshot { processor.snapshot() }
    func ingressSnapshot() -> MicAudioIngress.Snapshot { ingress.snapshot() }
}

/// The narrow framework boundary keeps tests on the production native owner
/// without creating a real SCStream or accessing capture hardware.
nonisolated protocol NativeSystemStream: Sendable {
    func startCapture(completionHandler: @escaping @Sendable (Error?) -> Void)
    func stopCapture(completionHandler: @escaping @Sendable (Error?) -> Void)
    func removeOutputs(_ relay: SystemAudioCaptureRelay)
}

nonisolated private final class ScreenCaptureKitStream: NativeSystemStream, @unchecked Sendable {
    private let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
    func startCapture(completionHandler: @escaping @Sendable (Error?) -> Void) {
        stream.startCapture(completionHandler: completionHandler)
    }
    func stopCapture(completionHandler: @escaping @Sendable (Error?) -> Void) {
        stream.stopCapture(completionHandler: completionHandler)
    }
    func removeOutputs(_ relay: SystemAudioCaptureRelay) {
        try? stream.removeStreamOutput(relay, type: .audio)
        try? stream.removeStreamOutput(relay, type: .screen)
    }
}

/// Immutable handle whose framework operations are serialized by a
/// CaptureOperationOwner; ownership survives a caller's deadline.
nonisolated final class NativeSystemCapture: @unchecked Sendable {
    let stream: any NativeSystemStream
    let relay: SystemAudioCaptureRelay
    private let lock = NSLock()
    private var startAttempted = false
    private var nativeCallInFlight = false
    private var nativeStopped = false
    private var retirementRequested = false
    private var retirementTask: Task<Void, Never>?
    private var retired = false
    private let quitWork: ShutdownWorkRegistry.Token?
    let preservesRecording: Bool
    private var meetingAccess: MeetingFileAccess?
    var isRetired: Bool { lock.withLock { retired } }
    init(stream: any NativeSystemStream, relay: SystemAudioCaptureRelay, meetingAccess: MeetingFileAccess?, preservesRecording: Bool,
         shutdown: ShutdownWorkRegistry = .shared) throws {
        self.preservesRecording = preservesRecording
        quitWork = preservesRecording ? try shutdown.begin("Retiring native system recording") : nil
        self.stream = stream; self.relay = relay; self.meetingAccess = meetingAccess
        relay.observeNativeStop { [weak self] in self?.recordNativeStop() }
    }
    func start() async throws {
        try lock.withLock {
            guard !startAttempted, !retirementRequested, !nativeStopped else { throw CaptureOperationOwner.Failure.cancelled }
            startAttempted = true
            nativeCallInFlight = true
        }
        defer {
            lock.withLock { nativeCallInFlight = false }
            _ = retirementIfReady()
        }
        // A failed start is not sufficient evidence about partial framework
        // setup. Cleanup still obtains a successful stop or terminal evidence.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func stop() async throws {
        let needsNativeStop = try lock.withLock {
            guard !nativeCallInFlight else { throw CaptureOperationOwner.Failure.busy }
            retirementRequested = true
            // Setup can throw before startCapture was ever invoked. There is
            // no native capture to stop in that case, but outputs still retire.
            if !startAttempted { nativeStopped = true }
            guard !nativeStopped else { return false }
            nativeCallInFlight = true
            return true
        }
        var stopError: Error?
        if needsNativeStop {
            stopError = await withCheckedContinuation { continuation in
                stream.stopCapture { error in continuation.resume(returning: error) }
            }
            lock.withLock {
                nativeCallInFlight = false
                if stopError == nil || Self.isAlreadyStopped(stopError) { nativeStopped = true }
            }
        }
        if let retirement = retirementIfReady() {
            await retirement.value
            return
        }
        // An arbitrary stop error can leave capture running. Preserve the
        // original source, file lease and Quit token until genuine terminal
        // evidence arrives or a later explicit stop succeeds.
        throw stopError ?? CaptureOperationOwner.Failure.busy
    }

    private static func isAlreadyStopped(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        // Apple documents this exact domain/code as already stopped or absent.
        // A matching numeric code from another domain proves nothing.
        return error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.attemptToStopStreamState.rawValue
    }
    private func recordNativeStop() {
        lock.withLock { nativeStopped = true }
        _ = retirementIfReady()
    }
    private func retirementIfReady() -> Task<Void, Never>? {
        lock.withLock {
            if let retirementTask { return retirementTask }
            guard retirementRequested, nativeStopped, !nativeCallInFlight else { return nil }
            let task = Task.detached { await self.retire() }
            retirementTask = task
            return task
        }
    }
    private func retire() async {
        stream.removeOutputs(relay)
        await relay.finish()
        // Resource disposal precedes published retirement and Quit completion;
        // neither a deadline nor the UI releasing its references can close it.
        meetingAccess = nil
        lock.withLock { retired = true }
        quitWork?.finish()
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
    private var desiredIntent = CaptureRequestIntent()
    private let operationOwner = CaptureOperationOwner()
    private var retirementPending = false
    private var stopping = false
    private var lastSourceProblemCount = 0
    private var observedNativeStop = false
    private(set) var health = CaptureSourceHealth()
    var recoveryRecordingURLProvider: (() -> URL?)?
    private struct Request {
        let filter: SCContentFilter
        let writer: FrameSending?
        let recordingURL: URL?
        let timeline: CaptureTimeline
        let meetingAccess: MeetingFileAccess?
        var outputEnabled: Bool
    }
    private var request: Request?
    var isPreviewSource: Bool { request != nil && request?.writer == nil }
    var requestToken: Int? { desiredIntent.active ? desiredIntent.revision : nil }
    var hasNativeSource: Bool { nativeSource != nil && !retirementPending && !stopping }
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
                      timeline: CaptureTimeline = CaptureTimeline(), audioOutputEnabled: Bool = false,
                      meetingAccess: MeetingFileAccess? = nil) async throws {
        guard !operationOwner.isBusy, stream == nil else {
            writer?.reportFailure(stream: .system, message: "The requested system source could not start while a previous capture was still owned by macOS.")
            throw CaptureOperationOwner.Failure.busy
        }
        let intent = desiredIntent.begin()
        if request?.timeline.epochMicroseconds != timeline.epochMicroseconds { health.reset() }
        request = Request(filter: contentFilter, writer: writer, recordingURL: url, timeline: timeline, meetingAccess: meetingAccess, outputEnabled: audioOutputEnabled)
        generation += 1
        health.begin(generation: generation)
        lastSourceProblemCount = 0
        observedNativeStop = false
        stopping = false
        let currentGeneration = generation
        meetingStartPTS = timeline.epochPTS
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, stream: .system)
        await forwarder.beginMeeting(epoch: timeline)
        await forwarder.beginGeneration(currentGeneration, writer: writer, outputEnabled: audioOutputEnabled)
        guard desiredIntent.matches(intent) else {
            await forwarder.stop()
            throw CaptureOperationOwner.Failure.cancelled
        }
        let display = MicDeliveryDisplayMailbox { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            guard !self.observeSystemSourceProblems() else { return }
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
        guard desiredIntent.matches(intent) else {
            await forwarder.stop()
            throw CaptureOperationOwner.Failure.cancelled
        }
        let relay = SystemAudioCaptureRelay(generation: currentGeneration, forwarder: forwarder, display: display,
            onRejected: { packet, reason in
                writer?.reportLoss(stream: .system, ptsUs: timeline.relativeMicroseconds(packet.captureTimeUs),
                                   frames: Int64(packet.outputFrameCount), reason: String(describing: reason))
            }, onProblem: reportProblem) { [weak self] error in
            reportProblem(.unknown(generation: currentGeneration, message: "System audio stopped: \(error.localizedDescription)"))
            AudioLog.error("stream.stopped", ["generation": currentGeneration, "error": String(describing: error)])
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, !self.stopping else { return }
                _ = self.observeSystemSourceProblems()
            }
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: contentFilter, configuration: config, delegate: relay)
        let native: NativeSystemCapture
        do {
            native = try NativeSystemCapture(stream: ScreenCaptureKitStream(stream), relay: relay, meetingAccess: meetingAccess,
                                             preservesRecording: writer != nil || url != nil)
        } catch {
            await forwarder.stop()
            health.fail(error.localizedDescription)
            reportProblem(.unknown(generation: currentGeneration, message: "System audio setup failed: \(error.localizedDescription)"))
            throw error
        }
        // Publish only after native admission succeeds. A sealed Quit can
        // reject that admission without leaving a phantom busy stream.
        self.forwarder = forwarder
        self.relay = relay
        self.stream = stream
        nativeSource = native
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
            let startRequest = CaptureOperationOwner.Request(onFailure: { error in
                reportProblem(.unknown(generation: currentGeneration, message: "System audio start failed: \(error.localizedDescription)"))
            }, operation: { try await native.start() }, cleanupIfAbandoned: { try? await native.stop() })
            try await operationOwner.perform(startRequest, preservesRecording: native.preservesRecording)
            guard desiredIntent.matches(intent) else { throw CaptureOperationOwner.Failure.cancelled }
        } catch {
            if !desiredIntent.matches(intent) {
                // A public Stop superseded this start. The same native owner
                // must finish cleanup; an old continuation cannot restore intent.
                if !native.isRetired, !operationOwner.isBusy {
                    let retirementRequest = CaptureOperationOwner.Request(operation: { try await native.stop() })
                    try? await operationOwner.perform(retirementRequest, preservesRecording: native.preservesRecording)
                }
                if nativeSource === native {
                    if native.isRetired { clearRetiredSource(); if request == nil { health.reset() } }
                    else { retirementPending = true; health.fail("The stopped system source is awaiting macOS cleanup.", quarantined: true) }
                }
                throw error
            }
            if !(error is CaptureOperationOwner.Failure) {
                attemptedRecordingDelegate?.recordingSetupFailed(error)
                reportProblem(.unknown(generation: currentGeneration, message: "System audio setup failed: \(error.localizedDescription)"))
            }
            if error is CaptureOperationOwner.Failure {
                retirementPending = true
                health.fail(error.localizedDescription, quarantined: true)
            } else {
                do {
                    let cleanupRequest = CaptureOperationOwner.Request(operation: { try await native.stop() })
                    try await operationOwner.perform(cleanupRequest, preservesRecording: native.preservesRecording)
                }
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
        let writer = request?.writer
        if !preserveRequest {
            desiredIntent.retire()
            request = nil
        }
        guard let native = nativeSource else {
            if !operationOwner.isBusy, !preserveRequest { health.reset() }
            return !operationOwner.isBusy
        }
        stopping = true
        guard !operationOwner.isBusy else {
            if !preserveRequest { writer?.reportFailure(stream: .system, message: "System capture retirement is waiting for an earlier native operation.") }
            return false
        }
        do {
            let stopRequest = CaptureOperationOwner.Request(onFailure: { error in
                writer?.reportFailure(stream: .system, message: "System audio stop failed: \(error.localizedDescription)")
            }, operation: { try await native.stop() })
            try await operationOwner.perform(stopRequest, preservesRecording: native.preservesRecording)
            clearRetiredSource()
            if !preserveRequest { request = nil }
            if request == nil { health.reset() }
            return true
        } catch {
            retirementPending = true
            health.fail(error.localizedDescription, quarantined: true)
            return false
        }
    }

    /// Retire desired capture synchronously before another source's teardown
    /// can suspend. Keep the request's sink until stopCapture owns native stop.
    func retireCaptureIntent() {
        desiredIntent.retire()
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
            if request == nil { health.reset() }
            else { health.fail("The previous system capture operation has finished.") }
        }
        if !observeSystemSourceProblems(), let snapshot = relay?.snapshot() {
            _ = health.progress(frames: snapshot.convertedFrames, generation: generation)
        }
        return allowRecovery && !operationOwner.isBusy && health.shouldRecover(requireContinuousCallbacks: false)
    }

    /// The notification task may be behind Refresh or a meter task on
    /// MainActor. Inspect the independently recorded source evidence first;
    /// old successful conversions can never overrule an already-known stop
    /// or conversion failure. Error publication is once per observation.
    private func observeSystemSourceProblems() -> Bool {
        guard let relay else { return health.invalidated }
        let problems = relay.ingressSnapshot()
        if problems.sourceProblemCount > lastSourceProblemCount,
           let problem = problems.latestSourceProblem {
            lastSourceProblemCount = problems.sourceProblemCount
            health.fail(problem.message)
            debugSystemErrorMessage = problem.message
            debugAudioErrors += 1
            metersModel?.setSystemError(message: debugSystemErrorMessage, errorCount: debugAudioErrors)
        }
        if let error = relay.stopError {
            if !observedNativeStop {
                observedNativeStop = true
                health.fail(error.localizedDescription)
                debugSystemErrorMessage = error.localizedDescription
                debugAudioErrors += 1
                metersModel?.setSystemError(message: debugSystemErrorMessage, errorCount: debugAudioErrors)
                onStreamStopped?(error)
            }
            return true
        }
        return health.invalidated
    }

    func resetRecoveryBudget() {
        guard !operationOwner.isBusy else { return }
        health.resetRecoveryBudget()
    }

    func invalidateAfterSystemWake() {
        guard desiredIntent.active else { return }
        health.invalidateAfterSystemWake()
        // Existing supervision waits for the original operation owner; fresh
        // callbacks cannot clear this invalidation before a new generation.
    }

    func restartCapture(expectedRequest: Int? = nil) async -> Bool {
        if let expectedRequest, !desiredIntent.matches(expectedRequest) { return false }
        guard let request, !operationOwner.isBusy else { return false }
        let intent = desiredIntent.revision
        guard desiredIntent.matches(intent) else { return false }
        let recordingURL: URL?
        if request.recordingURL != nil {
            guard let nextURL = recoveryRecordingURLProvider?() else {
                health.fail("System capture needs a new video segment before it can restart.", retryable: false)
                return false
            }
            recordingURL = nextURL
        } else { recordingURL = nil }
        guard await stopCapture(preserveRequest: true), desiredIntent.matches(intent) else { return false }
        do {
            try await startCapture(contentFilter: request.filter, writer: request.writer, recordTo: recordingURL,
                                   timeline: request.timeline, audioOutputEnabled: request.outputEnabled, meetingAccess: request.meetingAccess)
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
