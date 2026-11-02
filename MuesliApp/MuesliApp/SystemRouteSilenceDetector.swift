import Foundation

/// Detects ScreenCaptureKit system audio that keeps delivering buffers of
/// exact digital zeros after an output-route notification.
///
/// Incident 2 Nov 2026: a Bluetooth headset (Bose QC35 II) re-registered as
/// the default output without changing its device ID. SCK kept calling back
/// on time, so callback-based supervision stayed healthy, but every sample
/// was 0 for the last 11 minutes of a live call. The remote side was lost.
///
/// Digital silence alone is not a fault (nothing may be playing), so a
/// recovery request requires all of:
/// - an output-route notification, timestamped at the CoreAudio callback
///   (any fire, not only a device-ID change);
/// - a trailing exact-zero run that began no earlier than `leadSlackUs`
///   before the first notification of a burst and within `armWindowUs` of
///   its latest one, implying non-zero audio was flowing around the change;
/// - that run reaching `silenceThresholdUs` with buffers still arriving, and
///   then still unbroken `confirmUs` later (two-stage confirmation).
///
/// Speculative-recovery policy: an app that legitimately outputs exact zeros
/// for several seconds, starting within `armWindowUs` of a route change, can
/// still cause one unnecessary restart. That costs a sub-second gap and a new
/// video segment; a missed fault costs the remote side for the rest of the
/// meeting. In the incident recording there was no other exact-zero second in
/// 75 minutes of live call audio, pauses included.
///
/// After a recovery request, notifications are ignored until `cooldownUs` has
/// passed, so trailing fires from the same burst cannot arm the replacement
/// capture. `reset()` (per capture generation) keeps that fence. Tradeoff: a
/// genuinely new route failure inside the cooldown is not detected (callers
/// lift the fence with `withdrawRequest()` when a request is withdrawn; the
/// route window is kept until a restart actually commits and calls `reset()`).
/// Buffer timestamps may run at most `futureToleranceUs` ahead of now.
/// All times are host-clock microseconds, as used for capture timestamps.
nonisolated struct SystemRouteSilenceDetector: Sendable {
    var silenceThresholdUs: Int64 = 3_000_000
    var confirmUs: Int64 = 2_000_000
    var armWindowUs: Int64 = 10_000_000
    var leadSlackUs: Int64 = 1_000_000
    var callbackFreshnessUs: Int64 = 2_000_000
    var cooldownUs: Int64 = 60_000_000
    var futureToleranceUs: Int64 = 100_000
    /// First and latest notification of the current armed burst.
    private(set) var routeChangeUs: Int64?
    private(set) var latestRouteChangeUs: Int64?
    private(set) var cooldownUntilUs: Int64?
    /// Silence-run start seen at the first threshold crossing, and when.
    private var suspectRunStartUs: Int64?
    private var suspectSinceUs: Int64?
    /// A recovery request is outstanding: no further decisions until it is
    /// withdrawn or the capture generation is reset by a committed restart.
    private(set) var requestOutstanding = false

    enum Decision: Equatable { case none, expired, suspect, cleared, recover(silentForUs: Int64) }

    /// Returns false when the notification falls inside the post-recovery cooldown.
    @discardableResult
    mutating func noteRouteChange(atUs time: Int64) -> Bool {
        if let cooldownUntilUs, time < cooldownUntilUs { return false }
        // Keep the burst's first notification: a re-fire after the silence
        // began must not move the window past the run's start.
        if routeChangeUs == nil { routeChangeUs = time }
        latestRouteChangeUs = max(latestRouteChangeUs ?? time, time)
        return true
    }

    /// A withdrawn request was a false alarm: keep the route window armed and
    /// lift the cooldown so neither can hide a later fault.
    mutating func withdrawRequest() {
        requestOutstanding = false
        cooldownUntilUs = nil
        suspectRunStartUs = nil; suspectSinceUs = nil
    }

    /// Clears the armed burst for a new capture generation. The cooldown fence survives.
    mutating func reset() {
        routeChangeUs = nil; latestRouteChangeUs = nil
        suspectRunStartUs = nil; suspectSinceUs = nil
        requestOutstanding = false
    }

    /// - Parameters:
    ///   - lastCaptureUs: start time of the most recent delivered buffer.
    ///   - lastNonZeroEndUs: end time of the most recent buffer that held any
    ///     non-zero sample; nil if none has been seen in this generation.
    mutating func evaluate(nowUs: Int64, lastCaptureUs: Int64?, lastNonZeroEndUs: Int64?) -> Decision {
        guard !requestOutstanding, let route = routeChangeUs, let latestRoute = latestRouteChangeUs else { return .none }
        let latestRunStart = latestRoute + armWindowUs
        let fresh = lastCaptureUs.map { nowUs - $0 <= callbackFreshnessUs && $0 - nowUs <= futureToleranceUs } ?? false
        if let lastCaptureUs, let runStart = lastNonZeroEndUs, fresh,
           runStart >= route - leadSlackUs, runStart <= latestRunStart,
           lastCaptureUs - runStart >= silenceThresholdUs {
            // Qualifying run. Checked before expiry so a late watchdog tick
            // still acts on a fault that began inside the window.
            guard let suspectStart = suspectRunStartUs, let since = suspectSinceUs else {
                suspectRunStartUs = runStart; suspectSinceUs = nowUs
                return .suspect
            }
            if suspectStart != runStart {
                // Audio returned and a new silence began: the original
                // suspicion was wrong. Track the new run from scratch.
                suspectRunStartUs = runStart; suspectSinceUs = nowUs
                return .suspect
            }
            guard nowUs - since >= confirmUs else { return .none }
            suspectRunStartUs = nil; suspectSinceUs = nil
            requestOutstanding = true
            cooldownUntilUs = nowUs + cooldownUs
            return .recover(silentForUs: lastCaptureUs - runStart)
        }
        if suspectRunStartUs != nil, let runStart = lastNonZeroEndUs, runStart != suspectRunStartUs {
            // Non-zero audio arrived after the suspicion. Drop the suspected
            // run but keep the route window: a later run inside it still counts.
            suspectRunStartUs = nil; suspectSinceUs = nil
            return .cleared
        }
        if nowUs > latestRunStart + silenceThresholdUs + confirmUs + callbackFreshnessUs {
            reset()
            return .expired
        }
        return .none
    }
}
