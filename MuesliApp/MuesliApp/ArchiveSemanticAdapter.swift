import Foundation

/// Semantic consumer of native process completion and retained filesystem
/// owners. No listener is activated here. Production commands and the final
/// FileManager operation are fixed; model/CLI JSON cannot supply either.
nonisolated final class ArchiveSemanticAdapter: Sendable {
    struct Configuration: Sendable {
        let backendRoot: URL
        let outputRoot: URL
        let journalRoot: URL
    }
    typealias Workflow = ArchiveWorkflowOwner<Prepared>
    struct Original: Codable, Equatable, Sendable {
        let source: ArchiveReceipt.Source
        let identity: MeetingFileAccess.Identity
        let directories: [String]
        let entries: [ArchiveSourceInventory.EntryIdentity]
        init(_ source: ArchiveSourceEligibility.VerifiedSource) {
            let value = source.inventory
            self.source = .init(folder: value.canonicalFolderURL.path,
                directoryDevice: value.access.identity.directoryDevice, directoryInode: value.access.identity.directoryInode,
                files: value.files, sessionIDs: source.sessions.map(\.sourceSessionID))
            identity = value.access.identity; directories = value.directories; entries = value.identities
        }
        func compare(_ value: ArchiveSourceInventory.Snapshot, relocated: Bool = false) throws {
            try ArchiveSemanticAdapter.require(value.access.identity == identity && value.files == source.files && value.directories == directories
                        && value.identities == entries && (relocated || value.canonicalFolderURL.path == source.folder),
                        "The original source identity, bytes or complete directory inventory changed.")
        }
    }
    final class Prepared: @unchecked Sendable {
        let operationID: UUID
        let original: Original
        let nativeEvents: ArchiveReceipt.FileRecord
        let nativeDiagnostics: ArchiveReceipt.FileRecord
        let bundle: ArchiveOutputBundle
        let catalog: ArchiveAssetCopier.Catalog
        fileprivate let proof: BatchRediarizer.CompletedProcessingEvidence
        fileprivate let journalDirectory: ArchiveOutputBundle.Directory
        private let lock = NSLock()
        private var running = false
        private var terminal = false
        fileprivate init(operationID: UUID, initial: Initial, proof: BatchRediarizer.CompletedProcessingEvidence,
                         events: ArchiveReceipt.FileRecord, diagnostics: ArchiveReceipt.FileRecord) {
            self.operationID = operationID; original = initial.original; bundle = initial.bundle; catalog = initial.catalog
            journalDirectory = initial.journalDirectory; self.proof = proof; nativeEvents = events; nativeDiagnostics = diagnostics
        }
        fileprivate func admit() -> Bool { lock.withLock {
            guard !running && !terminal else { return false }; running = true; return true
        } }
        fileprivate func finish(terminal: Bool) { lock.withLock { running = false; self.terminal = terminal } }
    }
    fileprivate struct Initial: Sendable {
        let original: Original
        let catalog: ArchiveAssetCopier.Catalog
        let bundle: ArchiveOutputBundle
        let journalDirectory: ArchiveOutputBundle.Directory
    }
    private let configuration: Configuration
    #if DEBUG
    enum Checkpoint: Sendable { case initial, beforeProcessing, afterProcessing, beforeSnapshot, beforePending, beforeStagingRename, beforeTrash, afterTrash }
    private let fixtureCommand: [String]?
    private let fixtureRoot: URL?
    private let fixtureDestination: URL?
    private let checkpoint: (@Sendable (Checkpoint) throws -> Void)?
    private let journalCheckpoint: (@Sendable (ArchiveMoveJournal.Checkpoint) throws -> Void)?
    #endif
    init(configuration: Configuration) {
        self.configuration = configuration
        #if DEBUG
        fixtureCommand = nil; fixtureRoot = nil; fixtureDestination = nil; checkpoint = nil; journalCheckpoint = nil
        #endif
    }
    #if DEBUG
    /// Temporary synthetic fixtures only. The process still uses the actual
    /// native Batch admission/completion path; no serialized proof is accepted.
    init(configuration: Configuration, fixtureRoot: URL, fixtureCommand: [String], fixtureDestination: URL,
         checkpoint: (@Sendable (Checkpoint) throws -> Void)? = nil,
         journalCheckpoint: (@Sendable (ArchiveMoveJournal.Checkpoint) throws -> Void)? = nil) {
        self.configuration = configuration; self.fixtureRoot = fixtureRoot; self.fixtureCommand = fixtureCommand
        self.fixtureDestination = fixtureDestination; self.checkpoint = checkpoint; self.journalCheckpoint = journalCheckpoint
    }
    #endif
    func prepare(_ begin: Workflow.Begin, operationID: UUID) async throws -> Workflow.Preparation {
        // Actual I/O lifetime is retained even if a caller or socket departs.
        try await Task.detached { [self] in
            let initial = try initial(begin, operationID: operationID)
            #if DEBUG
            try checkpoint?(.beforeProcessing)
            #endif
            let proof = try await run(original: initial.original)
            #if DEBUG
            try checkpoint?(.afterProcessing)
            #endif
            return try complete(initial, proof: proof, operationID: operationID)
        }.value
    }
    private func initial(_ begin: Workflow.Begin, operationID: UUID) throws -> Initial {
        #if DEBUG
        if let fixtureRoot {
            try ArchiveSemanticAdapter.require(begin.sourcePath.hasPrefix(fixtureRoot.path + "/") && begin.vaultPath.hasPrefix(fixtureRoot.path + "/"),
                        "Synthetic adapter inputs must remain in their temporary fixture.")
        }
        try checkpoint?(.initial)
        #endif
        let source = try inspect(URL(fileURLWithPath: begin.sourcePath))
        let original = Original(source)
        try Self.require(original.source.sessionIDs.count <= 128, "Automatic archive processing supports at most 128 source sessions.")
        let identity = ArchiveOutputBundle.Identity(original.identity)
        // Admit every native root through retained no-follow ancestry before
        // creating even a protocol lock; none may lie inside source material.
        let output = try ArchiveOutputBundle.Directory(existing: configuration.outputRoot, excludingSource: identity)
        let journal = try ArchiveOutputBundle.Directory(existing: configuration.journalRoot, excludingSource: identity)
        try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: configuration.journalRoot, sourceIdentity: original.identity)
        let catalog = try ArchiveAssetCopier.copy(source: source, vaultURL: URL(fileURLWithPath: begin.vaultPath))
        let bundle = try ArchiveOutputBundle(root: output, sourceIdentity: original.identity, operationID: operationID)
        try original.compare(ArchiveSourceInventory.capture(access: source.inventory.access))
        try journal.validate()
        // Initial contains plain source observations only. This function's
        // source/reader/secondary EX owners all retire before Batch takes SH.
        return Initial(original: original, catalog: catalog, bundle: bundle, journalDirectory: journal)
    }
    private func run(original: Original) async throws -> BatchRediarizer.CompletedProcessingEvidence {
        let source = URL(fileURLWithPath: original.source.folder)
        let validateSource: @Sendable (TranscriptPersistenceStore.Context) throws -> Void = { context in
            try Self.require(context.access.identity == original.identity, "The original source changed before processing snapshot admission.")
            try original.compare(ArchiveSourceInventory.captureForProcessing(context: context))
        }
        let result: BatchRediarizer.Result
        #if DEBUG
        if let fixtureCommand {
            result = try await BatchRediarizer(timeoutSeconds: 10).runCommand(fixtureCommand,
                backendRoot: configuration.backendRoot, sourceMeetingDirectory: source, stream: .both, collectProcessingEvidence: true,
                expectedMeetingIdentity: original.identity, validateSource: validateSource)
        } else {
            result = try await BatchRediarizer().run(meetingDirectory: source, backendRoot: configuration.backendRoot,
                                                    stream: .both, collectProcessingEvidence: true,
                expectedMeetingIdentity: original.identity, validateSource: validateSource)
        }
        #else
        result = try await BatchRediarizer().run(meetingDirectory: source, backendRoot: configuration.backendRoot,
                                                stream: .both, collectProcessingEvidence: true,
                expectedMeetingIdentity: original.identity, validateSource: validateSource)
        #endif
        guard let proof = result.nativeProcessingEvidence else { throw Failure(message: "Actual native processing closure was not established.") }
        return proof
    }
    private func complete(_ initial: Initial, proof: BatchRediarizer.CompletedProcessingEvidence, operationID: UUID) throws -> Workflow.Preparation {
        let source = try inspect(URL(fileURLWithPath: initial.original.source.folder), expected: initial.original)
        try initial.original.compare(source.inventory)
        let processing = try proof.verify(source: source)
        try initial.journalDirectory.validate()
        try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: configuration.journalRoot, sourceIdentity: initial.original.identity)
        try initial.catalog.validate()
        let events = try initial.bundle.writeNative("processing-events.jsonl", bytes: proof.events, maximumBytes: 64 * 1024 * 1024)
        let diagnostics = try initial.bundle.writeNative("native-diagnostics.json", bytes: JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "native_process_and_resources_closed": true, "processing_source_verified": true,
            "stderr_capture": "not_available", "session_count": processing.sessionCount,
            "stream_count": processing.streamCount, "turn_count": processing.turnCount
        ], options: [.sortedKeys]), maximumBytes: 64 * 1024)
        struct Manifest: Encodable {
            let schema_version = 1
            let operation_id: UUID
            let receipt_path: String
            let native_events: ArchiveReceipt.FileRecord
            let native_diagnostics: ArchiveReceipt.FileRecord
            let source: Original
            let vault_path: String
            let speakers: [Speaker]
            let images: [Image]
            let authority = "Native in-process completion is required; this manifest is not archive permission."
            let validation_boundary = "Saved outputs are revalidated and preserved separately; vault files are not an atomic multi-file snapshot."
        }
        struct Speaker: Encodable { let source_session_id: UUID; let stream: String; let speaker_id: String }
        struct Image: Encodable {
            let source_session_id: UUID; let asset_id: UUID; let timeline_seconds: Double
            let source: ArchiveReceipt.FileRecord; let copied: ArchiveReceipt.FileRecord; let vault_path: String
        }
        let manifest = Manifest(operation_id: operationID, receipt_path: initial.bundle.receiptPath, native_events: events,
            native_diagnostics: diagnostics, source: initial.original, vault_path: initial.catalog.vaultPath,
            speakers: processing.speakerKeys.map { Speaker(source_session_id: $0.sourceSessionID, stream: $0.stream, speaker_id: $0.speakerID) }
                .sorted { ($0.source_session_id.uuidString, $0.stream, $0.speaker_id) < ($1.source_session_id.uuidString, $1.stream, $1.speaker_id) },
            images: initial.catalog.images.map { Image(source_session_id: $0.sourceSessionID, asset_id: $0.assetID,
                timeline_seconds: $0.timelineSeconds, source: $0.source, copied: $0.copied, vault_path: $0.vaultPath) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let file = try initial.bundle.writeNative("native-manifest.json", bytes: encoder.encode(manifest), maximumBytes: 16 * 1024 * 1024)
        try initial.original.compare(ArchiveSourceInventory.capture(access: source.inventory.access))
        let context = Prepared(operationID: operationID, initial: initial, proof: proof, events: events, diagnostics: diagnostics)
        return .init(context: context, outputManifestPath: file.path)
    }
    func finalize(_ prepared: Prepared, receiptPath: String, operationID: UUID) async -> Workflow.FinalOutcome {
        guard prepared.operationID == operationID, prepared.admit() else { return .uncertain }
        return await Task.detached { [self] in
            let outcome = finalizeOwned(prepared, receiptPath: receiptPath)
            if case .needsCorrection = outcome { prepared.finish(terminal: false) } else { prepared.finish(terminal: true) }
            return outcome
        }.value
    }
    private func finalizeOwned(_ prepared: Prepared, receiptPath: String) -> Workflow.FinalOutcome {
        var pendingAttempted = false
        var absenceEstablished = false
        var journal: ArchiveMoveJournal?
        do {
            try prepared.journalDirectory.validate(); try prepared.bundle.validate()
            try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: configuration.journalRoot, sourceIdentity: prepared.original.identity)
            absenceEstablished = true
            let source = try inspect(URL(fileURLWithPath: prepared.original.source.folder), expected: prepared.original)
            try prepared.original.compare(source.inventory)
            let processing = try prepared.proof.verify(source: source)
            try prepared.catalog.validate()
            let captured = try prepared.bundle.readReceipt(at: receiptPath)
            try validateOutputs(captured, prepared: prepared, processing: processing)
            #if DEBUG
            try checkpoint?(.beforeSnapshot)
            #endif
            let validationSnapshot = try prepared.bundle.snapshot(captured)
            let stage = try ArchiveSourceStaging(source: source.inventory.access,
                originalURL: source.inventory.canonicalFolderURL, operationID: prepared.operationID)
            #if DEBUG
            try checkpoint?(.beforePending)
            #endif
            try validateOutputs(captured, prepared: prepared, processing: processing)
            try prepared.original.compare(ArchiveSourceInventory.capture(access: source.inventory.access))
            try prepared.bundle.validate(); try prepared.journalDirectory.validate(); try stage.validate()
            // Set BEFORE init: a failed first write/fsync may already leave a
            // durable/partial anchor. No unclassified error can imply retry.
            pendingAttempted = true
            #if DEBUG
            journal = try ArchiveMoveJournal(rootURL: configuration.journalRoot, source: source.inventory.access,
                sessionIDs: prepared.original.source.sessionIDs, receipt: captured.file, operationID: prepared.operationID,
                plannedStagingURL: stage.stagedURL, validationSnapshot: validationSnapshot, checkpoint: journalCheckpoint)
            #else
            journal = try ArchiveMoveJournal(rootURL: configuration.journalRoot, source: source.inventory.access,
                sessionIDs: prepared.original.source.sessionIDs, receipt: captured.file, operationID: prepared.operationID,
                plannedStagingURL: stage.stagedURL, validationSnapshot: validationSnapshot)
            #endif
            guard let journal else { throw Failure(message: "Native pending intent was not established.") }
            let staged: ArchiveSourceInventory.Snapshot
            #if DEBUG
            staged = try stage.stage(journal: journal, afterValidation: { [self] in try checkpoint?(.beforeStagingRename) })
            #else
            staged = try stage.stage(journal: journal)
            #endif
            try prepared.original.compare(staged, relocated: true)
            #if DEBUG
            try checkpoint?(.beforeTrash)
            #endif
            try prepared.bundle.validate(); try prepared.catalog.validate(); try journal.validatePending(); try stage.validate()
            try prepared.original.compare(ArchiveSourceInventory.captureRelocated(access: source.inventory.access, at: stage.stagedURL), relocated: true)
            let destination = try trashVerifiedPrivateSource(stage.stagedURL)
            #if DEBUG
            try checkpoint?(.afterTrash)
            #endif
            try prepared.bundle.validate(); try prepared.catalog.validate()
            try source.inventory.access.validateRelocated(to: destination)
            try prepared.original.compare(ArchiveSourceInventory.captureRelocated(access: source.inventory.access, at: destination), relocated: true)
            try journal.recordMoved(to: destination)
            // Keep every secondary source participant and staging descriptor
            // through actual native move and durable terminal publication.
            withExtendedLifetime((source, stage, staged)) {}
            return .trashed
        } catch {
            if pendingAttempted || !absenceEstablished {
                try? journal?.recordUncertain(code: "native_archive_uncertain")
                return .uncertain
            }
            return .needsCorrection
        }
    }
    private func validateOutputs(_ captured: ArchiveOutputBundle.CapturedReceipt, prepared: Prepared,
                                 processing: ArchiveProcessingEvidence.Verified) throws {
        let receipt = captured.receipt
        try ArchiveSemanticAdapter.require(receipt.outputs.filter { $0.role == .reprocessEvents }.map(\.file) == [prepared.nativeEvents]
                    && receipt.outputs.filter { $0.role == .reprocessDiagnostics }.map(\.file) == [prepared.nativeDiagnostics],
                    "Native evidence destinations cannot be redefined by a receipt.")
        let native = prepared.bundle.nativePaths
        for output in receipt.outputs where ![.reprocessEvents, .reprocessDiagnostics].contains(output.role) {
            try ArchiveSemanticAdapter.require(!native.contains(output.file.path) && !output.file.path.hasPrefix(prepared.bundle.directory.path + "/"),
                        "External note outputs cannot alias native operation files.")
        }
        _ = try ArchiveOutputEvidence.validate(receipt: receipt, processing: processing, nativeEvents: prepared.nativeEvents,
            copiedImages: prepared.catalog.images, vaultURL: URL(fileURLWithPath: prepared.catalog.vaultPath))
        try receipt.validate(currentSource: prepared.original.source, receiptURL: URL(fileURLWithPath: captured.file.path))
        let current = try prepared.bundle.readReceipt(at: captured.file.path)
        try ArchiveSemanticAdapter.require(current.file == captured.file && current.bytes == captured.bytes, "Receipt changed during validation.")
    }
    private func trashVerifiedPrivateSource(_ staged: URL) throws -> URL {
        #if DEBUG
        if let fixtureDestination, let fixtureRoot {
            try ArchiveSemanticAdapter.require(staged.path.hasPrefix(fixtureRoot.path + "/") && fixtureDestination.path.hasPrefix(fixtureRoot.path + "/"),
                        "Synthetic moves must remain inside their temporary fixture.")
            try FileManager.default.moveItem(at: staged, to: fixtureDestination)
            return fixtureDestination
        }
        #endif
        var destination: NSURL?
        try FileManager.default.trashItem(at: staged, resultingItemURL: &destination)
        guard let destination else { throw Failure(message: "The native Trash operation returned no destination.") }
        return destination as URL
    }
    private func inspect(_ url: URL, expected: Original? = nil) throws -> ArchiveSourceEligibility.VerifiedSource {
        let access = try MeetingFileAccess.acquire(in: url, mode: .archive)
        if let expected {
            try Self.require(access.identity == expected.identity, "The original physical source folder changed before semantic admission.")
            try expected.compare(ArchiveSourceInventory.capture(access: access))
        }
        return try ArchiveSourceEligibility.inspect(access: access)
    }
    struct Failure: Error, LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
}
