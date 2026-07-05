import Foundation

/// Shared contract for a running microphone capture engine, so `AppModel` can
/// hold either `MicEngine` (AVAudioEngine) or `CaptureSessionMicEngine`
/// (AVCaptureSession) behind one property and one call site.
///
/// An actor-isolated method that is not itself declared `async` still
/// satisfies an `async` protocol requirement, because a cross-actor call
/// already requires `await` at the call site - so neither conformer needs to
/// change its own method signatures to adopt this.
protocol MicCapturing: Actor {
    /// - `pinned`: true when the device was a deliberate user pick (bind
    ///   unconditionally) rather than the system-default follow policy.
    /// - `onConfigurationChange`: fired when the OS moves the route, or (for
    ///   the capture-session engine) the bound device disconnects or the
    ///   session hits a runtime error. The caller re-resolves and restarts.
    func start(
        enableVoiceProcessing: Bool,
        preferredInputDeviceID: UInt32?,
        pinned: Bool,
        onConfigurationChange: (@Sendable () -> Void)?,
        onAudioData: @escaping (Data) -> Void
    ) async throws

    func stop() async
}
