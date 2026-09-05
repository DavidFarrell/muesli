import Foundation

/// One retained scan, with one folder owner at a time. An expired UI wait never
/// starts another scan or releases a blocked recovery operation.
nonisolated final class MeetingCatalogOwner: @unchecked Sendable {
    struct Snapshot: Sendable {
        let items: [MeetingHistoryItem]
        let unresolved: Set<URL>
        let problems: [String]
    }
    enum Outcome: Sendable { case completed(Snapshot), failed(String), timedOut, cancelled, busy }
    enum Step: Sendable { case enumerate, inspect(URL), beforeRecovery(URL) }
    private final class Attempt: @unchecked Sendable {
        let done = TaskCompletion()
        private let lock = NSLock()
        private var result: Result<Snapshot, Error>?
        func finish(_ result: Result<Snapshot, Error>) { lock.withLock { self.result = result }; done.markCompleted() }
        func outcome() -> Outcome {
            lock.withLock {
                switch result! {
                case .success(let snapshot): return .completed(snapshot)
                case .failure(let error): return .failed(error.localizedDescription)
                }
            }
        }
    }
    private let lock = NSLock()
    private var active: Attempt?
    private var recoveryEpoch: UInt64 = 0
    private var protectedFolders: Set<String> = []
    private let queue = DispatchQueue(label: "muesli.meeting-catalog", qos: .utility)
    private let store: TranscriptPersistenceStore
    private let checkpoint: @Sendable (Step) throws -> Void
    init(store: TranscriptPersistenceStore = .shared,
         checkpoint: @escaping @Sendable (Step) throws -> Void = { _ in }) {
        self.store = store; self.checkpoint = checkpoint
    }
    var isBusy: Bool { lock.withLock { active != nil } }
    /// A session started by this process has a finalizer owner. Even between
    /// source close and metadata commit, catalog discovery must not recover it.
    func protect(_ folder: URL) {
        lock.withLock { protectedFolders.insert(folder.standardizedFileURL.path); recoveryEpoch &+= 1 }
    }
    /// Call before a new start/resume can be dispatched. Existing scans may
    /// still read metadata, but cannot later recover that new capture as orphaned.
    func invalidateRecovery() { lock.withLock { recoveryEpoch &+= 1 } }

    @concurrent func scan(in base: URL, timeoutSeconds: Double = 5,
                          onCompletion: @escaping @Sendable (Outcome) -> Void = { _ in }) async -> Outcome {
        let attempt = Attempt()
        let epoch: UInt64? = lock.withLock {
            guard active == nil else { return nil }
            active = attempt
            return recoveryEpoch
        }
        guard let epoch else { return .busy }
        queue.async { [self] in
            let result = Result { try inspect(base: base, epoch: epoch) }
            lock.withLock { if active === attempt { active = nil } }
            attempt.finish(result)
            onCompletion(attempt.outcome())
        }
        switch await attempt.done.wait(timeoutSeconds: timeoutSeconds) {
        case .completed: return attempt.outcome()
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
    }

    private func inspect(base: URL, epoch: UInt64) throws -> Snapshot {
        try checkpoint(.enumerate)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else {
            return Snapshot(items: [], unresolved: [], problems: [])
        }
        let folders = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        guard folders.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
        var items: [MeetingHistoryItem] = []
        var unresolved: Set<URL> = []
        var problems: [String] = []
        for folder in folders {
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let terminal = DispatchSemaphore(value: 0)
            do {
                let operation = try store.start(in: folder, onCompletion: { _ in terminal.signal() }) { [self] context in
                    try checkpoint(.inspect(folder))
                    var metadata: MeetingMetadata
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.json").path) {
                        metadata = try context.readMetadata()
                    } else {
                        let legacy = try LegacyMeetingMetadata.buildLegacyMeetingMetadata(for: folder)
                        metadata = legacy
                        try Self.commit(metadata, context: context)
                    }
                    if OrphanedMeetingRecovery.needsRecovery(metadata), mayRecover(epoch, folder: folder) {
                        try checkpoint(.beforeRecovery(folder))
                        // New recorders retain OS leases through actual close.
                        // Folder ownership also excludes a new preparation here.
                        var artifactLeases: [FileHandle] = []
                        defer { for lease in artifactLeases { try? lease.close() } }
                        for session in metadata.sessions {
                            let root = folder.standardizedFileURL.resolvingSymlinksInPath()
                            let audio = root.appendingPathComponent(session.audioFolder).standardizedFileURL.resolvingSymlinksInPath()
                            guard audio.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
                            do {
                                try LocalAudioRecorder.withInactiveSource(directory: audio) { }
                                if let relative = session.artifactsFolder {
                                    let artifacts = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                                    guard artifacts.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
                                    if let lease = try SessionArtifactStore.acquireInactiveLease(directory: artifacts) { artifactLeases.append(lease) }
                                }
                            } catch {
                                // An active recorder owns this source even if its
                                // UI wait expired. Keep its recording status.
                                return Self.item(metadata, folder: folder)
                            }
                        }
                        if mayRecover(epoch, folder: folder) {
                            let evidence = OrphanedMeetingRecovery.inspectAndRecover(folderURL: folder, metadata: metadata)
                            // A start invalidates all outstanding recovery writes,
                            // including one whose media read took a long time.
                            if mayRecover(epoch, folder: folder) {
                                metadata = OrphanedMeetingRecovery.finalize(metadata, evidence: evidence, now: Date())
                                try Self.commit(metadata, context: context)
                            }
                        }
                    }
                    return Self.item(metadata, folder: folder)
                }
                // This is one retained catalog worker, not an observer Task per
                // timeout. The original child owner signals actual completion.
                terminal.wait()
                // Completion is already signalled. Read its result through a
                // callback-owned result box, avoiding an async bridge here.
                items.append(try operation.completedValue())
            } catch {
                unresolved.insert(folder)
                if problems.count < 100 { problems.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        return Snapshot(items: items.sorted { $0.createdAt > $1.createdAt }, unresolved: unresolved, problems: problems)
    }
    private func mayRecover(_ epoch: UInt64, folder: URL) -> Bool {
        lock.withLock { recoveryEpoch == epoch && !protectedFolders.contains(folder.standardizedFileURL.path) }
    }
    static func item(_ metadata: MeetingMetadata, folder: URL) -> MeetingHistoryItem {
        MeetingHistoryItem(id: folder.lastPathComponent, folderURL: folder, title: metadata.title,
                           createdAt: metadata.createdAt, durationSeconds: metadata.durationSeconds,
                           segmentCount: metadata.segmentCount, status: metadata.status)
    }
    /// Called only after the user's existing delete confirmation. The source
    /// lease and folder reservation apply to the actual move, including a stall.
    static func trash(in folder: URL, store: TranscriptPersistenceStore = .shared,
                      onCompletion: @escaping @Sendable (Result<Void, TranscriptPersistenceStore.Failure>) -> Void,
                      move: @escaping @Sendable (URL) throws -> Void = { folder in
                          var destination: NSURL?
                          try FileManager.default.trashItem(at: folder, resultingItemURL: &destination)
                      }) throws -> TranscriptPersistenceStore.Operation<Void> {
        try store.start(in: folder, onCompletion: onCompletion) { context in
            let inferenceLease = try BackendMeetingLease.acquire(in: folder, exclusive: true)
            defer { try? inferenceLease.close() }
            let metadata = try context.readMetadata()
            let root = folder.standardizedFileURL.resolvingSymlinksInPath()
            var artifactLeases: [FileHandle] = []
            defer { for lease in artifactLeases { try? lease.close() } }
            for session in metadata.sessions {
                let audio = root.appendingPathComponent(session.audioFolder).standardizedFileURL.resolvingSymlinksInPath()
                guard audio.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
                try LocalAudioRecorder.withInactiveSource(directory: audio) { }
                if let relative = session.artifactsFolder {
                    let artifacts = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                    guard artifacts.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
                    if let lease = try SessionArtifactStore.acquireInactiveLease(directory: artifacts) {
                        artifactLeases.append(lease)
                    }
                }
            }
            try move(folder)
        }
    }

    static func commit(_ metadata: MeetingMetadata, context: TranscriptPersistenceStore.Context) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try context.commit(files: ["meeting.json": encoder.encode(metadata)])
    }
}

/// UI observation belongs to a request generation. Deadlines may publish a
/// pending notice once, but only the original terminal callback ends a scan.
@MainActor
final class MeetingCatalogController {
    enum Event { case committed(MeetingCatalogOwner.Snapshot), pending, discarded, failed(String) }
    private let owner: MeetingCatalogOwner
    private let timeoutSeconds: Double
    private let onEvent: @MainActor (Event) -> Void
    private var revision: UInt64 = 0
    private var activeID: UUID?
    private var requestedBase: URL?
    init(owner: MeetingCatalogOwner = MeetingCatalogOwner(), timeoutSeconds: Double = 5,
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.owner = owner; self.timeoutSeconds = timeoutSeconds; self.onEvent = onEvent
    }
    func protect(_ folder: URL) {
        owner.protect(folder)
        invalidate()
    }
    func invalidate() {
        revision &+= 1
        owner.invalidateRecovery()
        // A stale in-flight snapshot is discarded. Its completion still ends
        // the owner; refresh requests are coalesced independently.
    }
    func refresh(in base: URL) {
        guard activeID == nil else { requestedBase = base; return }
        let id = UUID(), capturedRevision = revision
        activeID = id
        Task { [weak self, owner, timeoutSeconds] in
            let outcome = await owner.scan(in: base, timeoutSeconds: timeoutSeconds) { [weak self] result in
                guard let self else { return }
                Task { @MainActor in self.finish(result, id: id, revision: capturedRevision) }
            }
            guard let self, self.activeID == id else { return }
            switch outcome {
            case .timedOut, .cancelled: self.onEvent(.pending)
            case .busy: self.finish(.failed("A history read is already active."), id: id, revision: capturedRevision)
            default: break
            }
        }
    }
    private func finish(_ result: MeetingCatalogOwner.Outcome, id: UUID, revision captured: UInt64) {
        guard activeID == id else { return }
        activeID = nil
        if captured == revision {
            switch result {
            case .completed(let snapshot): onEvent(.committed(snapshot))
            case .failed(let message): onEvent(.failed(message))
            default: break
            }
        } else {
            onEvent(.discarded) // Clear a pending notice without publishing stale rows.
        }
        if let next = requestedBase { requestedBase = nil; refresh(in: next) }
    }
}
