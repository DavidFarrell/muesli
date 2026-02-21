@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

actor MicEngine {
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var onAudioData: ((Data) -> Void)?

    func start(preferredInputDeviceID: UInt32? = nil, onAudioData: @escaping (Data) -> Void) throws {
        guard !isRunning else { return }

        self.onAudioData = onAudioData

        do {
            try startEngine(preferredInputDeviceID: preferredInputDeviceID, enableVoiceProcessing: true)
            print("[MicEngine] Started with voice processing")
        } catch {
            print("[MicEngine] Voice-processing start failed: \(error). Retrying without voice processing.")
            try startEngine(preferredInputDeviceID: preferredInputDeviceID, enableVoiceProcessing: false)
            print("[MicEngine] Started without voice processing")
        }

        isRunning = true
    }

    private func startEngine(preferredInputDeviceID: UInt32?, enableVoiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let preferredInputDeviceID {
            if let audioUnit = inputNode.audioUnit {
                var deviceID = AudioDeviceID(preferredInputDeviceID)
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("[MicEngine] Failed to bind preferred input device \(preferredInputDeviceID): \(status)")
                } else {
                    print("[MicEngine] Bound input device \(preferredInputDeviceID)")
                }
            } else {
                print("[MicEngine] Input audio unit unavailable; cannot bind preferred input device \(preferredInputDeviceID)")
            }
        }

        if enableVoiceProcessing {
            do {
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
            } catch {
                print("[MicEngine] Failed to configure voice processing: \(error)")
            }
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[MicEngine] Native format: \(nativeFormat)")

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

        let engine = engine
        self.engine = nil
        isRunning = false
        onAudioData = nil

        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
        }

        print("[MicEngine] Stopped")
    }

    private func emitAudio(_ data: Data) {
        onAudioData?(data)
    }
}
