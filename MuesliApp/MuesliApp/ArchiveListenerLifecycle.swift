import Foundation

/// Native calls stay on the original listener lane. Implementations must report
/// onClosed once their original descriptors/leases are closed; a constructor
/// that throws must have finished all partial-allocation cleanup before return.
nonisolated protocol ArchiveListenerHandle: Sendable {
    func start()
    func stop()
}
extension ArchiveWorkflowServer: ArchiveListenerHandle {}

/// One process-lifetime semantic owner survives every listener generation. An
/// idle listener does not block Quit, but constructor and actual close do.
nonisolated final class ArchiveListenerLifecycle: @unchecked Sendable {
    typealias Factory = @Sendable (@escaping @Sendable () -> Void) throws -> any ArchiveListenerHandle
    enum Phase: String, Sendable { case stopped, starting, listening, stopping, failed }
    enum Failure: String, Sendable { case startupFailed, admissionRejected, listenerClosed }
    struct Snapshot: Sendable, Equatable {
        let generation: UUID
        let phase: Phase
        let desiredEnabled: Bool
        let failure: Failure?
    }
    enum StartupOutcome: Sendable, Equatable { case listening, failed, retired, inactive, timedOut, cancelled }
    private final class Attempt: @unchecked Sendable {
        let generation: UUID
        let startup = TaskCompletion()
        var outcome: StartupOutcome?
        var token: ShutdownWorkRegistry.Token?
        var listener: (any ArchiveListenerHandle)?
        var retired = false
        var started = false
        var stopQueued = false
        var stopInvoked = false
        var closeObserved = false
        var finishing = false
        init(generation: UUID, token: ShutdownWorkRegistry.Token) { self.generation = generation; self.token = token }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "muesli.archive-listener-lifecycle", qos: .utility)
    private let shutdown: ShutdownWorkRegistry
    private let factory: Factory
    private let closeSemanticAdmission: @Sendable () -> Void
    private let reopenSemanticAdmission: @Sendable () -> Void
    private let publish: (@MainActor @Sendable (Snapshot) -> Void)?
    private var generation = UUID()
    private var desiredEnabled = false
    private var active: Attempt?
    private var failure: Failure?
    private var publicationPending = false

    /// The semantic owner is supplied once, and is never reconstructed on
    /// Cancel Quit or listener restart. Factory must not reenter this lifecycle.
    init<Prepared>(workflow: ArchiveWorkflowOwner<Prepared>, shutdown: ShutdownWorkRegistry = .shared,
                   factory: @escaping Factory,
                   publish: (@MainActor @Sendable (Snapshot) -> Void)? = nil) {
        self.shutdown = shutdown; self.factory = factory; self.publish = publish
        closeSemanticAdmission = { _ = workflow.closeAdmissionForQuit() }
        reopenSemanticAdmission = { workflow.reopenAdmissionAfterCancelledQuit() }
    }
    convenience init<Prepared>(workflow: ArchiveWorkflowOwner<Prepared>, directory: URL,
                               shutdown: ShutdownWorkRegistry = .shared,
                               publish: (@MainActor @Sendable (Snapshot) -> Void)? = nil) {
        self.init(workflow: workflow, shutdown: shutdown, factory: { closed in
            try ArchiveWorkflowServer(directory: directory, onClosed: closed, handler: { workflow.handle($0) })
        }, publish: publish)
    }

    /// Admission is atomic with the registry's open phase. Repeated requests
    /// only coalesce desired state; they cannot enqueue another constructor.
    @discardableResult func enable() -> Bool {
        let accepted = lock.withLock {
            guard shutdown.acceptsUserWork else { return false }
            reopenSemanticAdmission()
            if !desiredEnabled { generation = UUID(); desiredEnabled = true; failure = nil }
            if active == nil { return startLocked() }
            return true
        }
        notify(); return accepted
    }
    func reopenAfterCancelledQuit() { _ = enable() }

    /// Call synchronously from accepted Quit, while its preparation bridge is
    /// retained and before beginQuit. No filesystem/native call runs here.
    func closeAdmissionForQuit() {
        let retiring: Attempt? = lock.withLock {
            desiredEnabled = false; generation = UUID()
            closeSemanticAdmission()
            guard let attempt = active else { return nil }
            attempt.retired = true
            if attempt.outcome == nil { attempt.outcome = .retired }
            if attempt.token == nil && !attempt.finishing {
                do { attempt.token = try shutdown.begin("Closing archive command listener") }
                catch { failure = .admissionRejected }
            }
            if !attempt.stopQueued {
                attempt.stopQueued = true
                queue.async { [self] in stopOnQueue(attempt) }
            }
            return attempt
        }
        retiring?.startup.markCompleted()
        notify()
    }
    var snapshot: Snapshot { lock.withLock { snapshotLocked() } }
    var hasActualOwner: Bool { lock.withLock { active != nil } }

    /// This observes one original startup. Expiry/cancellation does not release
    /// its slot, token, constructor or a late-created listener.
    @concurrent func waitForStartup(timeoutSeconds: Double) async -> StartupOutcome {
        guard let attempt = lock.withLock({ active }) else { return .inactive }
        switch await attempt.startup.wait(timeoutSeconds: timeoutSeconds) {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .completed: return lock.withLock { attempt.outcome ?? .failed }
        }
    }
    private func startLocked() -> Bool {
        do {
            let token = try shutdown.beginUserWork("Starting archive command listener")
            failure = nil
            generation = UUID()
            let attempt = Attempt(generation: generation, token: token)
            active = attempt
            queue.async { [self] in construct(attempt) }
            return true
        } catch {
            failure = .admissionRejected
            return false
        }
    }
    private func construct(_ attempt: Attempt) {
        do {
            let listener = try factory { [self, attempt] in observedClose(attempt) }
            let start = lock.withLock {
                attempt.listener = listener
                return !attempt.retired && !attempt.closeObserved
            }
            if start { listener.start() }
            if lock.withLock({ attempt.retired }) { stopOnQueue(attempt); return }
            let token: ShutdownWorkRegistry.Token? = lock.withLock {
                guard !attempt.closeObserved else { return nil }
                attempt.started = true
                let value = attempt.token; attempt.token = nil
                return value
            }
            token?.finish()
            let ready = lock.withLock {
                guard !attempt.retired && !attempt.closeObserved else { return false }
                attempt.outcome = .listening; return true
            }
            if ready { attempt.startup.markCompleted(); notify() }
        } catch {
            // The factory has returned from actual partial cleanup. A failed
            // initial startup does not spin retries; only a later explicit
            // enable/Cancel generation can request one successor.
            finishOnQueue(attempt, failure: .startupFailed)
        }
    }
    private func stopOnQueue(_ attempt: Attempt) {
        let listener: (any ArchiveListenerHandle)? = lock.withLock {
            guard active === attempt, !attempt.stopInvoked, let listener = attempt.listener else { return nil }
            attempt.stopInvoked = true
            return listener
        }
        listener?.stop()
    }
    private func observedClose(_ attempt: Attempt) {
        let enqueue = lock.withLock {
            guard active === attempt, !attempt.closeObserved else { return false }
            attempt.closeObserved = true
            return true
        }
        // Queuing behind construction/start/stop also fences an early callback
        // before the original invocation returns. There is only one callback job.
        if enqueue { queue.async { [self] in finishOnQueue(attempt, failure: .listenerClosed) } }
    }
    private func finishOnQueue(_ attempt: Attempt, failure observedFailure: Failure) {
        let closing = lock.withLock { () -> (ShutdownWorkRegistry.Token?, (any ArchiveListenerHandle)?) in
            attempt.finishing = true
            let token = attempt.token; attempt.token = nil
            let listener = attempt.listener; attempt.listener = nil
            return (token, listener)
        }
        // All native descriptors were closed by the callback/factory before
        // this point. Drop their wrapper and token on the original worker.
        withExtendedLifetime(closing.1) {}
        closing.0?.finish()
        lock.withLock {
            guard active === attempt else { return }
            active = nil
            if attempt.outcome == nil { attempt.outcome = attempt.retired ? .retired : .failed }
            if !attempt.retired { failure = observedFailure }
            if desiredEnabled && generation != attempt.generation { _ = startLocked() }
        }
        attempt.startup.markCompleted()
        notify()
    }
    private func snapshotLocked() -> Snapshot {
        let phase: Phase
        if let active { phase = active.retired ? .stopping : (active.started ? .listening : .starting) }
        else { phase = failure == nil ? .stopped : .failed }
        return Snapshot(generation: generation, phase: phase, desiredEnabled: desiredEnabled, failure: failure)
    }
    private func notify() {
        guard let publish else { return }
        let enqueue = lock.withLock {
            guard !publicationPending else { return false }
            publicationPending = true; return true
        }
        guard enqueue else { return }
        Task { @MainActor [self] in
            // Read at delivery, not at dispatch: an old queued UI callback
            // cannot republish a retired listener's "ready" state after Quit.
            let value = lock.withLock { publicationPending = false; return snapshotLocked() }
            publish(value)
        }
    }
}
