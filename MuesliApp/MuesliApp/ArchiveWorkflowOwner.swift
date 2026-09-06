import Foundation

/// One process-local operation. Prepared is native-only, never Codable. Its
/// factory must return only after child/reader/resource closure, without a live
/// shared source lease, so note preparation does not prevent Resume.
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
    /// The returned token must keep app shutdown blocked until deinit. Admission
    /// must be synchronous and finite; perform no file/process work in this hook.
    typealias WorkTokenFactory = @Sendable () throws -> any Sendable

    private struct Job {
        let id: UUID
        let begin: Begin
        var state: Wire.State = .preparing
        var context: Prepared?
        var outputManifestPath: String?
        var receiptPath: String?
        var failure: Wire.Failure?
        var retired = false
    }
    private final class TokenOwner: @unchecked Sendable {
        private var token: (any Sendable)?
        init(_ token: any Sendable) { self.token = token }
        // Only the retained worker calls this. The captured box then holds no
        // token when completion is published; closure capture lifetime is irrelevant.
        func release() { token = nil }
    }
    private let lock = NSLock()
    private let prepare: Prepare
    private let finalize: Finalize
    private let acquireWorkToken: WorkTokenFactory
    private var job: Job?
    private var accepting = true
    private var actualWorkActive = false

    init(acquireWorkToken: @escaping WorkTokenFactory, prepare: @escaping Prepare, finalize: @escaping Finalize) {
        self.acquireWorkToken = acquireWorkToken; self.prepare = prepare; self.finalize = finalize
    }

    func handle(_ request: Wire.Request) -> Wire.Response {
        // Apply the same shape check to in-process callers as wire requests.
        guard (try? request.encode()) != nil else { return Wire.Response(failure: .invalidRequest) }
        return lock.withLock {
            guard accepting else { return Wire.Response(failure: .stopping) }
            switch request.command {
            case .begin:
                let begin = Begin(sourcePath: request.sourcePath!, vaultPath: request.vaultPath!)
                if let job {
                    // A lost begin ACK can be retried without launching twice.
                    if !job.retired && job.begin == begin { return snapshot(job) }
                    return Wire.Response(failure: .busy)
                }
                let token: TokenOwner
                do { token = TokenOwner(try acquireWorkToken()) } catch { return Wire.Response(failure: .admissionRejected) }
                let id = UUID(); job = Job(id: id, begin: begin); actualWorkActive = true
                Task.detached { [self] in
                    let result: Result<Preparation, Error>
                    do { result = .success(try await prepare(begin, id)) } catch { result = .failure(error) }
                    token.release()
                    completePreparation(result, id: id)
                }
                return snapshot(job!)
            case .status:
                guard let job, job.id == request.operationID else { return Wire.Response(failure: .unknownOperation) }
                return snapshot(job)
            case .abandon:
                guard let job, job.id == request.operationID else { return Wire.Response(failure: .unknownOperation) }
                guard !actualWorkActive else { return Wire.Response(operationID: job.id, state: job.state, failure: .busy) }
                self.job = nil
                return Wire.Response(operationID: job.id, state: .abandoned)
            case .finalize:
                guard var job, job.id == request.operationID else { return Wire.Response(failure: .unknownOperation) }
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
                guard job.state == .awaitingOutputs, !actualWorkActive, let context = job.context else {
                    return Wire.Response(operationID: job.id, state: job.state, failure: .notReady)
                }
                let token: TokenOwner
                do { token = TokenOwner(try acquireWorkToken()) } catch { return Wire.Response(failure: .admissionRejected) }
                job.state = .finalizing; job.receiptPath = path; job.failure = nil
                self.job = job; actualWorkActive = true
                let id = job.id
                Task.detached { [self] in
                    let result: FinalOutcome
                    // An arbitrary IO exception may follow pending creation or
                    // the move itself. It is NEVER evidence of safe retry.
                    do { result = try await finalize(context, path, id) } catch { result = .uncertain }
                    token.release()
                    completeFinalization(result, id: id)
                }
                return snapshot(job)
            }
        }
    }

    /// Atomically closes admission before Quit checks ownership. No cancellation,
    /// deadline or disconnect releases a still-running native worker.
    func closeAdmissionForQuit() -> Bool {
        lock.withLock {
            accepting = false
            if actualWorkActive { job?.retired = true } else { job = nil }
            return !actualWorkActive
        }
    }
    /// Cancel Quit may reopen transport admission, but cannot restore a proof
    /// discarded/retired by the previous close operation.
    func reopenAdmissionAfterCancelledQuit() { lock.withLock { accepting = true } }
    var hasActualWork: Bool { lock.withLock { actualWorkActive } }

    private func completePreparation(_ result: Result<Preparation, Error>, id: UUID) {
        lock.withLock {
            guard var job, job.id == id else { return }
            actualWorkActive = false
            guard !job.retired else { self.job = nil; return }
            switch result {
            case .success(let prepared):
                guard (try? Wire.validatePath(prepared.outputManifestPath)) != nil else {
                    job.state = .failed; job.failure = .preparationFailed; self.job = job; return
                }
                job.context = prepared.context; job.outputManifestPath = prepared.outputManifestPath
                job.state = .awaitingOutputs
            case .failure: job.state = .failed; job.failure = .preparationFailed
            }
            self.job = job
        }
    }
    private func completeFinalization(_ outcome: FinalOutcome, id: UUID) {
        lock.withLock {
            guard var job, job.id == id else { return }
            actualWorkActive = false
            guard !job.retired else { self.job = nil; return }
            switch outcome {
            case .needsCorrection: job.state = .awaitingOutputs; job.failure = .validationFailed; job.receiptPath = nil
            case .retained: job.state = .retained; job.context = nil
            case .trashed: job.state = .trashed; job.context = nil
            case .uncertain: job.state = .uncertain; job.failure = .uncertain; job.context = nil
            }
            self.job = job
        }
    }
    private func snapshot(_ job: Job) -> Wire.Response {
        Wire.Response(operationID: job.id, state: job.state, outputManifestPath: job.outputManifestPath, failure: job.failure)
    }
}
