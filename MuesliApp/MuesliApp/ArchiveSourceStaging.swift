import Foundation
import Darwin

/// Durable intent must precede stage(). A raced replacement is preserved in
/// private staging and must never be sent to Trash unless its complete native
/// identity/inventory matches the already verified original.
nonisolated final class ArchiveSourceStaging: @unchecked Sendable {
    let directory: ArchiveOutputBundle.Directory
    let stagedURL: URL
    private let parent: ArchiveOutputBundle.Directory
    private let originalName: String
    private let lease: FileHandle
    private let access: MeetingFileAccess

    init(source: MeetingFileAccess, originalURL: URL, operationID: UUID) throws {
        try source.validate(); try source.validateRelocated(to: originalURL)
        access = source; originalName = originalURL.lastPathComponent
        parent = try ArchiveOutputBundle.Directory(existing: originalURL.deletingLastPathComponent(),
            excludingSource: .init(source.identity), requirePrivate: false)
        var parentInfo = stat()
        guard fstat(parent.fd, &parentInfo) == 0,
              UInt64(UInt32(bitPattern: parentInfo.st_dev)) == source.identity.directoryDevice else {
            throw ArchiveOutputBundle.Failure(message: "Native staging must remain on the source volume.")
        }
        directory = try parent.createDirectory(".muesli-archive-" + operationID.uuidString.lowercased() + "-" + UUID().uuidString.lowercased())
        stagedURL = URL(fileURLWithPath: directory.path + "/source")
        let fd = openat(directory.fd, ".stage-owner.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveOutputBundle.Failure(message: "Native staging ownership is unavailable.") }
        lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0,
              fsync(directory.fd) == 0, fcntl(directory.fd, F_FULLFSYNC) == 0 else {
            throw ArchiveOutputBundle.Failure(message: "Native staging ownership could not be durably established.")
        }
        try validate()
    }
    func validate() throws {
        try parent.validate(); try directory.validate()
        var named = stat(), owned = stat()
        guard fstat(lease.fileDescriptor, &owned) == 0,
              fstatat(directory.fd, ".stage-owner.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == owned.st_dev, named.st_ino == owned.st_ino,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1, named.st_uid == geteuid(),
              named.st_mode & 0o777 == 0o600 else {
            throw ArchiveOutputBundle.Failure(message: "Native staging ownership changed.")
        }
    }
    /// afterValidation is a synthetic race checkpoint, absent from production.
    func stage(journal: ArchiveMoveJournal, afterValidation: (@Sendable () throws -> Void)? = nil) throws -> ArchiveSourceInventory.Snapshot {
        let intent = journal.record
        guard intent.phase == .pending, intent.sourceIdentity == access.identity,
              intent.plannedStagingPath == stagedURL.path else {
            throw ArchiveOutputBundle.Failure(message: "Source staging requires its actual durable pending journal.")
        }
        try journal.validatePending()
        try validate(); try access.validate()
        try afterValidation?()
        guard renameatx_np(parent.fd, originalName, directory.fd, "source", UInt32(RENAME_EXCL)) == 0 else {
            throw ArchiveOutputBundle.Failure(message: "Native source staging failed; reconcile the durable intent.")
        }
        // Do not roll back over a new pathname occupant or delete captured
        // unexpected material. Both parent namespaces are synchronized first.
        guard fsync(parent.fd) == 0, fcntl(parent.fd, F_FULLFSYNC) == 0,
              fsync(directory.fd) == 0, fcntl(directory.fd, F_FULLFSYNC) == 0 else {
            throw ArchiveOutputBundle.Failure(message: "Native source staging synchronization is uncertain.")
        }
        try validate(); try access.validateRelocated(to: stagedURL)
        return try ArchiveSourceInventory.captureRelocated(access: access, at: stagedURL)
    }
}
