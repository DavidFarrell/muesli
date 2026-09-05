import Foundation
import CryptoKit
import Darwin

/// Existing-only descriptors used by the source gate. No recovery or creation.
/// Mutable setup is confined to inspect's original worker; after publication
/// the object only retains the descriptors and their nonblocking flock leases.
nonisolated final class ArchiveSourceReader: @unchecked Sendable {
    let access: MeetingFileAccess
    let folder: URL
    private var roots: [FileHandle] = []
    private var rootLinks: [(Int32, String, Int32)] = []
    private var leases: [String: [FileHandle]] = [:]
    private(set) var discovered: Set<String> = []
    private var pathBytes = 0
    private var root: Int32 { roots.last!.fileDescriptor }
    static let leaseNames: Set<String> = [".backend-owner.lock", ".capture-owner.lock", ".artifact-owner.lock",
                                         ".meeting-transaction.lock", "transcript_events.jsonl"]

    init(access: MeetingFileAccess) throws {
        self.access = access
        try Self.require(access.mode == .archive, "Exclusive archive ownership is required.")
        try access.validate()
        guard let physical = realpath(access.folderURL.path, nil) else { throw Self.failure("The owned source is unavailable.") }
        defer { free(physical) }
        folder = URL(fileURLWithPath: String(cString: physical))
        let fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try Self.require(fd >= 0, "The filesystem root is unavailable.")
        roots.append(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
        for name in folder.path.split(separator: "/").map(String.init) {
            let parent = root
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try Self.require(child >= 0, "The source ancestor changed.")
            roots.append(FileHandle(fileDescriptor: child, closeOnDealloc: true))
            rootLinks.append((parent, name, child))
        }
        let state = try Self.state(root)
        try Self.require(UInt64(UInt32(bitPattern: state.st_dev)) == access.identity.directoryDevice
                         && state.st_ino == access.identity.directoryInode, "The owned source identity changed.")
        try noTransaction()
    }

    /// Enumerate names/types only, then acquire every discovered protocol lease
    /// before any inventory hashes or semantic source bytes are read.
    func discoverAndLock() throws {
        try discover(root, path: "", depth: 0)
        let paths = discovered.filter { Self.leaseNames.contains(($0 as NSString).lastPathComponent.lowercased()) }
        try Self.require(paths.count <= 4096, "The source exceeds its secondary-owner limit.")
        for path in paths.sorted() {
            let handles = try openFile(path)
            let fd = handles.last!.fileDescriptor
            try Self.require(flock(fd, LOCK_EX | LOCK_NB) == 0,
                             "A source, artifact, journal or backend owner is still active: \(path)")
            leases[path] = handles
        }
        try validate()
    }
    func requireLease(_ path: String) throws {
        try Self.require(leases[path] != nil, "Current ownership evidence is missing; retain legacy or incomplete source: \(path)")
    }
    func validate() throws {
        try access.validate()
        for (parent, name, child) in rootLinks { try Self.link(parent, name, child) }
        for (path, handles) in leases { try validate(path, handles) }
        try noTransaction()
    }
    func noTransaction() throws {
        var value = stat()
        let result = fstatat(root, TranscriptPersistenceStore.journalDirectoryName, &value, AT_SYMLINK_NOFOLLOW)
        try Self.require(result < 0 && errno == ENOENT,
                         "An unresolved or unreadable transcript transaction requires recovery before eligibility can be checked.")
    }

    func read(_ record: ArchiveReceipt.FileRecord, maximumBytes: Int64) throws -> Data {
        var data = Data()
        try stream(record, maximumBytes: maximumBytes) { data.append($0) }
        return data
    }
    /// Bind the bytes actually parsed/replayed to the exhaustive inventory.
    func stream(_ record: ArchiveReceipt.FileRecord, maximumBytes: Int64, consume: (Data) -> Void) throws {
        try Self.require(record.bytes >= 0 && record.bytes <= maximumBytes, "A semantic source file exceeds its read limit: \(record.path)")
        let handles = try openFile(record.path)
        let fd = handles.last!.fileDescriptor
        let before = try Self.state(fd)
        try Self.require(before.st_size == record.bytes, "A source file changed after inventory: \(record.path)")
        var digest = SHA256(), total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            try Self.require(count >= 0, "A source read failed: \(record.path)")
            if count == 0 { break }
            try Self.require(Int64(count) <= record.bytes - total, "A source file grew after inventory: \(record.path)")
            total += Int64(count)
            let chunk = Data(buffer.prefix(count))
            digest.update(data: chunk); consume(chunk)
        }
        try Self.require(total == record.bytes && Self.stable(before, try Self.state(fd))
                         && digest.finalize().map { String(format: "%02x", $0) }.joined() == record.sha256,
                         "Source bytes differ from the exhaustive inventory: \(record.path)")
        try validate(record.path, handles)
    }

    private func discover(_ directory: Int32, path: String, depth: Int) throws {
        try Self.require(depth <= 32, "The source topology exceeds its depth limit.")
        let names = try Self.list(directory)
        for name in names.sorted() {
            let relative = path.isEmpty ? name : path + "/" + name
            try Self.require(discovered.count < 100_000 && relative.utf8.count <= 16 * 1024 * 1024 - pathBytes,
                             "The source topology exceeds its resource limit.")
            discovered.insert(relative); pathBytes += relative.utf8.count
            var value = stat()
            try Self.require(fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0, "A source entry is unavailable.")
            let kind = value.st_mode & S_IFMT
            try Self.require(kind == S_IFDIR || kind == S_IFREG, "A source entry is not a regular file or directory.")
            if kind == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try Self.require(child >= 0, "A source directory changed.")
                let handle = FileHandle(fileDescriptor: child, closeOnDealloc: true)
                try Self.link(directory, name, child)
                try discover(handle.fileDescriptor, path: relative, depth: depth + 1)
                try Self.link(directory, name, child)
            }
        }
        try Self.require(try Self.list(directory) == names, "The source topology changed while acquiring ownership.")
    }
    private func openFile(_ path: String) throws -> [FileHandle] {
        let names = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        try Self.require(!names.isEmpty && names.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") },
                         "Invalid source-relative path.")
        var handles: [FileHandle] = []
        for (index, name) in names.enumerated() {
            let parent = handles.last?.fileDescriptor ?? root
            let child = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (index + 1 < names.count ? O_DIRECTORY : 0))
            try Self.require(child >= 0, "A source file is missing or traverses a changed path: \(path)")
            handles.append(FileHandle(fileDescriptor: child, closeOnDealloc: true))
            try Self.link(parent, name, child)
        }
        let state = try Self.state(handles.last!.fileDescriptor)
        try Self.require(state.st_mode & S_IFMT == S_IFREG && state.st_nlink == 1 && state.st_uid == geteuid(),
                         "A source file must be a single-link regular file owned by this user: \(path)")
        return handles
    }
    private func validate(_ path: String, _ handles: [FileHandle]) throws {
        let names = path.split(separator: "/").map(String.init)
        for index in names.indices {
            try Self.link(index == 0 ? root : handles[index - 1].fileDescriptor, names[index], handles[index].fileDescriptor)
        }
        let state = try Self.state(handles.last!.fileDescriptor)
        try Self.require(state.st_nlink == 1 && state.st_uid == geteuid() && state.st_mode & S_IFMT == S_IFREG,
                         "A retained source file changed identity or ownership.")
    }
    private static func list(_ fd: Int32) throws -> Set<String> {
        let cursor = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try require(cursor >= 0, "A source directory cannot be enumerated.")
        guard let stream = fdopendir(cursor) else { Darwin.close(cursor); throw failure("A source directory cannot be enumerated.") }
        defer { closedir(stream) }
        var names: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { try require(errno == 0, "A source directory read failed."); return names }
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(Int(entry.pointee.d_namlen))) }
            guard let name = String(data: bytes, encoding: .utf8) else { throw failure("A source filename is not UTF-8.") }
            if name == "." || name == ".." { continue }
            try require(names.count < 100_000 && !name.isEmpty && !name.contains("/") && !name.contains("\0") && names.insert(name).inserted,
                        "A source directory has invalid, duplicate or excessive entries.")
        }
    }
    private static func state(_ fd: Int32) throws -> stat {
        var value = stat(); try require(fstat(fd, &value) == 0, "A source descriptor is unavailable."); return value
    }
    private static func link(_ parent: Int32, _ name: String, _ child: Int32) throws {
        let opened = try state(child); var named = stat()
        try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && opened.st_dev == named.st_dev
                    && opened.st_ino == named.st_ino && opened.st_mode & S_IFMT == named.st_mode & S_IFMT,
                    "A retained source path changed identity.")
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func failure(_ message: String) -> ArchiveSourceEligibility.Failure { .init(message: message) }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
}
