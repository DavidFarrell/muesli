import Foundation

/// One process-local operation. Prepared is native-only, never Codable. Its
/// factory must return only after child/reader/resource closure, without a live
/// shared source lease, so note preparation does not prevent Resume. Other
/// native context resources remain retained until explicit off-UI retirement.
/// Keep this owner for the process lifetime and close admission before Quit.
nonisolated final class ArchiveWorkflowOwner<Prepared: Sendable>: @unchecked Sendable {
    typealias Wire = ArchiveWorkflowProtocol
    struct Begin: Equatable, Sendable { let sourcePath: String; let vaultPath: String }
    struct Preparation: Sendable { let context: Prepared; let outputManifestPath: String }
    enum FinalOutcome: Sendable {
        /// Allowed only before creating ANY pending marker or attempting a move.
        case needsCorrection
        case retained, trashed, uncertain
    }
    typealias Prepare = @Sendable (Begin, UUID) async throws -> Preparation
    typealias Finalize = @Sendable (Prepared, String, UUID) async throws -> FinalOutcome
    /// These factories are finite, synchronous and non-reentrant. User work
    /// requires open admission; retirement is a successor allowed in quiescence.
    typealias WorkTokenFactory = @Sendable () throws -> any Sendable

    /// Only the original operation/disposal worker accesses the value. Job
    /// copies and UI retirement retain this box, never another Prepared value.
    private final class ContextOwner: @unchecked Sendable {
        var value: Prepared?
        func clear() { value = nil }
    }
    private final class TokenOwner: @unchecked Sendable {
        private var token: (any Sendable)?
        init(_ token: any Sendable) { self.token = token }
        func release() { token = nil }
    }
    private final class Job: @unchecked Sendable {
        let id: UUID
        let begin: Begin
        let context = ContextOwner()
        var state: Wire.State = .preparing
        var outputManifestPath: String?
        var receiptPath: String?
        var failure: Wire.Failure?
        var retired = false
        var retirementToken: TokenOwner?
        init(id: UUID, begin: Begin) { self.id = id; self.begin = begin }
    }
    private let lock = NSLock()
    private let prepare: Prepare
    private let finalize: Finalize
    private let acquireWorkToken: WorkTokenFactory
    private let acquireRetirementToken: WorkTokenFactory
    private var job: Job?
    private var accepting = true
    private var actualWorkActive = false

    init(acquireWorkToken: @escaping WorkTokenFactory, acquireRetirementToken: @escaping WorkTokenFactory,
         prepare: @escaping Prepare, finalize: @escaping Finalize) {
        self.acquireWorkToken = acquireWorkToken; self.acquireRetirementToken = acquireRetirementToken
        self.prepare = prepare; self.finalize = finalize
    }

    func handle(_ request: Wire.Request) -> Wire.Response {
        guard (try? request.encode()) != nil else { return Wire.Response(failure: .invalidRequest) }
        return lock.withLock {
            guard accepting else { return Wire.Response(failure: .stopping) }
            switch request.command {
            case .begin:
                let begin = Begin(sourcePath: request.sourcePath!, vaultPath: request.vaultPath!)
                if let job {
                    if !job.retired && job.begin == begin { return snapshot(job) }
                    return Wire.Response(failure: .busy)
                }
                let token: TokenOwner
                do { token = TokenOwner(try acquireWorkToken()) } catch { return Wire.Response(failure: .admissionRejected) }
                let job = Job(id: UUID(), begin: begin)
                self.job = job; actualWorkActive = true
                Task.detached { [self, job, token] in await runPreparation(job, token: token) }
                return snapshot(job)
            case .status:
                guard let job, job.id == request.operationID else { return Wire.Response(failure: .unknownOperation) }
                return snapshot(job)
            case .abandon:
                guard let job, job.id == request.operationID else { return Wire.Response(failure: .unknownOperation) }
                guard !actualWorkActive else { return Wire.Response(operationID: job.id, state: job.state, failure: .busy) }
                if job.state != .awaitingOutputs {
                    // Terminal states publish only after their context is empty.
                    self.job = nil
                    return Wire.Response(operationID: job.id, state: .abandoned)
                }
                guard reserveRetirement(job) else { return Wire.Response(failure: .admissionRejected) }
                job.retired = true; job.state = .retiring; actualWorkActive = true
                Task.detached { [self, job] in retireOnWorker(job) }
                return snapshot(job)
            case .finalize:
                guard let job, job.id == request.operationID else { return Wire.Response(failure: .unknownOperation) }
                guard !job.retired else { return Wire.Response(failure: .stopping) }
                let path = request.receiptPath!
                if job.state == .finalizing {
                    return job.receiptPath == path ? snapshot(job) : Wire.Response(operationID: job.id, state: job.state, failure: .busy)
                }
                if [.retained, .trashed, .uncertain, .failed].contains(job.state) {
                    if let original = job.receiptPath, original != path {
                        return Wire.Response(operationID: job.id, state: job.state, failure: .notReady)
                    }
                    return snapshot(job)
                }
                guard job.state == .awaitingOutputs, !actualWorkActive else {
                    return Wire.Response(operationID: job.id, state: job.state, failure: .notReady)
                }
                let token: TokenOwner
                do { token = TokenOwner(try acquireWorkToken()) } catch { return Wire.Response(failure: .admissionRejected) }
                job.state = .finalizing; job.receiptPath = path; job.failure = nil; actualWorkActive = true
                // Capture the empty-capable box, never a Prepared argument whose
                // closure lifetime could extend native cleanup past token release.
                Task.detached { [self, job, token] in await runFinalization(job, path: path, token: token) }
                return snapshot(job)
            }
        }
    }

    /// The caller's accepted Quit bridge must still be held. Retirement reserves
    /// a distinct successor before any original work token may end. A failure
    /// keeps the native context retained and admission closed; it never drops it
    /// on the caller. Production retirement admission must support quiescence.
    func closeAdmissionForQuit() -> Bool {
        lock.withLock {
            accepting = false
            guard let job else { return true }
            if !actualWorkActive && job.state != .awaitingOutputs {
                self.job = nil; return true
            }
            guard reserveRetirement(job) else { return false }
            job.retired = true
            if !actualWorkActive {
                job.state = .retiring; actualWorkActive = true
                Task.detached { [self, job] in retireOnWorker(job) }
            }
            return false
        }
    }
    func reopenAdmissionAfterCancelledQuit() { lock.withLock { accepting = true } }
    var hasActualWork: Bool { lock.withLock { actualWorkActive } }

    /// Called only with the workflow lock held. The supplied finite factory must
    /// not call back into this owner or perform native/filesystem work.
    private func reserveRetirement(_ job: Job) -> Bool {
        if job.retirementToken != nil { return true }
        do { job.retirementToken = TokenOwner(try acquireRetirementToken()); return true }
        catch { job.failure = .admissionRejected; return false }
    }

    /// Returning from this helper ends every local Preparation reference before
    /// the caller can dispose its only remaining box or release the work token.
    private func prepareIntoBox(_ job: Job) async -> String? {
        do {
            let value = try await prepare(job.begin, job.id)
            job.context.value = value.context
            return value.outputManifestPath
        } catch { return nil }
    }
    private func runPreparation(_ job: Job, token: TokenOwner) async {
        let path = await prepareIntoBox(job)
        let valid = path.flatMap { value -> String? in
            do { try Wire.validatePath(value); return value } catch { return nil }
        }
        if valid == nil { job.context.clear() }
        token.release()
        let retire = lock.withLock {
            guard self.job === job else { return false }
            if job.retired { return true }
            if let valid { job.outputManifestPath = valid; job.state = .awaitingOutputs }
            else { job.state = .failed; job.failure = .preparationFailed }
            actualWorkActive = false
            return false
        }
        if retire { retireOnWorker(job) }
    }

    /// The borrowed callback argument is scoped to this helper. Terminal cleanup
    /// runs only after all its local/async-frame references have returned.
    private func invokeFinalization(_ job: Job, path: String) async -> FinalOutcome {
        guard let context = job.context.value else { return .uncertain }
        do { return try await finalize(context, path, job.id) }
        catch { return .uncertain }
    }
    private func runFinalization(_ job: Job, path: String, token: TokenOwner) async {
        let outcome = await invokeFinalization(job, path: path)
        if case .needsCorrection = outcome {} else { job.context.clear() }
        token.release()
        let retire = lock.withLock {
            guard self.job === job else { return false }
            if job.retired { return true }
            switch outcome {
            case .needsCorrection: job.state = .awaitingOutputs; job.failure = .validationFailed; job.receiptPath = nil
            case .retained: job.state = .retained
            case .trashed: job.state = .trashed
            case .uncertain: job.state = .uncertain; job.failure = .uncertain
            }
            actualWorkActive = false
            return false
        }
        if retire { retireOnWorker(job) }
    }
    private func retireOnWorker(_ job: Job) {
        // No workflow lock is held during synchronous deinit/close. The box can
        // stay captured by old jobs/tasks because its native value is now gone.
        job.context.clear()
        let token = lock.withLock { job.retirementToken }
        token?.release()
        lock.withLock {
            guard self.job === job else { return }
            self.job = nil; actualWorkActive = false
        }
    }
    private func snapshot(_ job: Job) -> Wire.Response {
        Wire.Response(operationID: job.id, state: job.state, outputManifestPath: job.outputManifestPath, failure: job.failure)
    }
}
