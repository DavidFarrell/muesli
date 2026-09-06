import Foundation
import Darwin

/// One selected source and one export destination remain owned through actual
/// completion. A deadline stops waiting; it never admits a competing worker.
nonisolated final class TranscriptExportOwner: @unchecked Sendable {
    struct Receipt: Sendable {
        let directory: URL
        let segmentCount: Int
    }
    enum Failure: Error, LocalizedError, Sendable {
        case busy, recording, invalidDestination, sourceDestination, destinationExists
        case invalidSource(String), disk(String), publishedUnconfirmed(URL, String)
        var errorDescription: String? {
            switch self {
            case .busy: return "An export or save is still running. Wait for its actual result before trying again."
            case .recording: return "Stop and finish saving this meeting before exporting its transcript."
            case .invalidDestination: return "Choose a new export folder name inside an existing folder."
            case .sourceDestination: return "Choose an export location outside the original meeting folder."
            case .destinationExists: return "That export name already exists. Choose a new folder name; existing files were retained."
            case .invalidSource(let detail): return "The selected meeting's saved transcript could not be read: \(detail)"
            case .disk(let detail): return "The export could not be completed: \(detail)"
            case .publishedUnconfirmed(let url, let detail):
                return "The complete export folder “\(url.lastPathComponent)” was created, but its storage could not be confirmed: \(detail)"
            }
        }
    }
    enum WaitResult: Sendable { case completed(Result<Receipt, Failure>), timedOut, cancelled }
    enum Step: Equatable, Sendable {
        case readSource, createDirectory, writeJSONL, writeText, publish, syncPublishedDirectory
    }
    final class Attempt: @unchecked Sendable {
        private let lock = NSLock()
        private let completion = TaskCompletion()
        private var result: Result<Receipt, Failure>?
        fileprivate func finish(_ result: Result<Receipt, Failure>) {
            lock.withLock { self.result = result }
            completion.markCompleted()
        }
        @concurrent func wait(timeoutSeconds: Double) async -> WaitResult {
            switch await completion.wait(timeoutSeconds: timeoutSeconds) {
            case .completed: return .completed(lock.withLock { result! })
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            }
        }
    }
    private let lock = NSLock()
    private var active: Attempt?
    private let store: TranscriptPersistenceStore
    private let checkpoint: @Sendable (Step) throws -> Void
    init(store: TranscriptPersistenceStore = .shared,
         checkpoint: @escaping @Sendable (Step) throws -> Void = { _ in }) {
        self.store = store; self.checkpoint = checkpoint
    }
    var isBusy: Bool { lock.withLock { active != nil } }

    func start(sourceDirectory: URL, destinationDirectory: URL,
               onCompletion: @escaping @Sendable (Result<Receipt, Failure>) -> Void = { _ in }) throws -> Attempt {
        let attempt = Attempt()
        try lock.withLock {
            guard active == nil else { throw Failure.busy }
            active = attempt
        }
        do {
            _ = try store.start(in: sourceDirectory, onCompletion: { [self] outcome in
                let result: Result<Receipt, Failure>
                switch outcome {
                case .success(let value): result = value
                case .failure(let error): result = .failure(.invalidSource(error.localizedDescription))
                }
                lock.withLock { if active === attempt { active = nil } }
                attempt.finish(result)
                onCompletion(result)
            }) { [self] context -> Result<Receipt, Failure> in
                do { return .success(try export(context: context, destination: destinationDirectory)) }
                catch let error as Failure { return .failure(error) }
                catch { return .failure(.disk(error.localizedDescription)) }
            }
        } catch {
            lock.withLock { if active === attempt { active = nil } }
            if case .busy = error as? TranscriptPersistenceStore.Failure { throw Failure.busy }
            throw Failure.invalidSource(error.localizedDescription)
        }
        return attempt
    }

    private struct Record: Decodable {
        let type: String?
        let speaker_id: String?
        let stream: String?
        let source_session_id: String?
        let t0: Double
        let t1: Double?
        let text: String
        var segment: TranscriptSegment {
            TranscriptSegment(speakerID: speaker_id ?? "unknown", stream: stream ?? "unknown",
                              sourceSessionID: source_session_id, t0: t0, t1: t1, text: text, isPartial: false)
        }
    }

    private func export(context: TranscriptPersistenceStore.Context, destination: URL) throws -> Receipt {
        try checkpoint(.readSource)
        let source = context.folder.standardizedFileURL.resolvingSymlinksInPath()
        // All path resolution and access checks run on the original disk owner.
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              ![".", "..", "/"].contains(destination.lastPathComponent) else { throw Failure.invalidDestination }
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        guard target.path != source.path, !target.path.hasPrefix(source.path + "/") else { throw Failure.sourceDestination }
        let metadata: MeetingMetadata
        let input: FileHandle
        do {
            let handle = try Self.openRegular(source.appendingPathComponent("meeting.json"))
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            metadata = try decoder.decode(MeetingMetadata.self, from: data)
            guard metadata.status != .recording else { throw Failure.recording }
            input = try Self.openRegular(source.appendingPathComponent("transcript.jsonl"))
        } catch let error as Failure { throw error }
        catch { throw Failure.invalidSource(error.localizedDescription) }
        defer { try? input.close() }

        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else { throw Self.posix() }
        defer { Darwin.close(parentFD) }
        let stagingName = ".muesli-export-" + UUID().uuidString
        try checkpoint(.createDirectory)
        guard mkdirat(parentFD, stagingName, S_IRWXU) == 0 else { throw Self.posix() }
        let stagingFD = openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stagingFD >= 0 else {
            let error = Self.posix(); _ = unlinkat(parentFD, stagingName, AT_REMOVEDIR); throw error
        }
        var published = false
        var createdNames: [String] = []
        defer {
            if !published {
                // Only this attempt's explicitly created leaves are eligible.
                // Never recursively sweep staging or unexpected contents.
                for name in createdNames { _ = unlinkat(stagingFD, name, 0) }
                _ = unlinkat(parentFD, stagingName, AT_REMOVEDIR)
            }
            Darwin.close(stagingFD)
        }
        func create(_ name: String) throws -> FileHandle {
            let fd = openat(stagingFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw Self.posix() }
            createdNames.append(name)
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let jsonl = try create("transcript.jsonl")
        defer { try? jsonl.close() }
        let text = try create("transcript.txt")
        defer { try? text.close() }
        var pending = Data(), count = 0
        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            let record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: line)
                guard record.type == nil || record.type == "segment",
                      record.t0.isFinite, record.t0 >= 0,
                      (record.t1 ?? record.t0).isFinite, (record.t1 ?? record.t0) >= record.t0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch { throw Failure.invalidSource("A saved transcript record is invalid. No alternate transcript was substituted.") }
            try checkpoint(.writeText)
            let rendered = TranscriptModel.plainText(from: [record.segment], names: metadata.speakerNames)
            try text.write(contentsOf: Data(((count == 0 ? "" : "\n") + rendered).utf8))
            count += 1
        }
        // Memory is bounded by a 4 MiB record plus a fixed read chunk. Preserve
        // original JSONL bytes and source IDs; text uses precisely those records.
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try checkpoint(.writeJSONL)
            try jsonl.write(contentsOf: chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                guard line.count <= 4 * 1024 * 1024 else { throw Failure.invalidSource("A transcript record is too large.") }
                try consume(line)
                pending.removeSubrange(...newline)
            }
            guard pending.count <= 4 * 1024 * 1024 else { throw Failure.invalidSource("A transcript record is too large.") }
        }
        if !pending.isEmpty { try consume(pending) }
        guard count == metadata.segmentCount else {
            throw Failure.invalidSource("The saved record count does not match this meeting's metadata.")
        }
        try jsonl.synchronize(); try text.synchronize()
        try jsonl.close(); try text.close()
        guard fsync(stagingFD) == 0 else { throw Self.posix() }
        try checkpoint(.publish)
        guard renameatx_np(parentFD, stagingName, parentFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw Failure.destinationExists }
            // Unsupported exclusive rename fails closed; no overwrite fallback.
            throw Self.posix()
        }
        published = true
        do {
            try checkpoint(.syncPublishedDirectory)
            guard fsync(parentFD) == 0 else { throw Self.posix() }
        } catch { throw Failure.publishedUnconfirmed(target, error.localizedDescription) }
        return Receipt(directory: target, segmentCount: count)
    }

    private static func openRegular(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posix() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw CocoaError(.fileReadCorruptFile)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private static func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
