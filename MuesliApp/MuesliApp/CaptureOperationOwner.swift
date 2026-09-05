import Foundation

/// Owns one native lifecycle operation through its real completion. A timeout
/// releases the caller's wait, but keeps this owner quarantined until the
/// framework call returns and late-start cleanup has completed.
nonisolated final class CaptureOperationOwner: @unchecked Sendable {
    enum Failure: Error, LocalizedError, Sendable {
        case busy, timedOut, cancelled
        var errorDescription: String? {
            switch self {
            case .busy: return "The previous audio operation has not finished. Capture is waiting for macOS."
            case .timedOut: return "macOS did not finish the audio operation before its deadline."
            case .cancelled: return "The audio operation was cancelled while waiting for macOS."
            }
        }
    }
    private final class Operation: @unchecked Sendable {
        let completion = TaskCompletion()
        let lock = NSLock()
        var result: Result<Void, Error>?
        var abandoned = false
        var failureReported = false
        func takeFailureReport() -> Bool {
            lock.withLock { if failureReported { return false }; failureReported = true; return true }
        }
    }
    private let lock = NSLock()
    private var active: Operation?
    var isBusy: Bool { lock.withLock { active != nil } }

    @concurrent
    func perform(timeoutSeconds: Double = 8,
                 onFailure: @escaping @Sendable (Error) -> Void = { _ in },
                 operation: @escaping @Sendable () async throws -> Void,
                 cleanupIfAbandoned: @escaping @Sendable () async -> Void = {}) async throws {
        let state = Operation()
        guard lock.withLock({ if active != nil { return false }; active = state; return true }) else {
            onFailure(Failure.busy)
            throw Failure.busy
        }
        Task.detached(priority: .userInitiated) { [self] in
            let result: Result<Void, Error>
            do { try await operation(); result = .success(()) } catch {
                if state.takeFailureReport() { onFailure(error) }
                result = .failure(error)
            }
            let abandoned = state.lock.withLock {
                if state.abandoned { return true }
                lock.withLock { if active === state { active = nil } }
                state.result = result
                return false
            }
            if abandoned {
                await cleanupIfAbandoned()
                lock.withLock { if active === state { active = nil } }
            }
            state.completion.markCompleted()
        }
        let wait = await state.completion.wait(timeoutSeconds: timeoutSeconds)
        let result: Result<Void, Error>? = state.lock.withLock {
            if let result = state.result { return result }
            state.abandoned = true
            return nil
        }
        if let result { try result.get(); return }
        let failure: Failure = wait == .cancelled ? .cancelled : .timedOut
        if state.takeFailureReport() { onFailure(failure) }
        throw failure
    }
}

/// One invalidation per native generation, even if macOS emits a notification
/// storm while the UI executor is unavailable.
nonisolated final class CaptureInvalidationMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let consume: @MainActor @Sendable () -> Void
    private let onInvalidated: @Sendable () -> Void
    init(onInvalidated: @escaping @Sendable () -> Void = {}, consume: @escaping @MainActor @Sendable () -> Void) {
        self.onInvalidated = onInvalidated
        self.consume = consume
    }
    func callback() -> @Sendable () -> Void {
        { [self] in
            guard lock.withLock({ if fired { return false }; fired = true; return true }) else { return }
            onInvalidated()
            Task { @MainActor [self] in self.consume() }
        }
    }
}
