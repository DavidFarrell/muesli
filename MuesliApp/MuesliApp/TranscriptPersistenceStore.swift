import Foundation
import Darwin

/// Canonical transcript files form one recoverable transaction. A prepared
/// journal always means restore the prior snapshot; a committed journal means
/// keep the new snapshot. Readers must recover before opening canonical files.
nonisolated final class TranscriptPersistenceStore: Sendable {
    enum Step: Equatable, Sendable {
        case stage(String)
        case publishJournal
        case replace(String)
        case commitJournal
        case restore(String)
    }

    enum Failure: Error, LocalizedError {
        case invalidFiles
        case recoveryRequired(String)

        var errorDescription: String? {
            switch self {
            case .invalidFiles: return "The transcript transaction contains an invalid file."
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
    private static let lock = NSRecursiveLock()
    private static let allowed = Set(["transcript.txt", "transcript.jsonl", "meeting.json", "transcript_sources.json"])
    private let fault: @Sendable (Step) throws -> Void

    init(fault: @escaping @Sendable (Step) throws -> Void = { _ in }) {
        self.fault = fault
    }

    func commit(files: [String: Data], in folder: URL) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !files.isEmpty, Set(files.keys).isSubset(of: Self.allowed) else { throw Failure.invalidFiles }
        try recover(in: folder)
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
            try syncDirectory(folder)
        } catch {
            // Canonical files have not been touched yet.
            try? fm.removeItem(at: root)
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
                try fm.removeItem(at: root)
                try syncDirectory(folder)
            } catch let recoveryError {
                throw Failure.recoveryRequired(recoveryError.localizedDescription)
            }
            throw error
        }
        // A cleanup failure does not undo a durable commit. Recovery recognizes
        // the committed journal and only removes it.
        try? fm.removeItem(at: root)
        try? syncDirectory(folder)
    }

    func recover(in folder: URL) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
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
            try fm.removeItem(at: root)
            try syncDirectory(folder)
        } catch {
            throw Failure.recoveryRequired(error.localizedDescription)
        }
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
