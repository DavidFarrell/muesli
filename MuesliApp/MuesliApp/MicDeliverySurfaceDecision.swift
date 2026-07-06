import Foundation

/// Pure decision logic for whether a delivered mic buffer must surface to
/// MainActor regardless of the meter-publish gate (`MeterPublishGate`).
///
/// Two independent reasons force a surface:
/// - the first frame of a generation, so `AppModel` can reset the recovery
///   ladder promptly; and
/// - a frame that follows a delivery gap long enough to plausibly have been
///   a stall, EVEN IF that frame is silent.
///
/// The second reason is not an edge case: `MicRecoveryLadder`'s `.giveUp`
/// step parks the ladder WITHOUT rebuilding the engine (see
/// `AppModel.requestMicRecovery`), so a parked engine that resumes on the
/// SAME generation never produces an `isFirstFrame` event. If that resumed
/// audio also happens to be silence (quantizes to zero, and the meter gate
/// is already at rest at zero from the stall), the meter gate alone would
/// suppress every future delivery forever - the ladder would stay parked and
/// the persistent mic alert would never clear, even though audio is flowing
/// fine. Surfacing any post-gap frame, independent of its level, closes that
/// gap (audit: found by the 2026-07-06 livelock fix's review gate).
enum MicDeliverySurfaceDecision {
    static func mustSurface(
        isFirstFrame: Bool,
        secondsSinceLastFrame: Double?,
        resumptionGapThresholdSeconds: Double
    ) -> Bool {
        if isFirstFrame { return true }
        guard let secondsSinceLastFrame else { return false }
        return secondsSinceLastFrame > resumptionGapThresholdSeconds
    }
}
