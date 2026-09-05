import Foundation

/// A completion event owned by the operation, independent of anyone waiting
/// for it. Each wait owns only a timer and a continuation; timeout/cancellation
/// removes both. No observer task remains suspended on an unrelated task.value.
/// This bounds the WAIT, not the operation. Completion must be signalled by the
/// original owner; cancellation cannot establish that a framework call stopped.
nonisolated final class TaskCompletion: @unchecked Sendable {
    enum Outcome: Sendable, Equatable { case completed, timedOut, cancelled }

    private struct Waiter {
        let continuation: CheckedContinuation<Outcome, Never>
        let timer: DispatchSourceTimer

        func resolve(_ outcome: Outcome) {
            timer.setEventHandler {}
            timer.cancel()
            continuation.resume(returning: outcome)
        }
    }

    private static let timerQueue = DispatchQueue(label: "muesli.task-completion", qos: .utility)
    // All mutable state is under lock. Continuations resume outside the lock.
    private let lock = NSLock()
    private var completed = false
    private var waiters: [UUID: Waiter] = [:]

    func markCompleted() {
        let resolved: [Waiter] = lock.withLock {
            completed = true
            let resolved = Array(waiters.values)
            waiters.removeAll()
            return resolved
        }
        for waiter in resolved { waiter.resolve(.completed) }
    }

    var pendingWaiterCount: Int { lock.withLock { waiters.count } }

    @concurrent func wait(timeoutSeconds: Double) async -> Outcome {
        precondition(timeoutSeconds.isFinite && timeoutSeconds >= 0)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Outcome? = lock.withLock {
                    // Covers cancellation before registration; cancellation
                    // after this check removes the registered waiter under the
                    // same lock. There is no lost-cancellation window.
                    if Task.isCancelled { return .cancelled }
                    if completed { return .completed }
                    if timeoutSeconds == 0 { return .timedOut }
                    let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
                    timer.setEventHandler { [weak self] in
                        self?.resolve(id: id, outcome: .timedOut)
                    }
                    timer.schedule(deadline: .now() + timeoutSeconds)
                    waiters[id] = Waiter(continuation: continuation, timer: timer)
                    timer.resume()
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.resolve(id: id, outcome: .cancelled)
        }
    }

    private func resolve(id: UUID, outcome: Outcome) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resolve(outcome)
    }
}

/// Installs the completion event in the original task body. Repeated waits
/// share that event instead of creating one unstructured observer per attempt.
nonisolated struct CompletionTrackedTask: Sendable {
    private let task: Task<Void, Never>
    private let completion: TaskCompletion

    init(operation: @escaping @isolated(any) @Sendable () async -> Void) {
        let completion = TaskCompletion()
        self.completion = completion
        task = Task {
            defer { completion.markCompleted() }
            await operation()
        }
    }

    func cancel() { task.cancel() }

    @concurrent func wait(timeoutSeconds: Double) async -> TaskCompletion.Outcome {
        await completion.wait(timeoutSeconds: timeoutSeconds)
    }
}
