@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum MicEngineError: Error {
    case invalidInputFormat(sampleRate: Double, channelCount: UInt32, deviceID: UInt32?, vpioRequested: Bool)
    case inputAudioUnitUnavailable(deviceID: UInt32)
    case deviceBindFailed(deviceID: UInt32, status: Int32)
}

actor MicEngine {
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var onAudioData: ((Data) -> Void)?
    private var onConfigurationChange: (() -> Void)?
    private var configChangeObserver: NSObjectProtocol?
    private var convertFailures = 0
    private var retiredEngines: [UUID: AVAudioEngine] = [:]
    private let engineRetainDurationNs: UInt64 = 2_000_000_000

    /// The caller decides voice processing. Escalation is the caller's job: on a
    /// failure it can restart with `enableVoiceProcessing: false`.
    ///
    /// - `pinned`: when true the device is bound UNCONDITIONALLY (a deliberate
    ///   user pick must take effect even if it currently equals the default).
    ///   When false (auto-follow) we keep the skip-on-equal-default heuristic so
    ///   the engine tracks the system default route.
    /// - `onConfigurationChange`: fired when the OS moves the audio route under a
    ///   running engine (e.g. a Bluetooth headset connects). The caller restarts.
    func start(
        enableVoiceProcessing: Bool,
        preferredInputDeviceID: UInt32?,
        pinned: Bool = false,
        onConfigurationChange: (@Sendable () -> Void)? = nil,
        onAudioData: @escaping (Data) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onAudioData = onAudioData
        self.onConfigurationChange = onConfigurationChange
        do {
            try startEngine(
                preferredInputDeviceID: preferredInputDeviceID,
                enableVoiceProcessing: enableVoiceProcessing,
                pinned: pinned
            )
        } catch {
            AudioLog.error("engine.start.fail", [
                "vpio": enableVoiceProcessing,
                "pinned": pinned,
                "preferredID": preferredInputDeviceID ?? 0,
                "error": String(describing: error)
            ])
            throw error
        }
        AudioLog.event("engine.start.ok", [
            "vpio": enableVoiceProcessing,
            "pinned": pinned,
            "preferredID": preferredInputDeviceID ?? 0
        ])
        isRunning = true
    }

    private func startEngine(preferredInputDeviceID: UInt32?, enableVoiceProcessing: Bool, pinned: Bool) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // A pinned device binds unconditionally - a deliberate pick must win even
        // when it equals the current (possibly just-stolen) default. In
        // auto-follow we skip the bind when the requested device IS the live
        // default, leaving the engine to track the default route. The
        // unconditional bind in the wrong case is the call implicated in the
        // dead-mic bug, so it is now gated on `pinned`.
        if let preferredInputDeviceID {
            let liveDefault = currentDefaultInputDeviceID()
            if pinned || liveDefault != preferredInputDeviceID {
                try bindPreferredInputDevice(preferredInputDeviceID, on: inputNode)
                AudioLog.event("engine.bind", ["deviceID": preferredInputDeviceID, "pinned": pinned])
            } else {
                AudioLog.event("engine.bind.skip", ["deviceID": preferredInputDeviceID, "reason": "equals-default-follow"])
            }
        }

        // The caller controls VPIO. If it was requested and cannot be enabled,
        // let that throw out so the caller can decide to retry without it -
        // swallowing it would run plain capture while reporting VPIO enabled.
        if enableVoiceProcessing {
            try inputNode.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                print("[MicEngine] Ducking set to minimum")
            } else {
                print("[MicEngine] Ducking configuration unavailable (requires macOS 14+)")
            }
        }

        // Read the format only after VPIO is enabled - enabling VPIO changes the
        // input node format and is where the 0 Hz / 0 channel failure surfaces.
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[MicEngine] Native format: \(nativeFormat)")
        // print() output isn't captured in backend.log - log it properly so
        // the next incident's tap format is visible in the recorded log, not
        // just stdout.
        AudioLog.event("engine.tap.format", [
            "sampleRate": nativeFormat.sampleRate,
            "channels": nativeFormat.channelCount,
            "vpio": enableVoiceProcessing
        ])

        guard isUsableInputFormat(
            sampleRate: nativeFormat.sampleRate,
            channelCount: nativeFormat.channelCount
        ) else {
            throw MicEngineError.invalidInputFormat(
                sampleRate: nativeFormat.sampleRate,
                channelCount: nativeFormat.channelCount,
                deviceID: preferredInputDeviceID,
                vpioRequested: enableVoiceProcessing
            )
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat
        ) { [weak self] buffer, _ in
            guard let data = AudioConverterHelper.convertToInt16(buffer: buffer) else {
                // A tap that fires but fails to convert looks identical to a dead
                // mic from the outside and silently defeats the no-audio health
                // check - so count and log it (first failure carries the format).
                Task { [weak self] in
                    await self?.noteConversionFailure(format: "\(nativeFormat)")
                }
                return
            }
            Task { [weak self] in
                await self?.emitAudio(data)
            }
        }

        // Fire when the OS moves the route under a running engine (the event we
        // previously could not see at all - e.g. a Bluetooth headset connecting).
        if let onConfigurationChange {
            let callback = onConfigurationChange
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                AudioLog.event("engine.configchange.notify")
                callback()
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            throw error
        }
    }

    private func noteConversionFailure(format: String) {
        convertFailures += 1
        if convertFailures == 1 {
            AudioLog.error("tap.convert.fail", ["inputFormat": format])
        }
    }

    func stop() async {
        guard isRunning else { return }

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        onConfigurationChange = nil
        convertFailures = 0

        let runningEngine = engine
        self.engine = nil
        isRunning = false
        onAudioData = nil
        AudioLog.event("engine.stop")

        guard let runningEngine else {
            print("[MicEngine] Stopped")
            return
        }

        runningEngine.inputNode.removeTap(onBus: 0)
        runningEngine.stop()

        // Keep the engine alive briefly after stop; AVFAudio can dispatch late
        // property-listener callbacks during teardown.
        let retiredID = UUID()
        retiredEngines[retiredID] = runningEngine
        Task { [retiredID, engineRetainDurationNs] in
            try? await Task.sleep(nanoseconds: engineRetainDurationNs)
            self.releaseRetiredEngine(id: retiredID)
        }

        print("[MicEngine] Stopped")
    }

    private func releaseRetiredEngine(id: UUID) {
        retiredEngines.removeValue(forKey: id)
    }

    /// The system default input device, or nil if it cannot be read. Used to
    /// skip the device bind when the requested device is already the default.
    private func currentDefaultInputDeviceID() -> UInt32? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            print("[MicEngine] Could not read default input device: \(status)")
            return nil
        }

        return UInt32(deviceID)
    }

    private func bindPreferredInputDevice(_ preferredInputDeviceID: UInt32, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw MicEngineError.inputAudioUnitUnavailable(deviceID: preferredInputDeviceID)
        }

        var deviceID = AudioDeviceID(preferredInputDeviceID)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw MicEngineError.deviceBindFailed(deviceID: preferredInputDeviceID, status: status)
        }

        print("[MicEngine] Bound input device \(preferredInputDeviceID)")
    }

    private func emitAudio(_ data: Data) {
        onAudioData?(data)
    }
}
