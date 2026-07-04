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
/// A level of exactly 0 always publishes immediately (bypassing the
/// throttle) so meters visibly zero out on stop/reset instead of freezing at
/// their last nonzero value for up to one throttle window.
@MainActor
final class AudioMetersModel: ObservableObject {
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var debugMicBuffers: Int = 0
    @Published private(set) var debugMicFrames: Int = 0
    @Published private(set) var debugMicPTS: Double = 0
    @Published private(set) var debugMicFormat: String = "-"
    @Published private(set) var debugMicErrorMessage: String = "-"
    @Published private(set) var debugMicErrors: Int = 0

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

    /// Feed a mic-buffer tick. Throttled unless `level == 0`.
    func updateMic(level: Float, buffers: Int, frames: Int, pts: Double, format: String) {
        let now = Date()
        guard level == 0 || now.timeIntervalSince(lastMicPublishAt) >= minPublishInterval else { return }
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

    /// Feed a system-audio-buffer tick. Throttled unless `level == 0`.
    func updateSystem(level: Float, buffers: Int, frames: Int, pts: Double, format: String) {
        let now = Date()
        guard level == 0 || now.timeIntervalSince(lastSystemPublishAt) >= minPublishInterval else { return }
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
