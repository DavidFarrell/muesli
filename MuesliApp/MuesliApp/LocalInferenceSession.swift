import Foundation

/// A session selection is native app configuration, immutable for each accepted
/// operation. The broker alone displays the folder panel and creates bookmarks.
nonisolated struct LocalInferenceSelection: Sendable {
    let runtime: PackagedInferenceRuntime
    let sources: SourceCapabilityOwner

    func configuration(folder: URL, operation: MuesliInferenceOperation,
                       streams: MuesliInferenceStreams, liveSource: MuesliLiveSource? = nil) throws -> BackendXPCJobOwner.Configuration {
        guard sources.isAuthorizedSession else {
            throw BackendAdmissionOwner.Failure(message: "Enable local transcription again to authorize this session.")
        }
        return .init(operation: operation, streams: streams, liveSource: liveSource,
                     expectedRuntimeSHA256: runtime.runtimeManifestSHA256,
                     expectedModelsSHA256: runtime.modelManifestSHA256,
                     sourceCapabilityOwner: sources, sourceFolder: folder)
    }
}

/// Retains actual preparation through its worker's return. Retiring a caller,
/// task or Quit intent cancels authorization; it never abandons the worker.
nonisolated final class LocalInferenceSession: @unchecked Sendable {
    private final class Preparation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var owner: SourceCapabilityOwner?
        func install(_ value: SourceCapabilityOwner) throws {
            let retired = lock.withLock { owner = value; return cancelled }
            if retired { value.retireAdmission(); throw CancellationError() }
        }
        func requireCurrent() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
        func cancel() {
            let value = lock.withLock { cancelled = true; return owner }
            value?.retireAdmission()
        }
        func retireIntent() { lock.withLock { cancelled = true } }
    }
    private let lock = NSLock()
    private var selection: LocalInferenceSelection?
    private var preparation: Preparation?
    private var unavailabilityObserver: (@Sendable () -> Void)?
    private let shutdown: ShutdownWorkRegistry
    private let loadRuntime: @Sendable () throws -> PackagedInferenceRuntime
    private let prepareRoot: @Sendable () throws -> URL
    private let makeSourceOwner: @Sendable (URL) throws -> SourceCapabilityOwner

    init() {
        shutdown = .shared
        loadRuntime = { try PackagedInferenceRuntime.load() }
        prepareRoot = {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Muesli/Meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        makeSourceOwner = { try SourceCapabilityOwner(expectedRoot: $0) }
    }

    #if MUESLI_LOCAL_INFERENCE_TESTING
    enum Checkpoint: Sendable { case afterAuthorization, beforeWorkerReturn }
    private var checkpoint: @Sendable (Checkpoint) -> Void = { _ in }
    /// Compile-time-only model-free injection. Production never defines this
    /// flag, receives an alternate package/root, or substitutes its broker.
    init(testingShutdown: ShutdownWorkRegistry,
         loadRuntime: @escaping @Sendable () throws -> PackagedInferenceRuntime,
         prepareRoot: @escaping @Sendable () throws -> URL,
         makeSourceOwner: @escaping @Sendable (URL) throws -> SourceCapabilityOwner,
         checkpoint: @escaping @Sendable (Checkpoint) -> Void = { _ in }) {
        shutdown = testingShutdown
        self.loadRuntime = loadRuntime
        self.prepareRoot = prepareRoot
        self.makeSourceOwner = makeSourceOwner
        self.checkpoint = checkpoint
    }
    #endif

    var isReady: Bool { lock.withLock { selection?.sources.isAuthorizedSession == true } }

    /// Notifications are advisory and delivered outside the manager lock. UI
    /// consumers recheck isReady on their own executor before clearing state.
    func observeUnavailability(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { unavailabilityObserver = callback }
    }

    private func sourceBecameUnavailable(_ owner: SourceCapabilityOwner, operation: Preparation?) {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            let ownsPreparation = operation.map { preparation === $0 } ?? false
            guard ownsPreparation || selection?.sources === owner else { return nil }
            // No callback into the source owner while holding our lock. Its
            // notification already establishes failure/retirement; latch only
            // the original preparation intent so late success cannot publish.
            operation?.retireIntent()
            if selection?.sources === owner { selection = nil }
            return unavailabilityObserver
        }
        callback?()
    }

    func prepare() async throws -> LocalInferenceSelection {
        try Task.checkCancellation()
        let operation = Preparation()
        let existing: LocalInferenceSelection? = try lock.withLock {
            if let selection, selection.sources.isAuthorizedSession { return selection }
            guard preparation == nil else {
                throw BackendAdmissionOwner.Failure(message: "The previous transcription setup is still closing. Try again shortly.")
            }
            preparation = operation
            return nil
        }
        if let existing { return existing }
        let token: ShutdownWorkRegistry.Token
        do {
            token = try shutdown.beginUserWork("Preparing local transcription access", onQuit: { operation.cancel() })
        } catch {
            lock.withLock { if preparation === operation { preparation = nil } }
            throw error
        }
        let worker = Task.detached { [self] in
            defer {
                #if MUESLI_LOCAL_INFERENCE_TESTING
                checkpoint(.beforeWorkerReturn)
                #endif
                lock.withLock { if preparation === operation { preparation = nil } }
                token.finish()
            }
            do {
                try operation.requireCurrent()
                let runtime = try loadRuntime()
                try operation.requireCurrent()
                let root = try prepareRoot()
                let owner = try makeSourceOwner(root)
                try operation.install(owner)
                owner.observeUnavailability { [weak self, weak owner, weak operation] in
                    guard let owner else { return }
                    self?.sourceBecameUnavailable(owner, operation: operation)
                }
                try owner.authorizeSession()
                #if MUESLI_LOCAL_INFERENCE_TESTING
                checkpoint(.afterAuthorization)
                #endif
                try operation.requireCurrent()
                let value = LocalInferenceSelection(runtime: runtime, sources: owner)
                try lock.withLock {
                    try operation.requireCurrent()
                    guard owner.isAuthorizedSession else {
                        throw BackendAdmissionOwner.Failure(message: "The local transcription source session became unavailable before preparation completed.")
                    }
                    selection = value
                }
                return value
            } catch {
                operation.cancel()
                throw error
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        }, onCancel: { operation.cancel() })
    }

    func beginShutdown() {
        let state = lock.withLock { () -> (LocalInferenceSelection?, Preparation?, (@Sendable () -> Void)?) in
            let value = (selection, preparation, selection != nil && preparation == nil ? unavailabilityObserver : nil)
            selection = nil
            return value
        }
        state.1?.cancel()
        state.0?.sources.retireAdmission()
        state.2?()
    }
}
