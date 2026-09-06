import Foundation
import CryptoKit
import Darwin

/// Owns native artifacts outside the source. Names are exclusively created,
/// never overwritten or swept. No source lease is retained after preparation.
nonisolated final class ArchiveOutputBundle: @unchecked Sendable {
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    struct Identity: Equatable, Sendable {
        let device: UInt64; let inode: UInt64
        init(_ value: stat) { device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino }
        init(_ value: MeetingFileAccess.Identity) { device = value.directoryDevice; inode = value.directoryInode }
    }
    struct CapturedReceipt: Sendable {
        let receipt: ArchiveReceipt
        let file: ArchiveReceipt.FileRecord
        let bytes: Data
    }
    let directory: Directory
    let operationID: UUID
    let receiptPath: String
    private let lease: FileHandle
    private var nativeFiles: [String: OwnedFile] = [:]
    private var validationSnapshots: [ValidationSnapshot] = []
    private var snapshotAttempts = 0
    private var snapshotBytes: Int64 = 0
    private let lock = NSLock()
    private static let maximumSnapshotBytes: Int64 = 512 * 1024 * 1024
    private static let maximumManifestBytes = 8 * 1024 * 1024

    convenience init(rootURL: URL, sourceIdentity: MeetingFileAccess.Identity, operationID: UUID) throws {
        try self.init(root: Directory(existing: rootURL, excludingSource: Identity(sourceIdentity)), sourceIdentity: sourceIdentity, operationID: operationID)
    }
    init(root: Directory, sourceIdentity: MeetingFileAccess.Identity, operationID: UUID) throws {
        self.operationID = operationID
        try root.validate()
        directory = try root.createDirectory(operationID.uuidString.lowercased())
        receiptPath = directory.path + "/receipt.json"
        let descriptor = openat(directory.fd, ".native-owner.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try Self.require(descriptor >= 0, "Native output ownership cannot be created.")
        lease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try Self.require(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Native output ownership is unavailable.")
        try Self.synchronize(descriptor); try Self.synchronize(directory.fd)
        let anchor = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "operation_id": operationID.uuidString.lowercased(),
            "source_directory_device": sourceIdentity.directoryDevice, "source_directory_inode": sourceIdentity.directoryInode
        ], options: [.sortedKeys])
        nativeFiles[".native-anchor.json"] = try directory.writeExclusive(".native-anchor.json", bytes: anchor)
        try validate()
    }

    /// Used only while the retained prepare worker owns this new bundle.
    func writeNative(_ name: String, bytes: Data, maximumBytes: Int) throws -> ArchiveReceipt.FileRecord {
        try lock.withLock {
            try Self.require(["processing-events.jsonl", "native-diagnostics.json", "native-manifest.json"].contains(name)
                             && nativeFiles[name] == nil && bytes.count <= maximumBytes,
                             "Native artifact name, size or prior publication is invalid.")
            try validateUnlocked()
            let file = try directory.writeExclusive(name, bytes: bytes)
            nativeFiles[name] = file
            return file.record
        }
    }
    func validate() throws { try lock.withLock { try validateUnlocked() } }
    private func validateUnlocked() throws {
        try directory.validate()
        try Self.link(directory.fd, ".native-owner.lock", lease.fileDescriptor)
        try Self.regular(Self.state(lease.fileDescriptor), privateMode: true)
        for file in nativeFiles.values { try file.validate() }
        for snapshot in validationSnapshots { try snapshot.validate() }
    }
    var nativePaths: Set<String> { lock.withLock { Set(nativeFiles.values.map(\.record.path)) } }

    func readReceipt(at path: String) throws -> CapturedReceipt {
        try validate()
        try Self.require(path == receiptPath, "The receipt must use the native manifest's exact destination.")
        let file = try directory.readExisting("receipt.json", maximumBytes: Self.maximumManifestBytes)
        let bytes = try file.read(maximumBytes: Self.maximumManifestBytes)
        try ArchiveSourceJSON.check(bytes)
        let receipt = try ArchiveReceipt.decode(bytes)
        try Self.require(receipt.operationID == operationID, "The receipt belongs to another native operation.")
        return CapturedReceipt(receipt: receipt, file: file.record, bytes: bytes)
    }

    /// Preserve exact validated output bytes in durable, exclusively created
    /// native files. Live vault notes remain editable: this is not a multi-file
    /// atomic snapshot. Callers revalidate the live inputs again before pending.
    func snapshot(_ captured: CapturedReceipt) throws -> ArchiveReceipt.FileRecord {
        let outputs = captured.receipt.outputs
        var reservation = Int64(captured.bytes.count + Self.maximumManifestBytes)
        for output in outputs {
            try Self.require(output.file.bytes >= 0 && output.file.bytes <= Self.maximumSnapshotBytes - reservation,
                             "Native validation copies exceed their bounded byte budget.")
            reservation += output.file.bytes
        }
        let snapshot: Directory = try lock.withLock {
            try validateUnlocked()
            try Self.require(snapshotAttempts < 2 && reservation <= Self.maximumSnapshotBytes - snapshotBytes,
                             "Native validation attempts or retained bytes exceed their limit; retain this source for review.")
            snapshotAttempts += 1; snapshotBytes += reservation
            return try directory.createDirectory("validation-" + UUID().uuidString.lowercased())
        }
        var records: [[String: Any]] = []
        var observations: [FileObservation] = []
        let receipt = try snapshot.writeExclusive("receipt.json", bytes: captured.bytes)
        observations.append(receipt.observation)
        records.append(["role": "receipt", "original_path": captured.file.path, "snapshot_path": receipt.record.path,
                        "bytes": receipt.record.bytes, "sha256": receipt.record.sha256])
        for (index, output) in outputs.enumerated() {
            // This reader independently binds bytes to no-follow original file
            // identity while reading. The earlier declared size is only a cap.
            let bytes = try ArchiveReceipt.readVerifiedData(output.file, maximumBytes: output.file.bytes)
            let copy = try snapshot.writeExclusive(String(format: "output-%04d.bin", index), bytes: bytes)
            try Self.require(copy.record.bytes == output.file.bytes && copy.record.sha256 == output.file.sha256,
                             "The preserved validation bytes do not match the verified output.")
            observations.append(copy.observation)
            records.append(["role": output.role.rawValue, "original_path": output.file.path,
                            "snapshot_path": copy.record.path, "bytes": copy.record.bytes, "sha256": copy.record.sha256])
        }
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "operation_id": operationID.uuidString.lowercased(), "files": records
        ], options: [.sortedKeys])
        try Self.require(manifest.count <= Self.maximumManifestBytes, "Native validation manifest exceeds its limit.")
        let manifestFile = try snapshot.writeExclusive("snapshot.json", bytes: manifest)
        observations.append(manifestFile.observation)
        let preserved = ValidationSnapshot(directory: snapshot, files: observations)
        try preserved.validate()
        lock.withLock { validationSnapshots.append(preserved) }
        try snapshot.validate(); try validate()
        let current = try readReceipt(at: captured.file.path)
        try Self.require(current.file == captured.file && current.bytes == captured.bytes, "Receipt changed while validation bytes were preserved.")
        return manifestFile.record
    }

    /// Keep only directory ownership and bounded plain observations for copied
    /// files; retaining thousands of file descriptors would exhaust admission.
    struct FileObservation: Sendable {
        let name: String; let identity: Identity; let record: ArchiveReceipt.FileRecord
    }
    private struct ValidationSnapshot: Sendable {
        let directory: Directory; let files: [FileObservation]
        func validate() throws {
            try directory.validate()
            for expected in files {
                let file = try directory.readExisting(expected.name, maximumBytes: Int(expected.record.bytes))
                try ArchiveOutputBundle.require(file.observation.identity == expected.identity && file.record == expected.record,
                                                "Preserved native validation bytes or identity changed.")
                try file.validate()
            }
            try directory.validate()
        }
    }

    /// Existing canonical private directory; parents and identities remain
    /// held through every write. Source ancestry is rejected before any create.
    final class Directory: @unchecked Sendable {
        let path: String
        private let handles: [FileHandle]
        private let links: [(Int32, String, Int32)]
        private let excludedSource: Identity
        private let requirePrivate: Bool
        var fd: Int32 { handles.last!.fileDescriptor }
        init(existing url: URL, excludingSource: Identity, requirePrivate: Bool = true) throws {
            path = url.path; excludedSource = excludingSource
            self.requirePrivate = requirePrivate
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
            try ArchiveOutputBundle.require(path.hasPrefix("/") && path.utf8.count <= 4096 && !parts.isEmpty
                    && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }, "Native output path is not canonical.")
            let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            try ArchiveOutputBundle.require(root >= 0, "Filesystem root is unavailable.")
            var held = [FileHandle(fileDescriptor: root, closeOnDealloc: true)], linked: [(Int32,String,Int32)] = []
            for name in parts {
                let parent = held.last!.fileDescriptor
                let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try ArchiveOutputBundle.require(next >= 0, "Native output path is missing or traverses a symbolic link.")
                held.append(FileHandle(fileDescriptor: next, closeOnDealloc: true)); linked.append((parent,name,next))
                try ArchiveOutputBundle.require(Identity(ArchiveOutputBundle.state(next)) != excludingSource,
                                                "Native output must survive outside the original source.")
                try ArchiveOutputBundle.link(parent, name, next)
            }
            handles = held; links = linked
            try validate()
        }
        private init(parent: Directory, name: String, child: FileHandle) {
            path = parent.path + "/" + name; excludedSource = parent.excludedSource
            requirePrivate = true
            handles = parent.handles + [child]; links = parent.links + [(parent.fd, name, child.fileDescriptor)]
        }
        func validate() throws {
            for (parent,name,child) in links {
                try ArchiveOutputBundle.link(parent, name, child)
                try ArchiveOutputBundle.require(Identity(ArchiveOutputBundle.state(child)) != excludedSource, "Native output ancestry changed into the source.")
            }
            let value = try ArchiveOutputBundle.state(fd)
            try ArchiveOutputBundle.require(value.st_uid == geteuid() && (!requirePrivate || value.st_mode & 0o777 == 0o700),
                                            "Native output directory must remain private and user-owned.")
        }
        func createDirectory(_ name: String) throws -> Directory {
            try Self.component(name); try validate()
            try ArchiveOutputBundle.require(mkdirat(fd, name, 0o700) == 0, "Native output directory already exists or cannot be created.")
            let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try ArchiveOutputBundle.require(descriptor >= 0, "Native output directory cannot be admitted.")
            let child = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try ArchiveOutputBundle.link(fd, name, descriptor)
            let created = Directory(parent: self, name: name, child: child)
            try created.validate(); try ArchiveOutputBundle.synchronize(fd)
            return created
        }
        func writeExclusive(_ name: String, bytes: Data) throws -> OwnedFile {
            try Self.component(name); try validate()
            let descriptor = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try ArchiveOutputBundle.require(descriptor >= 0, "Native output already exists or cannot be created.")
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try ArchiveOutputBundle.write(bytes, fd: descriptor)
            try ArchiveOutputBundle.synchronize(descriptor); try ArchiveOutputBundle.synchronize(fd)
            let record = ArchiveReceipt.FileRecord(path: path + "/" + name, bytes: Int64(bytes.count), sha256: ArchiveOutputBundle.hash(bytes))
            let result = try OwnedFile(directory: self, name: name, handle: handle, record: record, privateMode: true)
            try result.validate(); return result
        }
        func readExisting(_ name: String, maximumBytes: Int) throws -> OwnedFile {
            try Self.component(name); try validate()
            let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            try ArchiveOutputBundle.require(descriptor >= 0, "Expected output is unavailable.")
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let bytes = try ArchiveOutputBundle.read(descriptor, maximumBytes: maximumBytes, privateMode: false)
            let record = ArchiveReceipt.FileRecord(path: path + "/" + name, bytes: Int64(bytes.count), sha256: ArchiveOutputBundle.hash(bytes))
            return try OwnedFile(directory: self, name: name, handle: handle, record: record, privateMode: false)
        }
        private static func component(_ value: String) throws {
            try ArchiveOutputBundle.require(!value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".."
                                             && !value.contains("/") && !value.contains("\0"), "Invalid native output name.")
        }
    }
    final class OwnedFile: @unchecked Sendable {
        let record: ArchiveReceipt.FileRecord
        private let directory: Directory
        private let name: String
        private let handle: FileHandle
        private let identity: Identity
        private let privateMode: Bool
        init(directory: Directory, name: String, handle: FileHandle, record: ArchiveReceipt.FileRecord, privateMode: Bool) throws {
            self.directory = directory; self.name = name; self.handle = handle; self.record = record; self.privateMode = privateMode
            identity = Identity(try ArchiveOutputBundle.state(handle.fileDescriptor))
            try ArchiveOutputBundle.link(directory.fd, name, handle.fileDescriptor)
        }
        var observation: FileObservation { .init(name: name, identity: identity, record: record) }
        func validate() throws { _ = try read(maximumBytes: Int(record.bytes)) }
        func read(maximumBytes: Int) throws -> Data {
            try directory.validate()
            try ArchiveOutputBundle.link(directory.fd, name, handle.fileDescriptor)
            try ArchiveOutputBundle.require(Identity(ArchiveOutputBundle.state(handle.fileDescriptor)) == identity, "Native file identity changed.")
            let bytes = try ArchiveOutputBundle.read(handle.fileDescriptor, maximumBytes: maximumBytes, privateMode: privateMode)
            try ArchiveOutputBundle.require(Int64(bytes.count) == record.bytes && ArchiveOutputBundle.hash(bytes) == record.sha256, "Native output bytes changed.")
            try ArchiveOutputBundle.link(directory.fd, name, handle.fileDescriptor); try directory.validate()
            return bytes
        }
    }
    private static func read(_ fd: Int32, maximumBytes: Int, privateMode: Bool) throws -> Data {
        let before = try state(fd); try regular(before, privateMode: privateMode)
        try require(before.st_size >= 0 && before.st_size <= maximumBytes, "Native output exceeds its read bound.")
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536), offset: off_t = 0
        while true {
            let count = pread(fd, &buffer, buffer.count, offset)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0 && count <= maximumBytes - bytes.count, "Native output read failed or grew.")
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count)); offset += off_t(count)
        }
        let after = try state(fd); try regular(after, privateMode: privateMode)
        try require(before.st_size == bytes.count && before.st_size == after.st_size
                    && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                    && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, "Native output changed during read.")
        return bytes
    }
    private static func write(_ bytes: Data, fd: Int32) throws {
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, "Native output write failed."); offset += count
            }
        }
    }
    private static func regular(_ value: stat, privateMode: Bool) throws {
        try require(value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1 && value.st_uid == geteuid()
                    && (!privateMode || value.st_mode & 0o777 == 0o600), "Native output is not an admitted regular file.")
    }
    private static func state(_ fd: Int32) throws -> stat { var value = stat(); try require(fstat(fd, &value) == 0, "Native descriptor unavailable."); return value }
    private static func link(_ parent: Int32, _ name: String, _ child: Int32) throws {
        let opened = try state(child); var named = stat()
        try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
                    && named.st_mode & S_IFMT == opened.st_mode & S_IFMT, "Native output path identity changed.")
    }
    private static func synchronize(_ fd: Int32) throws { try require(fsync(fd) == 0 && fcntl(fd, F_FULLFSYNC) == 0, "Native output could not be durably synchronized.") }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
}
