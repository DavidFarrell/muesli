import Foundation
import CryptoKit
import Darwin

/// Exhaustive, read-only inventory under the caller's exclusive meeting owner.
/// This is not source eligibility or permission to archive. In particular, all
/// files and empty directories are returned, including unindexed material and
/// protocol locks. The archive caller must inspect semantics and revalidate the
/// inventory immediately before its move while retaining this same owner.
nonisolated enum ArchiveSourceInventory {
    struct Limits: Sendable {
        var entries = 100_000
        var depth = 32
        var pathBytes = 16 * 1024 * 1024
        var fileBytes: Int64 = 64 * 1024 * 1024 * 1024
        var totalBytes: Int64 = 256 * 1024 * 1024 * 1024
    }
    struct EntryIdentity: Codable, Equatable, Sendable {
        let path: String; let device: UInt64; let inode: UInt64; let directory: Bool
    }
    struct Snapshot: Sendable {
        let access: MeetingFileAccess
        let canonicalFolderURL: URL
        let files: [ArchiveReceipt.FileRecord]
        /// Includes every descendant directory, even an empty unindexed one.
        let directories: [String]
        let identities: [EntryIdentity]
    }
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    /// Invoke on a retained file worker. Neither a UI timeout nor cancellation
    /// releases the original access while a kernel read is still outstanding.
    static func capture(access: MeetingFileAccess, limits: Limits = Limits(),
                        afterRootResolution: (@Sendable (URL) throws -> Void)? = nil,
                        beforeRead: (@Sendable (String) throws -> Void)? = nil) throws -> Snapshot {
        try captureImpl(access: access, location: nil, limits: limits, afterRootResolution: afterRootResolution, beforeRead: beforeRead)
    }
    /// Same held exclusive lease after the native owner relocates a source to
    /// private staging. Reuses the complete bounded walker, including empty
    /// directories; no self-conflicting flock or original-path validation.
    static func captureRelocated(access: MeetingFileAccess, at location: URL, limits: Limits = Limits()) throws -> Snapshot {
        try captureImpl(access: access, location: location, limits: limits, afterRootResolution: nil, beforeRead: nil)
    }
    private static func captureImpl(access: MeetingFileAccess, location: URL?, limits: Limits,
                                    afterRootResolution: (@Sendable (URL) throws -> Void)?,
                                    beforeRead: (@Sendable (String) throws -> Void)?) throws -> Snapshot {
        try require(access.mode == .archive, "Source inventory requires exclusive archive ownership.")
        try require(limits.entries > 0 && limits.depth > 0 && limits.pathBytes > 0
                    && limits.fileBytes >= 0 && limits.totalBytes >= 0, "Invalid source inventory limits.")
        if let location { try access.validateRelocated(to: location) } else { try access.validate() }
        // Foundation can shorten an existing /private/tmp path back to /tmp.
        // Resolve only the root's spelling, then independently open every
        // canonical component and compare the root to the already-held owner.
        // No descendant data is read until that identity comparison succeeds.
        guard let resolved = realpath((location ?? access.folderURL).path, nil) else {
            throw Failure(message: "The owned source folder cannot be resolved.")
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        try afterRootResolution?(URL(fileURLWithPath: path))
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        try require(path.hasPrefix("/") && !components.isEmpty
                    && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") },
                    "Source inventory requires a canonical absolute folder path.")
        var parents: [Int32] = []
        defer { parents.reversed().forEach { _ = Darwin.close($0) } }
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try require(root >= 0, "The filesystem root is unavailable.")
        parents.append(root)
        var links: [(Int32, String, Int32)] = []
        for component in components {
            let parent = parents.last!
            let child = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(child >= 0, "The source path changed or traverses a symbolic link.")
            parents.append(child)
            links.append((parent, String(component), child))
        }
        let directory = parents.last!
        let original = try state(directory)
        try require(UInt64(UInt32(bitPattern: original.st_dev)) == access.identity.directoryDevice
                    && original.st_ino == access.identity.directoryInode, "The source folder identity changed.")
        // Query the name used by recovery against the actual filesystem. A
        // differently cased spelling can designate the same entry on APFS.
        try requireNoTransaction(directory)
        var builder = Builder(limits: limits, beforeRead: beforeRead)
        try builder.walk(directory, path: "", depth: 0)
        try requireNoTransaction(directory)
        for (parent, name, child) in links { try validateLink(parent: parent, name: name, child: child) }
        if let location { try access.validateRelocated(to: location) } else { try access.validate() }
        return Snapshot(access: access, canonicalFolderURL: URL(fileURLWithPath: path),
                        files: builder.files.sorted { $0.path < $1.path },
                        directories: builder.directories.sorted(), identities: builder.identities.sorted { $0.path < $1.path })
    }

    private struct Builder {
        let limits: Limits
        let beforeRead: (@Sendable (String) throws -> Void)?
        var files: [ArchiveReceipt.FileRecord] = []
        var directories: [String] = []
        var identities: [EntryIdentity] = []
        var entries = 0
        var pathBytes = 0
        var totalBytes: Int64 = 0

        mutating func walk(_ directory: Int32, path: String, depth: Int) throws {
            let original = try state(directory)
            try require(original.st_mode & S_IFMT == S_IFDIR, "A source directory changed type.")
            // openat creates an independent directory cursor; dup would share
            // its position and make a second enumeration start at EOF.
            let names = try list(directory, maximum: limits.entries - entries)
            for name in names.sorted() {
                let relative = path.isEmpty ? name : path + "/" + name
                try require(relative != TranscriptPersistenceStore.journalDirectoryName,
                            "An unresolved transcript transaction prevents archiving. Open the meeting for recovery first.")
                try require(entries < limits.entries && relative.utf8.count <= limits.pathBytes - pathBytes,
                            "The source inventory exceeds its entry or path-size limit.")
                entries += 1; pathBytes += relative.utf8.count
                var namedChild = stat()
                try require(fstatat(directory, name, &namedChild, AT_SYMLINK_NOFOLLOW) == 0,
                            "A source entry is unavailable.")
                let kind = namedChild.st_mode & S_IFMT
                try require(kind == S_IFDIR || kind == S_IFREG, "A source entry is not a regular file or directory.")
                let child = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0))
                try require(child >= 0, "A source entry is unavailable or is a symbolic link.")
                defer { _ = Darwin.close(child) }
                let originalChild = try state(child)
                try require(originalChild.st_dev == namedChild.st_dev && originalChild.st_ino == namedChild.st_ino
                            && originalChild.st_mode & S_IFMT == kind, "A source entry changed before opening.")
                identities.append(.init(path: relative, device: UInt64(UInt32(bitPattern: originalChild.st_dev)),
                                        inode: originalChild.st_ino, directory: kind == S_IFDIR))
                switch originalChild.st_mode & S_IFMT {
                case S_IFDIR:
                    try require(depth < limits.depth, "The source directory depth exceeds its limit.")
                    directories.append(relative)
                    try walk(child, path: relative, depth: depth + 1)
                case S_IFREG:
                    try require(originalChild.st_nlink == 1 && originalChild.st_size >= 0
                                && originalChild.st_size <= limits.fileBytes,
                                "A source file is hard-linked or exceeds its size limit.")
                    try beforeRead?(relative)
                    let record = try fingerprint(child, path: relative, original: originalChild)
                    files.append(record)
                default:
                    throw Failure(message: "A source entry is not a regular file or directory.")
                }
                try validateLink(parent: directory, name: name, child: child)
            }
            try require(try list(directory, maximum: limits.entries) == names,
                        "The source directory entries changed during inventory.")
            try require(stable(original, try state(directory)), "A source directory changed during inventory.")
        }

        mutating func fingerprint(_ descriptor: Int32, path: String, original: stat) throws -> ArchiveReceipt.FileRecord {
            var hasher = SHA256()
            var count: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let size = Darwin.read(descriptor, &buffer, buffer.count)
                if size < 0 && errno == EINTR { continue }
                try require(size >= 0, "A source file could not be read.")
                if size == 0 { break }
                try require(Int64(size) <= limits.fileBytes - count && Int64(size) <= limits.totalBytes - totalBytes,
                            "The source inventory exceeds its byte limit.")
                count += Int64(size); totalBytes += Int64(size)
                hasher.update(data: Data(buffer.prefix(size)))
            }
            let current = try state(descriptor)
            try require(count == original.st_size && current.st_nlink == 1 && stable(original, current),
                        "A source file changed during inventory.")
            return ArchiveReceipt.FileRecord(path: path, bytes: count,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    private static func list(_ descriptor: Int32, maximum: Int) throws -> Set<String> {
        let cursor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try require(cursor >= 0, "A source directory cannot be enumerated.")
        guard let stream = fdopendir(cursor) else {
            _ = Darwin.close(cursor)
            throw Failure(message: "A source directory cannot be enumerated.")
        }
        defer { closedir(stream) }
        var result: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                try require(errno == 0, "A source directory read failed.")
                return result
            }
            let length = Int(entry.pointee.d_namlen)
            let nameBytes = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(length)) }
            guard let name = String(data: nameBytes, encoding: .utf8) else {
                throw Failure(message: "A source filename is not valid UTF-8.")
            }
            if name == "." || name == ".." { continue }
            try require(!name.isEmpty && !name.contains("/") && !name.contains("\0") && result.count < maximum,
                        "The source directory exceeds its entry limit or contains an invalid name.")
            try require(result.insert(name).inserted, "A source directory contains an ambiguous filename.")
        }
    }
    private static func state(_ descriptor: Int32) throws -> stat {
        var value = stat()
        try require(fstat(descriptor, &value) == 0, "A source entry is unavailable.")
        return value
    }
    private static func requireNoTransaction(_ directory: Int32) throws {
        var journal = stat()
        let result = fstatat(directory, TranscriptPersistenceStore.journalDirectoryName, &journal, AT_SYMLINK_NOFOLLOW)
        try require(result < 0 && errno == ENOENT,
                    "An unresolved or unreadable transcript transaction prevents archiving. Open the meeting for recovery first.")
    }
    private static func validateLink(parent: Int32, name: String, child: Int32) throws {
        var named = stat()
        let opened = try state(child)
        try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
                    && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
                    && named.st_mode & S_IFMT == opened.st_mode & S_IFMT,
                    "A source entry path changed during inventory.")
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
