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
        var failureReported = false
        func takeFailureReport() -> Bool {
            lock.withLock { if failureReported { return false }; failureReported = true; return true }
        }
    }
    /// The native start remains reserved until the UI either atomically takes
    /// ownership or refuses it. Claim and deadline retirement use the same lock.
    final class Claim: Sendable {
        private let take: @Sendable () -> Bool
        fileprivate init(take: @escaping @Sendable () -> Bool) { self.take = take }
        func claim() -> Bool { take() }
    }
    private final class AdoptionOffer: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@MainActor @Sendable (Claim) -> Void)?
        init(_ callback: @escaping @MainActor @Sendable (Claim) -> Void) { self.callback = callback }
        func take() -> (@MainActor @Sendable (Claim) -> Void)? {
            lock.withLock { defer { callback = nil }; return callback }
        }
        func retire() { lock.withLock { callback = nil } }
    }
    private let lock = NSLock()
    private var active: Operation?
    private let shutdown: ShutdownWorkRegistry
    init(shutdown: ShutdownWorkRegistry = .shared) { self.shutdown = shutdown }
    var isBusy: Bool { lock.withLock { active != nil } }

    @concurrent
    func perform(timeoutSeconds: Double = 8,
                 preservesRecording: Bool = false,
                 onFailure: @escaping @Sendable (Error) -> Void = { _ in },
                 operation: @escaping @Sendable () async throws -> Void,
                 adoption: (@MainActor @Sendable (Claim) -> Void)? = nil,
                 cleanupIfAbandoned: @escaping @Sendable () async -> Void = {}) async throws {
        let state = Operation()
        let quitWork = preservesRecording ? try shutdown.begin("Waiting for native recording cleanup") : nil
        guard lock.withLock({ if active != nil { return false }; active = state; return true }) else {
            onFailure(Failure.busy)
            throw Failure.busy
        }
        let offer = adoption.map(AdoptionOffer.init)
        Task.detached(priority: .userInitiated) { [self] in
            let result: Result<Void, Error>
            var cleanedUp = false
            do {
                try await operation()
                if let offer {
                    let claim = Claim { [self] in
                        state.lock.withLock {
                            guard state.claimOpen, !state.abandoned, !state.claimed else { return false }
                            state.claimed = true
                            state.result = .success(())
                            // No suspension between this transfer and the UI's
                            // engine assignment. Stop can now reserve this lane.
                            lock.withLock { if active === state { active = nil } }
                            return true
                        }
                    }
                    // The single UI offer cannot hold native cleanup hostage
                    // when MainActor is blocked. Expiry retires claim first and
                    // releases this worker; a queued UI offer then fails closed.
                    Task { @MainActor in
                        offer.take()?(claim)
                        state.adoptionDecision.markCompleted()
                    }
                    let decision = await state.adoptionDecision.wait(timeoutSeconds: timeoutSeconds)
                    let claimed = state.lock.withLock {
                        if state.claimed { return true }
                        state.claimOpen = false
                        return false
                    }
                    if !claimed {
                        offer.retire()
                        await cleanupIfAbandoned()
                        cleanedUp = true
                        throw decision == .timedOut ? Failure.timedOut : Failure.cancelled
                    }
                }
                result = .success(())
            } catch {
                if state.takeFailureReport() { onFailure(error) }
                result = .failure(error)
            }
            offer?.retire()
            let abandoned = state.lock.withLock {
                if state.abandoned { return true }
                lock.withLock { if active === state { active = nil } }
                state.result = result
                return false
            }
            if abandoned {
                if !cleanedUp { await cleanupIfAbandoned() }
                lock.withLock { if active === state { active = nil } }
            }
            quitWork?.finish()
            state.completion.markCompleted()
        }
        let wait = await state.completion.wait(timeoutSeconds: timeoutSeconds)
        let result: Result<Void, Error>? = state.lock.withLock {
            if let result = state.result { return result }
            state.abandoned = true
            return nil
        }
        if let result { try result.get(); return }
        state.adoptionDecision.markCompleted()
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
