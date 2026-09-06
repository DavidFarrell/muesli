import Foundation
import Darwin

/// Owns one direct, read-only Meetings-root authorization for this app session.
/// Prepare authorization before capture or the inference reservation deadline.
/// Job tokens remain retained through cancellation and transport loss until the
/// main app's original native observer supplies matching process-exit evidence.
nonisolated final class SourceCapabilityOwner: @unchecked Sendable {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    struct ProcessIdentity: Equatable, Sendable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct RootIdentity: Sendable {
        let path: String
        let device: UInt64
        let inode: UInt64
    }

    private enum State { case idle, authorizing, authorized, draining, failed, closed }
    private let root: RootIdentity
    private let transport: any SourceCapabilityTransport
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let control = DispatchQueue(label: "muesli.source-capability-control", qos: .utility)
    private var state = State.idle
    private var failure: String?
    private var authorizationDeadline: DispatchTime?
    private var active: [UUID: JobToken] = [:]
    private var seenJobs: Set<UUID> = []
    private var transportClosed = false
    private var unavailabilityObserver: (@Sendable () -> Void)?
    private var unavailabilityObserverRegistered = false
    private var unavailabilityDelivered = false

    init(expectedRoot: URL) throws {
        root = try Self.snapshotRoot(expectedRoot)
        transport = NativeSourceCapabilityTransport()
        installTransportFailureHandler()
    }

    #if MUESLI_SOURCE_OWNER_TESTING
    /// The app target never defines this compile flag or injects a transport.
    init(expectedRoot: URL, testingTransport: any SourceCapabilityTransport) throws {
        root = try Self.snapshotRoot(expectedRoot)
        transport = testingTransport
        installTransportFailureHandler()
    }
    #endif

    private func installTransportFailureHandler() {
        transport.setFailureHandler { [weak self] message in self?.sessionFailed(message) }
    }

    var isAuthorizedSession: Bool { lock.withLock { state == .authorized } }

    /// Register one availability observer for the original session. Idle and
    /// authorizing mean not ready yet; failure or retirement means unavailable.
    /// Delivery is exactly once and outside all locks, including late register.
    /// A second registration is ignored rather than replacing the first owner.
    func observeUnavailability(_ callback: @escaping @Sendable () -> Void) {
        let immediate = lock.withLock {
            guard !unavailabilityObserverRegistered else { return false }
            unavailabilityObserverRegistered = true
            if [.draining, .failed, .closed].contains(state) {
                unavailabilityDelivered = true
                return true
            }
            unavailabilityObserver = callback
            return false
        }
        if immediate { callback() }
    }

    private func notifyUnavailability() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard [.draining, .failed, .closed].contains(state), !unavailabilityDelivered,
                  let callback = unavailabilityObserver else { return nil }
            unavailabilityDelivered = true
            unavailabilityObserver = nil
            return callback
        }
        callback?()
    }

    /// Blocking, bounded preparation API. Call on an asynchronous preparation
    /// worker, never MainActor. Concurrent callers share the first panel/request;
    /// they cannot extend its original deadline or show another panel.
    func authorizeSession(timeoutSeconds: Double = 300) throws {
        guard !Thread.isMainThread, timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 300 else {
            throw Failure(message: "Source authorization requires a preparation worker and a timeout up to 300 seconds.")
        }
        let callerDeadline = DispatchTime.now() + timeoutSeconds
        let send = try lock.withLock {
            switch state {
            case .authorized: return false
            case .idle:
                state = .authorizing
                authorizationDeadline = callerDeadline
                return true
            case .authorizing: return false
            case .draining, .failed, .closed:
                throw Failure(message: failure ?? "The original source authorization session has ended.")
            }
        }
        if send {
            control.async { [self] in
                guard lock.withLock({ state == .authorizing }) else { return }
                transport.authorize(root: root) { [weak self] allowed, message in
                    self?.receivedAuthorization(allowed: allowed, message: message)
                }
            }
        }
        while true {
            let outcome: String? = lock.withLock {
                if state == .authorized { return nil }
                if state != .authorizing { return failure ?? "The original source authorization session has ended." }
                return ""
            }
            if outcome == nil { return }
            if let outcome, !outcome.isEmpty { throw Failure(message: outcome) }
            let originalDeadline = lock.withLock { authorizationDeadline ?? callerDeadline }
            if DispatchTime.now() >= min(callerDeadline, originalDeadline) {
                sessionFailed("Meetings-folder authorization timed out before capture or inference began.")
                throw Failure(message: "Meetings-folder authorization timed out before capture or inference began.")
            }
            _ = changed.wait(timeout: .now() + .milliseconds(25))
        }
    }

    /// Register the returned pending token with the original inference owner
    /// BEFORE any broker request is sent. onRegistered must store it and replay
    /// already-recorded native termination under that owner's normal race gate.
    /// A thrown timeout does not retire the registered token or its source pins.
    func acquire(meetingFolder: URL, leaseRecord: Data, jobID: UUID, process: ProcessIdentity,
                 onRegistered: @Sendable (JobToken) -> Void,
                 onCapabilityLost: @escaping @Sendable (String) -> Void) throws -> JobToken {
        guard !Thread.isMainThread else {
            throw Failure(message: "Source acquisition must run on the original inference admission worker.")
        }
        let child = try Self.directChild(meetingFolder, of: root.path)
        guard leaseRecord.count == 56, MuesliSourceLease(record: leaseRecord) != nil,
              process.pid > 1, process.startSeconds > 0, process.startMicroseconds < 1_000_000 else {
            throw Failure(message: "The original source lease or observed process identity is invalid.")
        }
        let token = try lock.withLock {
            guard state == .authorized, !seenJobs.contains(jobID), seenJobs.count < 16_384 else {
                throw Failure(message: failure ?? "This source session or job no longer accepts capabilities.")
            }
            let value = JobToken(owner: self, jobID: jobID, process: process,
                leaseRecord: leaseRecord, child: child, onCapabilityLost: onCapabilityLost)
            seenJobs.insert(jobID)
            active[jobID] = value
            return value
        }
        onRegistered(token)
        control.async { [self, token] in
            guard lock.withLock({ state == .authorized }), token.maySendRequest else {
                token.cancel("Source acquisition retired before its broker request.")
                return
            }
            transport.bookmark(child: child, jobID: jobID, leaseRecord: token.leaseRecord) { [weak token] data, message in
                token?.receivedBookmark(data, message: message)
            }
        }
        do {
            try token.waitForBookmark()
            return token
        } catch {
            token.cancel(error.localizedDescription)
            throw error
        }
    }

    /// Close admission while preserving already granted work. Accepted Quit and
    /// graceful live-stop preparation use this: the live owner still sends its
    /// normal meeting_stop before actual process exit retires the last token.
    /// A cancelled Quit therefore cannot silently cancel an active helper.
    func retireAdmission() {
        lock.withLock {
            if state != .failed && state != .closed { state = .draining }
        }
        notifyUnavailability()
        changed.signal()
        closeTransportIfDrained()
    }

    /// Explicit cancellation, unlike retireAdmission, signals active jobs.
    /// Neither path releases a token before its actual original process exit.
    func beginShutdown() {
        let tokens: [JobToken] = lock.withLock {
            if state != .failed && state != .closed { state = .draining }
            return Array(active.values)
        }
        notifyUnavailability()
        changed.signal()
        for token in tokens { token.cancel("The app is closing its source authorization session.") }
        closeTransportIfDrained()
    }

    private func receivedAuthorization(allowed: Bool, message: String?) {
        let accepted = lock.withLock {
            guard state == .authorizing, let deadline = authorizationDeadline, DispatchTime.now() < deadline else { return false }
            if allowed { state = .authorized; return true }
            return false
        }
        if !accepted { sessionFailed(message ?? "The original Meetings folder was not authorized before its preparation deadline.") }
        changed.signal()
    }

    private func sessionFailed(_ message: String) {
        let tokens: [JobToken] = lock.withLock {
            guard state != .closed else { return [] }
            if failure == nil { failure = message }
            state = .failed
            return Array(active.values)
        }
        notifyUnavailability()
        changed.signal()
        for token in tokens { token.cancel(message) }
        closeTransportIfDrained()
    }

    fileprivate func retired(_ token: JobToken) {
        let removed = lock.withLock {
            guard active[token.jobID] === token else { return false }
            active.removeValue(forKey: token.jobID)
            return true
        }
        guard removed else { return }
        control.async { [self] in
            if !lock.withLock({ transportClosed }) { transport.retire(jobID: token.jobID) }
            closeTransportIfDrained()
        }
    }

    private func closeTransportIfDrained() {
        let close = lock.withLock {
            guard active.isEmpty, [.draining, .failed].contains(state), !transportClosed else { return false }
            transportClosed = true
            state = .closed
            return true
        }
        if close { control.async { [self] in transport.close() } }
    }

    private static func snapshotRoot(_ url: URL) throws -> RootIdentity {
        guard url.isFileURL, url.baseURL == nil, url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw Failure(message: "The Meetings root must be an existing local directory.")
        }
        let path = url.path
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        var state = stat()
        guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX),
              realpath(path, &canonical) != nil,
              String(decoding: canonical.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == path,
              lstat(path, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_uid == geteuid() else {
            throw Failure(message: "The original Meetings directory is missing, symbolic, or no longer owned by this user.")
        }
        return RootIdentity(path: path, device: UInt64(state.st_dev), inode: state.st_ino)
    }

    private static func directChild(_ url: URL, of root: String) throws -> String {
        let child = url.lastPathComponent
        guard url.isFileURL, url.baseURL == nil, url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost",
              !child.isEmpty, child != ".", child != "..", !child.contains("/"), !child.utf8.contains(0),
              child.utf8.count <= Int(NAME_MAX), url.deletingLastPathComponent().path == root,
              url.path == root + "/" + child else {
            throw Failure(message: "The selected meeting must be one direct child of the original Meetings root.")
        }
        return child
    }

    deinit { transport.close() }

    nonisolated final class JobToken: @unchecked Sendable {
        let jobID: UUID
        let process: ProcessIdentity
        let leaseRecord: Data
        private let child: String
        private let lock = NSLock()
        private let changed = DispatchSemaphore(value: 0)
        private let deadline = DispatchTime.now() + 2
        private var owner: SourceCapabilityOwner?
        private var onCapabilityLost: (@Sendable (String) -> Void)?
        private var failure: String?
        private var bookmarkBytes: Data?
        private var receivedReply = false
        private var terminated = false

        fileprivate init(owner: SourceCapabilityOwner, jobID: UUID, process: ProcessIdentity, leaseRecord: Data,
                         child: String, onCapabilityLost: @escaping @Sendable (String) -> Void) {
            self.owner = owner
            self.jobID = jobID
            self.process = process
            self.leaseRecord = leaseRecord
            self.child = child
            self.onCapabilityLost = onCapabilityLost
        }

        /// The bytes are immutable and must be forwarded without resolving,
        /// recreating, downscoping or otherwise rewriting this capability.
        var bookmark: Data {
            get throws {
                try lock.withLock {
                    guard !terminated, failure == nil, let bookmarkBytes else {
                        throw Failure(message: failure ?? "The original source capability is not active.")
                    }
                    return bookmarkBytes
                }
            }
        }

        fileprivate var maySendRequest: Bool {
            lock.withLock { !terminated && failure == nil && !receivedReply && DispatchTime.now() < deadline }
        }

        fileprivate func receivedBookmark(_ data: Data?, message: String?) {
            let error: String? = lock.withLock {
                guard !terminated, failure == nil else { return nil }
                guard !receivedReply else { return "The broker returned more than one capability for this job." }
                receivedReply = true
                guard DispatchTime.now() < deadline else { return "The source broker reply arrived after its two-second admission bound." }
                guard let data, !data.isEmpty, data.count <= 1024 * 1024 else {
                    return message ?? "The source broker did not return a valid bounded bookmark."
                }
                bookmarkBytes = data
                return nil
            }
            if let error { cancel(error) }
            changed.signal()
        }

        fileprivate func waitForBookmark() throws {
            while true {
                let ready = try lock.withLock {
                    guard !terminated, failure == nil else {
                        throw Failure(message: failure ?? "The original inference process already terminated.")
                    }
                    return bookmarkBytes != nil
                }
                if ready { return }
                if DispatchTime.now() >= deadline {
                    throw Failure(message: "The source broker exceeded its two-second admission bound.")
                }
                _ = changed.wait(timeout: .now() + .milliseconds(10))
            }
        }

        /// Cancellation closes further handoff and signals the original job.
        /// It deliberately retains the owner, token and original source pins.
        fileprivate func cancel(_ message: String) {
            let callback: (@Sendable (String) -> Void)? = lock.withLock {
                guard !terminated, failure == nil else { return nil }
                failure = message
                let callback = onCapabilityLost
                onCapabilityLost = nil
                return callback
            }
            changed.signal()
            callback?(message)
        }

        /// Only the main app's original native observer can produce this type.
        /// A duplicate matching event is harmless; a different process instance
        /// or event without kernel exit/status flags never releases ownership.
        @discardableResult
        func observedTermination(_ evidence: MuesliProcessTermination) throws -> Bool {
            guard evidence.processIdentifier == process.pid, evidence.startSeconds == process.startSeconds,
                  evidence.startMicroseconds == process.startMicroseconds,
                  evidence.eventFlags & UInt32(NOTE_EXIT) != 0, evidence.eventFlags & UInt32(NOTE_EXITSTATUS) != 0 else {
                throw Failure(message: "The source token has no matching original-process termination evidence.")
            }
            let retired: (SourceCapabilityOwner?, (@Sendable (String) -> Void)?) = lock.withLock {
                guard !terminated else { return (nil, nil) }
                terminated = true
                bookmarkBytes = nil
                let callback = onCapabilityLost
                onCapabilityLost = nil
                let original = owner
                owner = nil
                return (original, callback)
            }
            changed.signal()
            // A cancellation callback may retain a native application owner.
            // Its destruction, like the owner's retirement work, stays outside
            // the token's cheap state lock.
            return withExtendedLifetime(retired.1) {
                guard let original = retired.0 else { return false }
                original.retired(self)
                return true
            }
        }
    }
}

/// The default implementation is fixed NSXPC. The test-only initializer above
/// substitutes callbacks to exercise races without a panel or source grant.
nonisolated protocol SourceCapabilityTransport: AnyObject, Sendable {
    func setFailureHandler(_ callback: @escaping @Sendable (String) -> Void)
    func authorize(root: SourceCapabilityOwner.RootIdentity, reply: @escaping @Sendable (Bool, String?) -> Void)
    func bookmark(child: String, jobID: UUID, leaseRecord: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    func retire(jobID: UUID)
    func close()
}

nonisolated private final class NativeSourceCapabilityTransport: SourceCapabilityTransport, @unchecked Sendable {
    private let connection = NSXPCConnection(serviceName: MuesliSourceAccessServiceName)
    private let lock = NSLock()
    private var failureHandler: (@Sendable (String) -> Void)?
    private var activated = false
    private var closed = false
    private var transportFailed = false

    init() {
        connection.setCodeSigningRequirement(MuesliSourceAccessServiceRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: MuesliSourceAccessService.self)
        connection.interruptionHandler = { [weak self] in self?.failed("The read-only source broker was interrupted.") }
        connection.invalidationHandler = { [weak self] in self?.failed("The read-only source broker was invalidated.") }
    }

    func setFailureHandler(_ callback: @escaping @Sendable (String) -> Void) {
        lock.withLock { failureHandler = callback }
    }

    private func failed(_ message: String) {
        let callback: (@Sendable (String) -> Void)? = lock.withLock {
            guard !closed, !transportFailed else { return nil }
            transportFailed = true
            return failureHandler
        }
        callback?(message)
    }

    private func proxy() -> (any MuesliSourceAccessService)? {
        // Never let a later retirement RPC silently relaunch a service after
        // the original connection was interrupted or invalidated.
        guard !lock.withLock({ closed || transportFailed }) else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in self?.failed(error.localizedDescription) }
            as? any MuesliSourceAccessService
    }

    func authorize(root: SourceCapabilityOwner.RootIdentity, reply: @escaping @Sendable (Bool, String?) -> Void) {
        let activate = lock.withLock {
            guard !closed, !transportFailed, !activated else { return false }
            activated = true
            return true
        }
        if activate { connection.activate() }
        guard let proxy = proxy() else { reply(false, "The source authorization connection is unavailable."); return }
        proxy.authorizeRoot(path: root.path, device: root.device, inode: root.inode, reply: reply)
    }

    func bookmark(child: String, jobID: UUID, leaseRecord: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let proxy = proxy() else { reply(nil, "The source capability connection is unavailable."); return }
        proxy.bookmark(child: child, jobID: jobID, leaseRecord: leaseRecord, reply: reply)
    }

    func retire(jobID: UUID) { proxy()?.retire(jobID: jobID) { _ in } }

    func close() {
        let first = lock.withLock {
            guard !closed else { return false }
            closed = true
            failureHandler = nil
            return true
        }
        if first { connection.invalidate() }
    }
}
