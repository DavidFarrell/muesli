import Foundation
import Darwin

/// Canonical transcript files form one recoverable transaction. A prepared
/// journal always means restore the prior snapshot; a committed journal means
/// keep the canonical snapshot (new, or fully restored old). Recovery and
/// mutation run only on an independently scheduled, reserved folder owner.
nonisolated final class TranscriptPersistenceStore: Sendable {
    enum Step: Equatable, Sendable {
        case stage(String)
        case publishJournal
        case replace(String)
        case commitJournal
        case restore(String)
        case stagingPublished
        case cleanupResolved
    }

    enum Failure: Error, LocalizedError, Sendable {
        case invalidFiles
        case busy
        case timedOut
        case cancelled
        case superseded
        case operationFailed(String)
        case recoveryRequired(String)

        var errorDescription: String? {
            switch self {
            case .invalidFiles: return "The transcript transaction contains an invalid file."
            case .busy: return "This meeting has an unfinished disk operation. Wait for it to finish before trying again."
            case .timedOut: return "The disk operation is still pending. Its outcome is not yet known; retry to check it."
            case .cancelled: return "The wait was cancelled. The owned disk operation may still finish."
            case .superseded: return "The saved transcript belongs to a viewer that is no longer current. Reopen the meeting to load it."
            case .operationFailed(let message): return message
            case .recoveryRequired(let detail):
                return "The transcript could not be saved or restored. Its recovery journal and originals were retained: \(detail)"
            }
        }
    }

    private struct Entry: Codable {
        let name: String
        let existed: Bool
    }
    private struct Journal: Codable {
        var committed: Bool
        let entries: [Entry]
    }

    static let shared = TranscriptPersistenceStore()
    static let journalDirectoryName = ".transcript-transaction"
    private final class Registry: @unchecked Sendable {
        private struct Pending: Sendable { let id: UUID; let work: @Sendable () -> Void }
        let lock = NSLock()
        var owners: [String: UUID] = [:]
        private var pending: [String: Pending] = [:]
        func admit(_ folder: URL, id: UUID, afterCurrent: Bool,
                   work: @escaping @Sendable () -> Void) throws -> Bool {
            try lock.withLock {
                let key = folder.standardizedFileURL.path
                if owners[key] != nil {
                    // Only terminal finalization may retain one intent behind
                    // an existing owner. Further edits and finalizers stay bounded.
                    guard afterCurrent, pending[key] == nil else { throw Failure.busy }
                    pending[key] = Pending(id: id, work: work)
                    return false
                }
                guard owners.count < 8 else { throw Failure.busy }
                owners[key] = id
                return true
            }
        }
        func release(_ folder: URL, id: UUID) {
            let next: Pending? = lock.withLock {
                let key = folder.standardizedFileURL.path
                guard owners[key] == id else { return nil }
                if let next = pending.removeValue(forKey: key) {
                    owners[key] = next.id
                    return next
                }
                owners.removeValue(forKey: key)
                return nil
            }
            if let next { DispatchQueue.global(qos: .utility).async(execute: next.work) }
        }
        func isBusy(_ folder: URL) -> Bool {
            lock.withLock { owners[folder.standardizedFileURL.path] != nil }
        }
    }
    private static let registry = Registry()
    private static let allowed = Set(["transcript.txt", "transcript.jsonl", "meeting.json", "transcript_sources.json"])
    private let fault: @Sendable (Step) throws -> Void

    init(fault: @escaping @Sendable (Step) throws -> Void = { _ in }) {
        self.fault = fault
    }

    enum WaitResult<Output: Sendable>: Sendable {
        case completed(Output)
        case failed(Failure)
        case timedOut
        case cancelled
    }

    final class Operation<Output: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let completion = TaskCompletion()
        private var result: Result<Output, Failure>?

        fileprivate func finish(_ result: Result<Output, Failure>) {
            lock.withLock { self.result = result }
            completion.markCompleted()
        }

        /// Only for an original worker that has observed its terminal callback.
        /// This takes a short state lock and never waits for completion.
        func completedValue() throws -> Output {
            guard let result = lock.withLock({ result }) else { throw Failure.busy }
            return try result.get()
        }

        @concurrent func wait(timeoutSeconds: Double) async -> WaitResult<Output> {
            switch await completion.wait(timeoutSeconds: timeoutSeconds) {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            case .completed:
                switch lock.withLock({ result! }) {
                case .success(let value): return .completed(value)
                case .failure(let failure): return .failed(failure)
                }
            }
        }

        @concurrent func value(timeoutSeconds: Double = 5) async throws -> Output {
            switch await wait(timeoutSeconds: timeoutSeconds) {
            case .completed(let value): return value
            case .failed(let error): throw error
            case .timedOut: throw Failure.timedOut
            case .cancelled: throw Failure.cancelled
            }
        }
    }

    /// Used only by the original worker closure while it owns this folder.
    /// Admission holds no I/O lock; unrelated folders can keep making progress.
    final class Context: Sendable {
        private let store: TranscriptPersistenceStore
        let folder: URL
        fileprivate init(store: TranscriptPersistenceStore, folder: URL) {
            self.store = store
            self.folder = folder
        }
        func commit(files: [String: Data]) throws { try store.commitOwned(files: files, in: folder) }
        func readData(named name: String) throws -> Data {
            guard TranscriptPersistenceStore.allowed.contains(name) else { throw Failure.invalidFiles }
            return try Data(contentsOf: folder.appendingPathComponent(name))
        }
        func readMetadata() throws -> MeetingMetadata {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MeetingMetadata.self, from: readData(named: "meeting.json"))
        }
    }

    /// Reserve immediately; all recovery, reads, preparation, and mutation run
    /// on the independently scheduled owner. A timed-out/cancelled waiter never
    /// releases this reservation or starts a replacement worker.
    func start<Output: Sendable>(in folder: URL,
                                onCompletion: @escaping @Sendable (Result<Output, Failure>) -> Void = { _ in },
                                operation: @escaping @Sendable (Context) throws -> Output) throws -> Operation<Output> {
        try admit(in: folder, afterCurrent: false, onCompletion: onCompletion, operation: operation)
    }

    /// Stop must not discard its final save merely because an earlier metadata
    /// edit is still writing. Retain one terminal intent and hand it the same
    /// folder only after the original worker really finishes. Waiter deadlines
    /// do not remove either owner or start a competing disk operation.
    func startAfterCurrent<Output: Sendable>(in folder: URL,
                                onCompletion: @escaping @Sendable (Result<Output, Failure>) -> Void = { _ in },
                                operation: @escaping @Sendable (Context) throws -> Output) throws -> Operation<Output> {
        try admit(in: folder, afterCurrent: true, onCompletion: onCompletion, operation: operation)
    }

    private func admit<Output: Sendable>(in folder: URL, afterCurrent: Bool,
                                onCompletion: @escaping @Sendable (Result<Output, Failure>) -> Void,
                                operation: @escaping @Sendable (Context) throws -> Output) throws -> Operation<Output> {
        let id = UUID()
        let owner = Operation<Output>()
        let work: @Sendable () -> Void = { [self] in
            let result: Result<Output, Failure>
            do {
                try recoverOwned(in: folder)
                result = .success(try operation(Context(store: self, folder: folder)))
            } catch let error as Failure {
                result = .failure(error)
            } catch {
                result = .failure(.operationFailed(error.localizedDescription))
            }
            Self.registry.release(folder, id: id)
            owner.finish(result)
            onCompletion(result)
        }
        if try Self.registry.admit(folder, id: id, afterCurrent: afterCurrent, work: work) {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
        return owner
    }

    /// Legacy synchronous metadata callers may refuse unresolved folders, but
    /// must never perform recovery or wait for an owner on the UI thread.
    func assertReadable(in folder: URL) throws {
        guard !Self.registry.isBusy(folder) else { throw Failure.busy }
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.journalDirectoryName).path) else {
            throw Failure.recoveryRequired("Open the meeting to run its independent recovery operation.")
        }
    }

    private func commitOwned(files: [String: Data], in folder: URL) throws {
        guard !files.isEmpty, Set(files.keys).isSubset(of: Self.allowed) else { throw Failure.invalidFiles }
        let fm = FileManager.default
        let root = folder.appendingPathComponent(Self.journalDirectoryName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var journal = Journal(committed: false, entries: [])
        do {
            let entries = try files.keys.sorted().map { name -> Entry in
                try fault(.stage(name))
                let target = folder.appendingPathComponent(name)
                let existed = fm.fileExists(atPath: target.path)
                if existed {
                    let original = try Data(contentsOf: target)
                    try durableWrite(original, to: root.appendingPathComponent("old-" + name))
                }
                try durableWrite(files[name]!, to: root.appendingPathComponent("new-" + name))
                return Entry(name: name, existed: existed)
            }
            journal = Journal(committed: false, entries: entries)
            try fault(.publishJournal)
            try writeJournal(journal, in: root)
            try fault(.stagingPublished)
            try syncDirectory(folder)
        } catch {
            // If a prepared journal was published, resolve it durably before
            // removing even one backup. Canonical files are still untouched.
            if fm.fileExists(atPath: root.appendingPathComponent("journal.json").path) {
                do { try resolveAndCleanup(journal, root: root, folder: folder) }
                catch { throw Failure.recoveryRequired(error.localizedDescription) }
            } else {
                try? fm.removeItem(at: root)
            }
            throw error
        }

        do {
            for entry in journal.entries {
                try fault(.replace(entry.name))
                let staged = try Data(contentsOf: root.appendingPathComponent("new-" + entry.name))
                try durableWrite(staged, to: folder.appendingPathComponent(entry.name))
            }
            try syncDirectory(folder)
            try fault(.commitJournal)
            journal.committed = true
            try writeJournal(journal, in: root)
        } catch {
            do {
                // If committing the journal itself failed, retain prepared
                // state before attempting rollback, including after a restart.
                journal.committed = false
                try writeJournal(journal, in: root)
                try restore(journal, from: root, in: folder)
                try resolveAndCleanup(journal, root: root, folder: folder)
            } catch let recoveryError {
                throw Failure.recoveryRequired(recoveryError.localizedDescription)
            }
            throw error
        }
        // A cleanup failure does not undo a durable commit. Recovery recognizes
        // the committed journal and only removes it.
        // Fault injection may model a crash during recursive cleanup.
        do {
            try fault(.cleanupResolved)
            try fm.removeItem(at: root)
            try syncDirectory(folder)
        } catch { /* committed marker remains authoritative */ }
    }

    private func recoverOwned(in folder: URL) throws {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(Self.journalDirectoryName, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return }
        let journalURL = root.appendingPathComponent("journal.json")
        guard fm.fileExists(atPath: journalURL.path) else {
            // An interrupted staging pass never changes canonical files.
            try fm.removeItem(at: root)
            return
        }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            let names = journal.entries.map(\.name)
            guard !names.isEmpty, Set(names).count == names.count, Set(names).isSubset(of: Self.allowed) else {
                throw Failure.invalidFiles
            }
            if !journal.committed { try restore(journal, from: root, in: folder) }
            try resolveAndCleanup(journal, root: root, folder: folder)
        } catch {
            throw Failure.recoveryRequired(error.localizedDescription)
        }
    }

    /// `committed` is the historical keep-canonical marker. It also marks a
    /// completely restored (old) snapshot. Once durable, interrupted cleanup no
    /// longer needs backups that recursive removal may already have deleted.
    private func resolveAndCleanup(_ journal: Journal, root: URL, folder: URL) throws {
        var resolved = journal
        resolved.committed = true
        try writeJournal(resolved, in: root)
        try fault(.cleanupResolved)
        try FileManager.default.removeItem(at: root)
        try syncDirectory(folder)
    }

    private func restore(_ journal: Journal, from root: URL, in folder: URL) throws {
        for entry in journal.entries {
            try fault(.restore(entry.name))
            let target = folder.appendingPathComponent(entry.name)
            if entry.existed {
                let original = try Data(contentsOf: root.appendingPathComponent("old-" + entry.name))
                try durableWrite(original, to: target)
            } else if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
        try syncDirectory(folder)
    }

    private func writeJournal(_ journal: Journal, in root: URL) throws {
        try durableWrite(JSONEncoder().encode(journal), to: root.appendingPathComponent("journal.json"))
        try syncDirectory(root)
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try Data(contentsOf: url) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func syncDirectory(_ folder: URL) throws {
        let fd = open(folder.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
