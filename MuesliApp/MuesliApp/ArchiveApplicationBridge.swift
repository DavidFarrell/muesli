import Foundation

/// The CLI can select source/vault/receipt paths; native app configuration owns
/// the backend, output roots, semantic worker and final filesystem operation.
nonisolated final class ArchiveApplicationBridge: Sendable {
    final class BackendSelection: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL?
        func set(_ value: URL?) { lock.withLock { self.value = value } }
        var selected: URL? { lock.withLock { value } }
    }
    private final class Context: Sendable {
        let adapter: ArchiveSemanticAdapter
        let prepared: ArchiveSemanticAdapter.Prepared
        init(adapter: ArchiveSemanticAdapter, prepared: ArchiveSemanticAdapter.Prepared) {
            self.adapter = adapter; self.prepared = prepared
        }
    }
    private enum Failure: Error { case backendNotConfigured }
    private let listener: ArchiveListenerLifecycle

    init(backend: BackendSelection, paths: ArchiveApplicationDirectories.Paths = .standard,
         shutdown: ShutdownWorkRegistry = .shared,
         publish: (@MainActor @Sendable (ArchiveListenerLifecycle.Snapshot) -> Void)? = nil) {
        let workflow = ArchiveWorkflowOwner<Context>(
            acquireWorkToken: { try shutdown.beginUserWork("Preparing or finalizing archive outputs") },
            acquireRetirementToken: { try shutdown.begin("Closing archive output ownership") },
            prepare: { begin, operationID in
                guard let backendRoot = backend.selected else { throw Failure.backendNotConfigured }
                // This read is native configuration, captured for this original
                // operation. Later settings changes cannot replace its adapter.
                let adapter = ArchiveSemanticAdapter(configuration: .init(backendRoot: backendRoot,
                    outputRoot: paths.output, journalRoot: paths.journal))
                let prepared = try await adapter.prepare(.init(sourcePath: begin.sourcePath, vaultPath: begin.vaultPath), operationID: operationID)
                return .init(context: Context(adapter: adapter, prepared: prepared.context), outputManifestPath: prepared.outputManifestPath)
            }, finalize: { context, receiptPath, operationID in
                switch await context.adapter.finalize(context.prepared, receiptPath: receiptPath, operationID: operationID) {
                case .needsCorrection: return .needsCorrection
                case .retained: return .retained
                case .trashed: return .trashed
                case .uncertain: return .uncertain
                }
            })
        listener = ArchiveListenerLifecycle(workflow: workflow, shutdown: shutdown, factory: { closed in
            try ArchiveApplicationDirectories.ensure(paths)
            return try ArchiveWorkflowServer(directory: paths.endpoint, onClosed: closed, handler: { workflow.handle($0) })
        }, publish: publish)
    }
    @discardableResult func enable() -> Bool { listener.enable() }
    func closeAdmissionForQuit() { listener.closeAdmissionForQuit() }
    func reopenAfterCancelledQuit() { listener.reopenAfterCancelledQuit() }
    var snapshot: ArchiveListenerLifecycle.Snapshot { listener.snapshot }
    var hasActualListenerOwner: Bool { listener.hasActualOwner }
}
