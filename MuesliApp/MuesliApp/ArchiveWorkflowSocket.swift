import Foundation
import Darwin

/// All filesystem/socket work belongs on a retained non-UI worker. A socket is
/// an IPC route for this UID, not an authentication boundary against other code
/// already running as the same user. It never carries transferable proof.
nonisolated enum ArchiveWorkflowSocket {
    typealias Failure = ArchiveWorkflowProtocol.Failure
    static let socketName = "archive.sock"
    static let lockName = "archive-owner.lock"
    static let maximumClients = 4
    static let requestSeconds: Double = 5

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Muesli/ArchiveBridge", isDirectory: true)
    }
    struct Identity: Equatable, Sendable {
        let device: dev_t; let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }
    final class Endpoint: @unchecked Sendable {
        let directory: URL
        let fd: Int32
        let identity: Identity
        private let closeLock = NSLock()
        private var closed = false
        init(directory: URL, create: Bool) throws {
            try ArchiveWorkflowProtocol.validatePath(directory.path)
            self.directory = directory
            // Walk from / with no-follow descriptors, including every ancestor.
            // Only the final private directory may be created by this owner.
            let parts = directory.path.split(separator: "/")
            guard !parts.isEmpty else { throw Failure.unsafeEndpoint }
            var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard current >= 0 else { throw Failure.unsafeEndpoint }
            do {
                for (index, component) in parts.enumerated() {
                    let name = String(component)
                    guard name != "." && name != ".." else { throw Failure.unsafeEndpoint }
                    if create && index == parts.count - 1 {
                        if mkdirat(current, name, 0o700) != 0 && errno != EEXIST { throw Failure.unsafeEndpoint }
                    }
                    let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw Failure.unsafeEndpoint }
                    Darwin.close(current); current = next
                }
                var info = stat()
                guard fstat(current, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
                    throw Failure.unsafeEndpoint
                }
                fd = current; identity = Identity(info)
            } catch { Darwin.close(current); throw error }
        }
        deinit { close() }
        func close() {
            let owned = closeLock.withLock { if closed { return false }; closed = true; return true }
            if owned { Darwin.close(fd) }
        }
        func validate() throws {
            // Reopen all ancestors rather than following a swapped parent.
            var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard current >= 0 else { throw Failure.unsafeEndpoint }
            defer { Darwin.close(current) }
            for component in directory.path.split(separator: "/") {
                let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unsafeEndpoint }
                Darwin.close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, Identity(info) == identity,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.unsafeEndpoint }
        }
        func socketIdentity() throws -> Identity {
            try validate(); var info = stat()
            guard fstatat(fd, socketName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw Failure.unsafeEndpoint }
            return Identity(info)
        }
    }

    static func descriptor() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.transportUnavailable }
        var one: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            Darwin.close(fd); throw Failure.transportUnavailable
        }
        return fd
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw Failure.unsafeEndpoint }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
        return value
    }
    static func withAddress<T>(_ value: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func verifyPeer(_ fd: Int32) throws {
        var uid = uid_t.max, gid = gid_t.max
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure.unsafeEndpoint }
    }
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func wait(_ fd: Int32, events: Int16, deadline: Double, stopping: () -> Bool = { false }) throws {
        while true {
            guard !stopping() else { throw Failure.stopping }
            let remaining = deadline - now()
            guard remaining > 0 else { throw Failure.transportTimeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(100, ceil(remaining * 1000))))
            if result < 0 && errno != EINTR { throw Failure.transportUnavailable }
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw Failure.transportUnavailable }
            }
        }
    }
    static func read(_ fd: Int32, count: Int, deadline: Double, stopping: () -> Bool = { false }) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline, stopping: stopping)
            let result = data.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
            }
            if result > 0 { offset += result }
            else if result == 0 { throw Failure.transportUnavailable }
            else if errno != EINTR && errno != EAGAIN { throw Failure.transportUnavailable }
        }
        return data
    }
    static func receive(_ fd: Int32, deadline: Double, stopping: () -> Bool = { false }) throws -> Data {
        let header = try read(fd, count: 4, deadline: deadline, stopping: stopping)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0 && count <= ArchiveWorkflowProtocol.maximumMessageBytes else { throw Failure.invalidRequest }
        return try read(fd, count: count, deadline: deadline, stopping: stopping)
    }
    static func send(_ fd: Int32, data: Data, deadline: Double, stopping: () -> Bool = { false }) throws {
        guard !data.isEmpty && data.count <= ArchiveWorkflowProtocol.maximumMessageBytes else { throw Failure.invalidRequest }
        var size = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &size) { Data($0) }; framed.append(data)
        var offset = 0
        while offset < framed.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, stopping: stopping)
            let result = framed.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), framed.count - offset) }
            if result > 0 { offset += result }
            else if result == 0 || (errno != EINTR && errno != EAGAIN) { throw Failure.transportUnavailable }
        }
    }
    static func request(_ request: ArchiveWorkflowProtocol.Request, directory: URL = defaultDirectory(),
                        timeoutSeconds: Double = requestSeconds) throws -> ArchiveWorkflowProtocol.Response {
        let deadline = now() + min(max(timeoutSeconds, 0.01), requestSeconds)
        let endpoint = try Endpoint(directory: directory, create: false)
        let original = try endpoint.socketIdentity()
        var address = try address(directory.appendingPathComponent(socketName).path)
        let fd = try descriptor(); defer { Darwin.close(fd) }
        let result = withAddress(&address) { Darwin.connect(fd, $0, $1) }
        if result != 0 {
            guard errno == EINPROGRESS else { throw Failure.transportUnavailable }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var failure: Int32 = 0; var length = socklen_t(MemoryLayout.size(ofValue: failure))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0 else { throw Failure.transportUnavailable }
        }
        try verifyPeer(fd)
        guard try endpoint.socketIdentity() == original else { throw Failure.unsafeEndpoint }
        try send(fd, data: request.encode(), deadline: deadline)
        let response = try JSONDecoder().decode(ArchiveWorkflowProtocol.Response.self, from: receive(fd, deadline: deadline))
        guard response.protocolVersion == ArchiveWorkflowProtocol.version else { throw Failure.invalidRequest }
        return response
    }
}

/// Creation and start are explicit; merely linking the app never opens a socket.
/// Stop is a nonblocking flag. The original owner alone closes FDs and releases
/// the exclusive listener lease after every accepted client has actually closed.
nonisolated final class ArchiveWorkflowServer: @unchecked Sendable {
    typealias Socket = ArchiveWorkflowSocket
    private let endpoint: Socket.Endpoint
    private let lease: Int32
    private let listener: Int32
    private let socketIdentity: Socket.Identity
    private let leaseIdentity: Socket.Identity
    private let requestTimeoutSeconds: Double
    private let afterClientClose: @Sendable (Int32) -> Void
    private let onClosed: @Sendable () -> Void
    private let handler: @Sendable (ArchiveWorkflowProtocol.Request) -> ArchiveWorkflowProtocol.Response
    private let lock = NSLock()
    private let clientsClosed = DispatchGroup()
    private var started = false
    private var stopped = false
    private var closed = false
    // Descriptor numbers are reusable as soon as close() returns. Occupancy
    // belongs to this accepted owner until its entire close path has finished.
    private var clients: Set<UUID> = []

    init(directory: URL, requestTimeoutSeconds: Double = Socket.requestSeconds,
         afterClientClose: @escaping @Sendable (Int32) -> Void = { _ in },
         onClosed: @escaping @Sendable () -> Void = {},
         handler: @escaping @Sendable (ArchiveWorkflowProtocol.Request) -> ArchiveWorkflowProtocol.Response) throws {
        self.handler = handler
        self.afterClientClose = afterClientClose
        self.onClosed = onClosed
        self.requestTimeoutSeconds = min(max(requestTimeoutSeconds, 0.05), Socket.requestSeconds)
        endpoint = try Socket.Endpoint(directory: directory, create: true)
        let fd = openat(endpoint.fd, Socket.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Socket.Failure.unsafeEndpoint }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw Socket.Failure.busy }
        lease = fd
        leaseIdentity = Socket.Identity(info)
        var ownedListener: Int32 = -1
        do {
            try endpoint.validate()
            var pathInfo = stat()
            guard fstatat(endpoint.fd, Socket.lockName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  Socket.Identity(pathInfo) == Socket.Identity(info) else { throw Socket.Failure.unsafeEndpoint }
            // Under the exclusive lease, only a verified stale socket may be removed.
            if fstatat(endpoint.fd, Socket.socketName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                _ = try endpoint.socketIdentity()
                guard unlinkat(endpoint.fd, Socket.socketName, 0) == 0 else { throw Socket.Failure.unsafeEndpoint }
            } else if errno != ENOENT { throw Socket.Failure.unsafeEndpoint }
            ownedListener = try Socket.descriptor()
            var address = try Socket.address(directory.appendingPathComponent(Socket.socketName).path)
            guard Socket.withAddress(&address, { Darwin.bind(ownedListener, $0, $1) }) == 0,
                  fchmodat(endpoint.fd, Socket.socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else { throw Socket.Failure.unsafeEndpoint }
            socketIdentity = try endpoint.socketIdentity()
            guard Darwin.listen(ownedListener, Int32(Socket.maximumClients)) == 0 else { throw Socket.Failure.transportUnavailable }
            listener = ownedListener
        } catch {
            if ownedListener >= 0 { Darwin.close(ownedListener) }
            Darwin.close(fd); throw error
        }
    }
    deinit {
        // An unstarted server owns its FDs locally; started servers retain self
        // until run() performs actual closure, including all client owners.
        if !started { Darwin.close(listener); Darwin.close(lease) }
    }
    func start() {
        let launch = lock.withLock { if started { return false }; started = true; return true }
        if launch { DispatchQueue.global(qos: .utility).async { [self] in run() } }
    }
    func stop() {
        lock.withLock { stopped = true }
        // An initialized-but-not-yet-started listener still owns descriptors.
        // Transfer them to the same retained close owner rather than closing
        // from an arbitrary caller or leaving shutdown permanently pending.
        start()
    }
    var isClosed: Bool { lock.withLock { closed } }
    var activeClientCount: Int { lock.withLock { clients.count } }
    private var isStopping: Bool { lock.withLock { stopped } }

    private func run() {
        while !isStopping {
            do { try Socket.wait(listener, events: Int16(POLLIN), deadline: Socket.now() + 0.25, stopping: { self.isStopping }) }
            catch Socket.Failure.transportTimeout { continue }
            catch { break }
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 { if errno == EAGAIN || errno == EINTR { continue }; break }
            var one: Int32 = 1
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
                Darwin.close(fd); continue
            }
            let clientID = UUID()
            let admitted = lock.withLock {
                guard !stopped && clients.count < Socket.maximumClients else { return false }
                clients.insert(clientID); clientsClosed.enter(); return true
            }
            guard admitted else { Darwin.close(fd); continue }
            let deadline = Socket.now() + requestTimeoutSeconds
            DispatchQueue.global(qos: .utility).async { [self] in serve(fd, clientID: clientID, deadline: deadline) }
        }
        lock.withLock { stopped = true }
        Darwin.close(listener)
        // The count reaches zero only after each original owner closes its FD.
        clientsClosed.wait()
        if (try? endpoint.socketIdentity()) == socketIdentity { _ = unlinkat(endpoint.fd, Socket.socketName, 0) }
        Darwin.close(lease)
        endpoint.close()
        lock.withLock { closed = true }
        onClosed()
    }
    private func serve(_ fd: Int32, clientID: UUID, deadline: Double) {
        defer {
            Darwin.close(fd)
            afterClientClose(fd)
            _ = lock.withLock { clients.remove(clientID) }
            clientsClosed.leave()
        }
        do {
            try Socket.verifyPeer(fd)
            let data = try Socket.receive(fd, deadline: deadline, stopping: { self.isStopping })
            let request = try ArchiveWorkflowProtocol.Request.decode(data)
            guard !isStopping else { return }
            try endpoint.validate()
            var info = stat()
            guard fstatat(endpoint.fd, Socket.lockName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Socket.Identity(info) == leaseIdentity,
                  try endpoint.socketIdentity() == socketIdentity else { throw Socket.Failure.unsafeEndpoint }
            let response = handler(request)
            try Socket.send(fd, data: response.encoded(), deadline: deadline, stopping: { self.isStopping })
        } catch { /* A failed connection never cancels the workflow it admitted. */ }
    }
}
