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
        let adoptionDecision = TaskCompletion()
        let lock = NSLock()
        var result: Result<Void, Error>?
        var abandoned = false
        var claimed = false
        var claimOpen = true
    }
    /// The native start remains reserved until the UI either atomically takes
    /// ownership or refuses it. Claim and deadline retirement use the same lock.
    final class Claim: Sendable {
        private let take: @Sendable () -> Bool
        fileprivate init(take: @escaping @Sendable () -> Bool) { self.take = take }
        func claim() -> Bool { take() }
    }
    /// Construct synchronously BEFORE awaiting perform. Suspended callers retain
    /// this emptyable owner, never the original callback arguments. The caller's
    /// independently retained resources remain the caller's responsibility.
    final class Request: @unchecked Sendable {
        private struct Callbacks: Sendable {
            let operation: @Sendable () async throws -> Void
            let adoption: (@MainActor @Sendable (Claim) -> Void)?
            let cleanup: @Sendable () async -> Void
            let failure: @Sendable (Error) -> Void
        }
        private let lock = NSLock()
        private var callbacks: Callbacks?
        private var used = false
        private var adoptionOpen = true
        private var adoptionActive = false
        private var failureReported = false
        private var failureActive = false
        private var retiring = false
        private let adoptionReturned = TaskCompletion()
        private let invocationsReturned = TaskCompletion()
        let hasAdoption: Bool

        init(onFailure: @escaping @Sendable (Error) -> Void = { _ in },
             operation: @escaping @Sendable () async throws -> Void,
             adoption: (@MainActor @Sendable (Claim) -> Void)? = nil,
             cleanupIfAbandoned: @escaping @Sendable () async -> Void = {}) {
            callbacks = Callbacks(operation: operation, adoption: adoption,
                                  cleanup: cleanupIfAbandoned, failure: onFailure)
            hasAdoption = adoption != nil
        }
        fileprivate func reserve() -> Bool {
            lock.withLock { if used { return false }; used = true; return true }
        }
        // Each borrowed callback is scoped to a helper that RETURNS before the
        // actual-completion signal. Clearing the stored callbacks cannot race a
        // local/coroutine copy of an accepted closure.
        fileprivate func run() async throws { try await callbacks!.operation() }
        fileprivate func cleanup() async { await callbacks!.cleanup() }
        @MainActor fileprivate func deliverAdoption(_ claim: Claim) {
            guard lock.withLock({
                if !adoptionOpen || adoptionActive { return false }
                adoptionOpen = false; adoptionActive = true; return true
            }) else { return }
            invokeAdoption(claim)
            lock.withLock { adoptionActive = false }
            adoptionReturned.markCompleted()
        }
        @MainActor private func invokeAdoption(_ claim: Claim) { callbacks?.adoption?(claim) }

        fileprivate final class FailureDelivery: Sendable {
            private let request: Request
            private let error: Error
            fileprivate init(_ request: Request, _ error: Error) { self.request = request; self.error = error }
            func deliver() {
                request.invokeFailure(error)
                request.failureReturned()
            }
        }
        // The deadline reserves this delivery while holding Operation.lock,
        // before the original worker may decide that it can retire the request.
        fileprivate func reserveFailure(_ error: Error) -> FailureDelivery? {
            lock.withLock {
                guard !failureReported, !retiring else { return nil }
                failureReported = true; failureActive = true
                return FailureDelivery(self, error)
            }
        }
        private func invokeFailure(_ error: Error) { callbacks?.failure(error) }
        private func failureReturned() {
            let finished = lock.withLock { failureActive = false; return retiring }
            if finished { invocationsReturned.markCompleted() }
        }
        fileprivate func reportFailure(_ error: Error) { reserveFailure(error)?.deliver() }

        fileprivate func closeAdoption() async {
            let idle = lock.withLock { adoptionOpen = false; return !adoptionActive }
            if idle { adoptionReturned.markCompleted() }
            // One wait by the original worker, deliberately without cancellation
            // or a deadline: an executing callback still owns its native inputs.
            await withCheckedContinuation { continuation in
                adoptionReturned.observeCompletion { continuation.resume() }
            }
        }
        fileprivate func retire() async {
            let idle = lock.withLock { retiring = true; return !failureActive }
            if idle { invocationsReturned.markCompleted() }
            await withCheckedContinuation { continuation in
                invocationsReturned.observeCompletion { continuation.resume() }
            }
            disposeCallbacks()
        }
        private func disposeCallbacks() {
            // The worker alone may destroy the captures, outside all locks and
            // only after native, cleanup, UI and failure invocations returned.
            callbacks = nil
        }
    }
    private let lock = NSLock()
    private var active: Operation?
    private let shutdown: ShutdownWorkRegistry
    init(shutdown: ShutdownWorkRegistry = .shared) { self.shutdown = shutdown }
    var isBusy: Bool { lock.withLock { active != nil } }

    /// Success reports the committed native result (or an atomic UI Claim).
    /// Normally this wait also observes callback retirement. If destruction of
    /// callback captures stalls past the deadline AFTER native completion was
    /// committed, return that known result without inventing native failure or
    /// invoking abandoned-start cleanup on an already-owned source. isBusy and
    /// the shutdown token remain held through actual Request disposal. Callers
    /// without an adoption callback must already own their native source.
    @concurrent
    func perform(_ request: Request, timeoutSeconds: Double = 8,
                 preservesRecording: Bool = false) async throws {
        guard request.reserve() else { throw Failure.busy }
        let state = Operation()
        let quitWork: ShutdownWorkRegistry.Token?
        do { quitWork = preservesRecording ? try shutdown.begin("Waiting for native recording cleanup") : nil }
        catch { await request.retire(); throw error }
        guard lock.withLock({ if active != nil { return false }; active = state; return true }) else {
            request.reportFailure(Failure.busy)
            await request.retire()
            quitWork?.finish()
            throw Failure.busy
        }
        Task.detached(priority: .userInitiated) { [self] in
            let result: Result<Void, Error>
            var cleanedUp = false
            do {
                try await request.run()
                if request.hasAdoption {
                    let claim = Claim { [self] in
                        state.lock.withLock {
                            guard state.claimOpen, !state.abandoned, !state.claimed else { return false }
                            state.claimed = true
                            state.result = .success(())
                            // Successful atomic transfer permits an immediate UI
                            // Stop. This request's work token still covers its
                            // callback until that invocation actually returns.
                            lock.withLock { if active === state { active = nil } }
                            return true
                        }
                    }
                    Task { @MainActor in
                        request.deliverAdoption(claim)
                        state.adoptionDecision.markCompleted()
                    }
                    let decision = await state.adoptionDecision.wait(timeoutSeconds: timeoutSeconds)
                    let claimed = state.lock.withLock {
                        if state.claimed { return true }
                        state.claimOpen = false
                        return false
                    }
                    await request.closeAdoption()
                    if !claimed {
                        await request.cleanup()
                        cleanedUp = true
                        throw decision == .timedOut ? Failure.timedOut : Failure.cancelled
                    }
                }
                result = .success(())
            } catch {
                request.reportFailure(error)
                result = .failure(error)
            }
            let abandoned = state.lock.withLock {
                if state.abandoned { return true }
                // Commit the native result atomically with the deadline's
                // abandonment decision, before destroying the cleanup closure.
                // Disposal is a separately retained native-work obligation.
                state.result = result
                return false
            }
            if abandoned && !cleanedUp { await request.cleanup() }
            await request.retire()
            lock.withLock { if active === state { active = nil } }
            quitWork?.finish()
            state.completion.markCompleted()
        }
        let wait = await state.completion.wait(timeoutSeconds: timeoutSeconds)
        let failure: Failure = wait == .cancelled ? .cancelled : .timedOut
        let observation: (Result<Void, Error>?, Request.FailureDelivery?) = state.lock.withLock {
            if let result = state.result { return (result, nil) }
            state.abandoned = true
            state.claimOpen = false
            return (nil, request.reserveFailure(failure))
        }
        if let result = observation.0 { try result.get(); return }
        state.adoptionDecision.markCompleted()
        observation.1?.deliver()
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
