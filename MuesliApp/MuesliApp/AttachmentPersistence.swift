import Foundation
import CryptoKit
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The retained meeting-folder owner publishes an attachment only after its
/// immutable bytes are synchronized. A failed manifest save leaves an unindexed
/// file for recovery; it never overwrites an earlier attachment.
nonisolated enum AttachmentPersistence {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumTextBytes = 1024 * 1024
    static let maximumManifestBytes = 4 * 1024 * 1024
    struct Snapshot: Sendable {
        let attachments: [Attachment]
        var cleanupNotice: String? = nil
    }
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    struct ImageInput: Sendable {
        let data: Data
        func png() throws -> Data {
            guard data.count <= maximumBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue <= 8192, height.doubleValue <= 8192,
                  width.doubleValue * height.doubleValue <= 16_000_000 else {
                throw Failure.invalid("Use an image of at most 16 megapixels, 8192 pixels per edge and 32 MB.")
            }
            // Decode and normalize orientation on the disk owner's worker,
            // before admitting immutable PNG bytes to the manifest.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)
            ] as CFDictionary) else { throw Failure.invalid("The image could not be decoded.") }
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure.invalid("The image could not be encoded.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), buffer.length <= maximumBytes else {
                throw Failure.invalid("The encoded attachment exceeds the 32 MB limit.")
            }
            return buffer as Data
        }
    }

    static func validFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".."
            && !filename.contains("/") && !filename.contains("\\") && !filename.contains("\0")
    }

    static func readManifest(context: TranscriptPersistenceStore.Context) throws -> AttachmentsManifest {
        let folder = try openFolder(context.folder)
        defer { Darwin.close(folder) }
        let file = openat(folder, "attachments.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return AttachmentsManifest(attachments: []) }
        guard file >= 0 else { throw Failure.invalid("The attachment list could not be opened safely. It has been preserved.") }
        defer { Darwin.close(file) }
        let data = try readBounded(file, limit: maximumManifestBytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AttachmentsManifest.self, from: data)
        guard Set(manifest.attachments.map(\.id)).count == manifest.attachments.count,
              manifest.attachments.allSatisfy({ validFilename($0.filename) && $0.timestamp.isFinite && $0.timestamp >= 0 }) else {
            throw Failure.invalid("The attachment list contains invalid identities or paths. Its contents have been preserved.")
        }
        return manifest
    }

    static func add(context: TranscriptPersistenceStore.Context, type: AttachmentType,
                    timestamp: Double, sourceID: String, data: Data) throws -> Snapshot {
        guard timestamp.isFinite, timestamp >= 0, !sourceID.isEmpty,
              !data.isEmpty, data.count <= maximumBytes else {
            throw Failure.invalid("The attachment has invalid timing or exceeds the 32 MB limit.")
        }
        if type == .text, data.count > maximumTextBytes || String(data: data, encoding: .utf8) == nil {
            throw Failure.invalid("Text attachments must be valid UTF-8 and no larger than 1 MB.")
        }
        var manifest = try readManifest(context: context)
        let directory = try openAttachmentDirectory(in: context.folder, create: true)
        defer { Darwin.close(directory) }
        let id = UUID()
        let filename = "attachment-\(id.uuidString).\(type == .image ? "png" : "txt")"
        // O_EXCL rejects collisions and symlinks. The manifest never points at
        // this file until all bytes, the file and its parent have been synced.
        let fd = openat(directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try sync(directory)
        manifest.attachments.append(Attachment(id: id, type: type, timestamp: timestamp,
            filename: filename, sourceSessionID: sourceID, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        try commit(manifest, context: context)
        return Snapshot(attachments: manifest.attachments)
    }

    static func remove(context: TranscriptPersistenceStore.Context, id: UUID) throws -> Snapshot {
        var manifest = try readManifest(context: context)
        guard let attachment = manifest.attachments.first(where: { $0.id == id }) else {
            throw Failure.invalid("This attachment is no longer in the saved meeting.")
        }
        let directory = try openAttachmentDirectory(in: context.folder, create: false)
        defer { Darwin.close(directory) }
        // Persist removal before touching bytes. Failed transactions preserve
        // the old index and file together; a crash afterward can only leave an
        // unindexed original, never an index referring to a deleted original.
        manifest.attachments.removeAll { $0.id == id }
        try commit(manifest, context: context)
        var result = Snapshot(attachments: manifest.attachments)
        // Old timestamp filenames may have been shared by multiple records.
        // Removing one record does not authorize deleting another record's bytes.
        guard !manifest.attachments.contains(where: { $0.filename == attachment.filename }) else { return result }
        if unlinkat(directory, attachment.filename, 0) != 0 && errno != ENOENT {
            result.cleanupNotice = "The attachment was removed from the meeting, but its unused file could not be deleted."
        } else {
            do { try sync(directory) }
            catch { result.cleanupNotice = "The attachment was removed, but deletion durability could not be confirmed." }
        }
        return result
    }

    private static func commit(_ manifest: AttachmentsManifest, context: TranscriptPersistenceStore.Context) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumManifestBytes else { throw Failure.invalid("The attachment list is full.") }
        try context.commit(files: ["attachments.json": data])
    }

    private static func openFolder(_ folder: URL) throws -> Int32 {
        let fd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }
    private static func openAttachmentDirectory(in folder: URL, create: Bool) throws -> Int32 {
        let parent = try openFolder(folder)
        defer { Darwin.close(parent) }
        if create, mkdirat(parent, "attachments", S_IRWXU) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = openat(parent, "attachments", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.invalid("The attachment directory must be an ordinary directory inside its meeting.") }
        return directory
    }
    private static func readBounded(_ fd: Int32, limit: Int) throws -> Data {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else {
            throw Failure.invalid("The attachment list is not a supported regular file. Its contents have been preserved.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw Failure.invalid("The attachment list exceeds its size limit.") }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, data.count == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw Failure.invalid("The attachment list changed while it was being read. Retry.")
        }
        return data
    }
    private static func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
