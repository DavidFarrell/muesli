import Foundation

nonisolated struct TranscriptReplacement: Sendable {
    let id = UUID()
    let segments: [TranscriptSegment]
    let metadata: MeetingMetadata
    let files: [String: Data]

    init(result: BatchRediarizer.Result, metadata previous: MeetingMetadata) throws {
        segments = result.turns.map { turn in
            TranscriptSegment(speakerID: turn.speakerId, stream: turn.stream,
                              sourceSessionID: turn.sourceSessionID, t0: turn.t0,
                              t1: turn.t1, text: turn.text, isPartial: false)
        }.sorted { $0.t0 < $1.t0 }
        var metadata = previous
        metadata.updatedAt = Date()
        metadata.segmentCount = segments.count
        let lastTimestamp = segments.map { $0.t1 ?? $0.t0 }.max() ?? 0
        metadata.lastTimestamp = max(metadata.lastTimestamp, lastTimestamp)
        metadata.durationSeconds = max(metadata.durationSeconds, result.duration, lastTimestamp)
        metadata.speakerNames = [:]
        // Reprocessing cannot certify or repair capture integrity.
        self.metadata = metadata
        files = try Self.files(segments: segments, text: TranscriptModel.plainText(from: segments),
                               metadata: metadata, sources: result.sources)
    }

    /// Shared by batch replacement and the stopped-session finalizer. All
    /// encoding completes before any canonical file changes.
    static func files(segments: [TranscriptSegment], text: String, metadata: MeetingMetadata,
                      sources: [BatchRediarizer.SourceInventory]? = nil) throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return [
            "transcript.jsonl": Data(try TranscriptModel.jsonLines(from: segments).utf8),
            "transcript.txt": Data(text.utf8),
            "meeting.json": try encoder.encode(metadata),
            // Clear an earlier batch inventory when a later save has no full
            // inventory, instead of falsely presenting it as current.
            "transcript_sources.json": try encoder.encode(sources)
        ]
    }
}

extension TranscriptModel {
    func applyBatchResult(_ result: BatchRediarizer.Result, requestID: UUID, in folder: URL,
                          store: TranscriptPersistenceStore = .shared,
                          timeoutSeconds: Double = 5) async throws -> TranscriptReplacement {
        try await applyOwnedReplacement(id: requestID, in: folder, store: store, timeoutSeconds: timeoutSeconds) { context in
            try TranscriptReplacement(result: result, metadata: context.readMetadata())
        }
    }

    /// Persistence is the admission point for changing what the viewer shows.
    /// Timeout keeps the original operation for retry; it does not establish
    /// failure of the save, release ownership, or publish an optimistic model.
    @discardableResult
    func applyReplacement(_ replacement: TranscriptReplacement, in folder: URL,
                          store: TranscriptPersistenceStore = .shared,
                          timeoutSeconds: Double = 5) async throws -> TranscriptReplacement {
        try await applyOwnedReplacement(id: replacement.id, in: folder, store: store, timeoutSeconds: timeoutSeconds) { _ in replacement }
    }

    private func applyOwnedReplacement(id: UUID, in folder: URL, store: TranscriptPersistenceStore,
                                       timeoutSeconds: Double,
                                       prepare: @escaping @Sendable (TranscriptPersistenceStore.Context) throws -> TranscriptReplacement) async throws -> TranscriptReplacement {
        let intent = UUID()
        replacementWaitIntent = intent
        let generation = contentGeneration
        let operation: TranscriptPersistenceStore.Operation<TranscriptReplacement>
        if let pending = pendingReplacement, pending.id == id, pending.folder == folder {
            operation = pending.operation
        } else {
            operation = try store.start(in: folder) { context in
                let replacement = try prepare(context)
                try context.commit(files: replacement.files)
                return replacement
            }
            pendingReplacement = PendingReplacement(id: id, folder: folder, operation: operation)
        }
        let replacement: TranscriptReplacement
        switch await operation.wait(timeoutSeconds: timeoutSeconds) {
        case .completed(let value): replacement = value
        case .failed(let error):
            if pendingReplacement?.id == id { pendingReplacement = nil }
            throw error
        case .timedOut: throw TranscriptPersistenceStore.Failure.timedOut
        case .cancelled: throw TranscriptPersistenceStore.Failure.cancelled
        }
        guard contentGeneration == generation, replacementWaitIntent == intent else {
            throw TranscriptPersistenceStore.Failure.superseded
        }
        pendingReplacement = nil
        resetForNewMeeting(keepSpeakerNames: false)
        segments = replacement.segments
        speakerNames = replacement.metadata.speakerNames
        if let last = segments.last, !last.text.isEmpty {
            lastTranscriptText = last.text
            lastTranscriptAt = Date()
        }
        return replacement
    }
}
