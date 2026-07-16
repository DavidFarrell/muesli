import Foundation

/// The subset of `FramedWriter` that `MicAudioForwarder` depends on. Exists
/// purely as a test seam - `FramedWriter` itself needs a real `FileHandle`
/// and can't be constructed in a unit test, so `MicAudioForwarderTests` uses
/// a fake conforming to this protocol to capture sent frames instead of
/// restructuring `FramedWriter`. `FramedWriter` conforms in `BackendProcess.swift`.
protocol FrameSending: AnyObject {
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
protocol MicMonotonicClock: Sendable {
    /// Monotonically non-decreasing microseconds. Only differences between
    /// two calls carry meaning - the absolute value has no defined epoch.
    func nowMicroseconds() -> Int64
}

/// Production clock: wraps `ContinuousClock`, which - unlike `SuspendingClock`
/// - keeps advancing across machine sleep, so a sleep/wake cycle mid-meeting
/// still produces a PTS gap the backend pads with silence rather than a
/// clock that silently stops (and unlike `Date`, is immune to NTP steps).
struct SystemMicMonotonicClock: MicMonotonicClock {
    private static let clock = ContinuousClock()
    private static let referenceInstant = clock.now

    func nowMicroseconds() -> Int64 {
        let elapsed = Self.clock.now - Self.referenceInstant
        let components = elapsed.components
        return components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
    }
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
/// Mic-side pending buffer entry, queued between tap install and
/// `setOutputEnabled(true)`. Deliberately NOT the identically-shaped
/// `PendingAudio` in `CaptureEngine.swift` (the system-audio side's own
/// pending-buffer type) - keeping the two independent means this file has no
/// dependency on `CaptureEngine.swift`, which is out of scope for the
/// 2026-07-08 mic-stall fix (see that RCA) and pulls in ScreenCaptureKit/
/// AVFoundation, unnecessary weight for `MicAudioForwarderTests` to compile
/// against.
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
    /// Ring cap while output is disabled. Originally 200 (the brief
    /// tap-install -> setOutputEnabled window); since the backend-readiness
    /// handshake (2026-07-16 RCA rec #3) this ring also carries the whole
    /// startup window until the backend acknowledges meeting_started - up to
    /// ~10s plus margin. Sizing: the 4096-frame tap at a 48kHz device is
    /// ~85ms per buffer (~2.7KB converted to 16k mono int16), so 512 buffers
    /// ≈ 43s / ~1.4MB worst case - cheap, and comfortably more than the 10s
    /// readiness timeout even on a 96kHz device (~22s). Overflow drops the
    /// OLDEST audio first: late early-meeting audio is acceptable, a lost
    /// meeting is not.
    private let maxPendingMicAudio = 512

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

    private let sampleRate: Int
    private let channels: Int

    init(sampleRate: Int, channels: Int, clock: MicMonotonicClock = SystemMicMonotonicClock()) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.clock = clock
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
    func beginMeeting() {
        meetingEpochUs = clock.nowMicroseconds()
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
    /// Called BOTH mid-meeting (`restartMeetingMicEngineForInputSwitch`, ahead
    /// of a fresh `beginGeneration`) and at true meeting end - it must
    /// therefore NEVER clear `meetingEpochUs` itself; only `endMeeting()`
    /// (called separately, only at true meeting end) does that.
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
    }

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
    func deliver(_ data: Data, generation callerGeneration: Int) -> DeliveryResult? {
        guard callerGeneration == generation else { return nil }
        let now = Date()
        // `startedAt` is per-generation bookkeeping only (part of the
        // liveness `Snapshot`) - it plays no part in the PTS computation
        // below any more. See `meetingEpochUs`/`beginMeeting` for the actual
        // PTS anchor.
        if startedAt == nil { startedAt = now }
        let nowUs = clock.nowMicroseconds()
        // `meetingEpochUs` should always be set by the time a frame arrives
        // (AppModel calls `beginMeeting()` before `startMeetingMicEngine()`
        // ever runs) - this self-heals rather than crashing or emitting a
        // nonsensical negative PTS in case that invariant is ever violated,
        // treating an unexpectedly-epoch-less first frame as meeting-timeline
        // zero.
        if meetingEpochUs == nil { meetingEpochUs = nowUs }
        let ptsUs = nowUs - (meetingEpochUs ?? nowUs)
        let isFirstFrame = !hadFirstFrameThisGeneration
        hadFirstFrameThisGeneration = true
        let secondsSinceLastFrame = lastFrameAt.map { now.timeIntervalSince($0) }

        let level = Self.rmsLevelInt16(data)
        frameCount += 1
        lastFrameAt = now

        if micOutputEnabled {
            writer?.send(type: .audio, stream: .mic, ptsUs: ptsUs, payload: data)
        } else {
            pendingMicAudio.append(MicPendingAudio(
                ptsUs: ptsUs, payload: data, sampleRate: sampleRate, channels: channels
            ))
            if pendingMicAudio.count > maxPendingMicAudio {
                pendingMicAudio.removeFirst(pendingMicAudio.count - maxPendingMicAudio)
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
