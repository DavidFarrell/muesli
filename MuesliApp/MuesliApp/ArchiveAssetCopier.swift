import Foundation
import Darwin
import CryptoKit
import ImageIO

/// Native-only copy provenance. Source bytes come exclusively from the closed
/// source ledger reader; no receipt field or model output can choose an input.
/// This worker does not delete originals or authorize an archive operation.
nonisolated enum ArchiveAssetCopier {
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    enum Checkpoint: Sendable { case beforeSourceRead, beforePublish, afterPublish }
    struct Identity: Equatable, Sendable {
        let device: UInt64; let inode: UInt64
        init(_ value: stat) { device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino }
    }
    fileprivate struct Copied: Sendable {
        let observation: ArchiveOutputEvidence.CopiedImage
        let directory: Identity
        let file: Identity
    }
    final class Catalog: @unchecked Sendable {
        let images: [ArchiveOutputEvidence.CopiedImage]
        let vaultPath: String
        let vaultIdentity: Identity
        private let root: Root
        private let copied: [Copied]
        fileprivate init(root: Root, copied: [Copied]) {
            self.root = root; self.copied = copied; images = copied.map(\.observation)
            vaultPath = root.path; vaultIdentity = root.vaultIdentity
        }
        /// Fresh path/identity/byte validation through retained vault ancestry.
        /// Original source ownership is intentionally not retained by a catalog.
        func validate() throws {
            try root.validate()
            for value in copied {
                let name = value.observation.sourceSessionID.uuidString.lowercased()
                let directory = try root.sourceDirectory(name, create: false)
                try require(Identity(try state(directory.fileDescriptor)) == value.directory, "Copied-image directory identity changed.")
                let fileName = value.observation.assetID.uuidString.lowercased() + ".png"
                let file = try openRegular(directory.fileDescriptor, fileName)
                try require(Identity(try state(file.fileDescriptor)) == value.file, "Copied-image file identity changed.")
                try verify(file.fileDescriptor, record: value.observation.copied)
                try link(directory.fileDescriptor, fileName, file.fileDescriptor)
                try link(root.assets.fileDescriptor, name, directory.fileDescriptor)
            }
            try root.validate()
        }
    }

    static func copy(source: ArchiveSourceEligibility.VerifiedSource, vaultURL: URL,
                     checkpoint: (@Sendable (Checkpoint) throws -> Void)? = nil) throws -> Catalog {
        let shots = source.screenshots
        try require(shots.count <= 256, "Screenshot preservation exceeds 256 images; retain the source for review.")
        var total: Int64 = 0
        for shot in shots {
            try require(shot.file.bytes > 0 && shot.file.bytes <= 32 * 1024 * 1024
                        && shot.file.bytes <= 512 * 1024 * 1024 - total, "Screenshot preservation exceeds its bounded byte budget.")
            total += shot.file.bytes
        }
        let root = try Root(vaultURL: vaultURL, sourceIdentity: source.inventory.access.identity)
        var copied: [Copied] = []
        for shot in shots {
            try root.validate(); try checkpoint?(.beforeSourceRead)
            let bytes = try source.readScreenshot(shot)
            try validatePNG(bytes)
            let sourceName = shot.sourceSessionID.uuidString.lowercased()
            let directory = try root.sourceDirectory(sourceName, create: true)
            let directoryIdentity = Identity(try state(directory.fileDescriptor))
            let finalName = shot.assetID.uuidString.lowercased() + ".png"
            let path = root.path + "/MuesliAssets/" + sourceName + "/" + finalName
            let record = ArchiveReceipt.FileRecord(path: path, bytes: shot.file.bytes, sha256: shot.file.sha256)
            let file: FileHandle
            var named = stat()
            let status = fstatat(directory.fileDescriptor, finalName, &named, AT_SYMLINK_NOFOLLOW)
            if status == 0 {
                // Never overwrite even an unrelated same-name file. Exact bytes
                // may be reused only after independent physical admission.
                file = try openRegular(directory.fileDescriptor, finalName)
                try verify(file.fileDescriptor, record: record)
            } else {
                try require(errno == ENOENT, "Existing copied image is unreadable.")
                let temporary = ".copy-" + UUID().uuidString
                let fd = openat(directory.fileDescriptor, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                try require(fd >= 0, "Could not stage a native image copy.")
                file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try write(bytes, fd: fd); try synchronize(fd)
                try verify(fd, record: record)
                try root.validate(); try link(root.assets.fileDescriptor, sourceName, directory.fileDescriptor)
                try link(directory.fileDescriptor, temporary, fd)
                try checkpoint?(.beforePublish)
                try require(renameatx_np(directory.fileDescriptor, temporary, directory.fileDescriptor, finalName, UInt32(RENAME_EXCL)) == 0,
                            "Copied-image destination appeared or publication failed. Existing files were preserved.")
                try checkpoint?(.afterPublish)
                try synchronize(directory.fileDescriptor)
            }
            try verify(file.fileDescriptor, record: record)
            try link(directory.fileDescriptor, finalName, file.fileDescriptor)
            try link(root.assets.fileDescriptor, sourceName, directory.fileDescriptor)
            copied.append(Copied(observation: .init(sourceSessionID: shot.sourceSessionID, assetID: shot.assetID,
                sourceRelativePath: shot.file.path, timelineSeconds: shot.timelineSeconds, source: shot.file, copied: record),
                directory: directoryIdentity, file: Identity(try state(file.fileDescriptor))))
        }
        try source.inventory.access.validate()
        let catalog = Catalog(root: root, copied: copied)
        try catalog.validate()
        return catalog
    }

    /// Decoding is bounded before allocating pixels. Original bytes are copied
    /// unchanged; this verifies a complete single PNG, not a re-encoding.
    private static func validatePNG(_ data: Data) throws {
        let signature = Data([137,80,78,71,13,10,26,10])
        try require(data.count <= 32 * 1024 * 1024 && data.starts(with: signature), "Indexed image is not a supported PNG.")
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) == 1, CGImageSourceGetStatus(image) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw Failure(message: "Indexed PNG is incomplete or invalid.") }
        let w = width.int64Value, h = height.int64Value
        try require(w > 0 && h > 0 && w <= 8192 && h <= 8192 && w * h <= 16_000_000,
                    "Indexed screenshot exceeds the supported decoded pixel budget.")
        guard let decoded = CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              decoded.width == w, decoded.height == h, CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete else {
            throw Failure(message: "Indexed PNG could not be decoded completely.")
        }
    }

    fileprivate final class Root: @unchecked Sendable {
        let path: String
        let handles: [FileHandle]
        let links: [(Int32, String, Int32)]
        let vaultIdentity: Identity
        let excludedSource: MeetingFileAccess.Identity
        let assets: FileHandle
        let lease: FileHandle
        var vault: Int32 { handles.last!.fileDescriptor }
        init(vaultURL: URL, sourceIdentity: MeetingFileAccess.Identity) throws {
            path = vaultURL.path; excludedSource = sourceIdentity
            let names = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
            try require(path.hasPrefix("/") && path.utf8.count <= 4096 && !names.isEmpty
                        && names.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }, "Vault path is not canonical.")
            let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            try require(fd >= 0, "Filesystem root is unavailable.")
            var held = [FileHandle(fileDescriptor: fd, closeOnDealloc: true)], linked: [(Int32,String,Int32)] = []
            for name in names {
                let parent = held.last!.fileDescriptor
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(child >= 0, "Vault path is missing or traverses a symbolic link.")
                held.append(FileHandle(fileDescriptor: child, closeOnDealloc: true)); linked.append((parent,name,child))
                let identity = Identity(try state(child))
                try require(identity.device != sourceIdentity.directoryDevice || identity.inode != sourceIdentity.directoryInode,
                            "Screenshot copies must survive outside the original source.")
                try link(parent, name, child)
            }
            handles = held; links = linked
            let final = try state(held.last!.fileDescriptor)
            try require(final.st_uid == geteuid(), "The selected vault is not owned by this user.")
            vaultIdentity = Identity(final)
            assets = try privateDirectory(held.last!.fileDescriptor, "MuesliAssets", create: true)
            let assetIdentity = Identity(try state(assets.fileDescriptor))
            try require(assetIdentity.device != sourceIdentity.directoryDevice || assetIdentity.inode != sourceIdentity.directoryInode, "Copied-image storage is the original source directory.")
            let leaseFD = openat(assets.fileDescriptor, ".copy-owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            try require(leaseFD >= 0, "Native image-copy ownership is unavailable.")
            lease = FileHandle(fileDescriptor: leaseFD, closeOnDealloc: true)
            try regular(try state(leaseFD))
            try require(flock(leaseFD, LOCK_EX | LOCK_NB) == 0, "Another actual image-copy operation still owns this vault.")
            try validate()
        }
        func validate() throws {
            for (parent,name,child) in links { try link(parent,name,child) }
            let current = try state(vault)
            try require(current.st_uid == geteuid() && Identity(current) == vaultIdentity, "Vault identity or ownership changed.")
            try link(vault, "MuesliAssets", assets.fileDescriptor); try privateMode(try state(assets.fileDescriptor))
            try link(assets.fileDescriptor, ".copy-owner.lock", lease.fileDescriptor); try regular(try state(lease.fileDescriptor))
        }
        func sourceDirectory(_ name: String, create: Bool) throws -> FileHandle {
            try validate()
            let directory = try privateDirectory(assets.fileDescriptor, name, create: create)
            let identity = Identity(try state(directory.fileDescriptor))
            try require(identity.device != excludedSource.directoryDevice || identity.inode != excludedSource.directoryInode,
                        "Copied-image session directory is the original source.")
            return directory
        }
    }
    private static func privateDirectory(_ parent: Int32, _ name: String, create: Bool) throws -> FileHandle {
        if create {
            let result = mkdirat(parent, name, 0o700)
            try require(result == 0 || errno == EEXIST, "Could not create a private copied-image directory.")
            if result == 0 { try synchronize(parent) }
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "Copied-image directory is missing or unsafe.")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try privateMode(try state(fd)); try link(parent, name, fd); return handle
    }
    private static func privateMode(_ value: stat) throws {
        try require(value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o777 == 0o700, "Copied-image directories must be private and owned by this user.")
    }
    private static func openRegular(_ parent: Int32, _ name: String) throws -> FileHandle {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(fd >= 0, "Copied image is missing or unsafe.")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try regular(try state(fd)); try link(parent, name, fd); return handle
    }
    private static func verify(_ fd: Int32, record: ArchiveReceipt.FileRecord) throws {
        let before = try state(fd); try regular(before)
        try require(before.st_size == record.bytes && record.bytes <= 32 * 1024 * 1024, "Copied image size changed.")
        var hash = SHA256(), offset: off_t = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < record.bytes {
            let count = pread(fd, &buffer, min(buffer.count, Int(record.bytes - offset)), offset)
            if count < 0 && errno == EINTR { continue }
            try require(count > 0, "Copied image read failed.")
            hash.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        let after = try state(fd); try regular(after)
        try require(before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                    && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                    && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
                    && hash.finalize().map { String(format: "%02x", $0) }.joined() == record.sha256, "Copied image bytes changed.")
    }
    private static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, "Native image-copy write failed."); offset += count
            }
        }
    }
    private static func synchronize(_ fd: Int32) throws { try require(fsync(fd) == 0 && fcntl(fd, F_FULLFSYNC) == 0, "Native image copy could not be durably synchronized.") }
    private static func regular(_ value: stat) throws {
        try require(value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1 && value.st_uid == geteuid() && value.st_mode & 0o777 == 0o600,
                    "Copied images and ownership files must be private, single-link regular files.")
    }
    private static func state(_ fd: Int32) throws -> stat { var value = stat(); try require(fstat(fd, &value) == 0, "Native image-copy descriptor is unavailable."); return value }
    private static func link(_ parent: Int32, _ name: String, _ fd: Int32) throws {
        let actual = try state(fd); var named = stat()
        try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && actual.st_dev == named.st_dev
                    && actual.st_ino == named.st_ino && actual.st_mode & S_IFMT == named.st_mode & S_IFMT, "Native image-copy path identity changed.")
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
}
