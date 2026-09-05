import Foundation
import Darwin

/// Image provenance is carried separately from its filename. Modern ledger
/// times already include the source session's offset in the meeting timeline.
nonisolated struct MeetingScreenshotInput: Sendable {
    struct Image: Sendable, Equatable {
        enum Origin: Sendable, Equatable {
            case committed(sourceSessionID: String, meetingTime: Double)
            case legacy
        }
        let file: MeetingScreenshotDirectory.Reference
        let origin: Origin
        var url: URL { file.url }
        var relativePath: String { file.relativePath }
        var timestamp: Double? {
            if case .committed(_, let time) = origin { return time }
            return nil
        }
        var sourceKey: String {
            if case .committed(let source, _) = origin { return source }
            return "legacy/unknown"
        }
        var evidence: String {
            switch origin {
            case .committed(let source, let time):
                return "Artifact \(relativePath) (image ID \(url.deletingPathExtension().lastPathComponent)); recorded source/session \(source), meeting-relative time \(String(format: "%.6f", time)) seconds."
            case .legacy:
                return "Legacy image: source/session and meeting-relative time are unverified; its filename is not timing evidence."
            }
        }
    }
    let images: [Image]
    let access: MeetingFileAccess
    var urls: [URL] { images.map(\.url) }

    private static let limit = 10_000
    private static func invalid(_ detail: String) -> NSError {
        NSError(domain: "MeetingScreenshotInput", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Screenshot evidence is unavailable: " + detail])
    }

    static func snapshot(context: TranscriptPersistenceStore.Context) throws -> MeetingScreenshotInput {
        try context.access.validate()
        let files = try MeetingScreenshotDirectory(access: context.access)
        var images: [Image] = [], imagePaths = Set<String>()
        var ledgerBytes: UInt64 = 0, ledgerRows = 0
        if let data = try files.readIfPresent("meeting.json", limit: 4 * 1024 * 1024) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(MeetingMetadata.self, from: data)
            guard metadata.sessions.count <= 1_000 else { throw CocoaError(.fileReadTooLarge) }
            var sources = Set<UUID>()
            for session in metadata.sessions {
                guard let relative = session.artifactsFolder else { continue }
                let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0] == "artifacts", let sourceID = UUID(uuidString: parts[1]),
                      sources.insert(sourceID).inserted else { throw invalid("invalid or repeated artifact session.") }
                let source = parts[1]
                if let expected = session.sourceSessionID, expected != source {
                    throw invalid("the indexed source and artifact session do not match.")
                }
                if let expected = session.artifactFinalization?.sourceSessionID, expected != source {
                    throw invalid("the recorded artifact outcome belongs to another source.")
                }
                // Retain the actual ownership lock, opened relative to the
                // admitted directory. Never follow a replaced ancestor path.
                let inactive = try files.open(relative + "/.artifact-owner.lock", isDirectory: false)
                defer { try? inactive.close() }
                guard flock(inactive.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    throw invalid("the artifact session is still being saved.")
                }
                let handle = try files.open(relative + "/assets.jsonl", isDirectory: false)
                defer { try? handle.close() }
                var remaining = try handle.seekToEnd()
                guard remaining <= 64 * 1024 * 1024 - ledgerBytes else { throw CocoaError(.fileReadTooLarge) }
                ledgerBytes += remaining
                try handle.seek(toOffset: 0)
                var artifactIDs = Set<UUID>()
                var row = Data(), sawHeader = false, offset: Double?, previousTime: Double?, captureEnd: Double?
                while remaining > 0 {
                    let chunk = try handle.read(upToCount: Int(min(remaining, 16 * 1024))) ?? Data()
                    guard !chunk.isEmpty else { throw invalid("the artifact ledger was truncated.") }
                    remaining -= UInt64(chunk.count)
                    for byte in chunk {
                        if byte != 0x0a {
                            guard row.count < 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                            row.append(byte)
                            continue
                        }
                        ledgerRows += 1
                        guard ledgerRows <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
                        guard let event = try JSONSerialization.jsonObject(with: row) as? [String: Any],
                              event["source_session_id"] as? String == source,
                              let type = event["type"] as? String else { throw invalid("the ledger source identity is invalid.") }
                        row.removeAll(keepingCapacity: true)
                        if !sawHeader {
                            guard type == "session", event["version"] == nil, event["schema_version"] == nil, let microseconds = number(event["timeline_offset_us"]),
                                  microseconds <= Double(Int64.max), microseconds.rounded() == microseconds else { throw invalid("the ledger session header is invalid.") }
                            offset = microseconds / 1_000_000
                            if let indexedOffset = session.timelineOffsetSeconds,
                               !indexedOffset.isFinite || indexedOffset < 0 || abs(indexedOffset - offset!) > 0.000001 {
                                throw invalid("the indexed and recorded timeline offsets differ.")
                            }
                            sawHeader = true
                            continue
                        }
                        guard type != "session" else { throw invalid("the ledger repeats its session header.") }
                        if type == "capture_stopped" {
                            guard captureEnd == nil, let time = number(event["t"]), time >= offset! else {
                                throw invalid("the recorded capture end is invalid.")
                            }
                            captureEnd = time
                            continue
                        }
                        guard type == "screenshot" else { continue }
                        guard let time = number(event["t"]), time >= offset!,
                              previousTime.map({ time >= $0 }) ?? true,
                              let path = event["path"] as? String else { throw invalid("a screenshot timestamp is invalid.") }
                        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                        guard pathParts.count == 4, Array(pathParts.prefix(3)) == ["artifacts", source, "screenshots"],
                              let artifactID = UUID(uuidString: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                              URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
                            throw invalid("a screenshot path does not belong to its recorded source.")
                        }
                        guard artifactIDs.insert(artifactID).inserted else { throw invalid("duplicate screenshot identity.") }
                        let image = Image(file: try files.reference(path),
                                          origin: .committed(sourceSessionID: source, meetingTime: time))
                        guard imagePaths.insert(image.url.path).inserted, images.count < limit else {
                            throw invalid("duplicate or excessive screenshot records.")
                        }
                        images.append(image)
                        previousTime = time
                    }
                }
                guard sawHeader else { throw invalid("the artifact ledger has no complete session header.") }
                if let last = previousTime, let end = captureEnd, last > end {
                    throw invalid("a screenshot falls after its recorded source capture ended.")
                }
                // The frozen trailing fragment is not a committed record.
            }
        }
        let legacyNames: [String]
        do { legacyNames = try files.names(in: "screenshots", limit: limit) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { legacyNames = [] }
        for name in legacyNames {
            guard images.count < limit else { throw CocoaError(.fileReadTooLarge) }
            guard ["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { continue }
            images.append(Image(file: try files.reference("screenshots/" + name), origin: .legacy))
        }
        try context.access.validate()
        return MeetingScreenshotInput(images: images.sorted { $0.url.path < $1.url.path }, access: context.access)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite && number >= 0 ? number : nil
    }


}

/// Retain the admitted directory itself. Every subsequent read traverses from
/// this descriptor, refusing symlinks and matching the snapshot's file identity.
nonisolated final class MeetingScreenshotDirectory: Sendable {
    let access: MeetingFileAccess
    private let descriptor: Int32
    init(access: MeetingFileAccess) throws {
        try access.validate()
        let fd = Darwin.open(access.folderURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var value = stat()
        guard fstat(fd, &value) == 0, UInt64(value.st_dev) == access.identity.directoryDevice,
              value.st_ino == access.identity.directoryInode else { _ = close(fd); throw MeetingFileAccess.Failure.changed }
        self.access = access; descriptor = fd
    }
    deinit { _ = close(descriptor) }

    struct Identity: Sendable, Equatable {
        let device: Int32, inode: UInt64, bytes: Int64
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; bytes = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    struct Reference: Sendable, Equatable {
        let directory: MeetingScreenshotDirectory
        let relativePath: String
        let identity: Identity
        var url: URL { directory.access.folderURL.appendingPathComponent(relativePath) }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.directory.access.identity == rhs.directory.access.identity && lhs.relativePath == rhs.relativePath && lhs.identity == rhs.identity
        }
        func open() throws -> FileHandle {
            let handle = try directory.open(relativePath, isDirectory: false)
            var value = stat()
            guard fstat(handle.fileDescriptor, &value) == 0, Identity(value) == identity else {
                try? handle.close(); throw MeetingFileAccess.Failure.changed
            }
            return handle
        }
    }
    func reference(_ relative: String) throws -> Reference {
        let handle = try open(relative, isDirectory: false)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(handle.fileDescriptor, &value) == 0 else { throw MeetingFileAccess.Failure.changed }
        return Reference(directory: self, relativePath: relative, identity: Identity(value))
    }
    func open(_ relative: String, isDirectory: Bool) throws -> FileHandle {
        try access.validate()
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var current = descriptor, intermediates: [Int32] = []
        defer { for fd in intermediates { _ = close(fd) } }
        for (index, part) in parts.enumerated() {
            let needsDirectory = index < parts.count - 1 || isDirectory
            let fd = openat(current, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (needsDirectory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var value = stat()
            guard fstat(fd, &value) == 0,
                  value.st_mode & S_IFMT == (needsDirectory ? S_IFDIR : S_IFREG),
                  needsDirectory || value.st_nlink == 1 else { _ = close(fd); throw CocoaError(.fileReadNoPermission) }
            if index == parts.count - 1 { return FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
            intermediates.append(fd); current = fd
        }
        throw CocoaError(.fileReadUnknown)
    }
    func readIfPresent(_ relative: String, limit: Int) throws -> Data? {
        let handle: FileHandle
        do { handle = try open(relative, isDirectory: false) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(handle.fileDescriptor, &initial) == 0, initial.st_size >= 0, initial.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0, Identity(initial) == Identity(after), data.count == initial.st_size else {
            throw MeetingFileAccess.Failure.changed
        }
        return data
    }
    func names(in relative: String, limit: Int) throws -> [String] {
        let handle = try open(relative, isDirectory: true)
        defer { try? handle.close() }
        let duplicate = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard let stream = fdopendir(duplicate) else { _ = close(duplicate); throw CocoaError(.fileReadUnknown) }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < limit else { throw CocoaError(.fileReadTooLarge) }
            names.append(name)
        }
        return names
    }
}
