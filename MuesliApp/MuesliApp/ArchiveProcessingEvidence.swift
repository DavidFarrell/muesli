import Foundation

/// Validates recorded processing against independently owned source bytes.
/// The caller must supply actual process completion, not a model-written
/// receipt assertion, and keep source/output ownership through later use.
/// This establishes protocol/byte coverage, not the semantic accuracy of ASR.
nonisolated enum ArchiveProcessingEvidence {
    struct Stream: Sendable {
        let pcmBytes: Int64
        let pcmSHA256: String
        let modelWAVSHA256: String
    }
    struct Session: Sendable {
        let id: String
        let audioFolder: String
        let offsetUs: Int64
        let manifestSHA256: String
        let manifestRevision: Int64
        let streams: [String: Stream]
    }
    struct Verified: Sendable {
        let sessionCount: Int
        let streamCount: Int
        let turnCount: Int
    }
    /// The future native owner derives this hash from the corresponding
    /// retained PCM byte range plus its canonical WAV header, not the report.
    typealias RecoveryInputHash = @Sendable (_ sourceID: String, _ stream: String, _ frames: Range<Int64>) throws -> String
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    private static let names: Set<String> = ["mic", "system"]
    private static let maximumLineBytes = 4 * 1024 * 1024
    private static let maximumLogBytes = 64 * 1024 * 1024

    /// Complete JSONL only. Partial tails, stdout noise, errors, multiple
    /// results and any records after the final result all retain the source.
    static func validate(log: Data, observedExitCode: Int32, expected: [Session],
                         recoveryInputHash: RecoveryInputHash? = nil) throws -> Verified {
        try require(observedExitCode == 0, "Reprocessing did not actually exit successfully.")
        try require(!log.isEmpty && log.count <= maximumLogBytes && log.last == 10,
                    "The processing journal is empty, incomplete or exceeds its size limit.")
        let decoder = JSONDecoder()
        var cursor = log.startIndex, records = 0
        var result: FinalResult?
        while cursor < log.endIndex {
            guard let newline = log[cursor...].firstIndex(of: 10) else { throw Failure(message: "The processing journal has an incomplete record.") }
            records += 1
            try require(records <= 100_000 && newline > cursor && newline - cursor <= maximumLineBytes,
                        "A processing journal record is empty or exceeds its limit.")
            let bytes = Data(log[cursor..<newline])
            cursor = newline + 1
            try ArchiveSourceJSON.check(bytes)
            let envelope = try decoder.decode(Envelope.self, from: bytes)
            try require(result == nil, "Processing records occurred after the final result.")
            switch envelope.type {
            case "status":
                guard let stage = envelope.stage else { throw Failure(message: "A processing status has no stage.") }
                try require(!stage.isEmpty && stage.utf8.count <= 128
                            && (envelope.stream == nil || names.contains(envelope.stream!)), "A processing status is malformed.")
            case "result": result = try decoder.decode(FinalResult.self, from: bytes)
            case "error": throw Failure(message: "The processing journal contains an error event.")
            default: throw Failure(message: "The processing journal contains an unknown event.")
            }
        }
        guard let result else { throw Failure(message: "Reprocessing has no complete final result.") }
        return try validate(result, expected: expected, recoveryInputHash: recoveryInputHash)
    }

    private static func validate(_ result: FinalResult, expected: [Session], recoveryInputHash: RecoveryInputHash?) throws -> Verified {
        try require(!expected.isEmpty && expected.count <= 128, "The source session count is unsupported.")
        var expectedIDs: Set<UUID> = []
        for source in expected {
            guard let id = UUID(uuidString: source.id) else { throw Failure(message: "Expected source identity is invalid.") }
            try require(expectedIDs.insert(id).inserted && source.offsetUs >= 0
                        && source.offsetUs <= 1_000_000_000_000_000 && source.manifestRevision > 0
                        && hash(source.manifestSHA256) && Set(source.streams.keys) == names,
                        "Expected source evidence is missing or duplicated.")
            for stream in source.streams.values {
                try require(stream.pcmBytes >= 0 && stream.pcmBytes <= 86_400 * 32_000
                            && stream.pcmBytes % 2 == 0 && hash(stream.pcmSHA256) && hash(stream.modelWAVSHA256),
                            "Expected source byte evidence is invalid.")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        let processing = result.processing
        try require(processing.schemaVersion == 1 && processing.complete && processing.recoveryRequested
                    && processing.requestedStreams.count == 2 && Set(processing.requestedStreams) == names
                    && processing.entries.count == expected.count * 2,
                    "Automatic archiving requires complete processing of both streams with recovery enabled.")
        try require(result.sources.count == expected.count, "Processing source inventory is incomplete.")
        var listed: Set<String> = [], expectedDuration = 0.0
        for source in result.sources {
            guard let original = byID[source.sourceSessionId] else { throw Failure(message: "Processing includes an unknown source.") }
            let duration = Double(original.streams.values.map(\.pcmBytes).max()!) / 32_000
            let offset = Double(original.offsetUs) / 1_000_000
            try require(listed.insert(original.id).inserted && source.audioFolder == original.audioFolder
                        && source.storageKind == "committed_pcm" && near(source.timelineOffsetSeconds, offset)
                        && near(source.durationSeconds, duration), "Processing source identity or media extent changed.")
            expectedDuration = max(expectedDuration, offset + duration)
        }
        try require(near(result.duration, expectedDuration) && result.turns.count <= 1_000_000,
                    "Processing duration or turn count is invalid.")
        var turnCounts: [String: Int] = [:], speakers: Set<String> = []
        for turn in result.turns {
            guard let source = byID[turn.sourceSessionId], let stream = source.streams[turn.stream] else {
                throw Failure(message: "A processed turn has no verified source and stream.")
            }
            let start = Double(source.offsetUs) / 1_000_000
            try require(turn.t0.isFinite && turn.t1.isFinite && turn.t0 >= start - 0.000001
                        && turn.t1 >= turn.t0 && turn.t1 <= start + Double(stream.pcmBytes) / 32_000 + 0.000001
                        && !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !turn.speakerId.isEmpty && turn.speakerId.utf8.count <= 256,
                        "A processed turn has invalid time, speaker or text evidence.")
            turnCounts[key(source.id, turn.stream), default: 0] += 1
            speakers.insert(turn.speakerId)
        }
        try require(result.speakers.count == speakers.count && Set(result.speakers) == speakers,
                    "The processing speaker inventory does not match its turns.")
        var entries: Set<String> = [], totalWindows = 0
        var recoverySourceBytes: Int64 = 0
        for entry in processing.entries {
            guard let source = byID[entry.sourceSessionId], let stream = source.streams[entry.stream], let input = entry.sourceInput else {
                throw Failure(message: "A processing entry has missing or unknown source evidence.")
            }
            let identity = key(source.id, entry.stream)
            try require(entries.insert(identity).inserted && entry.audioFolder == source.audioFolder
                        && entry.failureCode == nil && input.storageKind == "committed_pcm"
                        && input.relativePath == source.audioFolder + "/" + entry.stream + ".pcm"
                        && input.byteCount == stream.pcmBytes && input.committedBytes == stream.pcmBytes
                        && input.sha256 == stream.pcmSHA256 && input.manifestSha256 == source.manifestSHA256
                        && input.manifestRevision == source.manifestRevision && input.sessionId == source.id
                        && input.timelineOffsetUs == source.offsetUs && input.completed
                        && input.sampleRate == 16_000 && input.channels == 1
                        && input.frameCount == stream.pcmBytes / 2 && input.encoding == "PCM_16",
                        "Processing does not identify the exact closed source bytes and manifest.")
            let turns = turnCounts[identity, default: 0]
            if stream.pcmBytes == 0 {
                try require(entry.status == "empty" && entry.availability == "empty" && entry.modelInput == nil
                            && entry.asrWordCount == nil && entry.diarizationSegmentCount == nil && entry.turnCount == nil
                            && turns == 0, "An empty stream has contradictory processing evidence.")
                try emptyRecovery(entry.recovery, outcome: "not_run")
                continue
            }
            try require(entry.status == "processed" && entry.availability == "present" && turns > 0
                        && entry.turnCount == turns, "A nonempty source with no processed turns requires review before archiving.")
            let mainWords = try count(entry.asrWordCount); _ = try count(entry.diarizationSegmentCount)
            guard let model = entry.modelInput else { throw Failure(message: "The actual model input is unidentified.") }
            try model.validate(maximumFrames: stream.pcmBytes / 2)
            try require(model.frameCount == stream.pcmBytes / 2 && model.byteCount == stream.pcmBytes + 44
                        && model.sha256 == stream.modelWAVSHA256, "The model did not receive the verified source's exact normalized bytes.")
            try recovery(entry.recovery, sourceID: source.id, stream: entry.stream,
                         duration: Double(stream.pcmBytes) / 32_000, sourceBytes: stream.pcmBytes,
                         totalWindows: &totalWindows, sourceBytesRead: &recoverySourceBytes, inputHash: recoveryInputHash)
            try require(turns <= mainWords + entry.recovery.recoveredWordCount,
                        "Processing claims more turns than its actual returned words can supply.")
        }
        try require(!result.turns.isEmpty, "Sources without any processed turns require review before archiving.")
        return Verified(sessionCount: expected.count, streamCount: entries.count, turnCount: result.turns.count)
    }

    private static func emptyRecovery(_ value: Recovery, outcome: String) throws {
        try require(value.outcome == outcome && value.failureCode == nil && value.windows.isEmpty
                    && value.plannedWindowCount == 0 && value.attemptedWindowCount == 0 && value.failedWindowCount == 0
                    && value.emptyWindowCount == 0 && value.recoveredWindowCount == 0 && value.recoveredWordCount == 0,
                    "Recovery evidence is missing or contradictory.")
    }
    private static func recovery(_ value: Recovery, sourceID: String, stream: String, duration: Double,
                                 sourceBytes: Int64, totalWindows: inout Int, sourceBytesRead: inout Int64, inputHash: RecoveryInputHash?) throws {
        if value.outcome == "not_needed" { try emptyRecovery(value, outcome: "not_needed"); return }
        try require(value.outcome == "completed" && value.failureCode == nil && value.failedWindowCount == 0
                    && !value.windows.isEmpty && value.windows.count <= 1024 - totalWindows
                    && value.plannedWindowCount == value.windows.count && value.attemptedWindowCount == value.windows.count,
                    "Recovery failed, was incomplete or exceeded its supported evidence bound.")
        _ = try count(value.recoveredWordCount)
        totalWindows += value.windows.count
        var empty = 0, recovered = 0, words = 0
        for window in value.windows {
            try require(window.startSeconds.isFinite && window.endSeconds.isFinite && window.startSeconds >= 0
                        && window.endSeconds > window.startSeconds && window.endSeconds <= duration + 0.000001
                        && window.failureCode == nil, "A recovery window has invalid source timing or failed.")
            guard let model = window.modelInput else { throw Failure(message: "A recovery model input is unidentified.") }
            try model.validate(maximumFrames: Int64((duration * 16_000).rounded()))
            let lower = Int64((window.startSeconds * 16_000).rounded(.toNearestOrEven))
            let upper = Int64((window.endSeconds * 16_000).rounded(.toNearestOrEven))
            try require(upper > lower && model.frameCount == upper - lower,
                        "A recovery model input does not match its exact source frame range.")
            guard let inputHash else { throw Failure(message: "Recovery input bytes require independent verification before archiving.") }
            try require(sourceBytes <= 16 * 1024 * 1024 * 1024 - sourceBytesRead,
                        "Independent recovery verification exceeds its aggregate source-read budget.")
            sourceBytesRead += sourceBytes
            let verifiedHash = try inputHash(sourceID, stream, lower..<upper)
            try require(hash(verifiedHash) && model.sha256 == verifiedHash,
                        "Recovery used bytes that differ from the verified source range.")
            let recognizedWords = try count(window.asrWordCount)
            let recoveredWords = try count(window.recoveredWordCount)
            try require(recoveredWords <= recognizedWords, "Recovery claims more retained words than ASR returned.")
            if window.status == "recovered" { try require(recoveredWords > 0, "Recovery claims words without evidence."); recovered += 1 }
            else { try require(window.status == "processed_without_words" && recoveredWords == 0, "A recovery window is incomplete."); empty += 1 }
            words += recoveredWords
        }
        try require(value.emptyWindowCount == empty && value.recoveredWindowCount == recovered
                    && value.recoveredWordCount == words, "Recovery totals do not match the actual window records.")
    }
    private struct Envelope: Decodable {
        enum CodingKeys: String, CodingKey {
            case type
            case stage
            case stream
        }
 let type: String; let stage: String?; let stream: String? }
    private struct FinalResult: Decodable {
        enum CodingKeys: String, CodingKey {
            case duration
            case sources
            case turns
            case speakers
            case processing
        }

        let duration: Double; let sources: [Source]; let turns: [Turn]; let speakers: [String]; let processing: Processing
    }
    private struct Source: Decodable {
        enum CodingKeys: String, CodingKey {
            case sourceSessionId = "source_session_id"
            case audioFolder = "audio_folder"
            case timelineOffsetSeconds = "timeline_offset_seconds"
            case durationSeconds = "duration_seconds"
            case storageKind = "storage_kind"
        }

        let sourceSessionId: String; let audioFolder: String; let timelineOffsetSeconds: Double; let durationSeconds: Double; let storageKind: String
    }
    private struct Turn: Decodable {
        enum CodingKeys: String, CodingKey {
            case sourceSessionId = "source_session_id"
            case stream
            case speakerId = "speaker_id"
            case t0
            case t1
            case text
        }

        let sourceSessionId: String; let stream: String; let speakerId: String; let t0: Double; let t1: Double; let text: String
    }
    private struct Processing: Decodable {
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case complete
            case requestedStreams = "requested_streams"
            case recoveryRequested = "recovery_requested"
            case entries
        }

        let schemaVersion: Int; let complete: Bool; let requestedStreams: [String]; let recoveryRequested: Bool; let entries: [Entry]
    }
    private struct Entry: Decodable {
        enum CodingKeys: String, CodingKey {
            case sourceSessionId = "source_session_id"
            case audioFolder = "audio_folder"
            case stream
            case status
            case availability
            case sourceInput = "source_input"
            case modelInput = "model_input"
            case asrWordCount = "asr_word_count"
            case diarizationSegmentCount = "diarization_segment_count"
            case turnCount = "turn_count"
            case failureCode = "failure_code"
            case recovery
        }

        let sourceSessionId: String; let audioFolder: String; let stream: String; let status: String; let availability: String
        let sourceInput: SourceInput?; let modelInput: ModelInput?; let asrWordCount: Int?; let diarizationSegmentCount: Int?
        let turnCount: Int?; let failureCode: String?; let recovery: Recovery
    }
    private struct SourceInput: Decodable {
        enum CodingKeys: String, CodingKey {
            case relativePath = "relative_path"
            case storageKind = "storage_kind"
            case byteCount = "byte_count"
            case sha256
            case manifestSha256 = "manifest_sha256"
            case manifestRevision = "manifest_revision"
            case committedBytes = "committed_bytes"
            case sessionId = "session_id"
            case timelineOffsetUs = "timeline_offset_us"
            case completed
            case sampleRate = "sample_rate"
            case channels
            case frameCount = "frame_count"
            case encoding
        }

        let relativePath: String; let storageKind: String; let byteCount: Int64; let sha256: String
        let manifestSha256: String; let manifestRevision: Int64; let committedBytes: Int64; let sessionId: String
        let timelineOffsetUs: Int64; let completed: Bool
        let sampleRate: Int; let channels: Int; let frameCount: Int64; let encoding: String
    }
    private struct ModelInput: Decodable {
        enum CodingKeys: String, CodingKey {
            case format
            case sampleRate = "sample_rate"
            case channels
            case frameCount = "frame_count"
            case byteCount = "byte_count"
            case sha256
        }

        let format: String; let sampleRate: Int; let channels: Int; let frameCount: Int64; let byteCount: Int64; let sha256: String
        func validate(maximumFrames: Int64) throws {
            try require(format == "wav_pcm_s16le" && sampleRate == 16_000 && channels == 1 && frameCount > 0
                        && frameCount <= maximumFrames && byteCount == frameCount * 2 + 44 && hash(sha256),
                        "A model input has invalid format, size or fingerprint evidence.")
        }
    }
    private struct Recovery: Decodable {
        enum CodingKeys: String, CodingKey {
            case outcome
            case plannedWindowCount = "planned_window_count"
            case attemptedWindowCount = "attempted_window_count"
            case failedWindowCount = "failed_window_count"
            case emptyWindowCount = "empty_window_count"
            case recoveredWindowCount = "recovered_window_count"
            case recoveredWordCount = "recovered_word_count"
            case failureCode = "failure_code"
            case windows
        }

        let outcome: String; let plannedWindowCount: Int; let attemptedWindowCount: Int; let failedWindowCount: Int
        let emptyWindowCount: Int; let recoveredWindowCount: Int; let recoveredWordCount: Int; let failureCode: String?; let windows: [Window]
    }
    private struct Window: Decodable {
        enum CodingKeys: String, CodingKey {
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case status
            case modelInput = "model_input"
            case asrWordCount = "asr_word_count"
            case recoveredWordCount = "recovered_word_count"
            case failureCode = "failure_code"
        }

        let startSeconds: Double; let endSeconds: Double; let status: String; let modelInput: ModelInput?
        let asrWordCount: Int?; let recoveredWordCount: Int?; let failureCode: String?
    }
    private static func count(_ value: Int?) throws -> Int {
        guard let value, (0...1_000_000).contains(value) else { throw Failure(message: "A processing count is missing or exceeds its limit.") }
        return value
    }
    private static func key(_ source: String, _ stream: String) -> String { source + "/" + stream }
    private static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func near(_ a: Double, _ b: Double) -> Bool { a.isFinite && abs(a - b) <= 0.000001 }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
}
