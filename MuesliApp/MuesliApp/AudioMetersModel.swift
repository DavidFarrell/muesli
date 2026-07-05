import Foundation
import Combine

// MARK: - Audio Meters Model

/// Display-only mirror of the mic/system level meters and their debug
/// counters. `CaptureEngine` (system) and `AppModel` (mic) feed this at
/// audio-buffer rate, but publishes are throttled to ~15Hz so the view tree
/// doesn't re-diff on every buffer (the invalidation-storm fix). The
/// per-buffer-accurate counters stay on the feeders as internal state; this
/// model only holds the throttled values views actually render.
///
/// A TRANSITION to a level of exactly 0 publishes immediately (bypassing the
/// throttle) so meters visibly zero out on stop/reset instead of freezing at
/// their last nonzero value for up to one throttle window. Sustained zero
/// levels (digital silence) stay throttled like any other value.
@MainActor
final class AudioMetersModel: ObservableObject {
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var debugMicBuffers: Int = 0
    @Published private(set) var debugMicFrames: Int = 0
    @Published private(set) var debugMicPTS: Double = 0
    @Published private(set) var debugMicFormat: String = "-"
    @Published private(set) var debugMicErrorMessage: String = "-"
    @Published private(set) var debugMicErrors: Int = 0
    /// User-visible mic-dead recovery state (set by AppModel's recovery
    /// ladder). Distinct from debugMicErrorMessage: that's a hard engine-start
    /// failure, this is "the engine is running but audio isn't flowing".
    @Published private(set) var micAlert: String?

    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var debugSystemBuffers: Int = 0
    @Published private(set) var debugSystemFrames: Int = 0
    @Published private(set) var debugSystemPTS: Double = 0
    @Published private(set) var debugSystemFormat: String = "-"
    @Published private(set) var debugSystemErrorMessage: String = "-"
    @Published private(set) var debugAudioErrors: Int = 0

    /// Minimum spacing between publishes per stream (~15Hz).
    private let minPublishInterval: TimeInterval = 0.066
    private var lastMicPublishAt: Date = .distantPast
    private var lastSystemPublishAt: Date = .distantPast

    /// Feed a mic-buffer tick. Throttled, except a TRANSITION to zero
    /// publishes immediately (so the meter visibly resets on stop). A bare
    /// `level == 0` bypass would defeat the throttle entirely during digital
    /// silence, where every buffer's RMS is exactly 0.
    ///
    /// `force` bypasses the throttle for NON-buffer callers (reset/stop/
    /// restart status changes). Those fire once, so a dropped publish would
    /// never be retried - the counters could display stale values forever if
    /// the mic never delivers another buffer.
    func updateMic(level: Float, buffers: Int, frames: Int, pts: Double, format: String, force: Bool = false) {
        let now = Date()
        let transitionToZero = level == 0 && micLevel != 0
        guard force || transitionToZero || now.timeIntervalSince(lastMicPublishAt) >= minPublishInterval else { return }
        lastMicPublishAt = now
        micLevel = level
        debugMicBuffers = buffers
        debugMicFrames = frames
        debugMicPTS = pts
        debugMicFormat = format
    }

    /// Error/status paths aren't per-buffer-rate; publish immediately.
    func setMicError(message: String, errorCount: Int) {
        debugMicErrorMessage = message
        debugMicErrors = errorCount
    }

    /// One-shot recovery-ladder state changes; always publish immediately -
    /// same rationale as setMicError, a dropped throttled publish here would
    /// never be retried.
    func setMicAlert(_ message: String) {
        micAlert = message
    }

    func clearMicAlert() {
        micAlert = nil
    }

    /// Feed a system-audio-buffer tick. Throttled, except a TRANSITION to
    /// zero publishes immediately - see `updateMic`. This matters most here:
    /// the system stream sits at exactly-zero RMS whenever no audio plays.
    /// `force` is for one-shot non-buffer callers, as on the mic side.
    func updateSystem(level: Float, buffers: Int, frames: Int, pts: Double, format: String, force: Bool = false) {
        let now = Date()
        let transitionToZero = level == 0 && systemLevel != 0
        guard force || transitionToZero || now.timeIntervalSince(lastSystemPublishAt) >= minPublishInterval else { return }
        lastSystemPublishAt = now
        systemLevel = level
        debugSystemBuffers = buffers
        debugSystemFrames = frames
        debugSystemPTS = pts
        debugSystemFormat = format
    }

    /// Error/status paths aren't per-buffer-rate; publish immediately.
    func setSystemError(message: String, errorCount: Int) {
        debugSystemErrorMessage = message
        debugAudioErrors = errorCount
    }
}
