import Foundation

/// The backend-readiness handshake (2026-07-16 RCA rec #3,
/// `engineer-notes/bug-2026-07-16-stop-device-change/RCA-2026-07-16.md`).
///
/// The incident: the Python backend wedged at launch before its stdin read
/// loop, Swift piped audio into a full pipe for 26 minutes, and the meeting
/// presented as recording while capturing nothing. The fix's contract: a
/// meeting must not be reported as recording until the child has emitted
/// `{"type":"status","message":"meeting_started"}` in response to
/// `MSG_MEETING_START` (`muesli_backend.py` emits it immediately after
/// opening both stream writers - so readiness also proves the WAV/PCM files
/// exist on disk). If that acknowledgment doesn't arrive within the timeout,
/// start is treated as FAILED and torn down - a loud ~10-second failure
/// instead of a silent total loss.
///
/// Extracted from `AppModel` so the wait/timeout/early-exit logic is unit
/// testable (the repo's usual pattern - see `MicRecoveryLadder`,
/// `MeterPublishGate`). MainActor-confined like its callers: `markReady()`
/// comes from the backend stdout task (already `@MainActor`), the wait from
/// `startMeeting`, and the `isReady` fast-path check from the mic engine
/// start path.
@MainActor
final class BackendStartupGate {
    enum Outcome: Equatable {
        case ready
        /// The child never acknowledged within the timeout - alive but
        /// wedged (the incident's shape), or too slow to trust.
        case timedOut
        /// The child exited before acknowledging (crash-at-launch). Same
        /// failure handling as a timeout, but detected within one poll tick
        /// instead of waiting out the full window.
        case processExited
    }

    private(set) var isReady = false

    /// Called by the backend stdout handler when `meeting_started` arrives.
    func markReady() {
        isReady = true
    }

    /// Re-arm for a new meeting's handshake. Also called on meeting stop /
    /// failed-start teardown so the readiness gate on mid-meeting mic
    /// restarts (`attemptMeetingMicEngineStart`) can never see a stale
    /// `isReady` from a previous meeting.
    func reset() {
        isReady = false
    }

    /// Await readiness, polling on MainActor so the stdout task that calls
    /// `markReady()` keeps getting scheduled between checks. Returns early
    /// when the child process dies. The poll interval is coarse on purpose -
    /// readiness latency is dominated by the backend's import chain
    /// (seconds), not by detection granularity.
    func waitUntilReady(
        timeoutSeconds: Double,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        isProcessAlive: () -> Bool = { true }
    ) async -> Outcome {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if isReady { return .ready }
            if !isProcessAlive() { return .processExited }
            if Date() >= deadline { return .timedOut }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
