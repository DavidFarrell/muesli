import Foundation

/// Admission, native launch and cleanup have one retained owner. A deadline
/// retires intent; it never releases files, scope or a possibly starting child.
nonisolated final class BackendAdmissionOwner: @unchecked Sendable {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
        static let busy = Failure(message: "The previous transcription process is still starting or closing its files.")
        static let retired = Failure(message: "Transcription startup was cancelled or took too long; its original owner is still closing.")
    }

    final class Resources: @unchecked Sendable {
        let backend: BackendProcess
        let writer: FramedWriter
        private let onClosed: @Sendable () -> Void
        init(backend: BackendProcess, writer: FramedWriter? = nil,
             onClosed: @escaping @Sendable () -> Void = {}) {
            self.backend = backend
            self.writer = writer ?? FramedWriter(stdinHandle: backend.stdin)
            self.onClosed = onClosed
        }
        fileprivate func closeScope() { onClosed() }
    }

    final class Attempt: @unchecked Sendable {
        enum Outcome: Sendable { case ready, failed(String), timedOut, cancelled }
        private enum Phase { case preparing, ready, claimed, abandoned, failed }
        private let lock = NSLock()
        private var phase = Phase.preparing
        private var resources: Resources?
        private var error: String?
        private var expired = false
        private var timer: DispatchSourceTimer?
        private let deadline: DispatchTime
        private let ready = TaskCompletion()
        fileprivate let finished = TaskCompletion()
        fileprivate let decision = DispatchSemaphore(value: 0)

        fileprivate init(timeoutSeconds: Double) {
            deadline = .now() + timeoutSeconds
        }
        fileprivate func arm() {
            let source = DispatchSource.makeTimerSource(queue: BackendAdmissionOwner.deadlines)
            source.setEventHandler { [weak self] in self?.abandon(onlyUnclaimed: true, expired: true) }
            source.schedule(deadline: deadline)
            lock.withLock { timer = source }
            source.resume()
        }
        fileprivate func checkAdmission() throws {
            try lock.withLock {
                guard phase == .preparing, DispatchTime.now() < deadline else { throw Failure.retired }
            }
        }
        fileprivate func installed(_ value: Resources) { lock.withLock { resources = value } }
        fileprivate func offer() {
            lock.withLock { if phase == .preparing { phase = .ready } }
            ready.markCompleted()
        }
        fileprivate func fail(_ failure: Error) {
            lock.withLock {
                error = failure.localizedDescription
                if phase != .abandoned { phase = .failed }
            }
            stopTimer()
            ready.markCompleted()
        }
        private func stopTimer() {
            let old = lock.withLock { let old = timer; timer = nil; return old }
            old?.setEventHandler {}
            old?.cancel()
        }
        /// The consumer must claim on its publication executor, after checking
        /// the immutable source identity and Stop intent, without an intervening await.
        func claim() throws -> Resources {
            let value = try lock.withLock {
                guard phase == .ready, DispatchTime.now() < deadline, let resources else { throw Failure.retired }
                phase = .claimed
                return resources
            }
            stopTimer()
            decision.signal()
            return value
        }
        fileprivate var abandoned: Bool { lock.withLock { phase == .abandoned || phase == .failed } }
        fileprivate func abandon(onlyUnclaimed: Bool, expired: Bool = false) {
            let changed = lock.withLock {
                if onlyUnclaimed && phase == .claimed { return false }
                guard phase != .abandoned && phase != .failed else { return false }
                phase = .abandoned
                self.expired = expired
                return true
            }
            guard changed else { return }
            stopTimer()
            ready.markCompleted()
            decision.signal()
        }
        func cancel() { abandon(onlyUnclaimed: false) }

        @concurrent func waitUntilReady() async -> Outcome {
            let seconds = max(0, Double(deadline.uptimeNanoseconds) / 1e9 - Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
            let outcome = await ready.wait(timeoutSeconds: seconds)
            if outcome == .cancelled || Task.isCancelled {
                cancel()
                return .cancelled
            }
            if outcome == .timedOut {
                abandon(onlyUnclaimed: true, expired: true)
                return .timedOut
            }
            let result: Outcome = lock.withLock {
                if phase == .ready { return DispatchTime.now() < deadline ? .ready : .timedOut }
                if phase == .failed, let error { return .failed(error) }
                return expired ? .timedOut : .cancelled
            }
            if case .timedOut = result { abandon(onlyUnclaimed: true, expired: true) }
            return result
        }
        @concurrent func waitUntilClosed(timeoutSeconds: Double) async -> TaskCompletion.Outcome {
            await finished.wait(timeoutSeconds: timeoutSeconds)
        }
    }

    private static let deadlines = DispatchQueue(label: "muesli.backend-admission-deadline", qos: .utility)
    private let queue = DispatchQueue(label: "muesli.backend-admission", qos: .utility)
    private let lock = NSLock()
    private var active: Attempt?
    var isBusy: Bool { lock.withLock { active != nil } }

    func start(protecting meetingFolder: URL? = nil, timeoutSeconds: Double = 8, factory: @escaping @Sendable () throws -> Resources) throws -> Attempt {
        precondition(timeoutSeconds.isFinite && timeoutSeconds >= 0)
        let attempt = Attempt(timeoutSeconds: timeoutSeconds)
        try lock.withLock {
            guard active == nil else { throw Failure.busy }
            active = attempt
        }
        attempt.arm()
        queue.async { [self] in
            var resources: Resources?
            var meetingLease: FileHandle?
            do {
                try attempt.checkAdmission()
                if let meetingFolder { meetingLease = try BackendMeetingLease.acquire(in: meetingFolder, exclusive: false) }
                try attempt.checkAdmission()
                let value = try factory()
                resources = value
                attempt.installed(value)
                try attempt.checkAdmission()
                try value.backend.start(checkAdmission: { try attempt.checkAdmission() })
                attempt.offer()
                attempt.decision.wait()
            } catch { attempt.fail(error) }
            // This detached owner is not a child of the cancelled caller. It
            // retains this admission until every original resource really closes.
            let ownedResources = resources
            let ownedMeetingLease = meetingLease
            Task.detached { [self] in
                if let ownedResources { await Self.maintain(ownedResources, attempt: attempt) }
                try? ownedMeetingLease?.close()
                lock.withLock { if active === attempt { active = nil } }
                attempt.finished.markCompleted()
            }
        }
        return attempt
    }

    /// Stop retires an unclaimed startup synchronously. A claimed live backend
    /// remains under the regular meeting_stop/drain path, retaining its scope.
    func retireAdmission() { lock.withLock { active }?.abandon(onlyUnclaimed: true) }

    @concurrent private static func maintain(_ value: Resources, attempt: Attempt) async {
        let backend = value.backend
        if backend.hasStarted {
            var terminationAt: ContinuousClock.Instant?
            var killed = false
            while await backend.waitForExit(timeoutSeconds: 0.25) == nil {
                if attempt.abandoned {
                    if terminationAt == nil { backend.terminate(); terminationAt = .now }
                    if !killed, let terminationAt, terminationAt.duration(to: .now) >= .milliseconds(500) {
                        killed = true
                        backend.forceKill()
                    }
                }
            }
        }
        value.writer.forceCloseStdin()
        while !(await value.writer.closeStdinAndWait(timeoutSeconds: 1)) {}
        // Preserve the actual EOF tail before requesting an explicit abort.
        if backend.hasStarted { _ = await backend.finishStdout(timeoutSeconds: 5) }
        backend.cleanup()
        while !backend.stdoutStatus().closed { _ = await backend.finishStdout(timeoutSeconds: 1) }
        value.closeScope()
    }
}

/// All security-scope admission and executable filesystem checks run inside
/// the retained launch factory, for live and batch work alike.
nonisolated enum BackendLaunchConfiguration {
    static func python(in root: URL) throws -> String {
        let path = root.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw BackendAdmissionOwner.Failure(message: "Backend python not found at \(path).")
        }
        #if !DEBUG
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.uint16Value & 0o111 != 0 else {
            throw BackendAdmissionOwner.Failure(message: "Backend python is not executable.")
        }
        #endif
        return path
    }

    static func scoped(root: URL, build: (String) throws -> BackendProcess) throws -> BackendAdmissionOwner.Resources {
        guard root.startAccessingSecurityScopedResource() else {
            throw BackendAdmissionOwner.Failure(message: "Backend folder access denied. Re-select the folder.")
        }
        do {
            let backend = try build(python(in: root))
            return BackendAdmissionOwner.Resources(backend: backend, onClosed: { root.stopAccessingSecurityScopedResource() })
        } catch {
            root.stopAccessingSecurityScopedResource()
            throw error
        }
    }
}

/// Shared by live/batch inference and the actual catalog Trash operation.
/// A caller deadline never releases this lease. It is separate from the
/// transcript transaction so finalization may still save a degraded result.
nonisolated enum BackendMeetingLease {
    static func acquire(in folder: URL, exclusive: Bool) throws -> FileHandle {
        let path = folder.appendingPathComponent(".backend-owner.lock").path
        // Never create a folder here: a late attempt whose meeting was moved
        // must fail before any Python entry point can recreate its old path.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
                throw BackendAdmissionOwner.Failure(message: "Transcription or a pending move still owns this meeting folder.")
            }
            // The move may have completed between open and flock. An open
            // handle in Trash must not authorize a launch at the original path.
            var owned = stat(), current = stat()
            guard fstat(fd, &owned) == 0, lstat(path, &current) == 0,
                  owned.st_mode & S_IFMT == S_IFREG,
                  owned.st_dev == current.st_dev, owned.st_ino == current.st_ino else {
                throw BackendAdmissionOwner.Failure(message: "The meeting folder changed during transcription admission.")
            }
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }
}
