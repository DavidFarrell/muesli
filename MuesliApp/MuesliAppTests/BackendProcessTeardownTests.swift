import XCTest

/// Round-2 gate blocker regression tests: stdin single-queue ownership
/// through FULL teardown, `cleanup()` included. `BackendProcess.cleanup()`
/// used to close the stdin handle cross-thread while `FramedWriter`'s
/// writeQueue could still be mid-write (EPIPE fail-fast after a kill) - an
/// unsupported NSFileHandle race. Now stdin is closed exclusively by the
/// writer's queue, and teardown awaits the `closeStdinAndWait` barrier
/// before `cleanup()` runs. These tests drive real child processes through
/// both the healthy and the wedged (blocked-write) sequences.
final class BackendProcessTeardownTests: XCTestCase {
    /// Healthy child: /bin/cat exits ONLY when its stdin reaches EOF. With
    /// cleanup() no longer touching stdin, a clean cat exit after
    /// barrier-then-cleanup proves the queued close on the writer's queue
    /// is what delivered EOF - and that it had run before cleanup touched
    /// the remaining plumbing.
    func testTeardownDelegatesStdinCloseToWriterBarrier() async throws {
        let backend = try BackendProcess(command: ["/bin/cat"])
        try backend.start()
        let writer = FramedWriter(stdinHandle: backend.stdin)

        let payload = Data(repeating: 0x42, count: 1_024)
        for i in 0..<3 {
            writer.send(type: .audio, stream: .mic, ptsUs: Int64(i), payload: payload)
        }

        let closed = await writer.closeStdinAndWait(timeoutSeconds: 2)
        XCTAssertTrue(closed, "the queued close must have RUN before teardown proceeds")

        backend.cleanup() // must not touch stdin (and must not crash)

        let status = await backend.waitForExit(timeoutSeconds: 5)
        XCTAssertEqual(status, 0, "cat exits 0 only on stdin EOF - proving the writer's close delivered it")
    }

    /// Wedged child: /bin/sleep never reads stdin, so the pipe fills and a
    /// write blocks on the writeQueue - the 2026-07-16 incident's transport
    /// state. The barrier must (a) NOT complete while the close is stuck
    /// behind the blocked write, and (b) complete promptly once the
    /// reader's death EPIPE-unblocks the queue - only then does cleanup()
    /// run. This is the exact sequence the gate flagged, end to end.
    func testWedgedChildTeardownBarrierSequence() async throws {
        signal(SIGPIPE, SIG_IGN)

        let backend = try BackendProcess(command: ["/bin/sleep", "30"])
        try backend.start()
        let writer = FramedWriter(
            stdinHandle: backend.stdin,
            maxOutstandingBytes: 1_000_000,
            stallThresholdSeconds: 0.25
        )

        // Fill the ~64KB pipe: the first frame's payload write blocks in
        // the kernel, the rest queue behind it.
        let payload = Data(repeating: 0x55, count: 65_536)
        for i in 0..<3 {
            writer.send(type: .audio, stream: .mic, ptsUs: Int64(i), payload: payload)
        }
        let stalled = await pollUntil(timeout: 2.0) { writer.isBacklogStalled() }
        XCTAssertTrue(stalled, "the blocked write must register as a stall")

        // Barrier while the write is still blocked: the queued close cannot
        // run yet, and the barrier must say so (bounded, not hanging) - the
        // caller proceeds without ever touching stdin cross-thread.
        let earlyClose = await writer.closeStdinAndWait(timeoutSeconds: 0.5)
        XCTAssertFalse(earlyClose, "close is queued behind the blocked write - it must not report as run")

        // Reader dies (production: SIGTERM/SIGKILL escalation). EPIPE
        // unblocks the queue, queued writes fail fast, the close runs.
        backend.terminate()
        let closed = await writer.closeStdinAndWait(timeoutSeconds: 3)
        XCTAssertTrue(closed, "reader death must let the queued close execute")
        XCTAssertEqual(writer.backlogSnapshot().outstandingFrames, 0, "queue fully drained before cleanup")

        backend.cleanup() // runs strictly after the barrier - and stdin-free

        let status = await backend.waitForExit(timeoutSeconds: 5)
        XCTAssertNotNil(status, "the terminated child must be reaped")
    }

    private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
