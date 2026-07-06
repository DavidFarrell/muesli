import Foundation

/// Confines the mic-audio hot path (level compute + `FramedWriter` delivery)
/// to its own actor so a MainActor render storm can never stall mic capture
/// - the exact failure mode of the 2026-07-06 livelock incident. Mic buffers
/// used to reach the backend only via `Task { @MainActor in ... writer.send
/// }`; when the main thread entered a sustained SwiftUI transaction storm,
/// the mic feed died silently and the recovery machinery that should have
/// noticed (frames watchdog, recovery ladder) was starved by the very storm
/// it needed to detect. `FramedWriter` itself is already queued/thread-safe
/// (see `BackendProcess.swift`), so routing through it never actually needed
/// MainActor - only the THROTTLED meter snapshot + recovery-ladder state
/// transitions genuinely belong there, and those still hop out via
/// `AppModel.onMicAudioDelivered`.
///
/// Owns the per-buffer-accurate state the frames watchdog needs: frame
/// count, last-frame timestamp, and whether the first frame after a (re)start
/// has arrived yet. `AppModel` reads these via `snapshot()` instead of
/// touching per-buffer state on MainActor - critical so the watchdog's stall
/// detection stays correct even when MainActor itself is temporarily busy
/// (a delayed MainActor mirror must never be misread as "mic stopped").
actor MicAudioForwarder {
    private var writer: FramedWriter?
    private var micOutputEnabled = false
    private var pendingMicAudio: [PendingAudio] = []
    private let maxPendingMicAudio = 200

    private(set) var frameCount: Int = 0
    private(set) var lastFrameAt: Date?
    private var hadFirstFrameThisGeneration = false
    private var startedAt: Date?
    private var generation: Int = 0

    private var meterGate = MeterPublishGate(minPublishInterval: 0.066)

    private let sampleRate: Int
    private let channels: Int

    init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Ground-truth liveness data, cheap enough to poll from a background
    /// watchdog or hop to MainActor periodically - never the per-buffer
    /// values themselves.
    struct Snapshot {
        let frameCount: Int
        let lastFrameAt: Date?
        let startedAt: Date?
        let generation: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(frameCount: frameCount, lastFrameAt: lastFrameAt, startedAt: startedAt, generation: generation)
    }

    /// Called once per engine (re)start, BEFORE `engine.start()` so no buffer
    /// can arrive before the generation is armed - eliminates the narrow
    /// startup race the old MainActor-side `pendingMicAudio` mechanism was
    /// guarding against, rather than needing to reproduce it.
    func beginGeneration(_ generation: Int, writer: FramedWriter?) {
        self.generation = generation
        self.writer = writer
        micOutputEnabled = false
        frameCount = 0
        lastFrameAt = nil
        hadFirstFrameThisGeneration = false
        startedAt = nil
        pendingMicAudio.removeAll()
        meterGate = MeterPublishGate(minPublishInterval: 0.066)
    }

    /// Flip on right after a successful engine start (mirrors the exact
    /// timing of the old `micOutputEnabled = true`), flushing anything that
    /// arrived in the brief window between tap install and this call.
    func setOutputEnabled(_ enabled: Bool) {
        micOutputEnabled = enabled
        guard enabled, !pendingMicAudio.isEmpty else { return }
        let pending = pendingMicAudio
        pendingMicAudio.removeAll()
        for item in pending {
            writer?.send(type: .audio, stream: .mic, ptsUs: item.ptsUs, payload: item.payload)
        }
    }

    /// Full stop: drop the writer reference and any still-pending audio.
    func stop() {
        writer = nil
        micOutputEnabled = false
        pendingMicAudio.removeAll()
    }

    /// Everything a caller needs to update MainActor-side bookkeeping after a
    /// delivery that was worth surfacing (see `deliver`'s gating below).
    struct DeliveryResult {
        let level: Float
        let frameSampleCount: Int
        let elapsedSeconds: Double
        let isFirstFrame: Bool
    }

    /// The hot path: always computes level and forwards/queues the buffer
    /// (audio delivery must never depend on whether MainActor is free to
    /// receive a notification about it). Returns `nil` when there is nothing
    /// worth telling MainActor about - steady digital silence keeps updating
    /// `frameCount`/`lastFrameAt` internally (so the watchdog still sees
    /// truthful liveness) but does not force a MainActor hop for every
    /// buffer. The very first frame of a generation ALWAYS surfaces
    /// regardless of level - that is what lets `AppModel` reset the
    /// recovery ladder promptly (see `MeterPublishGate`'s doc comment for
    /// the quantize/dedupe rules and `AppModel.onMicAudioDelivered` for how
    /// the ladder reset is derived from `isFirstFrame` alone).
    func deliver(_ data: Data, generation callerGeneration: Int) -> DeliveryResult? {
        guard callerGeneration == generation else { return nil }
        let now = Date()
        if startedAt == nil { startedAt = now }
        let elapsed = now.timeIntervalSince(startedAt ?? now)
        let ptsUs = Int64(elapsed * 1_000_000.0)
        let isFirstFrame = !hadFirstFrameThisGeneration
        hadFirstFrameThisGeneration = true

        let level = Self.rmsLevelInt16(data)
        frameCount += 1
        lastFrameAt = now

        if micOutputEnabled {
            writer?.send(type: .audio, stream: .mic, ptsUs: ptsUs, payload: data)
        } else {
            pendingMicAudio.append(PendingAudio(
                ptsUs: ptsUs, payload: data, sampleRate: sampleRate, channels: channels
            ))
            if pendingMicAudio.count > maxPendingMicAudio {
                pendingMicAudio.removeFirst(pendingMicAudio.count - maxPendingMicAudio)
            }
        }

        guard isFirstFrame || meterGate.shouldPublish(level: level, now: now) else {
            return nil
        }

        return DeliveryResult(
            level: level,
            frameSampleCount: data.count / 2,
            elapsedSeconds: elapsed,
            isFirstFrame: isFirstFrame
        )
    }

    private static func rmsLevelInt16(_ data: Data) -> Float {
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
}
