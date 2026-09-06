import Foundation
import Darwin

/// Durable move intent outside the source. This type neither verifies note
/// semantics nor moves a file. A future move owner must obtain all validation
/// first, then retain this journal and the source owners through actual return.
nonisolated final class ArchiveMoveJournal: @unchecked Sendable {
    enum Phase: String, Codable, Sendable { case pending, moved, uncertain }
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let operationID: UUID
        let sourceFolder: String
        let sourceIdentity: MeetingFileAccess.Identity
        let sourceSessionIDs: [String]
        let receipt: ArchiveReceipt.FileRecord
        let phase: Phase
        let destination: String?
        let diagnosticCode: String?
        let observedAt: Double
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", operationID = "operation_id", sourceFolder = "source_folder"
            case sourceIdentity = "source_identity", sourceSessionIDs = "source_session_ids", receipt, phase, destination
            case diagnosticCode = "diagnostic_code", observedAt = "observed_at"
        }
    }
    enum Checkpoint: Sendable { case initialWrite, fileSync, publish, exchange, directorySync }
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    private static let limit = 256 * 1024
    private let lock = NSLock()
    private let root: Root
    private let source: MeetingFileAccess
    private let marker: String
    private let anchor: String
    private let anchorHandle: FileHandle
    private let anchorBytes: Data
    private var markerHandle: FileHandle
    private var currentBytes: Data
    private var current: Record
    private var terminalAttempted = false
    private let checkpoint: (@Sendable (Checkpoint) throws -> Void)?

    /// The root is an existing canonical, private (0700) app-owned directory.
    /// An existing source marker of ANY type/outcome blocks automatic reuse.
    /// It must be reconciled explicitly; no retry/overwrite/cleanup is inferred.
    init(rootURL: URL, source: MeetingFileAccess, sessionIDs: [String], receipt: ArchiveReceipt.FileRecord,
         operationID: UUID = UUID(), checkpoint: (@Sendable (Checkpoint) throws -> Void)? = nil) throws {
        try Self.require(source.mode == .archive, "Move intent requires exclusive source ownership.")
        try source.validate()
        try Self.require(!sessionIDs.isEmpty && sessionIDs.count <= 128
                         && Set(sessionIDs.compactMap(UUID.init(uuidString:))).count == sessionIDs.count,
                         "Move intent requires distinct source UUIDs.")
        try Self.require(Self.absolute(receipt.path) && receipt.path.utf8.count <= 16_384 && receipt.bytes > 0
                         && receipt.bytes <= 8 * 1024 * 1024 && Self.hash(receipt.sha256), "Invalid receipt fingerprint.")
        let root = try Root(rootURL, excludingSource: DirectoryIdentity(source.identity))
        try Self.require(!root.identities.contains(DirectoryIdentity(source.identity)), "Move intent must survive outside the source.")
        self.root = root; self.source = source; self.checkpoint = checkpoint
        marker = Self.marker(source.identity)
        anchor = Self.anchor(source.identity)
        try Self.requireAbsent(root.fd, marker)
        try Self.requireAbsent(root.fd, anchor)
        current = Record(schemaVersion: 1, operationID: operationID, sourceFolder: source.folderURL.path,
            sourceIdentity: source.identity, sourceSessionIDs: sessionIDs, receipt: receipt, phase: .pending,
            destination: nil, diagnosticCode: nil, observedAt: Date().timeIntervalSince1970)
        currentBytes = try Self.encode(current)
        anchorBytes = currentBytes
        // The immutable anchor survives a removed/replaced mutable marker.
        // It is never renamed or deleted by publication or reconciliation.
        let anchorFD = openat(root.fd, anchor, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        try Self.require(anchorFD >= 0, "Previous archive intent exists or its anchor cannot be created. Retain the source.")
        anchorHandle = FileHandle(fileDescriptor: anchorFD, closeOnDealloc: true)
        let fd = openat(root.fd, marker, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        try Self.require(fd >= 0, "A previous or uncertain archive marker exists, or intent cannot be created. Retain the source.")
        markerHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Never remove a partially written marker on failure. No capability is
        // returned until both file and parent-directory sync have succeeded.
        try checkpoint?(.initialWrite)
        try Self.write(anchorBytes, fd: anchorFD)
        try Self.write(currentBytes, fd: fd)
        try checkpoint?(.fileSync)
        try Self.require(fsync(anchorFD) == 0 && fcntl(anchorFD, F_FULLFSYNC) == 0, "Pending move anchor could not be synchronized.")
        try Self.require(fsync(fd) == 0 && fcntl(fd, F_FULLFSYNC) == 0, "Pending move intent could not be synchronized.")
        try checkpoint?(.directorySync)
        try Self.require(fsync(root.fd) == 0 && fcntl(root.fd, F_FULLFSYNC) == 0, "Pending move intent directory could not be synchronized.")
        try root.validate(); try source.validate(); try requireCurrent()
    }

    var record: Record { lock.withLock { current } }

    /// Record only the destination returned by the actual native move. Recheck
    /// that the original name is absent and the returned directory really is
    /// the original inode. Cross-volume/ambiguous results stay unresolved.
    /// This does not independently certify that a directory is Finder Trash.
    func recordMoved(to destination: URL) throws {
        try lock.withLock {
            try requirePending()
            var old = stat()
            let originalStatus = lstat(current.sourceFolder, &old)
            try Self.require(originalStatus < 0 && errno == ENOENT, "The original pathname still exists or is unreadable; move outcome is uncertain.")
            let target = try Root.openDirectory(destination)
            defer { target.handles.reversed().forEach { try? $0.close() } }
            let state = try Self.state(target.handles.last!.fileDescriptor)
            try Self.require(DirectoryIdentity(state) == DirectoryIdentity(current.sourceIdentity),
                             "The reported destination is not the original source directory.")
            try Root.validateLinks(target.links)
            terminalAttempted = true
            try replace(phase: .moved, destination: destination.path, diagnosticCode: nil)
        }
    }

    /// Failed, interrupted or ambiguous moves never become automatically
    /// retryable, even if the original pathname is currently visible again.
    func recordUncertain(code: String) throws {
        try lock.withLock {
            try requirePending()
            try Self.require(!code.isEmpty && code.utf8.count <= 128
                             && code.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 },
                             "Invalid move diagnostic code.")
            terminalAttempted = true
            try replace(phase: .uncertain, destination: nil, diagnosticCode: code)
        }
    }

    /// Read-only reconciliation input. Pending, partial, malformed and missing
    /// markers are never translated into permission to repeat a move.
    static func inspect(rootURL: URL, sourceIdentity: MeetingFileAccess.Identity) throws -> Record {
        let root = try Root(rootURL, createLease: false), name = marker(sourceIdentity)
        let fd = openat(root.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(fd >= 0, "No readable archive outcome exists.")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let bytes = try read(handle.fileDescriptor)
        try ArchiveSourceJSON.check(bytes)
        let value = try JSONDecoder().decode(Record.self, from: bytes)
        try require(value.schemaVersion == 1 && value.sourceIdentity == sourceIdentity
                    && value.observedAt.isFinite, "Unsupported or mismatched archive outcome.")
        let anchorName = anchor(sourceIdentity)
        let anchorFD = openat(root.fd, anchorName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(anchorFD >= 0, "Archive intent anchor is missing; retain and reconcile the source.")
        let anchorHandle = FileHandle(fileDescriptor: anchorFD, closeOnDealloc: true)
        let anchorBytes = try read(anchorHandle.fileDescriptor)
        try ArchiveSourceJSON.check(anchorBytes)
        let original = try JSONDecoder().decode(Record.self, from: anchorBytes)
        try require(original.phase == .pending && original.destination == nil && original.diagnosticCode == nil
                    && original.schemaVersion == value.schemaVersion && original.operationID == value.operationID
                    && original.sourceFolder == value.sourceFolder && original.sourceIdentity == value.sourceIdentity
                    && original.sourceSessionIDs == value.sourceSessionIDs && original.receipt == value.receipt
                    && original.observedAt.isFinite, "Archive outcome does not match its immutable intent anchor.")
        if value.phase == .pending { try require(value == original, "Pending archive marker was changed.") }
        try link(root.fd, anchorName, anchorFD)
        try link(root.fd, name, fd); try root.validate()
        return value
    }

    private func requirePending() throws {
        try Self.require(current.phase == .pending && !terminalAttempted, "This move already has a terminal or uncertain outcome; do not retry.")
        try requireCurrent()
    }
    private func requireCurrent() throws {
        try root.validate()
        try Self.link(root.fd, anchor, anchorHandle.fileDescriptor)
        try Self.require(try Self.read(anchorHandle.fileDescriptor) == anchorBytes, "The immutable archive intent anchor was changed.")
        try Self.link(root.fd, marker, markerHandle.fileDescriptor)
        try Self.require(try Self.read(markerHandle.fileDescriptor) == currentBytes, "The durable move intent was changed or is incomplete.")
    }
    private func replace(phase: Phase, destination: String?, diagnosticCode: String?) throws {
        let value = Record(schemaVersion: 1, operationID: current.operationID, sourceFolder: current.sourceFolder,
            sourceIdentity: current.sourceIdentity, sourceSessionIDs: current.sourceSessionIDs, receipt: current.receipt,
            phase: phase, destination: destination, diagnosticCode: diagnosticCode, observedAt: Date().timeIntervalSince1970)
        let bytes = try Self.encode(value), temporary = ".outcome-" + UUID().uuidString
        let fd = openat(root.fd, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        try Self.require(fd >= 0, "Archive outcome staging failed; pending intent remains unresolved.")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // An interrupted staging file is harmless and remains for explicit
        // reconciliation. Never broadly delete app-support contents on recovery.
        try Self.write(bytes, fd: fd)
        try checkpoint?(.fileSync)
        try Self.require(fsync(fd) == 0 && fcntl(fd, F_FULLFSYNC) == 0, "Archive outcome could not be synchronized.")
        try requireCurrent(); try Self.link(root.fd, temporary, fd)
        try checkpoint?(.publish)
        try requireCurrent(); try Self.link(root.fd, temporary, fd)
        try checkpoint?(.exchange)
        // Atomically retain whatever inode actually occupies the marker slot.
        // A pre-rename check alone cannot prevent substitution in this window.
        try Self.require(renameatx_np(root.fd, temporary, root.fd, marker, UInt32(RENAME_SWAP)) == 0,
                         "Archive outcome could not be exchanged; immutable intent remains nonretryable.")
        // On mismatch leave BOTH files exactly where the atomic swap put them.
        // Never roll back over a concurrent writer or delete displaced evidence.
        try Self.link(root.fd, temporary, markerHandle.fileDescriptor)
        try Self.require(try Self.read(markerHandle.fileDescriptor) == currentBytes,
                         "The displaced archive marker changed; reconcile both retained files.")
        try checkpoint?(.directorySync)
        try Self.require(fsync(root.fd) == 0 && fcntl(root.fd, F_FULLFSYNC) == 0, "Archive outcome directory synchronization failed; reconcile the actual outcome.")
        try root.validate(); try Self.link(root.fd, marker, fd)
        try Self.link(root.fd, temporary, markerHandle.fileDescriptor)
        try Self.require(try Self.read(markerHandle.fileDescriptor) == currentBytes, "Displaced archive evidence changed during publication.")
        try Self.link(root.fd, anchor, anchorHandle.fileDescriptor)
        try Self.require(try Self.read(anchorHandle.fileDescriptor) == anchorBytes, "Archive intent anchor changed during publication.")
        try Self.require(try Self.read(fd) == bytes, "Archive outcome changed during publication.")
        markerHandle = handle; current = value; currentBytes = bytes
    }

    private struct DirectoryIdentity: Hashable {
        let device: UInt64; let inode: UInt64
        init(_ value: MeetingFileAccess.Identity) { device = value.directoryDevice; inode = value.directoryInode }
        init(_ value: stat) { device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino }
    }
    private final class Root: @unchecked Sendable {
        let handles: [FileHandle]
        let links: [(Int32, String, Int32)]
        let identities: Set<DirectoryIdentity>
        private let lease: FileHandle
        var fd: Int32 { handles.last!.fileDescriptor }
        init(_ url: URL, createLease: Bool = true, excludingSource: DirectoryIdentity? = nil) throws {
            let opened = try Self.openDirectory(url)
            handles = opened.handles; links = opened.links
            let final = try ArchiveMoveJournal.state(handles.last!.fileDescriptor)
            try require(final.st_uid == geteuid() && final.st_mode & 0o777 == 0o700, "Archive journal root must be a private app-owned directory.")
            identities = try Set(handles.map { DirectoryIdentity(try ArchiveMoveJournal.state($0.fileDescriptor)) })
            if let excludingSource { try require(!identities.contains(excludingSource), "Move intent must survive outside the source.") }
            try Self.validateLinks(links)
            let descriptor = openat(handles.last!.fileDescriptor, ".archive-owner.lock", O_RDWR | (createLease ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            try require(descriptor >= 0, "Archive journal ownership is unavailable.")
            lease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try regular(try ArchiveMoveJournal.state(descriptor))
            try require(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Another actual archive operation still owns the journal.")
            try validate()
        }
        func validate() throws {
            try Self.validateLinks(links); try link(fd, ".archive-owner.lock", lease.fileDescriptor)
            let value = try ArchiveMoveJournal.state(fd)
            try require(value.st_uid == geteuid() && value.st_mode & 0o777 == 0o700, "Archive journal privacy changed.")
            try regular(try ArchiveMoveJournal.state(lease.fileDescriptor))
        }
        static func openDirectory(_ url: URL) throws -> (handles: [FileHandle], links: [(Int32, String, Int32)]) {
            try require(absolute(url.path) && url.path.utf8.count <= 16_384, "Invalid canonical archive path.")
            let descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            try require(descriptor >= 0, "Filesystem root is unavailable.")
            var handles = [FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)], links: [(Int32, String, Int32)] = []
            for name in url.path.split(separator: "/").map(String.init) {
                let parent = handles.last!.fileDescriptor
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(child >= 0, "Archive path is missing or traverses a symbolic link.")
                handles.append(FileHandle(fileDescriptor: child, closeOnDealloc: true)); links.append((parent, name, child))
                try link(parent, name, child)
            }
            return (handles, links)
        }
        static func validateLinks(_ links: [(Int32, String, Int32)]) throws {
            for (parent, name, child) in links { try link(parent, name, child) }
        }
    }
    private static func anchor(_ identity: MeetingFileAccess.Identity) -> String { "source-\(identity.directoryDevice)-\(identity.directoryInode).anchor.json" }
    private static func requireAbsent(_ parent: Int32, _ name: String) throws {
        var existing = stat()
        let result = fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW)
        try require(result < 0 && errno == ENOENT, "Previous or uncertain archive intent exists. Retain the source; never retry automatically.")
    }
    private static func marker(_ identity: MeetingFileAccess.Identity) -> String { "source-\(identity.directoryDevice)-\(identity.directoryInode).json" }
    private static func encode(_ value: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value); try require(data.count <= limit, "Archive intent exceeds its bound."); return data
    }
    private static func read(_ fd: Int32) throws -> Data {
        let before = try state(fd); try regular(before)
        try require(before.st_size >= 0 && before.st_size <= limit, "Archive marker exceeds its bound.")
        var data = Data(), offset: off_t = 0, buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = pread(fd, &buffer, buffer.count, offset)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0 && count <= limit - data.count, "Archive marker read failed or grew.")
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count)); offset += off_t(count)
        }
        let after = try state(fd); try regular(after)
        try require(Int64(data.count) == before.st_size && before.st_size == after.st_size
                    && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                    && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                    "Archive marker changed during read.")
        return data
    }
    private static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                try require(written > 0, "Archive intent write failed."); offset += written
            }
        }
    }
    private static func regular(_ value: stat) throws {
        try require(value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1 && value.st_uid == geteuid()
                    && value.st_mode & 0o777 == 0o600, "Archive ownership/evidence must be a private single-link regular file.")
    }
    private static func state(_ fd: Int32) throws -> stat { var value = stat(); try require(fstat(fd, &value) == 0, "Archive descriptor is unavailable."); return value }
    private static func link(_ parent: Int32, _ name: String, _ fd: Int32) throws {
        let value = try state(fd); var named = stat()
        try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && value.st_dev == named.st_dev
                    && value.st_ino == named.st_ino && value.st_mode & S_IFMT == named.st_mode & S_IFMT, "Archive path identity changed.")
    }
    private static func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
}
