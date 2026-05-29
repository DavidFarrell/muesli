import Foundation

/// User setting for hardware echo cancellation (VPIO). String raw value so it
/// persists stably in UserDefaults across builds.
enum AECMode: String { case auto, on, off }

/// Whether to request VoiceProcessingIO for the given mode and output route.
/// Auto enables it only when the output is the built-in speaker, the only route
/// where a mic/speaker echo path is guaranteed.
func shouldRequestVoiceProcessing(mode: AECMode, outputIsBuiltInSpeaker: Bool) -> Bool {
    switch mode {
    case .on:   return true
    case .off:  return false
    case .auto: return outputIsBuiltInSpeaker
    }
}
