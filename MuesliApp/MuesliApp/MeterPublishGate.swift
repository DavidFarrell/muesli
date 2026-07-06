import Foundation

/// Pure decision logic shared by every meter-publish gate in the app
/// (`AudioMetersModel`'s authoritative per-stream gate, `CaptureEngine`'s
/// capture-queue pre-gate, `MicAudioForwarder`'s actor-side pre-gate) so the
/// quantize/dedupe/at-rest rules live in exactly one place and are unit
/// testable without any actor, queue, or audio hardware involved.
///
/// A TRANSITION to (quantized) zero always publishes immediately. Once AT
/// REST at zero, further zero readings are suppressed indefinitely - this is
/// what stops sustained digital silence from re-publishing forever (audit:
/// 2026-07-06 livelock post-mortem - meters "not going quiet" was a
/// persistent invalidation driver feeding the storm, even though it wasn't
/// convicted as the loop-closer itself). Any nonzero reading is still
/// subject to the plain time-based throttle, same as before.
struct MeterPublishGate {
    /// Sentinel: nothing published yet, so the very first reading (even a
    /// zero one) is treated as a transition rather than "already at rest".
    private(set) var lastPublishedLevel: Float = -1
    private var lastPublishAt: Date = .distantPast
    let minPublishInterval: TimeInterval

    init(minPublishInterval: TimeInterval) {
        self.minPublishInterval = minPublishInterval
    }

    static func quantize(_ level: Float) -> Float {
        (level * 100).rounded() / 100
    }

    /// Returns whether the caller should publish `level` now, and (as a
    /// mutating side effect) records that decision so the NEXT call is
    /// judged against it. `now` is a parameter rather than read from the
    /// clock internally so the decision is trivially unit testable.
    mutating func shouldPublish(level: Float, now: Date, force: Bool = false) -> Bool {
        let quantized = Self.quantize(level)
        let transitionToZero = quantized == 0 && lastPublishedLevel != 0

        if !force, quantized == 0, !transitionToZero {
            // Already at rest at zero - stay quiet.
            return false
        }
        guard force || transitionToZero || now.timeIntervalSince(lastPublishAt) >= minPublishInterval else {
            return false
        }
        lastPublishAt = now
        lastPublishedLevel = quantized
        return true
    }
}
