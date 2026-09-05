import XCTest

@MainActor
final class TaskCompletionTests: XCTestCase {
    func testOneShotOwnerObserverBeforeAfterAndRacingCompletion() async {
        for iteration in 0..<60 {
            let completion = TaskCompletion()
            let observed = TaskCompletion()
            let counter = CompletionObserverCounter()
            if iteration.isMultiple(of: 2) { completion.markCompleted() }
            DispatchQueue.global().async { completion.markCompleted(); completion.markCompleted() }
            completion.observeCompletion { counter.increment(); observed.markCompleted() }
            let result = await observed.wait(timeoutSeconds: 1)
            XCTAssertEqual(result, .completed)
            completion.markCompleted()
            XCTAssertEqual(counter.value, 1)
        }
    }

    func testCompletionBeforeWaitAndRepeatedCompletion() async {
        let completion = TaskCompletion()
        completion.markCompleted()
        completion.markCompleted()
        let outcome = await completion.wait(timeoutSeconds: 0)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(completion.pendingWaiterCount, 0)
    }

    func testRepeatedTimeoutsLeaveNoWaiters() async {
        let completion = TaskCompletion()
        for _ in 0..<20 {
            let outcome = await completion.wait(timeoutSeconds: 0.002)
            XCTAssertEqual(outcome, .timedOut)
            XCTAssertEqual(completion.pendingWaiterCount, 0)
        }
        completion.markCompleted()
        let outcome = await completion.wait(timeoutSeconds: 1)
        XCTAssertEqual(outcome, .completed, "late owner completion remains observable")
    }

    func testCancellationBeforeOrDuringRegistrationLeavesNoWaiters() async {
        let completion = TaskCompletion()
        for _ in 0..<100 {
            let waiter = Task.detached { await completion.wait(timeoutSeconds: 20) }
            waiter.cancel()
            let outcome = await waiter.value
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertEqual(completion.pendingWaiterCount, 0)
        }
    }

    func testConcurrentCompletionCancellationAndTimeoutResolveOnce() async {
        for iteration in 0..<30 {
            let completion = TaskCompletion()
            let waiter = Task.detached { await completion.wait(timeoutSeconds: 0.002) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) {
                completion.markCompleted()
            }
            if iteration.isMultiple(of: 2) { waiter.cancel() }
            let outcome = await waiter.value
            XCTAssertTrue([.completed, .cancelled, .timedOut].contains(outcome))
            XCTAssertEqual(completion.pendingWaiterCount, 0)
        }
    }

    func testMultipleWaitersShareCompletionAndCanExpireIndependently() async {
        let completion = TaskCompletion()
        let short = Task.detached { await completion.wait(timeoutSeconds: 0.02) }
        let long = Task.detached { await completion.wait(timeoutSeconds: 2) }
        let shortOutcome = await short.value
        XCTAssertEqual(shortOutcome, .timedOut)
        completion.markCompleted()
        let longOutcome = await long.value
        XCTAssertEqual(longOutcome, .completed)
        XCTAssertEqual(completion.pendingWaiterCount, 0)
    }

    func testBoundedWaitDoesNotJoinOrClaimCancellationOfNoncooperativeTask() async {
        let operation = NoncooperativeOperation()
        let task = CompletionTrackedTask { await operation.run() }
        // Independent release prevents a broken timeout implementation from
        // hanging the suite. Task cancellation does not release this operation.
        let failSafe = DispatchWorkItem { operation.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: failSafe)
        defer { failSafe.cancel(); operation.release() }
        let clock = ContinuousClock()
        let start = clock.now
        let first = await task.wait(timeoutSeconds: 0.03)
        XCTAssertEqual(first, .timedOut)
        task.cancel()
        let afterCancellation = await task.wait(timeoutSeconds: 0.03)
        XCTAssertEqual(afterCancellation, .timedOut, "cancellation is not completion")
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        operation.release()
        let finished = await task.wait(timeoutSeconds: 1)
        XCTAssertEqual(finished, .completed)
        XCTAssertEqual(operation.runCount, 1, "waiting never starts repeated work")
    }
}

nonisolated private final class NoncooperativeOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var count = 0
    var runCount: Int { lock.withLock { count } }

    @concurrent func run() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                count += 1
                if released { return true }
                self.continuation = continuation
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    func release() {
        let saved = lock.withLock {
            released = true
            let saved = continuation
            continuation = nil
            return saved
        }
        saved?.resume()
    }
}

nonisolated private final class CompletionObserverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
