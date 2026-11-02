import Foundation

/// Detects ScreenCaptureKit system audio that keeps delivering buffers of
/// exact digital zeros after an output-route notification.
///
/// Incident 2 Nov 2026: a Bluetooth headset (Bose QC35 II) re-registered as
/// the default output without changing its device ID. SCK kept calling back
/// on time, so callback-based supervision stayed healthy, but every sample
/// was 0 for the last 11 minutes of a live call. The remote side was lost.
///
/// Digital silence alone is not a fault (nothing may be playing), so recovery
/// requires all of:
/// - an output-route notification (any fire, not only a device-ID change);
/// - a trailing exact-zero run that began no earlier than `leadSlackUs`
///   before the first notification of a burst and within `armWindowUs`
///   after its latest one, which implies non-zero audio was flowing around
///   the route change (CoreAudio fires several notifications per change);
/// - that run lasting at least `silenceThresholdUs`, with buffers still
///   arriving.
/// Each burst of notifications permits at most one recovery request.
/// All times are host-clock microseconds, as used for capture timestamps.
nonisolated struct SystemRouteSilenceDetector: Sendable {
    var silenceThresholdUs: Int64 = 3_000_000
    var armWindowUs: Int64 = 30_000_000
    var leadSlackUs: Int64 = 1_000_000
    var callbackFreshnessUs: Int64 = 2_000_000
    /// First and latest notification of the current armed burst.
    private(set) var routeChangeUs: Int64?
    private(set) var latestRouteChangeUs: Int64?

    enum Decision: Equatable { case none, expired, recover(silentForUs: Int64) }

    mutating func noteRouteChange(atUs now: Int64) {
        // Keep the burst's first notification: a re-fire after the silence
        // began must not move the window past the run's start.
        if routeChangeUs == nil { routeChangeUs = now }
        latestRouteChangeUs = now
    }

    mutating func reset() { routeChangeUs = nil; latestRouteChangeUs = nil }

    /// - Parameters:
    ///   - lastCaptureUs: start time of the most recent delivered buffer.
    ///   - lastNonZeroEndUs: end time of the most recent buffer that held any
    ///     non-zero sample; nil if none has been seen in this generation.
    mutating func evaluate(nowUs: Int64, lastCaptureUs: Int64?, lastNonZeroEndUs: Int64?) -> Decision {
        guard let route = routeChangeUs, let latestRoute = latestRouteChangeUs else { return .none }
        let latestRunStart = latestRoute + armWindowUs
        // Past the point where a qualifying run could still begin and reach
        // the threshold: this notification is spent.
        if nowUs > latestRunStart + silenceThresholdUs + callbackFreshnessUs {
            reset()
            return .expired
        }
        guard let lastCaptureUs, let runStart = lastNonZeroEndUs,
              nowUs - lastCaptureUs <= callbackFreshnessUs,
              runStart >= route - leadSlackUs, runStart <= latestRunStart else { return .none }
        let silentFor = lastCaptureUs - runStart
        guard silentFor >= silenceThresholdUs else { return .none }
        reset()
        return .recover(silentForUs: silentFor)
    }
}
