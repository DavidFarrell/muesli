import XCTest

@MainActor
final class MainActorStarvationWatchdogTests: XCTestCase {
    private typealias State = MainActorStarvationWatchdog.ProbeState
    private let context = MainActorStarvationWatchdog.Context(
        activeScreen: "meeting", transcriptRows: 12, historyCount: 3, meterPublishCount: 45
    )

    func testOneOutstandingEchoAndRateLimitedReportsDuringLongStall() throws {
        var state = State(threshold: .seconds(5), relogInterval: .seconds(10))
        state.start(now: .zero)
        let id = try XCTUnwrap(state.tick(now: .zero).echoID)
        XCTAssertNil(state.tick(now: .seconds(4)).report)
        let first = state.tick(now: .seconds(5))
        XCTAssertNil(first.echoID)
        XCTAssertEqual(first.report?.kind, .starved)
        XCTAssertEqual(first.report?.elapsed, .seconds(5))
        XCTAssertNil(first.report?.lastResponsiveContext)
        for second in 6..<15 {
            let tick = state.tick(now: .seconds(second))
            XCTAssertNil(tick.echoID)
            XCTAssertNil(tick.report)
        }
        let next = state.tick(now: .seconds(15))
        XCTAssertNil(next.echoID)
        XCTAssertEqual(next.report?.kind, .starved)
        XCTAssertEqual(state.pending?.id, id)
        let recovered = state.acknowledge(id: id, now: .seconds(16), context: context)
        XCTAssertEqual(recovered?.kind, .recovered)
        XCTAssertEqual(recovered?.elapsed, .seconds(16))
        XCTAssertNil(state.acknowledge(id: id, now: .seconds(17), context: context))
        XCTAssertNotEqual(state.tick(now: .seconds(18)).echoID, id)
    }

    func testContextIsExplicitlyFromLastResponsiveEcho() throws {
        var state = State(threshold: .seconds(5), relogInterval: .seconds(10))
        state.start(now: .zero)
        let id = try XCTUnwrap(state.tick(now: .zero).echoID)
        XCTAssertNil(state.acknowledge(id: id, now: .seconds(1), context: context))
        _ = state.tick(now: .seconds(2))
        let report = try XCTUnwrap(state.tick(now: .seconds(7)).report)
        XCTAssertEqual(report.lastResponsiveContext, context)
        XCTAssertEqual(report.contextAge, .seconds(6))
        XCTAssertTrue(report.logLine.contains("last_responsive_context_age_ms=6000"))
    }

    func testStopRestartRetainsOneOutstandingEchoAndIgnoresWrongReplies() throws {
        var state = State(threshold: .seconds(5), relogInterval: .seconds(10))
        state.start(now: .zero)
        let id = try XCTUnwrap(state.tick(now: .zero).echoID)
        _ = state.tick(now: .seconds(5))
        state.stop()
        XCTAssertNil(state.tick(now: .seconds(20)).report)
        for second in 21...100 {
            state.start(now: .seconds(second))
            XCTAssertNil(state.tick(now: .seconds(second)).echoID)
            state.stop()
        }
        state.start(now: .seconds(101))
        XCTAssertNil(state.acknowledge(id: id + 1, now: .seconds(102), context: context))
        XCTAssertEqual(state.pending?.id, id)
        XCTAssertEqual(state.tick(now: .seconds(106)).report?.kind, .starved)
        XCTAssertEqual(state.acknowledge(id: id, now: .seconds(107), context: context)?.kind, .recovered)
        XCTAssertNotNil(state.tick(now: .seconds(108)).echoID)
    }

    func testReplyWhileStoppedFreesSlotWithoutReportingRecovery() throws {
        var state = State(threshold: .seconds(5), relogInterval: .seconds(10))
        state.start(now: .zero)
        let id = try XCTUnwrap(state.tick(now: .zero).echoID)
        _ = state.tick(now: .seconds(5))
        state.stop()
        XCTAssertNil(state.acknowledge(id: id, now: .seconds(6), context: context))
        XCTAssertNil(state.pending)
        state.start(now: .seconds(7))
        XCTAssertNotNil(state.tick(now: .seconds(7)).echoID)
    }

    /// This intentionally blocks the real MainActor. An independent fail-safe
    /// always releases it, even if the watchdog regresses. Assertions after
    /// release use evidence captured off MainActor BEFORE that release.
    func testPersistsStarvationReportWhileMainActorIsActuallyBlocked() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = BackendLogWriter(ringBufferLimit: 10)
        writer.reset(handle: try FileHandle(forWritingTo: url))
        let evidence = BlockedMainActorEvidence()
        let recovered = TaskCompletion()
        let watchdog = MainActorStarvationWatchdog(
            logWriter: writer,
            pingIntervalSeconds: 0.01,
            starvedThresholdSeconds: 0.08,
            starvedRelogIntervalSeconds: 1,
            onReport: { report in
                if report.kind == .starved {
                    // Synchronous tail read also orders this read after the
                    // independent writer queue's append to the real file.
                    let tail = writer.tailSnapshot(limit: 10)
                    let persisted = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    evidence.recordReport(offMain: !Thread.isMainThread,
                                          persisted: persisted.contains("mainactor.starved") &&
                                            tail.contains(where: { $0.contains("mainactor.starved") }))
                } else {
                    recovered.markCompleted()
                }
            }
        )
        defer {
            watchdog.stop()
            writer.close()
            _ = writer.tailSnapshot(limit: 1)
            try? FileManager.default.removeItem(at: url)
        }

        let failSafe = DispatchWorkItem { evidence.releaseByFailSafe() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2, execute: failSafe)
        defer { failSafe.cancel() }
        evidence.beginBlocking()
        watchdog.start()
        // No actor task, XCTest expectation, or watchdog timeout can release
        // this wait. Only its off-UI report (or independent fail-safe) can.
        let released = evidence.blockMainActorUntilReleased()
        evidence.endBlocking()

        XCTAssertEqual(released, .success)
        let snapshot = evidence.snapshot()
        XCTAssertFalse(snapshot.failSafeFired, "watchdog failed to report while MainActor was blocked")
        XCTAssertTrue(snapshot.reportedWhileBlocked)
        XCTAssertTrue(snapshot.reportedOffMain)
        XCTAssertTrue(snapshot.persisted)
        let recovery = await recovered.wait(timeoutSeconds: 1)
        XCTAssertEqual(recovery, .completed, "late echo must report recovery after the actor is released")
    }
}

nonisolated private final class BlockedMainActorEvidence: @unchecked Sendable {
    struct Snapshot {
        var failSafeFired = false
        var reportedWhileBlocked = false
        var reportedOffMain = false
        var persisted = false
    }
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    private var evidence = Snapshot()

    func beginBlocking() { lock.withLock { blocked = true } }
    func endBlocking() { lock.withLock { blocked = false } }
    // Deliberately synchronous: an await here would release MainActor and
    // remove the failure condition this integration test needs to exercise.
    @MainActor func blockMainActorUntilReleased() -> DispatchTimeoutResult {
        release.wait(timeout: .now() + 3)
    }
    func recordReport(offMain: Bool, persisted: Bool) {
        lock.withLock {
            evidence.reportedWhileBlocked = blocked
            evidence.reportedOffMain = offMain
            evidence.persisted = persisted
        }
        release.signal()
    }
    func releaseByFailSafe() {
        lock.withLock { evidence.failSafeFired = true }
        release.signal()
    }
    func snapshot() -> Snapshot { lock.withLock { evidence } }
}
