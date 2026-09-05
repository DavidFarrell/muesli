import Foundation

/// Every edit is a fresh metadata read + field patch + transaction under the
/// same folder owner. It never replaces session/source metadata with a UI copy.
nonisolated enum MeetingMetadataMutation {
    struct Patch: Sendable {
        var title: String? = nil
        var names: [String: String] = [:]
        var contentGeneration: UInt64 = 0
        var expectedNames: [String: String]? = nil
    }
    static func start(in folder: URL, patch: Patch, store: TranscriptPersistenceStore = .shared,
                      onCompletion: @escaping @Sendable (Result<MeetingMetadata, TranscriptPersistenceStore.Failure>) -> Void = { _ in }) throws -> TranscriptPersistenceStore.Operation<MeetingMetadata> {
        let title = patch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { throw MeetingRenameError.emptyTitle }
        return try store.start(in: folder, onCompletion: onCompletion) { context in
            var metadata = try context.readMetadata()
            if let expected = patch.expectedNames, expected != metadata.speakerNames {
                throw TranscriptPersistenceStore.Failure.operationFailed("Speaker names changed after identification. Identify speakers again before applying suggestions.")
            }
            if let title { metadata.title = title }
            metadata.speakerNames.merge(patch.names) { _, reviewed in reviewed }
            metadata.updatedAt = Date()
            try MeetingCatalogOwner.commit(metadata, context: context)
            return metadata
        }
    }
}

/// One active edit and one coalesced set of later name edits per folder. The
/// terminal callback, not a waiter deadline, releases this coordinator's owner.
@MainActor
final class MeetingMetadataEdits {
    typealias Publication = @MainActor @Sendable () -> Void
    typealias Delivery = @Sendable (@escaping Publication) -> Void
    enum Event {
        case committed(URL, MeetingMetadata, MeetingMetadataMutation.Patch)
        case pending(URL, UUID)
        case failed(URL, String, UUID)
    }
    private struct Active {
        let id: UUID
        let patch: MeetingMetadataMutation.Patch
        let operation: TranscriptPersistenceStore.Operation<MeetingMetadata>
    }
    private let store: TranscriptPersistenceStore
    private let timeoutSeconds: Double
    private let onEvent: @MainActor (Event) -> Void
    private let deliver: Delivery
    private var active: [URL: Active] = [:]
    private var desiredNames: [URL: MeetingMetadataMutation.Patch] = [:]
    private var retired: Set<URL> = []
    private var transferredNameIDs: [URL: Set<UUID>] = [:]
    private var superseded: Set<UUID> = []
    init(store: TranscriptPersistenceStore = .shared, timeoutSeconds: Double = 5,
         deliver: @escaping Delivery = { publication in Task { @MainActor in publication() } },
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.store = store; self.timeoutSeconds = timeoutSeconds; self.onEvent = onEvent
        self.deliver = deliver
    }
    func isPending(in folder: URL) -> Bool { active[folder] != nil || retired.contains(folder) }

    /// Stop transfers accepted name intent into its immutable finalizer payload.
    /// The active disk operation is not cancelled or released; the finalizer
    /// must queue behind that owner and apply this patch after reading metadata.
    func retire(in folder: URL) -> [String: String] {
        retired.insert(folder)
        let operation = active[folder]
        if let operation, operation.patch.expectedNames == nil, operation.patch.title == nil, !operation.patch.names.isEmpty {
            transferredNameIDs[folder, default: []].insert(operation.id)
        }
        // Conditional suggestions must pass their own fresh-disk comparison.
        // A finalizer reads any actual commit; it must not turn an unresolved
        // conditional proposal into an unconditional transferred name intent.
        let current = operation?.patch.expectedNames == nil ? (operation?.patch.names ?? [:]) : [:]
        let queued = desiredNames.removeValue(forKey: folder)?.names ?? [:]
        return current.merging(queued) { _, latest in latest }
    }
    /// A successful successor supersedes only the name operations whose intent
    /// it received. Keep the active slot until its original callback arrives;
    /// suppress both delayed pending and terminal publication from those IDs.
    /// Returned IDs authorize clearing only those operations' own notices.
    @discardableResult
    func completeRetirement(in folder: URL, successorSucceeded: Bool) -> Set<UUID> {
        retired.remove(folder)
        let transferred = transferredNameIDs.removeValue(forKey: folder) ?? []
        guard successorSucceeded else { return [] }
        if let current = active[folder], transferred.contains(current.id) {
            superseded.insert(current.id)
        }
        return transferred
    }

    func submitNames(_ names: [String: String], in folder: URL, contentGeneration: UInt64, expectedNames: [String: String]? = nil) {
        guard !names.isEmpty else { return }
        guard !retired.contains(folder) else {
            onEvent(.failed(folder, "This meeting is finishing its saved transcript. Wait for that save before editing speakers.", UUID()))
            return
        }
        if active[folder] != nil {
            guard expectedNames == nil else {
                onEvent(.failed(folder, "A speaker edit is still pending. Wait before applying identification suggestions.", UUID()))
                return
            }
            var patch = desiredNames[folder] ?? MeetingMetadataMutation.Patch(contentGeneration: contentGeneration)
            // A new viewer generation supersedes queued UI edits to old labels.
            if patch.contentGeneration != contentGeneration { patch.names = [:] }
            patch.contentGeneration = contentGeneration
            patch.names.merge(names) { _, latest in latest }
            desiredNames[folder] = patch
        } else {
            do { _ = try start(in: folder, patch: .init(names: names, contentGeneration: contentGeneration, expectedNames: expectedNames)) }
            catch { onEvent(.failed(folder, error.localizedDescription, UUID())) }
        }
    }

    func rename(in folder: URL, to title: String) async throws -> String {
        guard active[folder] == nil, !retired.contains(folder) else { throw TranscriptPersistenceStore.Failure.busy }
        let operation = try start(in: folder, patch: .init(title: title))
        return try await operation.value(timeoutSeconds: timeoutSeconds).title
    }

    @discardableResult
    private func start(in folder: URL, patch: MeetingMetadataMutation.Patch) throws -> TranscriptPersistenceStore.Operation<MeetingMetadata> {
        let id = UUID()
        let operation = try MeetingMetadataMutation.start(in: folder, patch: patch, store: store) { [weak self, deliver] result in
            guard let self else { return }
            deliver { self.finish(id: id, folder: folder, result: result) }
        }
        active[folder] = Active(id: id, patch: patch, operation: operation)
        Task { @MainActor [weak self, deliver] in
            let outcome = await operation.wait(timeoutSeconds: self?.timeoutSeconds ?? 5)
            guard let self else { return }
            switch outcome {
            case .timedOut, .cancelled:
                deliver { self.publishPending(id: id, folder: folder) }
            case .completed, .failed: break // The original callback publishes once.
            }
        }
        return operation
    }

    private func publishPending(id: UUID, folder: URL) {
        guard active[folder]?.id == id, !superseded.contains(id) else { return }
        onEvent(.pending(folder, id))
    }

    private func finish(id: UUID, folder: URL,
                        result: Result<MeetingMetadata, TranscriptPersistenceStore.Failure>) {
        guard let current = active[folder], current.id == id else { return }
        active.removeValue(forKey: folder) // Retire before any late timeout UI task.
        if superseded.remove(id) == nil {
            switch result {
            case .success(let metadata):
                onEvent(.committed(folder, metadata, current.patch))
            case .failure(let error):
                onEvent(.failed(folder, error.localizedDescription, id))
            }
        }
        if var next = desiredNames.removeValue(forKey: folder) {
            if case .failure = result, current.patch.contentGeneration == next.contentGeneration {
                next.names = current.patch.names.merging(next.names) { _, newer in newer }
            }
            do { _ = try start(in: folder, patch: next) }
            catch { onEvent(.failed(folder, error.localizedDescription, UUID())) }
        }
    }
}
