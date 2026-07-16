import XCTest

/// Unit coverage for the 2026-07-16 backpressure detector's pure core - see
/// `engineer-notes/bug-2026-07-16-stop-device-change/RCA-2026-07-16.md`
/// (rec #2). The incident signature: a wedged backend stops reading its
/// stdin pipe, `FileHandle.write` blocks (never throws), and 26 minutes of
/// audio piled up as retained queue payloads with no alarm. These tests pin
/// the two behaviours that make that impossible: stall detection (work
/// queued + no completion progress) and the drop-with-accounting backlog cap.
final class WriteBacklogTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func makeTracker(
        maxOutstandingBytes: Int = 100_000,
        stallThresholdSeconds: TimeInterval = 5.0
    ) -> WriteBacklogTracker {
        WriteBacklogTracker(
            maxOutstandingBytes: maxOutstandingBytes,
            stallThresholdSeconds: stallThresholdSeconds
        )
    }

    // MARK: - Stall detection

    func testHealthyFastConsumerNeverStalls() {
        var tracker = makeTracker()
        // 20 simulated seconds of enqueue-then-complete at frame cadence -
        // the healthy shape: completions keep pace, backlog hovers near zero.
        for i in 0..<200 {
            let enqueueAt = at(Double(i) * 0.1)
            XCTAssertTrue(tracker.recordEnqueue(bytes: 2_730, droppable: true, now: enqueueAt))
            XCTAssertFalse(tracker.isStalled(now: enqueueAt))
            tracker.recordCompletion(bytes: 2_730, now: enqueueAt.addingTimeInterval(0.01))
            XCTAssertFalse(tracker.isStalled(now: enqueueAt.addingTimeInterval(0.05)))
        }
        XCTAssertEqual(tracker.outstandingFrames, 0)
        XCTAssertEqual(tracker.droppedFrames, 0)
    }

    func testStallFiresWhenCompletionsStopButEnqueuesContinue() {
        var tracker = makeTracker(stallThresholdSeconds: 5.0)
        // Wedged-from-frame-one: enqueues arrive, nothing ever completes -
        // the exact incident shape (backend never entered its read loop).
        _ = tracker.recordEnqueue(bytes: 2_730, droppable: true, now: at(0))
        _ = tracker.recordEnqueue(bytes: 2_730, droppable: true, now: at(1))
        _ = tracker.recordEnqueue(bytes: 2_730, droppable: true, now: at(2))
        XCTAssertFalse(tracker.isStalled(now: at(4.9)), "below threshold - not yet a stall")
        XCTAssertTrue(tracker.isStalled(now: at(5.1)), "no completion for >5s with work queued")
    }

    func testIdleQueueIsNeverStalled() {
        var tracker = makeTracker()
        XCTAssertFalse(tracker.isStalled(now: at(60)), "nothing ever enqueued")

        _ = tracker.recordEnqueue(bytes: 100, droppable: true, now: at(0))
        tracker.recordCompletion(bytes: 100, now: at(0.1))
        XCTAssertFalse(
            tracker.isStalled(now: at(120)),
            "a drained queue idling for minutes is healthy, not stalled"
        )
    }

    func testCompletionResetsTheStallClock() {
        var tracker = makeTracker(stallThresholdSeconds: 5.0)
        _ = tracker.recordEnqueue(bytes: 100, droppable: true, now: at(0))
        _ = tracker.recordEnqueue(bytes: 100, droppable: true, now: at(0.5))
        tracker.recordCompletion(bytes: 100, now: at(3))
        // One frame still outstanding, but progress happened at t=3 - the
        // stall clock measures from there, not from the first enqueue.
        XCTAssertFalse(tracker.isStalled(now: at(7.9)))
        XCTAssertTrue(tracker.isStalled(now: at(8.1)))
    }

    func testRecoveryAfterDrainClearsStall() {
        var tracker = makeTracker(stallThresholdSeconds: 5.0)
        _ = tracker.recordEnqueue(bytes: 100, droppable: true, now: at(0))
        _ = tracker.recordEnqueue(bytes: 100, droppable: true, now: at(1))
        XCTAssertTrue(tracker.isStalled(now: at(6)))
        // Consumer comes back and drains everything.
        tracker.recordCompletion(bytes: 100, now: at(7))
        tracker.recordCompletion(bytes: 100, now: at(7.1))
        XCTAssertFalse(tracker.isStalled(now: at(20)), "empty queue - stall must clear")
    }

    // MARK: - Backlog cap

    func testDropsAudioBeyondByteCapWithAccounting() {
        var tracker = makeTracker(maxOutstandingBytes: 250)
        XCTAssertTrue(tracker.recordEnqueue(bytes: 100, droppable: true, now: at(0)))
        XCTAssertTrue(tracker.recordEnqueue(bytes: 100, droppable: true, now: at(1)))
        // 200 outstanding; +100 would breach 250 - dropped, with accounting.
        XCTAssertFalse(tracker.recordEnqueue(bytes: 100, droppable: true, now: at(2)))
        XCTAssertFalse(tracker.recordEnqueue(bytes: 100, droppable: true, now: at(3)))

        XCTAssertEqual(tracker.outstandingFrames, 2)
        XCTAssertEqual(tracker.outstandingBytes, 200)
        XCTAssertEqual(tracker.droppedFrames, 2)
        XCTAssertEqual(tracker.droppedBytes, 200)
        XCTAssertEqual(tracker.totalEnqueuedFrames, 2, "drops must not count as enqueued")
    }

    func testControlFramesAreNeverDropped() {
        var tracker = makeTracker(maxOutstandingBytes: 50)
        XCTAssertTrue(tracker.recordEnqueue(bytes: 40, droppable: true, now: at(0)))
        XCTAssertFalse(tracker.recordEnqueue(bytes: 40, droppable: true, now: at(1)), "audio over cap drops")
        XCTAssertTrue(
            tracker.recordEnqueue(bytes: 40, droppable: false, now: at(2)),
            "control frames (meeting start/stop) bypass the cap - dropping meeting_stop would be worse than the memory"
        )
        XCTAssertEqual(tracker.outstandingFrames, 2)
        XCTAssertEqual(tracker.droppedFrames, 1)
    }

    func testDrainReopensAdmissionAfterDrops() {
        var tracker = makeTracker(maxOutstandingBytes: 250)
        _ = tracker.recordEnqueue(bytes: 200, droppable: true, now: at(0))
        XCTAssertFalse(tracker.recordEnqueue(bytes: 100, droppable: true, now: at(1)))
        tracker.recordCompletion(bytes: 200, now: at(2))
        XCTAssertTrue(
            tracker.recordEnqueue(bytes: 100, droppable: true, now: at(3)),
            "once the backlog drains below the cap, audio is admitted again"
        )
    }
}
