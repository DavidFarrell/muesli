import Foundation

/// The fixed local service transport. It never launches a command or passes an
/// environment, model path, or import path to the service.
nonisolated final class BackendXPCJobOwner: NSObject, @unchecked Sendable {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    struct Reservation: Sendable {
        let instanceID: UUID
        let jobID: UUID
        let processID: Int32
        let runtimeSHA256: Data
        let modelsSHA256: Data
    }

    struct Result: Sendable {
        let instanceID: UUID
        let jobID: UUID
        let requestDigest: Data
        let operationStatus: Int32
    }

    struct ProcessIdentity: Sendable, Equatable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    /// Immutable configuration assembled by the app from its sealed bundle
    /// and original source owner. Native source admission remains independent.
    struct Configuration: @unchecked Sendable {
        let operation: MuesliInferenceOperation
        let streams: MuesliInferenceStreams
        let liveSource: MuesliLiveSource?
        let expectedRuntimeSHA256: Data
        let expectedModelsSHA256: Data
        let sourceBookmark: @Sendable () throws -> Data
        let sourceCapabilityOwner: SourceCapabilityOwner?
        let sourceFolder: URL?

        /// Model-free fixtures can supply their already-scoped generated source.
        /// Application factories use the session-owner initializer below.
        init(operation: MuesliInferenceOperation, streams: MuesliInferenceStreams, liveSource: MuesliLiveSource?,
             expectedRuntimeSHA256: Data, expectedModelsSHA256: Data,
             sourceBookmark: @escaping @Sendable () throws -> Data) {
            self.operation = operation; self.streams = streams; self.liveSource = liveSource
            self.expectedRuntimeSHA256 = expectedRuntimeSHA256; self.expectedModelsSHA256 = expectedModelsSHA256
            self.sourceBookmark = sourceBookmark; sourceCapabilityOwner = nil; sourceFolder = nil
        }

        init(operation: MuesliInferenceOperation, streams: MuesliInferenceStreams, liveSource: MuesliLiveSource?,
             expectedRuntimeSHA256: Data, expectedModelsSHA256: Data,
             sourceCapabilityOwner: SourceCapabilityOwner, sourceFolder: URL) {
            self.operation = operation; self.streams = streams; self.liveSource = liveSource
            self.expectedRuntimeSHA256 = expectedRuntimeSHA256; self.expectedModelsSHA256 = expectedModelsSHA256
            self.sourceCapabilityOwner = sourceCapabilityOwner; self.sourceFolder = sourceFolder
            sourceBookmark = { throw Failure(message: "Application source access requires its original read-only capability owner.") }
        }
    }

    struct Completion: @unchecked Sendable {
        let reservation: Reservation
        let requestDigest: Data?
        let operationResult: Result?
        let registeredProcess: ProcessIdentity?
        let termination: MuesliProcessTermination
        let failure: String?
    }

    private static let serviceName = "paidiaconsulting.MuesliApp.InferenceService"
    private static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"JA9EPB8K4N\" and identifier \"paidiaconsulting.MuesliApp.InferenceService\""
    private let configuration: Configuration
    private let jobID = UUID()
    private let connection = NSXPCConnection(serviceName: serviceName)
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let control = DispatchQueue(label: "muesli.xpc-job-control", qos: .utility)
    private let completed: @Sendable (Completion) -> Void
    private var attempted = false
    private var reservation: Reservation?
    private var lease: MuesliSourceLease?
    private var observer: MuesliNativeProcessObserver?
    private var registeredProcess: ProcessIdentity?
    private var termination: MuesliProcessTermination?
    private var requestDigest: Data?
    private var sourceSent = false
    private var sourceCapability: SourceCapabilityOwner.JobToken?
    private var accepted = false
    private var result: Result?
    private var failure: String?
    private var transportEnded = false
    private var transportFailure: String?
    private var cancelled = false
    private var retirementRequested = false
    private var cancelSent = false
    private var completionDelivered = false
    private var resultDeadlineExpired = false
    private var serviceEnds: [FileHandle] = []
    private var admissionDeadline: DispatchTime?

    init(configuration: Configuration, completed: @escaping @Sendable (Completion) -> Void) throws {
        guard configuration.expectedRuntimeSHA256.count == 32,
              configuration.expectedModelsSHA256.count == 32,
              [.preflight, .live, .reprocess].contains(configuration.operation),
              [.system, .mic, .both].contains(configuration.streams),
              (configuration.operation == .live) == (configuration.liveSource != nil) else {
            throw Failure(message: "Invalid fixed inference configuration.")
        }
        self.configuration = configuration
        self.completed = completed
        super.init()
        connection.setCodeSigningRequirement(Self.requirement)
        connection.remoteObjectInterface = MuesliServiceInterfaceV2()
        connection.exportedInterface = MuesliClientInterfaceV2()
        connection.exportedObject = Receiver(owner: self)
        connection.interruptionHandler = { [weak self] in self?.transportFailed("Inference connection was interrupted.") }
        connection.invalidationHandler = { [weak self] in self?.transportFailed("Inference connection was invalidated.") }
    }

    /// Must be called by the retained admission owner before start. The record
    /// is copied and validated; the native service will independently pin it.
    func installLease(_ record: Data) throws {
        guard let value = MuesliSourceLease(record: record) else {
            throw Failure(message: "Invalid inference source identity.")
        }
        try lock.withLock {
            guard !attempted else { throw Failure(message: "Inference admission already began.") }
            lease = value
        }
    }

    /// Blocks only the original admission worker, with cancellation checks
    /// throughout. Independent callbacks and cancel RPC never queue behind it.
    func start(input: FileHandle, output: FileHandle, diagnostics: FileHandle,
               checkAdmission: @escaping @Sendable () throws -> Void,
               withNativeLaunch: (@escaping @Sendable () throws -> Void) throws -> Void) throws {
        let sourceLease: MuesliSourceLease = try lock.withLock {
            guard !attempted, let lease else { throw Failure(message: "Inference requires one original source lease.") }
            attempted = true
            // Full sealed-runtime verification is source-free and measured
            // 18.6s on the first qualified launch. Keep this phase bounded;
            // 45s + the later 8s admission stays below the service's 60s timer.
            admissionDeadline = .now() + 45
            serviceEnds = [input, output, diagnostics]
            return lease
        }
        do {
            try ensureAdmission(checkAdmission)
            connection.activate()
            try proxy().reserveJob(jobID) { [weak self] value, error in self?.receivedReservation(value, error: error) }
            try wait(checkAdmission: checkAdmission) { $0.reservation != nil }
            let reserved = lock.withLock { reservation! }
            try ensureAdmission(checkAdmission)
            try lock.withLock {
                guard !cancelled, !transportEnded, termination == nil, failure == nil,
                      let deadline = admissionDeadline, DispatchTime.now() < deadline else {
                    throw Failure(message: "Inference reservation retired before source admission.")
                }
                admissionDeadline = .now() + 8
            }
            // Successful return means the actual peer instance is authenticated
            // and NOTE_EXIT is armed. No source bytes or descriptors preceded it.
            let native = try MuesliNativeProcessObserver.armConnection(connection,
                codeSigningRequirement: Self.requirement, timeout: 2,
                terminationHandler: { [weak self] value in self?.observedTermination(value) },
                failureHandler: { [weak self] error in self?.observationFailed(error.localizedDescription) })
            lock.withLock {
                observer = native
                registeredProcess = ProcessIdentity(pid: native.processIdentifier,
                    startSeconds: native.startSeconds, startMicroseconds: native.startMicroseconds)
            }
            guard native.processIdentifier == reserved.processID else {
                throw Failure(message: "Inference reservation belongs to a different process.")
            }
            try ensureAdmission(checkAdmission)
            let sourceRecord = sourceLease.record
            let bookmark: Data
            if let capabilityOwner = configuration.sourceCapabilityOwner, let sourceFolder = configuration.sourceFolder {
                let process = SourceCapabilityOwner.ProcessIdentity(pid: native.processIdentifier,
                    startSeconds: native.startSeconds, startMicroseconds: native.startMicroseconds)
                let token = try capabilityOwner.acquire(meetingFolder: sourceFolder, leaseRecord: sourceRecord,
                    jobID: jobID, process: process, onRegistered: { [self] token in
                        let alreadyTerminated = lock.withLock {
                            sourceCapability = token
                            return termination
                        }
                        if let alreadyTerminated {
                            do { try token.observedTermination(alreadyTerminated) }
                            catch { observationFailed(error.localizedDescription) }
                        }
                    }, onCapabilityLost: { [weak self] message in self?.sourceCapabilityFailed(message) })
                bookmark = try token.bookmark
            } else {
                bookmark = try configuration.sourceBookmark()
            }
            guard !bookmark.isEmpty, bookmark.count <= 1024 * 1024,
                  let digest = MuesliInferenceRequestDigest(configuration.operation, reserved.instanceID,
                    jobID, bookmark, sourceLease, configuration.liveSource, configuration.streams) else {
                throw Failure(message: "Invalid inference source request.")
            }
            try withNativeLaunch { [self] in
                try ensureAdmission(checkAdmission)
                guard let wireLease = MuesliSourceLease(record: sourceRecord) else {
                    throw Failure(message: "Inference source record could not be reconstructed.")
                }
                try lock.withLock {
                    guard !cancelled, !transportEnded, termination == nil, failure == nil else {
                        throw Failure(message: failure ?? "Inference admission retired before source transfer.")
                    }
                    guard let admissionDeadline, DispatchTime.now() < admissionDeadline else {
                        throw Failure(message: "Inference admission expired before source transfer.")
                    }
                    requestDigest = digest
                    sourceSent = true
                }
                try proxy().run(configuration.operation, instanceID: reserved.instanceID, jobID: jobID,
                    sourceBookmark: bookmark, sourceLease: wireLease, liveSource: configuration.liveSource,
                    streams: configuration.streams, requestDigest: digest, input: input, output: output,
                    diagnostics: diagnostics) { [weak self] value in self?.receivedResult(value) }
                try wait(checkAdmission: checkAdmission) { $0.accepted }
            }
        } catch {
            let close: [FileHandle] = lock.withLock {
                guard !sourceSent else { return [] }
                let handles = serviceEnds
                serviceEnds = []
                return handles
            }
            for handle in close { try? handle.close() }
            cancel()
            if !hasStarted { connection.invalidate() }
            throw error
        }
    }

    var hasStarted: Bool { lock.withLock { observer != nil || termination != nil } }
    var isRunning: Bool { lock.withLock { (observer != nil || termination != nil) && termination == nil } }

    func cancel() {
        lock.withLock { cancelled = true; retirementRequested = true }
        changed.signal()
        control.async { [self] in sendCancellationIfReserved() }
    }

    private func sendCancellationIfReserved() {
        let reserved: Reservation? = lock.withLock {
            guard retirementRequested, !cancelSent, let reservation else { return nil }
            cancelSent = true
            return reservation
        }
        guard let reserved else { return }
        // Native service owns group retirement. The host never checks a PID
        // and subsequently kills it, or treats cancel acknowledgement as exit.
        try? proxy().cancelJob(jobID, instanceID: reserved.instanceID) { _ in }
    }

    private func proxy() throws -> any MuesliInferenceServiceV2 {
        guard let value = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.transportFailed(error.localizedDescription)
        }) as? any MuesliInferenceServiceV2 else {
            throw Failure(message: "Inference service proxy unavailable.")
        }
        return value
    }

    private func ensureAdmission(_ checkAdmission: @Sendable () throws -> Void) throws {
        try checkAdmission()
        try lock.withLock {
            guard !cancelled, !transportEnded, termination == nil, failure == nil,
                  let admissionDeadline, DispatchTime.now() < admissionDeadline else {
                throw Failure(message: failure ?? "Inference admission retired before source transfer.")
            }
        }
    }

    private func wait(checkAdmission: @Sendable () throws -> Void,
                      until predicate: (BackendXPCJobOwner) -> Bool) throws {
        while true {
            try checkAdmission()
            let done = try lock.withLock {
                guard !cancelled, failure == nil else {
                    throw Failure(message: failure ?? "Inference admission ended before acceptance.")
                }
                guard let admissionDeadline, DispatchTime.now() < admissionDeadline else {
                    throw Failure(message: "Inference source admission timed out.")
                }
                if predicate(self) { return true }
                guard !transportEnded else {
                    throw Failure(message: "Inference source admission timed out or lost its connection.")
                }
                guard termination == nil else {
                    throw Failure(message: "Inference process exited before admission.")
                }
                return false
            }
            if done { return }
            _ = changed.wait(timeout: .now() + .milliseconds(25))
        }
    }

    private func receivedReservation(_ value: MuesliServiceReservation?, error: String?) {
        lock.withLock {
            guard reservation == nil, !completionDelivered else { failure = "Duplicate inference reservation."; return }
            guard let value, value.protocolVersion == 2, value.jobID == jobID,
                  value.processID > 1, value.processID == connection.processIdentifier,
                  value.runtimeManifestSHA256 == configuration.expectedRuntimeSHA256,
                  value.modelManifestSHA256 == configuration.expectedModelsSHA256 else {
                failure = error ?? "Inference reservation or sealed runtime identity did not match."
                return
            }
            reservation = Reservation(instanceID: value.instanceID, jobID: value.jobID,
                processID: value.processID, runtimeSHA256: value.runtimeManifestSHA256,
                modelsSHA256: value.modelManifestSHA256)
        }
        changed.signal()
        if lock.withLock({ failure != nil }) { cancel() }
        if lock.withLock({ failure != nil && reservation == nil && !sourceSent }) { connection.invalidate() }
        control.async { [self] in sendCancellationIfReserved() }
    }

    private func receivedAcceptance(job: UUID, instance: UUID, digest: Data) {
        let close: [FileHandle] = lock.withLock {
            guard sourceSent, let reservation, job == jobID, instance == reservation.instanceID,
                  digest == requestDigest, !accepted else {
                failure = "Inference source acknowledgement did not match its request."
                return []
            }
            accepted = true
            let handles = serviceEnds
            serviceEnds = []
            return handles
        }
        // Only the service-facing copies close here. FramedWriter retains
        // exclusive ownership of the parent's input-writing endpoint.
        for handle in close { try? handle.close() }
        changed.signal()
        if lock.withLock({ failure != nil }) { cancel() }
        deliverCompletionIfSettled()
    }

    private func receivedResult(_ value: MuesliOperationResult) {
        lock.withLock {
            guard !completionDelivered, result == nil, sourceSent, let reservation,
                  value.jobID == jobID, value.instanceID == reservation.instanceID,
                  value.requestDigest == requestDigest else {
                if !completionDelivered { failure = "Inference operation result did not match its request." }
                return
            }
            result = Result(instanceID: value.instanceID, jobID: value.jobID,
                requestDigest: value.requestDigest, operationStatus: value.operationStatus)
            if value.operationStatus != 0 { failure = "Inference operation failed (status \(value.operationStatus))." }
        }
        changed.signal()
        if lock.withLock({ failure != nil }) { cancel() }
        deliverCompletionIfSettled()
    }

    private func observedTermination(_ value: MuesliProcessTermination) {
        let (close, capability) = lock.withLock {
            termination = value
            let handles = serviceEnds
            serviceEnds = []
            return (handles, sourceCapability)
        }
        for handle in close { try? handle.close() }
        if let capability {
            do { try capability.observedTermination(value) }
            catch { observationFailed(error.localizedDescription) }
        }
        changed.signal()
        // A queued operation reply may follow the kernel event. A finite wait
        // can settle missing evidence as failure, never as successful exit.
        control.asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock { resultDeadlineExpired = true }
            deliverCompletionIfSettled()
        }
        deliverCompletionIfSettled()
    }

    private func observationFailed(_ message: String) {
        lock.withLock { failure = message }
        changed.signal()
        cancel()
        // Keep the owner retained. Observation failure is not actual death.
    }

    private func sourceCapabilityFailed(_ message: String) {
        lock.withLock { if !completionDelivered && failure == nil { failure = message } }
        changed.signal()
        cancel()
        // The registered token and original source owner remain retained until
        // the independent kernel observer reports this exact process instance.
    }

    private func transportFailed(_ message: String) {
        lock.withLock { transportEnded = true; transportFailure = message; retirementRequested = true }
        changed.signal()
        control.async { [self] in sendCancellationIfReserved() }
        deliverCompletionIfSettled()
    }

    private func deliverCompletionIfSettled() {
        let value: Completion? = lock.withLock {
            guard !completionDelivered, let reservation, let termination,
                  (result != nil && accepted) || resultDeadlineExpired || !sourceSent else { return nil }
            completionDelivered = true
            let actualProcess = ProcessIdentity(pid: termination.processIdentifier,
                startSeconds: termination.startSeconds, startMicroseconds: termination.startMicroseconds)
            return Completion(reservation: reservation, requestDigest: requestDigest,
                operationResult: result, registeredProcess: registeredProcess, termination: termination,
                failure: failure ?? (cancelled ? "Inference operation was cancelled." : nil)
                    ?? (!sourceSent || registeredProcess != actualProcess ? "Inference exited before original source admission was established." : nil)
                    ?? (sourceSent && (result == nil || !accepted)
                        ? (transportFailure ?? "Inference exited without matching admission and operation evidence.") : nil))
        }
        guard let value else { return }
        completed(value)
        connection.invalidate()
    }

    deinit { connection.invalidate() }

    private final class Receiver: NSObject, MuesliInferenceClientV2, @unchecked Sendable {
        weak var owner: BackendXPCJobOwner?
        init(owner: BackendXPCJobOwner) { self.owner = owner }
        func acceptedJob(_ jobID: UUID, instanceID: UUID, requestDigest: Data) {
            owner?.receivedAcceptance(job: jobID, instance: instanceID, digest: requestDigest)
        }
    }
}
