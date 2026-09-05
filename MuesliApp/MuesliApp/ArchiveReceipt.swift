import Foundation
import CryptoKit
import Darwin

/// The machine-readable successor to the prose-only Merge receipt. This type
/// verifies a handoff; it never grants a move or opens an archive lease. The
/// native archive owner must separately prove source eligibility and retain
/// all leases through revalidation, durable pending state and the actual move.
nonisolated struct ArchiveReceipt: Codable, Equatable, Sendable {
    struct FileRecord: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    struct Source: Codable, Equatable, Sendable {
        let folder: String
        let directoryDevice: UInt64
        let directoryInode: UInt64
        /// Exact, complete relative file inventory, excluding only protocol
        /// lock files. Source semantic validation is a separate prerequisite.
        let files: [FileRecord]
        let sessionIDs: [String]
        enum CodingKeys: String, CodingKey {
            case folder, files
            case directoryDevice = "directory_device", directoryInode = "directory_inode", sessionIDs = "session_ids"
        }
    }
    struct Output: Codable, Equatable, Sendable {
        enum Role: String, Codable, CaseIterable, Sendable {
            case rawNote = "raw_note", officialNote = "official_note", redactionReport = "redaction_report"
            case speakerProvenance = "speaker_provenance", reprocessEvents = "reprocess_events"
            case reprocessDiagnostics = "reprocess_diagnostics", attachment
        }
        let role: Role
        let file: FileRecord
        let noteID: String?
        enum CodingKeys: String, CodingKey { case role, file; case noteID = "note_id" }
    }
    struct Checks: Codable, Equatable, Sendable {
        let reprocessExitCode: Int
        let finalResultCount: Int
        let errorEventCount: Int
        let coveredSessionIDs: [String]
        let deterministicRedactionsVerified: Bool
        let imageLinksVerified: Bool
        let sourceIntegrityProblems: [String]
        enum CodingKeys: String, CodingKey {
            case reprocessExitCode = "reprocess_exit_code", finalResultCount = "final_result_count"
            case errorEventCount = "error_event_count", coveredSessionIDs = "covered_session_ids"
            case deterministicRedactionsVerified = "deterministic_redactions_verified"
            case imageLinksVerified = "image_links_verified", sourceIntegrityProblems = "source_integrity_problems"
        }
    }
    enum Cleanup: String, Codable, Sendable { case retained, pending, trashed, uncertain }
    let schemaVersion: Int
    let operationID: UUID
    let source: Source
    let outputs: [Output]
    let checks: Checks
    let cleanup: Cleanup
    enum CodingKeys: String, CodingKey {
        case source, outputs, checks, cleanup
        case schemaVersion = "schema_version", operationID = "operation_id"
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func decode(_ data: Data) throws -> ArchiveReceipt {
        try require(data.count <= 8 * 1024 * 1024, "The handoff receipt exceeds its size limit.")
        let value = try JSONDecoder().decode(Self.self, from: data)
        try require(value.schemaVersion == 2, "This handoff receipt version cannot authorize automatic cleanup.")
        return value
    }

    /// `currentSource` must come from a fresh exhaustive inventory under an
    /// exclusive archive lease, after independent closed/loss-free validation.
    /// These receipt checks cannot establish those facts on their own.
    func validate(currentSource: Source, receiptURL: URL) throws {
        try Self.require(schemaVersion == 2 && cleanup == .retained,
                         "Cleanup is already pending, uncertain or completed, or uses an unsupported receipt version.")
        try Self.require(Self.absolute(source.folder), "The source folder is not a canonical absolute path.")
        try Self.require(source.directoryInode > 0 && source.directoryDevice > 0,
                         "The source folder identity is missing.")
        try Self.require(!source.files.isEmpty && source.files.count <= 100_000,
                         "The receipt has no complete bounded source inventory.")
        try Self.require(Set(source.files.map(\.path)).count == source.files.count,
                         "The source inventory contains duplicate paths.")
        for file in source.files {
            try Self.require(Self.relative(file.path) && Self.fingerprint(file), "A source file fingerprint is malformed.")
        }
        try Self.require(!source.sessionIDs.isEmpty && source.sessionIDs.count <= 10_000
                         && source.sessionIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
                         && Set(source.sessionIDs).count == source.sessionIDs.count,
                         "The source session inventory is missing or ambiguous.")
        // Order has no significance; every file and session must agree.
        try Self.require(source.folder == currentSource.folder
                         && source.directoryDevice == currentSource.directoryDevice
                         && source.directoryInode == currentSource.directoryInode
                         && source.files.sorted(by: { $0.path < $1.path }) == currentSource.files.sorted(by: { $0.path < $1.path })
                         && source.sessionIDs.sorted() == currentSource.sessionIDs.sorted(),
                         "The original source inventory changed or contains omitted material.")
        try Self.require(checks.reprocessExitCode == 0 && checks.finalResultCount == 1
                         && checks.errorEventCount == 0 && checks.sourceIntegrityProblems.isEmpty
                         && checks.deterministicRedactionsVerified && checks.imageLinksVerified
                         && checks.coveredSessionIDs.sorted() == source.sessionIDs.sorted(),
                         "One or more required handoff checks failed or did not cover every source session.")
        let receiptPath = receiptURL.path
        try Self.require(Self.absolute(receiptPath) && !Self.inside(receiptPath, source.folder),
                         "The receipt must remain outside the source folder.")
        let sourceIdentity = FileIdentity(device: source.directoryDevice, inode: source.directoryInode)
        let storedReceipt = try Self.readSnapshot(at: receiptURL, maximumBytes: 8 * 1024 * 1024, captureBytes: true)
        try Self.require(!storedReceipt.ancestors.contains(sourceIdentity),
                         "The receipt is physically inside the source folder.")
        try Self.require(try Self.decode(storedReceipt.data) == self,
                         "The persisted receipt differs from the validated handoff.")
        var outputIdentities: Set<FileIdentity> = [storedReceipt.identity]
        try Self.require(outputs.count >= 6 && outputs.count <= 4096
                         && Set(outputs.map { $0.file.path }).count == outputs.count,
                         "The output inventory is incomplete or contains duplicate paths.")
        let noteRoles: Set<Output.Role> = [.rawNote, .officialNote, .redactionReport]
        let noteIDs = Set(outputs.filter { noteRoles.contains($0.role) }.compactMap(\.noteID))
        try Self.require(!noteIDs.isEmpty && noteIDs.count <= 256
                         && noteIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 },
                         "The note groups are missing or invalid.")
        for noteID in noteIDs {
            for role in noteRoles {
                try Self.require(outputs.filter { $0.role == role && $0.noteID == noteID }.count == 1,
                                 "Each note must have one raw copy, official copy and redaction report.")
            }
        }
        for role in Output.Role.allCases where !noteRoles.contains(role) && role != .attachment {
            try Self.require(outputs.filter { $0.role == role && $0.noteID == nil }.count == 1
                             && outputs.filter { $0.role == role }.count == 1,
                             "The receipt must contain exactly one shared \(role.rawValue) output.")
        }
        for output in outputs {
            try Self.require(!noteRoles.contains(output.role) || output.noteID != nil,
                             "A required note output has no group identity.")
            if let noteID = output.noteID {
                try Self.require(noteIDs.contains(noteID), "An attachment refers to an unknown note group.")
            }
        }
        for output in outputs {
            let file = output.file
            try Self.require(Self.absolute(file.path) && !Self.inside(file.path, source.folder)
                             && file.path != receiptPath && Self.fingerprint(file),
                             "An output path or fingerprint is invalid, aliases the receipt, or lies inside the source.")
            if output.role != .reprocessDiagnostics {
                try Self.require(file.bytes > 0, "A required handoff output is empty.")
            }
            let actual = try Self.readSnapshot(at: URL(fileURLWithPath: file.path), maximumBytes: file.bytes)
            try Self.require(!actual.ancestors.contains(sourceIdentity), "A handoff output is physically inside the source folder.")
            try Self.require(outputIdentities.insert(actual.identity).inserted,
                             "Handoff outputs or the receipt alias the same physical file.")
            try Self.require(actual.record == file, "A saved handoff output no longer matches its receipt.")
        }
    }

    private static func relative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func absolute(_ path: String) -> Bool { path.hasPrefix("/") && relative(String(path.dropFirst())) }
    private static func inside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
    private static func fingerprint(_ value: FileRecord) -> Bool {
        value.bytes >= 0 && value.sha256.utf8.count == 64
            && value.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Bounded-memory hashing with no symlink traversal, special-file reads or
    /// hard-linked outputs. All descriptors stay open until identity and size
    /// are checked again. The caller retains its actual operation across waits.
    static func readFingerprint(at url: URL, maximumBytes: Int64) throws -> FileRecord {
        try readSnapshot(at: url, maximumBytes: maximumBytes).record
    }
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
        init(_ value: stat) { device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino) }
    }
    private struct Snapshot {
        let record: FileRecord
        let identity: FileIdentity
        let ancestors: Set<FileIdentity>
        let data: Data
    }
    private static func readSnapshot(at url: URL, maximumBytes: Int64, captureBytes: Bool = false) throws -> Snapshot {
        let path = url.path
        try require(absolute(path) && maximumBytes >= 0, "The output path or size limit is invalid.")
        let components = path.split(separator: "/").map(String.init)
        var descriptors: [Int32] = []
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw Failure(message: "Could not open the filesystem root.") }
        descriptors.append(root)
        var links: [(Int32, String, Int32)] = []
        for (index, component) in components.enumerated() {
            let parent = descriptors.last!
            let directory = index < components.count - 1
            let descriptor = openat(parent, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw Failure(message: "A handoff output is unavailable or traverses a symbolic link.") }
            descriptors.append(descriptor)
            links.append((parent, component, descriptor))
        }
        let descriptor = descriptors.last!
        var before = stat()
        try require(fstat(descriptor, &before) == 0 && before.st_mode & S_IFMT == S_IFREG
                    && before.st_nlink == 1 && before.st_size >= 0 && before.st_size <= maximumBytes,
                    "A handoff output is not an independent regular file of the expected size.")
        var hasher = SHA256()
        var data = Data()
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let size = Darwin.read(descriptor, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            try require(size >= 0, "A handoff output could not be read.")
            if size == 0 { break }
            try require(Int64(size) <= maximumBytes - count, "A handoff output grew during validation.")
            count += Int64(size)
            let chunk = Data(buffer.prefix(size))
            hasher.update(data: chunk)
            if captureBytes { data.append(chunk) }
        }
        var after = stat()
        try require(fstat(descriptor, &after) == 0 && count == before.st_size && before.st_size == after.st_size
                    && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                    && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                    && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                    && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec && after.st_nlink == 1,
                    "A handoff output changed during validation.")
        var ancestors: Set<FileIdentity> = []
        for descriptor in descriptors.dropLast() {
            var value = stat()
            try require(fstat(descriptor, &value) == 0, "An output ancestor is unavailable.")
            ancestors.insert(FileIdentity(value))
        }
        for (parent, name, child) in links {
            var named = stat(); var opened = stat()
            try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && fstat(child, &opened) == 0
                        && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino,
                        "A handoff output path changed during validation.")
        }
        return Snapshot(record: FileRecord(path: path, bytes: count,
                                           sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()),
                        identity: FileIdentity(after), ancestors: ancestors, data: data)
    }
}
