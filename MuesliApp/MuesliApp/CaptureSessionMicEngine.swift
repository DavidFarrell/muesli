import AVFoundation
import CoreMedia
import Foundation

enum CaptureSessionMicEngineError: Error {
    /// No AVCaptureDevice matches the CoreAudio device UID we asked for.
    case deviceNotFound(uid: String)
    case cannotCreateInput(underlying: String)
    case cannotAddInput
    case cannotAddOutput
}

/// Second microphone-capture engine, used only for the case AVAudioEngine
/// cannot handle: a device PINNED away from the current system default audio
/// route (e.g. capturing from the MacBook's built-in mic while a Bluetooth
/// headset holds the default output/input route).
///
/// Root cause this works around (confirmed via MicEngine's engine.tap.format
/// diagnostic, incident 4-5 Jul 2026): AVAudioEngine's `inputNode` negotiates
/// its tap format from the CURRENT AUDIO ROUTE, not from the device bound via
/// `kAudioOutputUnitProperty_CurrentDevice`. With a 16kHz Bluetooth HFP route
/// live and a 44.1/48kHz device pinned, the tap installs at the route's
/// format against a device that will never deliver it - `engine.start()`
/// succeeds and render callbacks never fire. AVCaptureSession instead selects
/// an explicit `AVCaptureDevice` and negotiates THAT device's own native
/// format, so it does not have this route-coupling problem.
///
/// Trade-off: no voice-processing (echo cancellation) on this path -
/// AVCaptureSession has no VPIO equivalent. Callers must not request it here;
/// see `AppModel.shouldUseCaptureSessionEngine`.
actor CaptureSessionMicEngine: MicCapturing {
    private var session: AVCaptureSession?
    private var isRunning = false
    private var onAudioData: ((Data) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var delegateRelay: SampleBufferRelay?
    private var convertFailures = 0
    private var firstBufferLogged = false

    // AVCaptureAudioDataOutput callbacks arrive off-actor on this queue; the
    // relay hops them onto the actor via Task, mirroring MicEngine's tap
    // closure (which does the same from a CoreAudio realtime thread).
    private let sampleQueue = DispatchQueue(label: "com.muesli.capturesession.audio")

    func start(
        enableVoiceProcessing: Bool,
        preferredInputDeviceID: UInt32?,
        pinned: Bool,
        onConfigurationChange: (@Sendable () -> Void)?,
        onAudioData: @escaping (Data) -> Void
    ) throws {
        guard !isRunning else { return }
        guard let preferredInputDeviceID, let uid = AudioDeviceManager.deviceUID(preferredInputDeviceID) else {
            throw CaptureSessionMicEngineError.deviceNotFound(uid: "none")
        }

        self.onAudioData = onAudioData
        do {
            try startSession(deviceUID: uid, onConfigurationChange: onConfigurationChange)
        } catch {
            AudioLog.error("capturesession.start.fail", ["uid": uid, "error": String(describing: error)])
            throw error
        }
        AudioLog.event("capturesession.start.ok", ["uid": uid, "pinned": pinned])
        isRunning = true
    }

    private func startSession(deviceUID uid: String, onConfigurationChange: (@Sendable () -> Void)?) throws {
        guard let device = Self.captureDevice(forCoreAudioUID: uid) else {
            throw CaptureSessionMicEngineError.deviceNotFound(uid: uid)
        }

        let session = AVCaptureSession()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureSessionMicEngineError.cannotCreateInput(underlying: String(describing: error))
        }
        guard session.canAddInput(input) else { throw CaptureSessionMicEngineError.cannotAddInput }
        session.addInput(input)

        // No `audioSettings` set on purpose: leaving it nil delivers the
        // device's native PCM format (typically float32), which
        // `AudioConverterHelper.convertToInt16` already knows how to read
        // (interleaved/planar, any channel count) and resample to the
        // 16kHz-mono-Int16 contract every downstream consumer expects.
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { throw CaptureSessionMicEngineError.cannotAddOutput }
        session.addOutput(output)

        let relay = SampleBufferRelay { [weak self] sampleBuffer in
            Task { [weak self] in
                await self?.handleSampleBuffer(sampleBuffer)
            }
        }
        output.setSampleBufferDelegate(relay, queue: sampleQueue)
        delegateRelay = relay

        registerObservers(device: device, session: session, onConfigurationChange: onConfigurationChange)

        // AVCaptureSession's own docs call out that start/stop can block, same
        // as AVAudioEngine's start() - MicEngine calls that synchronously from
        // this same actor, so this matches established style rather than
        // adding a detached-queue indirection for a contained spike.
        session.startRunning()
        self.session = session

        let nativeFormat = device.activeFormat.formatDescription.audioStreamBasicDescription
        AudioLog.event("capturesession.device", [
            "uid": uid,
            "name": device.localizedName,
            "nativeSampleRate": nativeFormat?.mSampleRate ?? -1,
            "nativeChannels": nativeFormat?.mChannelsPerFrame ?? 0
        ])
    }

    /// Fired on the OS moving the route, the bound device disconnecting, or
    /// the session hitting a runtime error - the capture-session analogues of
    /// MicEngine's `.AVAudioEngineConfigurationChange`. Captured once at
    /// registration and invoked directly from the notification callback
    /// (matches `MicEngine.startEngine`'s own configchange wiring) - no actor
    /// hop needed since the closure is `@Sendable`.
    private func registerObservers(
        device: AVCaptureDevice,
        session: AVCaptureSession,
        onConfigurationChange: (@Sendable () -> Void)?
    ) {
        guard let onConfigurationChange else { return }
        let callback = onConfigurationChange

        let runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            AudioLog.error("capturesession.runtime-error", ["error": String(describing: error)])
            callback()
        }
        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil
        ) { _ in
            AudioLog.event("capturesession.device-disconnected")
            callback()
        }
        observers = [runtimeErrorObserver, disconnectObserver]
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            noteConversionFailure(reason: "no-format-description")
            return
        }
        let avFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            noteConversionFailure(reason: "pcm-buffer-alloc")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            noteConversionFailure(reason: "copy-pcm-status-\(status)")
            return
        }

        guard let data = AudioConverterHelper.convertToInt16(buffer: pcmBuffer) else {
            noteConversionFailure(reason: "int16-convert")
            return
        }

        if !firstBufferLogged {
            firstBufferLogged = true
            AudioLog.event("capturesession.first-buffer", [
                "sampleRate": avFormat.sampleRate,
                "channels": avFormat.channelCount
            ])
        }
        onAudioData?(data)
    }

    private func noteConversionFailure(reason: String) {
        convertFailures += 1
        if convertFailures == 1 {
            AudioLog.error("capturesession.convert.fail", ["reason": reason])
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        onAudioData = nil
        firstBufferLogged = false
        convertFailures = 0

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        delegateRelay = nil

        let runningSession = session
        session = nil
        AudioLog.event("capturesession.stop")

        runningSession?.stopRunning()
    }

    /// Maps a CoreAudio device UID (`kAudioDevicePropertyDeviceUID` - the same
    /// UID persisted for the pin, see `ContentView.AudioDeviceManager`) to its
    /// `AVCaptureDevice`. Scans the discovery session rather than trusting
    /// `AVCaptureDevice(uniqueID:)` blindly: on macOS an audio AVCaptureDevice's
    /// `uniqueID` is expected to equal the CoreAudio UID, but scanning and
    /// comparing explicitly turns a divergence into a typed "not found" error
    /// instead of silently capturing the wrong device.
    static func captureDevice(forCoreAudioUID uid: String) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.first { $0.uniqueID == uid }
    }
}

/// AVCaptureAudioDataOutput requires an NSObject delegate; the engine itself
/// is an actor and cannot conform directly. This just forwards each buffer.
private final class SampleBufferRelay: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer(sampleBuffer)
    }
}
