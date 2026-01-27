@preconcurrency import AVFoundation

actor MicEngine {
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var onAudioData: ((Data) -> Void)?

    func start(onAudioData: @escaping (Data) -> Void) throws {
        guard !isRunning else { return }

        self.onAudioData = onAudioData

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode

        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("[MicEngine] Failed to enable voice processing: \(error)")
        }

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

        engine.prepare()
        try engine.start()

        isRunning = true
        print("[MicEngine] Started with AEC enabled")
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
