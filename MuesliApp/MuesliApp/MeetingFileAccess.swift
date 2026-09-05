import Foundation
import Darwin

/// Cooperative archive exclusion. Acquire on the original file worker, before
/// any reads or writes. References transfer ownership; there is no early unlock
/// for a caller deadline. Archive acquires EX directly, never upgrades SH.
nonisolated final class MeetingFileAccess: @unchecked Sendable {
    enum Mode: Sendable { case shared, archive }
    struct Identity: Codable, Sendable, Equatable {
        let directoryDevice: UInt64
        let directoryInode: UInt64
        let lockDevice: UInt64
        let lockInode: UInt64
    }
    enum Failure: Error, LocalizedError {
        case busy, changed, invalid
        var errorDescription: String? {
            switch self {
            case .busy: return "This meeting is still in use by a file operation or archive."
            case .changed: return "The meeting folder changed during file admission. Reopen it before trying again."
            case .invalid: return "The meeting ownership file is not a private regular file."
            }
        }
    }
    static let accessName = ".meeting-access.lock"
    static let transactionName = ".meeting-transaction.lock"
    let folderURL: URL
    let identity: Identity
    let mode: Mode
    private let directory: FileHandle
    private let handle: FileHandle

    private init(folder: URL, mode: Mode, directory: FileHandle, handle: FileHandle) throws {
        folderURL = folder; self.mode = mode; self.directory = directory; self.handle = handle
        var folderState = stat(), lockState = stat()
        guard fstat(directory.fileDescriptor, &folderState) == 0, fstat(handle.fileDescriptor, &lockState) == 0 else {
            throw Self.posixError()
        }
        identity = Identity(directoryDevice: UInt64(folderState.st_dev), directoryInode: folderState.st_ino,
                            lockDevice: UInt64(lockState.st_dev), lockInode: lockState.st_ino)
        try validate()
    }

    static func acquire(in folder: URL, mode: Mode = .shared,
                        afterOpen: (@Sendable () throws -> Void)? = nil) throws -> MeetingFileAccess {
        let folder = folder.standardizedFileURL
        // Never recreate a moved meeting. A final-component symlink is not a
        // meeting identity, even when its target currently looks plausible.
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let directory = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let handle = try openLock(accessName, directory: fd)
        try afterOpen?()
        try lock(handle, exclusive: mode == .archive)
        return try MeetingFileAccess(folder: folder, mode: mode, directory: directory, handle: handle)
    }

    /// Recheck after admission, including the case where the original folder
    /// was moved and another folder now occupies its old pathname.
    func validate() throws {
        var current = stat(), lockState = stat()
        guard lstat(folderURL.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              UInt64(current.st_dev) == identity.directoryDevice, current.st_ino == identity.directoryInode,
              fstatat(directory.fileDescriptor, Self.accessName, &lockState, AT_SYMLINK_NOFOLLOW) == 0,
              lockState.st_mode & S_IFMT == S_IFREG,
              UInt64(lockState.st_dev) == identity.lockDevice, lockState.st_ino == identity.lockInode else {
            throw Failure.changed
        }
    }

    /// Serialization is separate from archive exclusion: capture may keep an
    /// SH access reference while its finalizer owns this EX transaction scope.
    func transaction() throws -> Transaction {
        try validate()
        let handle = try Self.openLock(Self.transactionName, directory: directory.fileDescriptor)
        try Self.lock(handle, exclusive: true)
        var owned = stat(), current = stat()
        guard fstat(handle.fileDescriptor, &owned) == 0,
              fstatat(directory.fileDescriptor, Self.transactionName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              owned.st_dev == current.st_dev, owned.st_ino == current.st_ino else { throw Failure.changed }
        try validate()
        return Transaction(access: self, handle: handle)
    }

    final class Transaction: Sendable {
        let access: MeetingFileAccess
        private let handle: FileHandle
        fileprivate init(access: MeetingFileAccess, handle: FileHandle) { self.access = access; self.handle = handle }
    }

    private static func openLock(_ name: String, directory: Int32) throws -> FileHandle {
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_uid == geteuid() else { throw Failure.invalid }
        return handle
    }
    private static func lock(_ handle: FileHandle, exclusive: Bool) throws {
        guard flock(handle.fileDescriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
            throw posixError()
        }
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
