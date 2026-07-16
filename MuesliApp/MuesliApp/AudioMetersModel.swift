import Foundation
import Combine

// MARK: - Audio Meters Model

/// Display-only mirror of the mic/system level meters and their debug
/// counters. `CaptureEngine` (system) and `AppModel`/`MicAudioForwarder`
/// (mic) feed this at audio-buffer rate, but publishes are gated by
/// `MeterPublishGate` so the view tree doesn't re-diff on every buffer (the
/// invalidation-storm fix). The per-buffer-accurate counters stay on the
/// feeders as internal state; this model only holds the gated values views
/// actually render.
///
/// Each stream is ONE `@Published` snapshot struct rather than several
/// separate `@Published` fields, so a single update fires at most one
/// `objectWillChange` per stream instead of up to five (audit: 2026-07-06
/// livelock post-mortem). `MeterPublishGate` also stops re-publishing once a
/// stream is at rest at (quantized) zero - sustained digital silence
/// previously kept re-publishing at the throttled rate forever, which was a
/// real, persistent invalidation driver even though it wasn't convicted as
/// the storm's loop-closer.
@MainActor
final class AudioMetersModel: ObservableObject {
    struct StreamMeters: Equatable {
        var level: Float = 0
        var debugBuffers: Int = 0
        var debugFrames: Int = 0
        var debugPTS: Double = 0
        var debugFormat: String = "-"
        var debugErrorMessage: String = "-"
        var debugErrors: Int = 0
    }

    @Published private(set) var mic = StreamMeters()
    @Published private(set) var system = StreamMeters()

    /// User-visible mic-dead recovery state (set by AppModel's recovery
    /// ladder). Distinct from `mic.debugErrorMessage`: that's a hard
    /// engine-start failure, this is "the engine is running but audio isn't
    /// flowing".
    @Published private(set) var micAlert: String?

    /// User-visible backend-not-persisting state (set by AppModel's
    /// writequeue-backpressure detector, 2026-07-16 RCA rec #2). Distinct
    /// from `micAlert`: the mic can be perfectly healthy - the incident's
    /// meters bounced for 26 minutes - while the backend consumes nothing
    /// and the recording silently ceases to exist. Rendered as a prominent
    /// banner in SessionView, not a meter footnote: this one means the
    /// meeting is being LOST.
    @Published private(set) var backendAlert: String?

    /// Cumulative count of actual `mic`/`system` publishes - NOT `@Published`
    /// (it exists for `RunLoopStormTripwire`'s diagnostic rate calculation,
    /// not for the UI, and must not itself become an invalidation source).
    private(set) var publishCount: Int = 0

    private var micGate = MeterPublishGate(minPublishInterval: 0.066)
    private var systemGate = MeterPublishGate(minPublishInterval: 0.066)

    /// Feed a mic-buffer tick. Gated by `MeterPublishGate` (throttled, with a
    /// transition-to-zero bypass and an at-rest-zero cutoff - see its doc
    /// comment). `force` bypasses the gate for NON-buffer callers (reset/
    /// stop/restart status changes): those fire once, so a dropped publish
    /// there would never be retried and the counters could display stale
    /// values forever if the mic never delivers another buffer.
    func updateMic(level: Float, buffers: Int, frames: Int, pts: Double, format: String, force: Bool = false) {
        let now = Date()
        guard micGate.shouldPublish(level: level, now: now, force: force) else { return }
        let candidate = StreamMeters(
            level: MeterPublishGate.quantize(level),
            debugBuffers: buffers,
            debugFrames: frames,
            debugPTS: pts,
            debugFormat: format,
            debugErrorMessage: mic.debugErrorMessage,
            debugErrors: mic.debugErrors
        )
        guard force || candidate != mic else { return }
        mic = candidate
        publishCount += 1
    }

    /// Error/status paths aren't per-buffer-rate; publish immediately.
    func setMicError(message: String, errorCount: Int) {
        mic.debugErrorMessage = message
        mic.debugErrors = errorCount
    }

    /// One-shot recovery-ladder state changes; always publish immediately -
    /// same rationale as setMicError, a dropped publish here would never be
    /// retried.
    func setMicAlert(_ message: String) {
        micAlert = message
    }

    func clearMicAlert() {
        micAlert = nil
    }

    /// One-shot state changes from the backpressure detector; always publish
    /// immediately - same rationale as setMicAlert.
    func setBackendAlert(_ message: String) {
        backendAlert = message
    }

    func clearBackendAlert() {
        backendAlert = nil
    }

    /// Feed a system-audio-buffer tick. Mirrors `updateMic` - see its doc
    /// comment for the gating rules; this matters most here since the
    /// system stream sits at exactly-zero RMS whenever nothing is playing.
    func updateSystem(level: Float, buffers: Int, frames: Int, pts: Double, format: String, force: Bool = false) {
        let now = Date()
        guard systemGate.shouldPublish(level: level, now: now, force: force) else { return }
        let candidate = StreamMeters(
            level: MeterPublishGate.quantize(level),
            debugBuffers: buffers,
            debugFrames: frames,
            debugPTS: pts,
            debugFormat: format,
            debugErrorMessage: system.debugErrorMessage,
            debugErrors: system.debugErrors
        )
        guard force || candidate != system else { return }
        system = candidate
        publishCount += 1
    }

    /// Error/status paths aren't per-buffer-rate; publish immediately.
    func setSystemError(message: String, errorCount: Int) {
        system.debugErrorMessage = message
        system.debugErrors = errorCount
    }
}
