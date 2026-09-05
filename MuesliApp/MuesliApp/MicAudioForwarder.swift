import Foundation

/// The subset of `FramedWriter` that `MicAudioForwarder` depends on. Exists
/// purely as a test seam - `FramedWriter` itself needs a real `FileHandle`
/// and can't be constructed in a unit test, so `MicAudioForwarderTests` uses
/// a fake conforming to this protocol to capture sent frames instead of
/// restructuring `FramedWriter`. `FramedWriter` conforms in `BackendProcess.swift`.
nonisolated protocol FrameSending: AnyObject, Sendable {
    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data)
}

/// Abstraction over a monotonic time source, used for the forwarder's
/// meeting-epoch PTS clock. Injectable so tests can simulate a generation
/// restart at an arbitrary elapsed time without depending on wall-clock
/// `Date` - the 2026-07-08 mic-stall RCA
/// (`engineer-notes/bug-2026-07-08-mic-stall/RCA-2026-07-08.md`) specifically
/// rules `Date` out for this purpose: an NTP step mid-meeting would corrupt
/// the PTS timeline the backend's `write_aligned_audio` aligns writes
/// against. Production uses `SystemMicMonotonicClock`.
nonisolated protocol MicMonotonicClock: Sendable {
    /// Monotonically non-decreasing microseconds. Only differences between
    /// two calls carry meaning - the absolute value has no defined epoch.
    func nowMicroseconds() -> Int64
}

/// Host-clock epoch factory for compatibility with injected test clocks.
/// Packet timestamps always come from native capture, never this clock at
/// delivery. Sleep policy and cross-source calibration live in CaptureTimeline.
nonisolated struct SystemMicMonotonicClock: MicMonotonicClock {
    func nowMicroseconds() -> Int64 { CaptureTimeline.hostNowMicroseconds() }

}

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
/// Separate forwarder instances own microphone and system state. Sharing this
/// implementation does not couple source generations, readiness or shutdown.
private struct MicPendingAudio {
    let ptsUs: Int64
    let payload: Data
    let sampleRate: Int
    let channels: Int
}

actor MicAudioForwarder {
    private var writer: FrameSending?
    private var micOutputEnabled = false
    private var pendingMicAudio: [MicPendingAudio] = []
    private var pendingMicBytes = 0
    /// Cumulative eviction diagnostics (forwarder lifetime, mirroring the
    /// system side's PendingAudioGate accounting): audio dropped from the
    /// pending ring is audio that never reached the backend, and must be
    /// countable after the fact.
    private(set) var pendingEvictedFrames = 0
    private(set) var pendingEvictedBytes = 0
    /// Ring cap while output is disabled, in PCM BYTES - deliberately not a
    /// callback count (gate BLOCKER 2 on the 2026-07-16 slice): callback
    /// cadence is engine-dependent (the AVAudioEngine tap chunks at 4096
    /// frames ≈ 85ms, but `CaptureSessionMicEngine`'s
    /// AVCaptureAudioDataOutput has no such guarantee and can deliver far
    /// smaller buffers), so a count cap covers an unpredictable wall-time
    /// span. Bytes are cadence-independent: post-conversion audio is 16kHz
    /// mono int16 = 32,000 B/s, so the 2MiB default ≈ 65s - covering engine
    /// start -> capture setup (~2-3s) -> the 10s readiness timeout with a
    /// wide margin, while bounding memory. Overflow drops the OLDEST audio
    /// first: late early-meeting audio is acceptable, a lost meeting is not.
    private let maxPendingMicBytes: Int

    private(set) var frameCount: Int = 0
    private(set) var lastFrameAt: Date?
    private var hadFirstFrameThisGeneration = false
    private var startedAt: Date?
    private var generation: Int = 0

    private let clock: MicMonotonicClock
    /// Meeting-timeline zero for PTS purposes: set once by `beginMeeting()`
    /// and left untouched across every `beginGeneration()`/`stop()` call
    /// until `endMeeting()`. This is the fix for the 2026-07-08 mic-stall
    /// incident - see that method's doc comment.
    private var meetingEpochUs: Int64?

    private var meterGate = MeterPublishGate(minPublishInterval: 0.066)
    // A frame following a gap this long always surfaces regardless of level
    // or the meter gate - see MicDeliverySurfaceDecision's doc comment for
    // why a silent resumption must not be suppressed forever. Deliberately
    // smaller than AppModel's mic-stall threshold (4s) so a genuine
    // resumption surfaces well before the next watchdog tick could
    // re-detect the same stall.
    private let resumptionGapThresholdSeconds: TimeInterval = 2.0

    private let stream: StreamID
    private let sampleRate: Int
    private let channels: Int

    init(
        sampleRate: Int,
        channels: Int,
        stream: StreamID = .mic,
        clock: MicMonotonicClock = SystemMicMonotonicClock(),
        maxPendingBytes: Int = 2 * 1024 * 1024
    ) {
        self.stream = stream
        self.sampleRate = sampleRate
        self.channels = channels
        self.clock = clock
        self.maxPendingMicBytes = maxPendingBytes
    }

    /// Marks meeting-timeline zero for PTS purposes. Call exactly once, at
    /// true meeting start, before the first `beginGeneration()` of the
    /// meeting (see `AppModel.startMeeting`, where this sits alongside the
    /// existing `micStartTime = Date()` assignment). Unlike `beginGeneration`,
    /// this must NOT be called again on a mid-meeting engine rebuild: the
    /// backend aligns file writes to this epoch (`write_aligned_audio`), so
    /// resetting it on every watchdog rebuild is exactly the 2026-07-08
    /// mic-stall regression this fixes - PTS would restart at zero while the
    /// output file position keeps advancing, and the backend would silently
    /// drop every mic frame until the new PTS clock caught back up (see
    /// `engineer-notes/bug-2026-07-08-mic-stall/RCA-2026-07-08.md`).
    func beginMeeting(epoch: CaptureTimeline? = nil) {
        meetingEpochUs = epoch?.epochMicroseconds ?? clock.nowMicroseconds()
    }

    /// Clears the meeting epoch at true meeting end. Deliberately separate
    /// from `stop()`, which is ALSO called mid-meeting (input-device
    /// restarts via `restartMeetingMicEngineForInputSwitch`) and must not
    /// lose the epoch there - only `AppModel`'s true end-of-meeting teardown
    /// paths (failed-start teardown and `stopMeeting`) call this, alongside
    /// their existing `micStartTime = nil`.
    func endMeeting() {
        meetingEpochUs = nil
    }

    /// Ground-truth liveness data, cheap enough to poll from a background
    /// watchdog or hop to MainActor periodically - never the per-buffer
    /// values themselves.
    nonisolated struct Snapshot: Sendable {
        let frameCount: Int
        let lastFrameAt: Date?
        let startedAt: Date?
        let generation: Int
        let pendingEvictedFrames: Int
        let pendingEvictedBytes: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(
            frameCount: frameCount,
            lastFrameAt: lastFrameAt,
            startedAt: startedAt,
            generation: generation,
            pendingEvictedFrames: pendingEvictedFrames,
            pendingEvictedBytes: pendingEvictedBytes
        )
    }

    /// Called once per engine (re)start, BEFORE `engine.start()` so no buffer
    /// can arrive before the generation is armed - eliminates the narrow
    /// startup race the old MainActor-side `pendingMicAudio` mechanism was
    /// guarding against, rather than needing to reproduce it. Resets all
    /// per-generation liveness state (frame count, first-frame flag, the
    /// generation's own `startedAt`) but deliberately does NOT touch
    /// `meetingEpochUs` - see `beginMeeting`.
    func beginGeneration(_ generation: Int, writer: FrameSending?) {
        self.generation = generation
        self.writer = writer
        micOutputEnabled = false
        frameCount = 0
        lastFrameAt = nil
        hadFirstFrameThisGeneration = false
        startedAt = nil
        pendingMicAudio.removeAll()
        pendingMicBytes = 0
        meterGate = MeterPublishGate(minPublishInterval: 0.066)
    }

    /// Flip on right after a successful engine start (or, under the
    /// readiness handshake, when the backend acknowledges meeting_started),
    /// flushing anything queued while output was disabled.
    ///
    /// Ordering note (the system-audio side's gate BLOCKER 1 does NOT apply
    /// here): this is a synchronous actor-isolated method with no suspension
    /// points, and `deliver` is actor-isolated too - so the flush and the
    /// `micOutputEnabled` flip are atomic with respect to deliveries. A
    /// frame can never be sent live ahead of the still-unflushed prefix.
    func setOutputEnabled(_ enabled: Bool) {
        micOutputEnabled = enabled
        guard enabled, !pendingMicAudio.isEmpty else { return }
        let pending = pendingMicAudio
        pendingMicAudio.removeAll()
        pendingMicBytes = 0
        for item in pending {
            writer?.send(type: .audio, stream: stream, ptsUs: item.ptsUs, payload: item.payload)
        }
    }

    /// Full stop: drop the writer reference and any still-pending audio.
    /// Called BOTH mid-meeting (`restartMeetingMicEngineForInputSwitch`, ahead
    /// of a fresh `beginGeneration`) and at true meeting end - it must
    /// therefore NEVER clear `meetingEpochUs` itself; only `endMeeting()`
    /// (called separately, only at true meeting end) does that.
    func stop() {
        writer = nil
        micOutputEnabled = false
        pendingMicAudio.removeAll()
        pendingMicBytes = 0
    }

    /// Everything a caller needs to update MainActor-side bookkeeping after a
    /// delivery that was worth surfacing (see `deliver`'s gating below).
    nonisolated struct DeliveryResult: Sendable {
        let level: Float
        let frameSampleCount: Int
        let totalFrameCount: Int
        /// Seconds since the MEETING epoch (`beginMeeting`), not since this
        /// generation started - restores the pre-2026-07-06 meaning of the
        /// old `debugMicPTS` display value. See `MicAudioForwarder`'s and
        /// `beginMeeting`'s doc comments for why this must survive
        /// generation rebuilds.
        let elapsedSeconds: Double
        let isFirstFrame: Bool
        /// True when this delivery surfaced ONLY because it followed a long
        /// delivery gap (not because it's the first frame of a generation,
        /// and not because the meter gate would have let it through on its
        /// own) - see `MicDeliverySurfaceDecision`. Informational, for
        /// logging; `AppModel` doesn't need to branch on it for correctness
        /// since it resets the recovery ladder on attempts/parked state too.
        let isResumptionAfterGap: Bool

        func mergingRecoveryFlags(from previous: DeliveryResult?) -> DeliveryResult {
            DeliveryResult(level: level, frameSampleCount: frameSampleCount, totalFrameCount: totalFrameCount,
                           elapsedSeconds: elapsedSeconds,
                           isFirstFrame: isFirstFrame || previous?.isFirstFrame == true,
                           isResumptionAfterGap: isResumptionAfterGap || previous?.isResumptionAfterGap == true)
        }
    }

    // Recovery flags survive latest-only UI coalescing.
    /// The hot path: always computes level and forwards/queues the buffer
    /// (audio delivery must never depend on whether MainActor is free to
    /// receive a notification about it). Returns `nil` when there is nothing
    /// worth telling MainActor about - steady digital silence keeps updating
    /// `frameCount`/`lastFrameAt` internally (so the watchdog still sees
    /// truthful liveness) but does not force a MainActor hop for every
    /// buffer. `MicDeliverySurfaceDecision.mustSurface` always overrides the
    /// meter gate for the first frame of a generation OR a frame following a
    /// long delivery gap - the latter is what lets a PARKED recovery ladder
    /// (which gives up without rebuilding the engine, so no new generation
    /// ever starts) un-park on a silent resumption instead of staying parked
    /// forever (see that type's doc comment).
    func deliver(_ packet: CapturedMicAudio) -> DeliveryResult? {
        guard packet.generation == generation, let meetingEpochUs else { return nil }
        let data = packet.data
        let now = Date()
        if startedAt == nil { startedAt = now }
        let ptsUs = packet.captureTimeUs - meetingEpochUs
        let isFirstFrame = !hadFirstFrameThisGeneration
        hadFirstFrameThisGeneration = true
        let secondsSinceLastFrame = lastFrameAt.map { now.timeIntervalSince($0) }

        let level = Self.rmsLevelInt16(data)
        frameCount += 1
        lastFrameAt = now

        if micOutputEnabled {
            writer?.send(type: .audio, stream: stream, ptsUs: ptsUs, payload: data)
        } else if writer != nil {
            pendingMicAudio.append(MicPendingAudio(
                ptsUs: ptsUs, payload: data, sampleRate: sampleRate, channels: channels
            ))
            pendingMicBytes += data.count
            while pendingMicBytes > maxPendingMicBytes, !pendingMicAudio.isEmpty {
                let evicted = pendingMicAudio.removeFirst()
                pendingMicBytes -= evicted.payload.count
                pendingEvictedFrames += 1
                pendingEvictedBytes += evicted.payload.count
                // Loud but rate-limited: eviction means startup audio is
                // being lost, which should never happen inside the sized
                // window - worth a log line, not one per frame.
                if pendingEvictedFrames == 1 || pendingEvictedFrames % 256 == 0 {
                    AudioLog.error("capture.pending.evicted", [
                        "stream": stream.rawValue,
                        "evictedFrames": pendingEvictedFrames,
                        "evictedBytes": pendingEvictedBytes
                    ])
                }
            }
        }

        let mustSurface = MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: isFirstFrame,
            secondsSinceLastFrame: secondsSinceLastFrame,
            resumptionGapThresholdSeconds: resumptionGapThresholdSeconds
        )
        guard mustSurface || meterGate.shouldPublish(level: level, now: now) else {
            return nil
        }

        return DeliveryResult(
            level: level,
            frameSampleCount: data.count / 2,
            totalFrameCount: frameCount,
            elapsedSeconds: Double(ptsUs) / 1_000_000.0,
            isFirstFrame: isFirstFrame,
            isResumptionAfterGap: mustSurface && !isFirstFrame
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
