import Foundation

/// The CLI can select source/vault/receipt paths; native app configuration owns
/// the backend, output roots, semantic worker and final filesystem operation.
nonisolated final class ArchiveApplicationBridge: Sendable {
    final class BackendSelection: @unchecked Sendable {
        private let lock = NSLock()
        enum Selection: Sendable {
            case packaged(LocalInferenceSelection)
            #if DEBUG
            case development(URL)
            #endif
        }
        private var value: Selection?
        func setInference(_ value: LocalInferenceSelection?) { lock.withLock { self.value = value.map(Selection.packaged) } }
        #if DEBUG
        func set(_ value: URL?) { lock.withLock { self.value = value.map(Selection.development) } }
        #endif
        var selected: Selection? { lock.withLock { value } }
    }
    private final class Context: Sendable {
        let adapter: ArchiveSemanticAdapter
        let prepared: ArchiveSemanticAdapter.Prepared
        init(adapter: ArchiveSemanticAdapter, prepared: ArchiveSemanticAdapter.Prepared) {
            self.adapter = adapter; self.prepared = prepared
        }
    }
    private enum Failure: Error, LocalizedError {
        case backendNotConfigured
        var errorDescription: String? { "Enable local transcription in Muesli before processing an archive." }
    }
    private let listener: ArchiveListenerLifecycle

    init(backend: BackendSelection, paths: ArchiveApplicationDirectories.Paths = .standard,
         shutdown: ShutdownWorkRegistry = .shared,
         publish: (@MainActor @Sendable (ArchiveListenerLifecycle.Snapshot) -> Void)? = nil) {
        let workflow = ArchiveWorkflowOwner<Context>(
            acquireWorkToken: { try shutdown.beginUserWork("Preparing or finalizing archive outputs") },
            acquireRetirementToken: { try shutdown.begin("Closing archive output ownership") },
            prepare: { begin, operationID in
                guard let selected = backend.selected else { throw Failure.backendNotConfigured }
                // This read is native configuration, captured for this original
                // operation. Later settings changes cannot replace its adapter.
                let configuration: ArchiveSemanticAdapter.Configuration
                switch selected {
                case .packaged(let inference):
                    configuration = .init(inference: inference, outputRoot: paths.output, journalRoot: paths.journal)
                #if DEBUG
                case .development(let root):
                    configuration = .init(backendRoot: root, outputRoot: paths.output, journalRoot: paths.journal)
                #endif
                }
                let adapter = ArchiveSemanticAdapter(configuration: configuration)
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
