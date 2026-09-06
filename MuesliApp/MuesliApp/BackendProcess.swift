import Foundation

// MARK: - Backend Process

/// Process control/callback state is protected by `processLock`; output is
/// owned by BackendOutputReader's separate queue. No event journal operation
/// or stdout delivery depends on the UI actor.
nonisolated enum BackendLaunchCheckpoint: Sendable { case beforeRun, afterRun }

/// An in-memory native observation, never decoded from stdout or an archive
/// receipt. Only the native owner in this file can construct this evidence.
nonisolated struct BackendCompletionEvidence: Sendable {
    enum OSTermination: Sendable, Equatable {
        case exited(Int32)
        case signalled(Int32)
    }
    enum Operation: String, Sendable { case preflight, live, reprocess }
    enum Stream: String, Sendable { case mic, system, both }
    struct ProcessIdentity: Sendable, Equatable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }
    /// Retained from the original native reservation/request, not supplied by
    /// Python or copied from its terminal reply. The request digest binds the
    /// typed lease, including both fixed lock identities, and configuration.
    struct XPCBinding: Sendable, Equatable {
        let jobID: UUID
        let instanceID: UUID
        let requestSHA256: String
        let process: ProcessIdentity
        let sourceIdentity: MeetingFileAccess.Identity
        let sourceSnapshotSHA256: String?
        let operation: Operation
        let stream: Stream
        let runtimeManifestSHA256: String
        let modelSetSHA256: String
    }
    struct XPCReply: Sendable {
        let jobID: UUID
        let instanceID: UUID
        let requestSHA256: String
        let operationStatus: Int32
    }
    struct KernelExit: Sendable {
        let process: ProcessIdentity
        let rawWaitStatus: Int32
        let observedExit: Bool
        let observedExitStatus: Bool
    }
    struct XPCOutcome: Sendable, Equatable {
        let operationStatus: Int32
        let termination: OSTermination
        let rawWaitStatus: Int32
    }
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    private enum Observation: Sendable {
        case process(OSTermination)
        case xpc(XPCBinding, XPCOutcome)
    }
    private let observation: Observation

    fileprivate init(legacyTermination: OSTermination) {
        observation = .process(legacyTermination)
    }
    /// Reserved for the native XPC owner after its authenticated reply and
    /// independently registered kernel observer have both completed.
    fileprivate init(xpcBinding: XPCBinding, reply: XPCReply, kernel: KernelExit) throws {
        observation = .xpc(xpcBinding, try Self.validateSuccessfulXPC(binding: xpcBinding, reply: reply, kernel: kernel))
    }

    var osTermination: OSTermination {
        switch observation {
        case .process(let termination): return termination
        case .xpc(_, let outcome): return outcome.termination
        }
    }
    var operationStatus: Int32 {
        switch observation {
        case .process(.exited(let code)): return code
        // Match Foundation.Process.terminationStatus for legacy callers;
        // osTermination retains that this value is a signal, not exit(code).
        case .process(.signalled(let signal)): return signal
        case .xpc(_, let outcome): return outcome.operationStatus
        }
    }

    /// This validates candidate observations but cannot mint native evidence.
    /// The real owner must establish the provenance of all three arguments.
    static func validateSuccessfulXPC(binding: XPCBinding, reply: XPCReply, kernel: KernelExit) throws -> XPCOutcome {
        try require(binding.process.pid > 1 && binding.process.startSeconds > 0
                    && binding.process.startMicroseconds < 1_000_000
                    && binding.sourceIdentity.directoryInode > 0 && binding.sourceIdentity.lockInode > 0,
                    "Native completion has an invalid process or source identity.")
        try require(hash(binding.requestSHA256) && hash(binding.runtimeManifestSHA256) && hash(binding.modelSetSHA256)
                    && (binding.sourceSnapshotSHA256 == nil || hash(binding.sourceSnapshotSHA256!)),
                    "Native completion has an invalid request, runtime, model or source digest.")
        try require(reply.jobID == binding.jobID && reply.instanceID == binding.instanceID
                    && reply.requestSHA256 == binding.requestSHA256,
                    "The inference reply belongs to a different job, service instance or request.")
        try require(kernel.observedExit && kernel.observedExitStatus && kernel.process == binding.process,
                    "The original inference process has no matching kernel exit observation.")
        try require(reply.operationStatus == 0, "The inference operation did not complete successfully.")
        let termination: OSTermination
        // These are wait(2) status bits delivered with NOTE_EXITSTATUS, not a
        // service-reported status. Preserve the actual normal exit 125 or
        // SIGKILL; exit 126 denotes failed group signalling and is rejected.
        if kernel.rawWaitStatus == 125 << 8 { termination = .exited(125) }
        else if kernel.rawWaitStatus == SIGKILL { termination = .signalled(SIGKILL) }
        else { throw Failure(message: "The inference process did not follow its qualified cleanup exit policy.") }
        return XPCOutcome(operationStatus: reply.operationStatus, termination: termination, rawWaitStatus: kernel.rawWaitStatus)
    }

    func requireSuccessfulArchive(sourceIdentity: MeetingFileAccess.Identity, snapshotSHA256: String) throws {
        switch observation {
        case .process(let termination):
            try Self.require(termination == .exited(0), "Reprocessing did not actually exit successfully.")
        case .xpc(let binding, _):
            try Self.validateArchiveBinding(binding, sourceIdentity: sourceIdentity, snapshotSHA256: snapshotSHA256)
        }
    }

    /// A testable binding check, deliberately separate from the restricted
    /// native-evidence constructor and the source-byte protocol verifier.
    static func validateArchiveBinding(_ binding: XPCBinding, sourceIdentity: MeetingFileAccess.Identity,
                                       snapshotSHA256: String) throws {
        try require(binding.operation == .reprocess && binding.stream == .both,
                    "Automatic archiving requires native reprocessing of both streams.")
        try require(binding.sourceIdentity == sourceIdentity && hash(snapshotSHA256)
                    && binding.sourceSnapshotSHA256 == snapshotSHA256,
                    "Native completion belongs to a different physical source or input snapshot.")
    }

    private static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}

nonisolated final class BackendProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let output: BackendOutputReader
    private let processLock = NSLock()
    private let processQueue = DispatchQueue(label: "muesli.backend-native", qos: .utility)
    private let launchCheckpoint: (@Sendable (BackendLaunchCheckpoint) throws -> Void)?
    private var attemptedStart = false
    private let exitCompletion = TaskCompletion()
    private let callbackQueue = DispatchQueue(label: "muesli.backend-exit", qos: .utility)
    private var started = false
    private var exitStatus: Int32?
    private var observedCompletion: BackendCompletionEvidence?
    private var exitCallback: (@Sendable (Int32) -> Void)?

    let stdoutLines: BackendEventLines

    var onJSONLine: (@Sendable (String) -> Void)? {
        get { output.onJSONLine }
        set { output.onJSONLine = newValue }
    }
    var onStderrLine: (@Sendable (String) -> Void)? {
        get { output.onStderrLine }
        set { output.onStderrLine = newValue }
    }
    var onExit: (@Sendable (Int32) -> Void)? {
        get { processLock.withLock { exitCallback } }
        set { processLock.withLock { exitCallback = newValue } }
    }

    /// Ownership transfers to FramedWriter; cleanup never touches this handle.
    var stdin: FileHandle { stdinPipe.fileHandleForWriting }

    init(command: [String], workingDirectory: URL? = nil, environment: [String: String]? = nil,
         eventJournalURL: URL? = nil, maximumStdoutLineBytes: Int = 4 * 1024 * 1024,
         beforeEventJournalIO: (@Sendable (BackendJournalCheckpoint) throws -> Void)? = nil,
         launchCheckpoint: (@Sendable (BackendLaunchCheckpoint) throws -> Void)? = nil) throws {
        guard !command.isEmpty else {
            throw NSError(domain: "Muesli", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        self.launchCheckpoint = launchCheckpoint
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = workingDirectory
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            process.environment = env
        }
        output = BackendOutputReader(stdoutHandle: stdoutPipe.fileHandleForReading,
                                     stderrHandle: stderrPipe.fileHandleForReading,
                                     journalURL: eventJournalURL, maximumLineBytes: maximumStdoutLineBytes,
                                     beforeJournalIO: beforeEventJournalIO)
        stdoutLines = output.lines
    }

    /// Pass only the fixed source identity contract to package initialization.
    /// Child descriptors are acquired independently; no parent fd inheritance
    /// or app lifetime assumption can authorize recreating a moved source.
    func installMeetingLease(access: MeetingFileAccess, backendLease: FileHandle) throws {
        try access.validate()
        var value = stat(), current = stat()
        let path = access.folderURL.appendingPathComponent(".backend-owner.lock").path
        guard fstat(backendLease.fileDescriptor, &value) == 0, lstat(path, &current) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == geteuid(),
              value.st_dev == current.st_dev, value.st_ino == current.st_ino else {
            throw BackendAdmissionOwner.Failure(message: "The backend ownership file changed before child launch.")
        }
        let identity = access.identity
        let token: [String: Any] = [
            "version": 1,
            "folder": access.folderURL.path,
            "directory": ["device": identity.directoryDevice, "inode": identity.directoryInode],
            "locks": [
                ".meeting-access.lock": ["device": identity.lockDevice, "inode": identity.lockInode],
                ".backend-owner.lock": ["device": UInt64(value.st_dev), "inode": value.st_ino]
            ]
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: token, options: [.sortedKeys]), as: UTF8.self)
        try processQueue.sync {
            guard !processLock.withLock({ attemptedStart }) else {
                throw BackendAdmissionOwner.Failure(message: "Cannot change meeting identity after child launch begins.")
            }
            var environment = process.environment ?? ProcessInfo.processInfo.environment
            environment["MUESLI_MEETING_LEASE"] = encoded
            process.environment = environment
        }
    }

    /// Called by BackendAdmissionOwner's worker. The cheap state lock is never
    /// held across native launch, journal work, or process-control calls.
    typealias LaunchScope = @Sendable (@escaping @Sendable () throws -> Void) throws -> Void

    func start(checkAdmission: @escaping @Sendable () throws -> Void = {},
               withNativeLaunch: LaunchScope = { try $0() }) throws {
        try processLock.withLock {
            guard !attemptedStart else {
                throw NSError(domain: "Muesli", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Backend process cannot be restarted"])
            }
            attemptedStart = true
        }
        do {
            try checkAdmission()
            try output.prepare()
            try checkAdmission()
            try processQueue.sync {
                try checkAdmission()
                process.terminationHandler = { [weak self] process in
                    guard let self else { return }
                    let status = process.terminationStatus
                    let callback = self.processLock.withLock {
                        self.exitStatus = status
                        self.observedCompletion = BackendCompletionEvidence(legacyTermination:
                            process.terminationReason == .exit ? .exited(status) : .signalled(status))
                        return self.exitCallback
                    }
                    self.exitCompletion.markCompleted()
                    // Exit is NOT stdout EOF: output may still be in the pipe.
                    self.callbackQueue.async { callback?(status) }
                }
                try launchCheckpoint?(.beforeRun)
                // An archive-specific source transaction may own this actual
                // invocation. The process queue stays serialized until return.
                try withNativeLaunch { [self] in
                    try checkAdmission()
                    try process.run()
                    processLock.withLock { started = true }
                    try launchCheckpoint?(.afterRun)
                }
            }
        } catch {
            output.cleanup()
            throw error
        }
    }

    func stop() {
        cleanup()
        terminate()
    }

    @concurrent func waitForExit(timeoutSeconds: Double) async -> Int32? {
        guard processLock.withLock({ started }) else { return nil }
        _ = await exitCompletion.wait(timeoutSeconds: timeoutSeconds)
        return processLock.withLock { exitStatus }
    }

    /// Control requests are queued even during Process.run. In particular a
    /// UI cancellation handler never waits behind the native launch operation.
    func terminate() {
        processQueue.async { [self] in if process.isRunning { process.terminate() } }
    }

    var hasStarted: Bool { processLock.withLock { started } }
    var isRunning: Bool { processLock.withLock { started && exitStatus == nil } }
    /// Available only after the actual native termination callback. An exit
    /// wait timeout, model-written result or caller cancellation cannot mint it.
    func completionEvidence() -> BackendCompletionEvidence? { processLock.withLock { observedCompletion } }

    func forceKill() {
        processQueue.async { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func stdoutStatus() -> BackendStdoutStatus { output.status() }

    /// Waits for the reader's EOF/closure and journal outcome, independently
    /// of the lossy UI consumer. Timeout/cancellation leaves the reader running.
    /// `.drained` requires `status.isComplete` before claiming complete events.
    @concurrent func finishStdout(timeoutSeconds: Double) async -> BackendStdoutDrainResult {
        await output.finish(timeoutSeconds: timeoutSeconds)
    }

    /// Explicit queued abort of stdout/stderr. Prefer finishStdout after child
    /// exit before cleanup. Aborting before EOF records incomplete output; this
    /// method's return is NOT evidence that reading or journaling has finished.
    /// Stdin remains exclusively owned by FramedWriter, including on failure.
    func cleanup() { output.cleanup() }
}

// MARK: - Framed Writer

nonisolated enum StreamID: UInt8 {
    case system = 0
    case mic = 1
}

nonisolated enum MsgType: UInt8 {
    case audio = 1
    case screenshotEvent = 2
    case meetingStart = 3
    case meetingStop = 4
}

nonisolated final class FramedWriter: FrameSending, @unchecked Sendable {
    /// Frame header size: type (1) + stream (1) + PTS (8) + length (4).
    private static let headerByteCount = 14

    private let handle: FileHandle
    private let writeQueue = DispatchQueue(label: "muesli.framed-writer", qos: .userInitiated)
    private var didFail = false
    private var writeErrorHandler: (@Sendable (Error) -> Void)?
    var onWriteError: (@Sendable (Error) -> Void)? {
        get { stateLock.withLock { writeErrorHandler } }
        set { stateLock.withLock { writeErrorHandler = newValue } }
    }

    /// Guards `backlog` and `isForceClosed` - `send` is called from the
    /// capture queue, the mic forwarder actor and MainActor, and completions
    /// land on `writeQueue`. Everything under the lock is cheap counter
    /// arithmetic; no per-frame timers or dispatch sources (2026-07-16 RCA
    /// rec #2 requires the detection itself to be near-free).
    private let stateLock = NSLock()
    private var backlog: WriteBacklogTracker
    private var isForceClosed = false
    /// Set (under `stateLock`) by the queued close the moment it has
    /// actually executed on `writeQueue` - the observable fact the
    /// `closeStdinAndWait` teardown barrier waits for.
    private var stdinCloseHasRun = false
    private var stdinCloseEnqueueCount = 0
    private let stdinCloseCompletion = TaskCompletion()
    /// Diagnostics beyond the tracker's backlog accounting: queued writes
    /// that threw (EPIPE after the child died, or writes landing after the
    /// handle closed) and sends rejected because `forceCloseStdin` already
    /// ran. Both count toward "audio that never reached the backend".
    private var failedWrites = 0
    private var rejectedAfterCloseFrames = 0

    init(
        stdinHandle: FileHandle,
        maxOutstandingBytes: Int = WriteBacklogTracker.defaultMaxOutstandingBytes,
        stallThresholdSeconds: TimeInterval = WriteBacklogTracker.defaultStallThresholdSeconds
    ) {
        self.handle = stdinHandle
        self.backlog = WriteBacklogTracker(
            maxOutstandingBytes: maxOutstandingBytes,
            stallThresholdSeconds: stallThresholdSeconds
        )
    }

    /// Fire-and-forget for callers, exactly as before - the audio hot paths
    /// must never block on the pipe. New since the 2026-07-16 incident:
    /// enqueue/completion accounting feeds the backpressure detector, and
    /// audio frames beyond the backlog cap are dropped-with-accounting
    /// instead of retained (a wedged child used to grow ~100MB of queued
    /// payloads invisibly). Control frames are never dropped.
    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        let frameBytes = Self.headerByteCount + payload.count
        let admitted: Bool = stateLock.withLock {
            guard !isForceClosed else {
                rejectedAfterCloseFrames += 1
                return false
            }
            return backlog.recordEnqueue(bytes: frameBytes, droppable: type == .audio, now: Date())
        }
        guard admitted else { return }
        writeQueue.async {
            let wroteOK = self.writeFrame(type: type, stream: stream, ptsUs: ptsUs, payload: payload)
            self.stateLock.withLock {
                self.backlog.recordCompletion(bytes: frameBytes, now: Date())
                if !wroteOK {
                    self.failedWrites += 1
                }
            }
        }
    }

    /// Read-only view of the backpressure state for AppModel's watchdog.
    struct BacklogSnapshot {
        let outstandingFrames: Int
        let outstandingBytes: Int
        let droppedFrames: Int
        let droppedBytes: Int
        let totalEnqueuedFrames: Int
        let totalCompletedFrames: Int
        let failedWrites: Int
        let rejectedAfterCloseFrames: Int
        let secondsSinceLastProgress: TimeInterval?
        let isStalled: Bool
    }

    func backlogSnapshot(now: Date = Date()) -> BacklogSnapshot {
        stateLock.withLock {
            BacklogSnapshot(
                outstandingFrames: backlog.outstandingFrames,
                outstandingBytes: backlog.outstandingBytes,
                droppedFrames: backlog.droppedFrames,
                droppedBytes: backlog.droppedBytes,
                totalEnqueuedFrames: backlog.totalEnqueuedFrames,
                totalCompletedFrames: backlog.totalCompletedFrames,
                failedWrites: failedWrites,
                rejectedAfterCloseFrames: rejectedAfterCloseFrames,
                secondsSinceLastProgress: backlog.secondsSinceLastProgress(now: now),
                isStalled: backlog.isStalled(now: now)
            )
        }
    }

    func isBacklogStalled(now: Date = Date()) -> Bool {
        stateLock.withLock { backlog.isStalled(now: now) }
    }

    /// FRESH no-progress check for the post-stop exit wait (gate BLOCKER 4
    /// fix): true only when work is outstanding RIGHT NOW and nothing has
    /// completed for at least `seconds`. Any completion resets the clock, so
    /// a backend that recovered - or recovers while the caller is waiting -
    /// stops satisfying this immediately; there is no historical latch here.
    func hasMadeNoProgress(forAtLeast seconds: TimeInterval, now: Date = Date()) -> Bool {
        stateLock.withLock { backlog.hasMadeNoProgress(forAtLeast: seconds, now: now) }
    }

    func closeStdinAfterDraining() {
        enqueueStdinClose()
    }

    /// One queue-owned close shared by all deadline waits. Keep admission
    /// closed and avoid accumulating closure jobs behind a blocked pipe write.
    private func enqueueStdinClose() {
        let enqueue = stateLock.withLock {
            isForceClosed = true
            guard stdinCloseEnqueueCount == 0 else { return false }
            stdinCloseEnqueueCount = 1
            return true
        }
        guard enqueue else { return }
        writeQueue.async {
            try? self.handle.close()
            self.stateLock.withLock { self.stdinCloseHasRun = true }
            self.stdinCloseCompletion.markCompleted()
        }
    }

    /// Actual queued operation count and completion, including while the queue
    /// is blocked. This also lets teardown diagnostics distinguish a pending close.
    var stdinCloseSnapshot: (enqueued: Int, closed: Bool) {
        stateLock.withLock { (stdinCloseEnqueueCount, stdinCloseHasRun) }
    }

    /// Teardown barrier: reject further sends, enqueue the close, and wait
    /// - bounded - for the queue to have actually EXECUTED it, so callers
    /// (finalize / failed-start teardown) know the writer is done with the
    /// handle before tearing down the rest of the process plumbing. By the
    /// time this is called the child has exited or been killed, so a write
    /// blocked on the full pipe has failed over with EPIPE and the queue is
    /// draining - the timeout is defensive. Returns whether the close ran;
    /// on `false` (or task cancellation) the caller must simply proceed
    /// WITHOUT touching stdin itself - the queued close still runs whenever
    /// the queue unblocks, and the pipe's deinit is the final backstop.
    @concurrent func closeStdinAndWait(timeoutSeconds: Double) async -> Bool {
        enqueueStdinClose()
        _ = await stdinCloseCompletion.wait(timeoutSeconds: timeoutSeconds)
        return stateLock.withLock { stdinCloseHasRun }
    }

    /// Stop-path hardening for a wedged reader (2026-07-16 RCA rec #6).
    /// Two effects: new `send` calls are rejected immediately (with
    /// accounting - see `rejectedAfterCloseFrames`), and a close of the
    /// write end is enqueued on the writeQueue.
    ///
    /// The close deliberately goes THROUGH the queue, not around it
    /// (gate BLOCKER 3 fix): NSFileHandle must not be used from multiple
    /// threads simultaneously, so closing from the caller's thread while a
    /// write sits blocked on the queue would be an unsupported race
    /// (crash / half-written frame risk). Single-queue handle ownership is
    /// preserved instead, which means this method alone cannot unblock a
    /// write stuck on a full pipe - the queued close waits behind it. The
    /// designed unblocking agent is killing the READER (see
    /// AppModel.finalizeStoppedMeeting's SIGTERM->SIGKILL escalation):
    /// the child's death closes the pipe's read end, the blocked write
    /// fails over with EPIPE, any remaining queued writes fail fast, and
    /// then the queued close runs. Against a healthy-but-slow child the
    /// queue drains normally and the close delivers EOF, exactly like
    /// `closeStdinAfterDraining`.
    func forceCloseStdin() {
        stateLock.withLock { isForceClosed = true }
        enqueueStdinClose()
    }

    /// Returns whether both writes succeeded (runs on `writeQueue` only).
    private func writeFrame(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) -> Bool {
        var header = Data()
        header.append(type.rawValue)
        header.append(stream.rawValue)

        var pts = ptsUs.littleEndian
        header.append(Data(bytes: &pts, count: 8))

        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: payload)
            return true
        } catch {
            if !didFail {
                didFail = true
                onWriteError?(error)
            }
            return false
        }
    }
}
