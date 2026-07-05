import Foundation

/// Decides which mic-capture engine to use for a resolved device.
///
/// AVAudioEngine cannot capture from a device pinned away from the live
/// system default (see `CaptureSessionMicEngine`'s header comment for the
/// mechanism) - that is the one case this returns `true` for. Everything
/// else (follow-mode, or a pin that happens to equal the current default)
/// keeps using AVAudioEngine, which is the only path with VPIO.
///
/// A free function, not a method, so it is testable without touching
/// `AppModel` or CoreAudio.
func shouldUseCaptureSessionEngine(resolvedID: UInt32, pinned: Bool, liveDefaultInputID: UInt32) -> Bool {
    guard pinned, resolvedID != 0 else { return false }
    return resolvedID != liveDefaultInputID
}

/// Whether a running mic engine needs a restart, given a fresh re-resolve.
///
/// A bare device-id compare misses one case: the system default can move
/// AWAY from or BACK TO a pinned device while `desiredID` stays the same
/// (it's still the pinned device either way) - but the required ENGINE KIND
/// changes under it (`shouldUseCaptureSessionEngine`'s result flips). The 5
/// Jul 2026 incident this spike exists to fix is exactly the away-case:
/// pinned == default at start picks AVAudioEngine; the default then moves
/// elsewhere; `desiredID` is unchanged so an id-only compare never restarts,
/// leaving AVAudioEngine bound to a device it can no longer capture (the
/// route-coupling bug - see CaptureSessionMicEngine's header). The back-case
/// (kind should downgrade from CaptureSessionMicEngine to AVAudioEngine+VPIO
/// once the pinned device becomes the default again) matters too, so this
/// restarts on either direction, not just the away-case.
///
/// A free function, not a method, so it is testable without touching
/// `AppModel` or CoreAudio.
func shouldRestartForSelection(
    desiredID: UInt32,
    boundID: UInt32,
    desiredUsesCaptureSession: Bool,
    currentUsesCaptureSession: Bool
) -> Bool {
    guard desiredID != 0 else { return false }
    if desiredID != boundID { return true }
    return desiredUsesCaptureSession != currentUsesCaptureSession
}
