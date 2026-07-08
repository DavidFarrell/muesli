import XCTest

/// Deterministic fake conforming to `FrameSending`, used to capture every
/// frame `MicAudioForwarder` sends without needing a real `FramedWriter`
/// (which requires a live `FileHandle` from a running process - see
/// `FrameSending`'s doc comment in `MicAudioForwarder.swift`).
private final class FakeFrameSender: FrameSending {
    struct SentFrame {
        let type: MsgType
        let stream: StreamID
        let ptsUs: Int64
        let payloadCount: Int
    }

    private(set) var sent: [SentFrame] = []

    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        sent.append(SentFrame(type: type, stream: stream, ptsUs: ptsUs, payloadCount: payload.count))
    }
}

/// Deterministic fake clock: starts at zero and only advances when a test
/// explicitly tells it to, so a simulated generation restart can land at an
/// EXACT elapsed time instead of racing the real wall clock. Mutated only
/// from sequential `await`-separated steps within a single test method (the
/// actor under test never calls it concurrently with a test's `advance`), so
/// `@unchecked Sendable` is safe here without actor isolation of its own.
private final class FakeMicMonotonicClock: MicMonotonicClock, @unchecked Sendable {
    private var microseconds: Int64 = 0

    func nowMicroseconds() -> Int64 { microseconds }

    func advance(seconds: Double) {
        microseconds += Int64(seconds * 1_000_000.0)
    }
}

/// Regression coverage for the 2026-07-08 mic-stall incident - see
/// `engineer-notes/bug-2026-07-08-mic-stall/RCA-2026-07-08.md`. The root
/// cause was `MicAudioForwarder`'s PTS anchor being reset by every
/// `beginGeneration` (mid-meeting engine rebuild) instead of staying pinned
/// to meeting start; the backend's `write_aligned_audio` aligns writes by
/// PTS and silently drops any frame whose PTS lands behind the file's
/// current write position, so every rebuild cost minutes of dropped mic
/// audio. These tests pin the fix: PTS must survive `beginGeneration` and
/// the mid-meeting `stop()` call `restartMeetingMicEngineForInputSwitch`
/// makes ahead of it, and must only reset via the meeting-scoped
/// `beginMeeting`/`endMeeting` pair.
final class MicAudioForwarderTests: XCTestCase {
    private func makeSampleData(byteCount: Int = 320) -> Data {
        // Silent frame - the tests below exercise PTS/generation bookkeeping,
        // not level computation or meter gating, so content doesn't matter.
        Data(repeating: 0, count: byteCount)
    }

    /// The core regression test: simulates the incident's shape almost
    /// exactly (RCA: "Rebuild #1 (gen=5) at wall ~48.5 s ... mic stays ~48.5s
    /// behind system for the rest of the recording"). A frame delivered ~4s
    /// after a mid-meeting rebuild must carry a PTS that continues from the
    /// MEETING epoch (~52s), not one that restarts at 0 for the new
    /// generation - and the mid-meeting `stop()` a real input-switch restart
    /// makes ahead of `beginGeneration` must not disturb that either.
    func testPTSContinuesFromMeetingEpochAcrossGenerationRestart() async {
        let clock = FakeMicMonotonicClock()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, clock: clock)
        let sender = FakeFrameSender()

        await forwarder.beginMeeting()
        await forwarder.beginGeneration(1, writer: sender)
        await forwarder.setOutputEnabled(true)

        _ = await forwarder.deliver(makeSampleData(), generation: 1)
        clock.advance(seconds: 48.0)
        _ = await forwarder.deliver(makeSampleData(), generation: 1)

        // Mirrors restartMeetingMicEngineForInputSwitch: stop() runs BEFORE
        // the next beginGeneration, mid-meeting. Must not clear the epoch.
        await forwarder.stop()
        await forwarder.beginGeneration(2, writer: sender)
        await forwarder.setOutputEnabled(true)

        clock.advance(seconds: 4.0)
        let result = await forwarder.deliver(makeSampleData(), generation: 2)

        XCTAssertNotNil(result)
        XCTAssertEqual(
            result?.elapsedSeconds ?? -1, 52.0, accuracy: 0.001,
            "PTS must continue from the MEETING epoch (~52s), not restart at 0 for the new generation"
        )
        XCTAssertEqual(
            sender.sent.last?.ptsUs, 52_000_000,
            "the frame actually sent to the backend must carry the meeting-anchored PTS"
        )
    }

    /// First-frame surfacing (used to un-stick the UI/recovery-ladder state
    /// on every engine rebuild) is per-generation bookkeeping and must keep
    /// working exactly as before, even though the PTS anchor no longer
    /// resets alongside it - the two are now deliberately independent.
    func testFirstFrameSurfacesForEachGenerationDespiteSharedEpoch() async {
        let clock = FakeMicMonotonicClock()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, clock: clock)
        let sender = FakeFrameSender()

        await forwarder.beginMeeting()
        await forwarder.beginGeneration(1, writer: sender)
        await forwarder.setOutputEnabled(true)
        let firstGen1 = await forwarder.deliver(makeSampleData(), generation: 1)
        XCTAssertEqual(firstGen1?.isFirstFrame, true)
        let secondGen1 = await forwarder.deliver(makeSampleData(), generation: 1)
        XCTAssertEqual(secondGen1?.isFirstFrame, false)

        clock.advance(seconds: 48.0)
        await forwarder.stop()
        await forwarder.beginGeneration(2, writer: sender)
        await forwarder.setOutputEnabled(true)
        let firstGen2 = await forwarder.deliver(makeSampleData(), generation: 2)
        XCTAssertEqual(firstGen2?.isFirstFrame, true, "first-frame surfacing resets per generation")
    }

    /// The pending-buffer flush path (`setOutputEnabled(true)` after frames
    /// arrived while output was still disabled - the brief window between
    /// tap install and that call in `attemptMeetingMicEngineStart`) must
    /// forward each frame's PTS as computed AT CAPTURE TIME, not recomputed
    /// at flush time - otherwise a slow flush would compress captured audio
    /// into a shorter span than it actually occupied on the meeting timeline.
    func testPendingBufferFlushForwardsCaptureTimePTS() async {
        let clock = FakeMicMonotonicClock()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, clock: clock)
        let sender = FakeFrameSender()

        await forwarder.beginMeeting()
        await forwarder.beginGeneration(1, writer: sender)
        // Output deliberately NOT enabled yet - frames must queue.

        _ = await forwarder.deliver(makeSampleData(), generation: 1)
        clock.advance(seconds: 0.5)
        _ = await forwarder.deliver(makeSampleData(), generation: 1)

        XCTAssertTrue(sender.sent.isEmpty, "frames must queue, not send, before output is enabled")

        clock.advance(seconds: 10.0) // flush happens well after capture
        await forwarder.setOutputEnabled(true)

        XCTAssertEqual(sender.sent.count, 2)
        XCTAssertEqual(sender.sent[0].ptsUs, 0)
        XCTAssertEqual(
            sender.sent[1].ptsUs, 500_000,
            "capture-time PTS (0.5s in), not flush-time PTS (10.5s)"
        )
    }

    /// `endMeeting` must actually release the epoch: a later meeting reusing
    /// the same forwarder instance (and the same process-lifetime monotonic
    /// clock, which keeps counting up) has to start its own PTS at zero
    /// again rather than inheriting wherever the previous meeting left off.
    func testEndMeetingResetsEpochForNextMeeting() async {
        let clock = FakeMicMonotonicClock()
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1, clock: clock)
        let sender = FakeFrameSender()

        await forwarder.beginMeeting()
        await forwarder.beginGeneration(1, writer: sender)
        await forwarder.setOutputEnabled(true)
        _ = await forwarder.deliver(makeSampleData(), generation: 1)

        clock.advance(seconds: 100.0)
        await forwarder.stop()
        await forwarder.endMeeting()

        clock.advance(seconds: 5.0)
        await forwarder.beginMeeting()
        await forwarder.beginGeneration(2, writer: sender)
        await forwarder.setOutputEnabled(true)
        let result = await forwarder.deliver(makeSampleData(), generation: 2)

        XCTAssertEqual(
            result?.elapsedSeconds ?? -1, 0.0, accuracy: 0.001,
            "a new meeting's PTS must start at zero again, not continue the previous meeting's clock"
        )
    }
}
