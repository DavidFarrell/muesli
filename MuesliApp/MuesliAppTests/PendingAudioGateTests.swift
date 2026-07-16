import XCTest

/// Coverage for the system-audio readiness gate (gate BLOCKERS 1 and 2 on
/// the 2026-07-16 slice). Blocker 1: the old flush set enabled=true and
/// then sent the buffered prefix OUTSIDE the critical section, so a
/// concurrent capture callback could send a newer PTS ahead of it - and the
/// backend's PTS-aligned writer would silently drop the whole prefix on a
/// healthy meeting. Blocker 2: the old ring capped by callback COUNT, which
/// covers an unpredictable wall-time span. These tests pin the atomic
/// flush+enable ordering and the byte-based cap.
final class PendingAudioGateTests: XCTestCase {
    private func item(_ pts: Int64, byteCount: Int = 4) -> PendingAudioGate.Item {
        PendingAudioGate.Item(ptsUs: pts, payload: Data(repeating: 0, count: byteCount))
    }

    /// Thread-safe ordered log standing in for the FramedWriter serial
    /// queue's enqueue order.
    private final class OrderedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []

        func append(_ value: Int64) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testBuffersWhileDisabledAndFlushesInOrder() {
        let gate = PendingAudioGate()
        XCTAssertFalse(gate.admitOrBuffer(item(0)))
        XCTAssertFalse(gate.admitOrBuffer(item(1)))
        XCTAssertFalse(gate.admitOrBuffer(item(2)))

        var flushed: [Int64] = []
        gate.enableAndFlush { flushed.append($0.ptsUs) }
        XCTAssertEqual(flushed, [0, 1, 2], "buffered prefix flushes complete, in capture order")

        XCTAssertTrue(gate.admitOrBuffer(item(3)), "gate open - subsequent frames pass live")
        XCTAssertEqual(gate.snapshot().bufferedFrames, 0)
    }

    func testByteCapEvictsOldestFirstWithAccounting() {
        let gate = PendingAudioGate(maxPendingBytes: 30)
        for pts in 0..<5 {
            _ = gate.admitOrBuffer(item(Int64(pts), byteCount: 10)) // cap holds 3
        }
        var flushed: [Int64] = []
        gate.enableAndFlush { flushed.append($0.ptsUs) }
        XCTAssertEqual(flushed, [2, 3, 4], "oldest evicted first - the newest audio survives")

        // Accounting is reset with the gate, so snapshot before reset.
        let gate2 = PendingAudioGate(maxPendingBytes: 30)
        for pts in 0..<5 {
            _ = gate2.admitOrBuffer(item(Int64(pts), byteCount: 10))
        }
        let snap = gate2.snapshot()
        XCTAssertEqual(snap.bufferedFrames, 3)
        XCTAssertEqual(snap.bufferedBytes, 30)
        XCTAssertEqual(snap.droppedOldestFrames, 2)
        XCTAssertEqual(snap.droppedOldestBytes, 20)
    }

    func testResetClosesTheGateAndClearsBuffer() {
        let gate = PendingAudioGate()
        gate.enableAndFlush { _ in }
        XCTAssertTrue(gate.admitOrBuffer(item(0)))

        gate.reset()
        XCTAssertFalse(gate.admitOrBuffer(item(1)), "reset closes the gate again")
        var flushed: [Int64] = []
        gate.enableAndFlush { flushed.append($0.ptsUs) }
        XCTAssertEqual(flushed, [1], "only post-reset frames survive a reset")
    }

    /// The BLOCKER 1 regression test: a producer thread delivering
    /// monotonically increasing PTS (SCK's serial callback queue) races
    /// `enableAndFlush`. Whatever the interleaving, the combined enqueue
    /// order seen by the writer must stay strictly increasing - a single
    /// out-of-order pair is exactly the shape that makes the backend drop
    /// the buffered prefix. The old implementation (flip enabled, then
    /// flush outside the lock) fails this within a few iterations.
    func testConcurrentDeliveryDuringEnableAndFlushNeverReorders() {
        for iteration in 0..<200 {
            let gate = PendingAudioGate()
            let log = OrderedLog()
            let frameCount = 200
            let producerDone = DispatchSemaphore(value: 0)

            let producer = Thread {
                for pts in 0..<frameCount {
                    let candidate = PendingAudioGate.Item(
                        ptsUs: Int64(pts), payload: Data(repeating: 0, count: 4)
                    )
                    if gate.admitOrBuffer(candidate) {
                        log.append(candidate.ptsUs)
                    }
                }
                producerDone.signal()
            }
            producer.start()

            // Enable at a random point mid-stream to spray the race window.
            usleep(UInt32.random(in: 0...300))
            gate.enableAndFlush { log.append($0.ptsUs) }

            XCTAssertEqual(
                producerDone.wait(timeout: .now() + 5), .success,
                "producer must finish (iteration \(iteration))"
            )

            let order = log.snapshot
            XCTAssertEqual(order.count, frameCount, "every frame arrives exactly once (iteration \(iteration))")
            for i in 1..<order.count where order[i] <= order[i - 1] {
                XCTFail("PTS order violated at index \(i): \(order[i - 1]) -> \(order[i]) (iteration \(iteration))")
                return
            }
        }
    }
}
