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
        let url: URL
        let origin: Origin
        var relativePath: String? = nil
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
                return "Artifact \(relativePath ?? url.lastPathComponent) (image ID \(url.deletingPathExtension().lastPathComponent)); recorded source/session \(source), meeting-relative time \(String(format: "%.6f", time)) seconds."
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
        let root = context.folder
        var images: [Image] = [], imagePaths = Set<String>()
        var ledgerBytes: UInt64 = 0, ledgerRows = 0
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.json").path) {
            let metadata = try context.readMetadata()
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
                let directory = try safeURL(root: root, relative: relative, directory: true)
                // A pending native writer can have appended a complete-looking
                // line before fsync. Read only after its original owner closes.
                _ = try safeURL(root: root, relative: relative + "/.artifact-owner.lock", directory: false)
                guard let inactive = try SessionArtifactStore.acquireInactiveLease(directory: directory) else {
                    throw invalid("the artifact session has no ownership evidence.")
                }
                defer { try? inactive.close() }
                let ledger = try safeURL(root: root, relative: relative + "/assets.jsonl", directory: false)
                let handle = try FileHandle(forReadingFrom: ledger)
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
                        let image = Image(url: try safeURL(root: root, relative: path, directory: false),
                                          origin: .committed(sourceSessionID: source, meetingTime: time), relativePath: path)
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
        let legacy = root.appendingPathComponent("screenshots", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            let folder = try safeURL(root: root, relative: "screenshots", directory: true)
            guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]) else { throw CocoaError(.fileReadUnknown) }
            var count = 0
            for case let url as URL in entries {
                count += 1
                guard count <= limit, images.count < limit else { throw CocoaError(.fileReadTooLarge) }
                guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { continue }
                images.append(Image(url: try safeURL(root: root, relative: "screenshots/" + url.lastPathComponent,
                                                    directory: false), origin: .legacy))
            }
        }
        try context.access.validate()
        return MeetingScreenshotInput(images: images.sorted { $0.url.path < $1.url.path }, access: context.access)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite && number >= 0 ? number : nil
    }

    /// Reject traversal and every symlink component, including a legacy image
    /// that would otherwise cause speaker-ID to read outside the meeting.
    private static func safeURL(root: URL, relative: String, directory: Bool) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw invalid("an artifact path is not a contained relative path.")
        }
        var url = root
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(part)
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw invalid("a recorded image or directory is missing.") }
            let expected = index == parts.count - 1 && !directory ? S_IFREG : S_IFDIR
            guard value.st_mode & S_IFMT == expected,
                  expected != S_IFREG || value.st_nlink == 1 else { throw invalid("an image or directory has an unsafe file identity.") }
        }
        return url
    }
}
