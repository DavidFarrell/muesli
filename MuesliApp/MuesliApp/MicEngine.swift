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
    private var retiredEngines: [UUID: AVAudioEngine] = [:]
    private let engineRetainDurationNs: UInt64 = 2_000_000_000

    /// The caller decides voice processing. Escalation is the caller's job: on a
    /// failure it can restart with `enableVoiceProcessing: false`.
    func start(
        enableVoiceProcessing: Bool,
        preferredInputDeviceID: UInt32?,
        onAudioData: @escaping (Data) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onAudioData = onAudioData
        try startEngine(preferredInputDeviceID: preferredInputDeviceID, enableVoiceProcessing: enableVoiceProcessing)
        print("[MicEngine] Started with voice processing \(enableVoiceProcessing ? "enabled" : "disabled")")
        isRunning = true
    }

    private func startEngine(preferredInputDeviceID: UInt32?, enableVoiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Skip the bind only when the requested device is confirmed to be the
        // current default - the unconditional bind is the risky call implicated
        // in the dead-mic bug. If the default cannot be read, honour the
        // explicit selection and bind rather than silently drop it (nil default
        // is not equal to the requested id, so this binds).
        if let preferredInputDeviceID, currentDefaultInputDeviceID() != preferredInputDeviceID {
            try bindPreferredInputDevice(preferredInputDeviceID, on: inputNode)
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
                return
            }
            Task { [weak self] in
                await self?.emitAudio(data)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }

        let runningEngine = engine
        self.engine = nil
        isRunning = false
        onAudioData = nil

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
