import Foundation

/// What the mic-dead recovery ladder should do next, given how many recovery
/// attempts have already been made this stall and whether the current input
/// is pinned away from the live system default.
enum MicRecoveryStep: Equatable {
    case rebuild
    case fallbackToSystemDefault
    case giveUp
}

/// Pure decision logic for automatic mic-dead recovery (no CoreAudio/actor
/// calls), so the attempt progression can be unit tested without live audio.
/// `AppModel.requestMicRecovery` is the caller: it owns the attempt counter,
/// the CoreAudio checks, and the actual engine rebuild/fallback side effects.
enum MicRecoveryLadder {
    /// Attempts 1-2 rebuild the engine outright. Attempt 3 falls back to the
    /// system default only if the input is currently pinned to a device that
    /// differs from it (a fallback with nothing to fall back to would just be
    /// another identical rebuild); otherwise attempt 3 already gives up, same
    /// as attempt 4+, rather than retrying a rebuild indefinitely.
    static func step(forAttempt attempt: Int, isPinnedAwayFromDefault: Bool) -> MicRecoveryStep {
        switch attempt {
        case 1, 2:
            return .rebuild
        case 3:
            return isPinnedAwayFromDefault ? .fallbackToSystemDefault : .giveUp
        default:
            return .giveUp
        }
    }
}
