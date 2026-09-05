import Foundation

/// Every edit is a fresh metadata read + field patch + transaction under the
/// same folder owner. It never replaces session/source metadata with a UI copy.
nonisolated enum MeetingMetadataMutation {
    struct Patch: Sendable {
        var title: String? = nil
        var names: [String: String] = [:]
        var contentGeneration: UInt64 = 0
    }
    static func start(in folder: URL, patch: Patch, store: TranscriptPersistenceStore = .shared,
                      onCompletion: @escaping @Sendable (Result<MeetingMetadata, TranscriptPersistenceStore.Failure>) -> Void = { _ in }) throws -> TranscriptPersistenceStore.Operation<MeetingMetadata> {
        let title = patch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { throw MeetingRenameError.emptyTitle }
        return try store.start(in: folder, onCompletion: onCompletion) { context in
            var metadata = try context.readMetadata()
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
    enum Event {
        case committed(URL, MeetingMetadata, MeetingMetadataMutation.Patch)
        case pending(URL)
        case failed(URL, String)
    }
    private struct Active {
        let id: UUID
        let patch: MeetingMetadataMutation.Patch
        let operation: TranscriptPersistenceStore.Operation<MeetingMetadata>
    }
    private let store: TranscriptPersistenceStore
    private let timeoutSeconds: Double
    private let onEvent: @MainActor (Event) -> Void
    private var active: [URL: Active] = [:]
    private var desiredNames: [URL: MeetingMetadataMutation.Patch] = [:]
    init(store: TranscriptPersistenceStore = .shared, timeoutSeconds: Double = 5,
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.store = store; self.timeoutSeconds = timeoutSeconds; self.onEvent = onEvent
    }
    func isPending(in folder: URL) -> Bool { active[folder] != nil }

    func submitNames(_ names: [String: String], in folder: URL, contentGeneration: UInt64) {
        guard !names.isEmpty else { return }
        if active[folder] != nil {
            var patch = desiredNames[folder] ?? MeetingMetadataMutation.Patch(contentGeneration: contentGeneration)
            // A new viewer generation supersedes queued UI edits to old labels.
            if patch.contentGeneration != contentGeneration { patch.names = [:] }
            patch.contentGeneration = contentGeneration
            patch.names.merge(names) { _, latest in latest }
            desiredNames[folder] = patch
        } else {
            do { _ = try start(in: folder, patch: .init(names: names, contentGeneration: contentGeneration)) }
            catch { onEvent(.failed(folder, error.localizedDescription)) }
        }
    }

    func rename(in folder: URL, to title: String) async throws -> String {
        guard active[folder] == nil else { throw TranscriptPersistenceStore.Failure.busy }
        let operation = try start(in: folder, patch: .init(title: title))
        return try await operation.value(timeoutSeconds: timeoutSeconds).title
    }

    @discardableResult
    private func start(in folder: URL, patch: MeetingMetadataMutation.Patch) throws -> TranscriptPersistenceStore.Operation<MeetingMetadata> {
        let id = UUID()
        let operation = try MeetingMetadataMutation.start(in: folder, patch: patch, store: store) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in self.finish(id: id, folder: folder, result: result) }
        }
        active[folder] = Active(id: id, patch: patch, operation: operation)
        Task { @MainActor [weak self] in
            let outcome = await operation.wait(timeoutSeconds: self?.timeoutSeconds ?? 5)
            guard let self, self.active[folder]?.id == id else { return }
            switch outcome {
            case .timedOut, .cancelled: self.onEvent(.pending(folder))
            case .completed, .failed: break // The original callback publishes once.
            }
        }
        return operation
    }

    private func finish(id: UUID, folder: URL,
                        result: Result<MeetingMetadata, TranscriptPersistenceStore.Failure>) {
        guard let current = active[folder], current.id == id else { return }
        active.removeValue(forKey: folder) // Retire before any late timeout UI task.
        switch result {
        case .success(let metadata): onEvent(.committed(folder, metadata, current.patch))
        case .failure(let error): onEvent(.failed(folder, error.localizedDescription))
        }
        if var next = desiredNames.removeValue(forKey: folder) {
            if case .failure = result, current.patch.contentGeneration == next.contentGeneration {
                next.names = current.patch.names.merging(next.names) { _, newer in newer }
            }
            do { _ = try start(in: folder, patch: next) }
            catch { onEvent(.failed(folder, error.localizedDescription)) }
        }
    }
}
