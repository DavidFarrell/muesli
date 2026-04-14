@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

actor MicEngine {
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var onAudioData: ((Data) -> Void)?
    private var retiredEngines: [UUID: AVAudioEngine] = [:]
    private let engineRetainDurationNs: UInt64 = 2_000_000_000

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

        if let preferredInputDeviceID {
            bindPreferredInputDevice(preferredInputDeviceID, on: inputNode)
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

    private func bindPreferredInputDevice(_ preferredInputDeviceID: UInt32, on inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else {
            print("[MicEngine] Input audio unit unavailable; cannot bind preferred input device \(preferredInputDeviceID)")
            return
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

        if status != noErr {
            print("[MicEngine] Failed to bind preferred input device \(preferredInputDeviceID): \(status)")
            return
        }

        print("[MicEngine] Bound input device \(preferredInputDeviceID)")
    }

    private func emitAudio(_ data: Data) {
        onAudioData?(data)
    }
}
