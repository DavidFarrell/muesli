import XCTest

/// Coverage for the backend-readiness handshake's wait logic (2026-07-16
/// RCA rec #3, `engineer-notes/bug-2026-07-16-stop-device-change/
/// RCA-2026-07-16.md`): a meeting must not present as recording until the
/// backend acknowledges meeting_started, and a missing acknowledgment must
/// become a FAST, LOUD start failure instead of a silent 26-minute loss.
/// Timeouts here are test-shortened; the polling structure is what's under
/// test, not the production 10s constant.
@MainActor
final class BackendStartupGateTests: XCTestCase {
    func testAlreadyReadyReturnsImmediately() async {
        let gate = BackendStartupGate()
        gate.markReady()
        let start = Date()
        let outcome = await gate.waitUntilReady(timeoutSeconds: 5.0)
        XCTAssertEqual(outcome, .ready)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "ready gate must not wait")
    }

    func testReadyDuringWaitReturnsReady() async {
        let gate = BackendStartupGate()
        // The production shape: the backend stdout task marks ready while
        // startMeeting is suspended in waitUntilReady.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            gate.markReady()
        }
        let outcome = await gate.waitUntilReady(
            timeoutSeconds: 5.0,
            pollIntervalNanoseconds: 10_000_000
        )
        XCTAssertEqual(outcome, .ready)
    }

    func testTimeoutWhenNeverReady() async {
        let gate = BackendStartupGate()
        let start = Date()
        let outcome = await gate.waitUntilReady(
            timeoutSeconds: 0.2,
            pollIntervalNanoseconds: 10_000_000
        )
        XCTAssertEqual(outcome, .timedOut, "the incident's wedged-child shape must resolve as a failure")
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), 0.2,
            "the full window must be granted before giving up"
        )
    }

    func testDeadProcessFailsFastWithoutWaitingOutTheTimeout() async {
        let gate = BackendStartupGate()
        let start = Date()
        let outcome = await gate.waitUntilReady(
            timeoutSeconds: 5.0,
            pollIntervalNanoseconds: 10_000_000,
            isProcessAlive: { false }
        )
        XCTAssertEqual(outcome, .processExited)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 1.0,
            "a crash-at-launch must fail within a poll tick, not wait out the handshake window"
        )
    }

    func testReadyWinsOverDeadProcess() async {
        // A backend that acknowledged and THEN exited did start successfully
        // - the acknowledgment must take precedence over the exit check.
        let gate = BackendStartupGate()
        gate.markReady()
        let outcome = await gate.waitUntilReady(
            timeoutSeconds: 1.0,
            isProcessAlive: { false }
        )
        XCTAssertEqual(outcome, .ready)
    }

    func testResetClosesTheGateForTheNextMeeting() async {
        let gate = BackendStartupGate()
        gate.markReady()
        XCTAssertTrue(gate.isReady)
        gate.reset()
        XCTAssertFalse(gate.isReady, "a new meeting must never inherit the previous meeting's readiness")
        let outcome = await gate.waitUntilReady(
            timeoutSeconds: 0.1,
            pollIntervalNanoseconds: 10_000_000
        )
        XCTAssertEqual(outcome, .timedOut)
    }
}
