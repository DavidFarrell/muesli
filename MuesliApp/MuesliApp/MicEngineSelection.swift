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
