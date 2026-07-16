import XCTest

/// Integration coverage for `FramedWriter`'s backpressure detection and
/// force-close against a REAL pipe - the pure counter logic is pinned in
/// `WriteBacklogTrackerTests`; these tests verify the wiring: a healthy
/// consumer never reads as stalled, a full pipe (nobody reading - the
/// 2026-07-16 incident's exact transport state) is detected and capped, and
/// `forceCloseStdin` EOFs the reader without needing the write queue.
final class FramedWriterTests: XCTestCase {
    private static let headerByteCount = 14

    /// Read continuously off the pipe on a background thread until EOF,
    /// counting bytes. Mirrors a healthy backend's stdin consumption. The
    /// thread retains `self` until EOF releases it, so a test must close the
    /// write end before returning.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var byteCount = 0

        init(handle: FileHandle) {
            Thread.detachNewThread { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { return } // EOF
                    lock.lock()
                    byteCount += chunk.count
                    lock.unlock()
                }
            }
        }

        var totalBytesRead: Int {
            lock.lock()
            defer { lock.unlock() }
            return byteCount
        }
    }

    /// Poll `condition` on the current thread until it holds or the timeout
    /// elapses. The writer's completions land on its own queue, so tests
    /// must wait for them rather than assert immediately.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testHealthyConsumerDeliversEverythingAndNeverStalls() {
        let pipe = Pipe()
        // Cap well above the test's whole volume: this test enqueues its 50
        // frames in a burst far faster than real-time audio (production
        // paces enqueues at ~64KB/s), and the cap must not be what's under
        // test here - stall detection and complete delivery are.
        let writer = FramedWriter(
            stdinHandle: pipe.fileHandleForWriting,
            maxOutstandingBytes: 1_000_000,
            stallThresholdSeconds: 0.25
        )
        let drain = PipeDrain(handle: pipe.fileHandleForReading)

        let payload = Data(repeating: 0xAB, count: 2_730)
        let frameCount = 50
        for i in 0..<frameCount {
            writer.send(type: .audio, stream: .mic, ptsUs: Int64(i), payload: payload)
        }

        let expectedBytes = frameCount * (Self.headerByteCount + payload.count)
        XCTAssertTrue(
            waitUntil(timeout: 2.0) { drain.totalBytesRead == expectedBytes },
            "all frames must reach the reader (got \(drain.totalBytesRead)/\(expectedBytes) bytes)"
        )

        // Well past the (test-shortened) stall threshold with a consumer
        // that kept pace: no stall, no drops.
        Thread.sleep(forTimeInterval: 0.4)
        let snap = writer.backlogSnapshot()
        XCTAssertFalse(snap.isStalled)
        XCTAssertEqual(snap.outstandingFrames, 0)
        XCTAssertEqual(snap.droppedFrames, 0)
        XCTAssertEqual(snap.totalCompletedFrames, frameCount)

        writer.forceCloseStdin() // release the drain thread via EOF
    }

    func testFullPipeIsDetectedAsStalledAndCapDropsAudio() {
        let pipe = Pipe()
        // Cap sized so exactly two 64KB frames are admitted: the first
        // blocks in the kernel once the ~64KB pipe buffer fills, the second
        // queues behind it, and everything further must drop.
        let payload = Data(repeating: 0xCD, count: 65_536)
        let frameBytes = Self.headerByteCount + payload.count
        let writer = FramedWriter(
            stdinHandle: pipe.fileHandleForWriting,
            maxOutstandingBytes: frameBytes * 2,
            stallThresholdSeconds: 0.25
        )

        // Nobody reads - the incident's transport state.
        for i in 0..<4 {
            writer.send(type: .audio, stream: .mic, ptsUs: Int64(i), payload: payload)
        }

        // Admission accounting is synchronous in send(), so this is
        // deterministic regardless of how far the blocked write got.
        var snap = writer.backlogSnapshot()
        XCTAssertEqual(snap.totalEnqueuedFrames, 2)
        XCTAssertEqual(snap.droppedFrames, 2)
        XCTAssertEqual(snap.droppedBytes, frameBytes * 2)

        // No completions can happen; past the threshold this must read as
        // stalled - the alive-but-not-reading alarm the incident never had.
        XCTAssertTrue(
            waitUntil(timeout: 1.0) { writer.isBacklogStalled() },
            "blocked pipe with queued work must register as stalled"
        )

        // Consumer comes back: drain the pipe, the blocked write finishes,
        // the backlog empties and the stall clears.
        let drain = PipeDrain(handle: pipe.fileHandleForReading)
        XCTAssertTrue(
            waitUntil(timeout: 2.0) { writer.backlogSnapshot().outstandingFrames == 0 },
            "draining the pipe must let the queued writes complete"
        )
        XCTAssertFalse(writer.isBacklogStalled())
        snap = writer.backlogSnapshot()
        XCTAssertEqual(snap.totalCompletedFrames, 2)
        XCTAssertEqual(drain.totalBytesRead, frameBytes * 2, "only admitted frames reach the pipe")

        writer.forceCloseStdin()
    }

    func testForceCloseStopsNewSendsAndEOFsTheReader() {
        let pipe = Pipe()
        let writer = FramedWriter(
            stdinHandle: pipe.fileHandleForWriting,
            maxOutstandingBytes: 100_000,
            stallThresholdSeconds: 0.25
        )
        let payload = Data(repeating: 0xEF, count: 100)
        writer.send(type: .audio, stream: .mic, ptsUs: 0, payload: payload)
        XCTAssertTrue(
            waitUntil(timeout: 1.0) { writer.backlogSnapshot().totalCompletedFrames == 1 }
        )

        writer.forceCloseStdin()

        // Post-close sends are no-ops: nothing enqueued, nothing dropped -
        // the writer is done, not backlogged.
        writer.send(type: .audio, stream: .mic, ptsUs: 1, payload: payload)
        writer.send(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
        let snap = writer.backlogSnapshot()
        XCTAssertEqual(snap.totalEnqueuedFrames, 1)
        XCTAssertEqual(snap.droppedFrames, 0)

        // The reader sees the one delivered frame then EOF.
        let expected = Self.headerByteCount + payload.count
        var readTotal = 0
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            readTotal += chunk.count
        }
        XCTAssertEqual(readTotal, expected)
    }

    func testDoubleForceCloseIsSafe() {
        let pipe = Pipe()
        let writer = FramedWriter(stdinHandle: pipe.fileHandleForWriting)
        writer.forceCloseStdin()
        writer.forceCloseStdin() // second close must not crash (try? close)
        writer.closeStdinAfterDraining() // nor the queued close afterwards
        XCTAssertTrue(waitUntil(timeout: 1.0) { true })
    }
}
