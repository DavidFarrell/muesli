import Foundation
import CryptoKit

/// Recorded-source integrity only. A successful inspection does not establish
/// processing coverage, silence, speaker identity, redaction or archive consent.
/// No move, recovery, process launch, media decoder or file mutation occurs here.
nonisolated enum ArchiveSourceEligibility {
    struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    struct Session: Sendable {
        let sourceSessionID: String
        let audioFolder: String
        let offsetSeconds: Double
        let durationSeconds: Double
        let streams: [String: ArchiveReceipt.FileRecord]
        let manifest: ArchiveReceipt.FileRecord
        let manifestRevision: Int64
        let timelineOffsetUs: Int64
        /// Derived bytes; these do not assert that a WAV file exists on disk.
        let modelInputs: [String: ModelInput]
    }
    struct ModelInput: Sendable, Equatable {
        let bytes: Int64
        let sha256: String
    }
    /// Keep this result through the future caller's final revalidation. Its
    /// descriptors are released only on actual deinit, never on a wait timeout.
    final class VerifiedSource: Sendable {
        let inventory: ArchiveSourceInventory.Snapshot
        let sessions: [Session]
        private let reader: ArchiveSourceReader
        /// Verify on a retained file worker: the process exit must come from
        /// its actual native owner. This method never launches or deletes.
        func verifyProcessing(log: Data, observedExitCode: Int32) throws -> ArchiveProcessingEvidence.Verified {
            let expected = try sessions.map { session in
                var streams: [String: ArchiveProcessingEvidence.Stream] = [:]
                for name in ["mic", "system"] {
                    guard let pcm = session.streams[name], let model = session.modelInputs[name] else {
                        throw Failure(message: "Verified source stream evidence is missing.")
                    }
                    streams[name] = .init(pcmBytes: pcm.bytes, pcmSHA256: pcm.sha256, modelWAVSHA256: model.sha256)
                }
                return ArchiveProcessingEvidence.Session(id: session.sourceSessionID, audioFolder: session.audioFolder,
                    offsetUs: session.timelineOffsetUs, manifestSHA256: session.manifest.sha256,
                    manifestRevision: session.manifestRevision, streams: streams)
            }
            try reader.validate()
            let result = try ArchiveProcessingEvidence.validate(log: log, observedExitCode: observedExitCode, expected: expected,
                recoveryInputHash: { [self] source, stream, frames in
                    try recoveryWAVHash(sourceID: source, stream: stream, frames: frames)
                })
            try reader.validate()
            return result
        }
        /// Hash the canonical WAV for a frame range while also rechecking the
        /// entire original PCM fingerprint. No temporary audio is created.
        func recoveryWAVHash(sourceID: String, stream: String, frames: Range<Int64>) throws -> String {
            guard let session = sessions.first(where: { $0.sourceSessionID == sourceID }),
                  let pcm = session.streams[stream], frames.lowerBound >= 0,
                  frames.upperBound > frames.lowerBound, frames.upperBound <= pcm.bytes / 2,
                  pcm.bytes <= 86_400 * 32_000 else {
                throw Failure(message: "Recovery range has no corresponding verified PCM source.")
            }
            let lower = frames.lowerBound * 2, upper = frames.upperBound * 2
            var digest = SHA256(), offset: Int64 = 0
            digest.update(data: wavHeader(UInt32(upper - lower)))
            try reader.validate()
            try reader.stream(pcm, maximumBytes: 86_400 * 32_000) { chunk in
                let start = max(lower, offset), end = min(upper, offset + Int64(chunk.count))
                if start < end { digest.update(data: chunk[Int(start - offset)..<Int(end - offset)]) }
                offset += Int64(chunk.count)
            }
            try reader.validate()
            return hex(digest.finalize())
        }
        fileprivate init(inventory: ArchiveSourceInventory.Snapshot, sessions: [Session], reader: ArchiveSourceReader) {
            self.inventory = inventory; self.sessions = sessions; self.reader = reader
        }
    }
    /// Synchronous disk work: call only from an independently retained file
    /// worker. A bounded waiter must retain that original worker until return.
    static func inspect(access: MeetingFileAccess,
                        semanticByteLimit: Int64 = 64 * 1024 * 1024,
                        beforeInventory: (@Sendable () throws -> Void)? = nil,
                        beforeSemanticRead: (@Sendable () throws -> Void)? = nil) throws -> VerifiedSource {
        try require(semanticByteLimit > 0 && semanticByteLimit <= 64 * 1024 * 1024, "Invalid semantic read budget.")
        let reader = try ArchiveSourceReader(access: access)
        try reader.discoverAndLock()
        try reader.requireLease(".backend-owner.lock")
        try beforeInventory?()
        let inventory = try ArchiveSourceInventory.capture(access: access)
        try require(reader.discovered == Set(inventory.files.map(\.path) + inventory.directories),
                    "The source topology changed after secondary ownership was acquired.")
        try reader.validate()
        try beforeSemanticRead?()
        var check = Check(reader: reader, inventory: inventory, semanticByteLimit: semanticByteLimit)
        let sessions = try check.run()
        try reader.validate()
        return VerifiedSource(inventory: inventory, sessions: sessions, reader: reader)
    }

    private struct Check {
        let reader: ArchiveSourceReader
        let inventory: ArchiveSourceInventory.Snapshot
        var files: [String: ArchiveReceipt.FileRecord]
        let directories: Set<String>
        var semanticBytesRemaining: Int64
        var usedFiles: Set<String> = []
        var usedDirectories: Set<String> = []
        var recordCount = 0
        init(reader: ArchiveSourceReader, inventory: ArchiveSourceInventory.Snapshot, semanticByteLimit: Int64) {
            self.reader = reader; self.inventory = inventory
            files = Dictionary(uniqueKeysWithValues: inventory.files.map { ($0.path, $0) })
            directories = Set(inventory.directories)
            semanticBytesRemaining = semanticByteLimit
        }
        mutating func file(_ path: String) throws -> ArchiveReceipt.FileRecord {
            guard let value = files[path] else { throw Failure(message: "Indexed source material is missing: \(path)") }
            usedFiles.insert(path); return value
        }
        mutating func read<T: Decodable>(_ type: T.Type, _ path: String, cap: Int64, dates: Bool = false) throws -> T {
            let data = try bytes(path, cap: cap)
            return try decode(type, data, dates: dates)
        }
        mutating func bytes(_ path: String, cap: Int64) throws -> Data {
            let record = try file(path)
            try require(record.bytes <= semanticBytesRemaining, "The combined semantic source reads exceed their bounded budget.")
            semanticBytesRemaining -= record.bytes
            return try reader.read(record, maximumBytes: cap)
        }
        mutating func directory(_ path: String) throws {
            try require(directories.contains(path), "An indexed source directory is missing: \(path)")
            usedDirectories.insert(path)
        }
        mutating func lease(_ path: String) throws { try reader.requireLease(path); _ = try file(path) }

        mutating func run() throws -> [Session] {
            let metadata = try read(MeetingMetadata.self, "meeting.json", cap: 4 * 1024 * 1024, dates: true)
            try require(metadata.version == 1 && metadata.status == .completed && !metadata.sessions.isEmpty
                        && metadata.sessions.count <= 1024 && finite(metadata.durationSeconds)
                        && finite(metadata.lastTimestamp), "Meeting closure or extent is unknown; retain the source.")
            try require(Set(metadata.sessions.map(\.sessionID)).count == metadata.sessions.count
                        && metadata.sessions.allSatisfy { $0.sessionID > 0 }, "Session indices are invalid or duplicated.")
            var ids: Set<UUID> = [], audioFolders: Set<String> = []
            var result: [Session] = []
            var previousEnd = 0.0
            for session in metadata.sessions.sorted(by: { $0.sessionID < $1.sessionID }) {
                guard let sourceID = session.sourceSessionID, let uuid = UUID(uuidString: sourceID),
                      let offset = session.timelineOffsetSeconds, let duration = session.durationSeconds,
                      let ended = session.endedAt else { throw Failure(message: "Legacy or missing session identity/extent requires review.") }
                try require(ids.insert(uuid).inserted && audioFolders.insert(session.audioFolder).inserted,
                            "Source UUIDs or audio folders are duplicated.")
                let expectedAudio = session.sessionID == 1 ? "audio" : "audio-session-\(session.sessionID)"
                try require(session.audioFolder == expectedAudio && session.finalizationStatus == "completed"
                            && finite(offset) && offset < 1_000_000_000 && finite(duration) && duration <= 86_400
                            && abs(offset - previousEnd) <= 0.000002
                            && ended >= session.startedAt, "A session is incomplete, overlapping or has an unverified timeline extent.")
                try require(Set(session.streams.keys) == ["mic", "system"]
                            && session.streams.values.allSatisfy { $0.sampleRate == 16_000 && $0.channels == 1 },
                            "Both normalized source formats must be explicitly indexed.")
                try directory(session.audioFolder)
                try lease(session.audioFolder + "/.capture-owner.lock")
                try lease(session.audioFolder + "/transcript_events.jsonl")
                let manifestFile = try file(session.audioFolder + "/source-recording.json")
                let manifestData = try bytes(manifestFile.path, cap: 1024 * 1024)
                let manifest = try decode(LocalAudioRecorder.Manifest.self, manifestData)
                let power = try decode(PowerEvidence.self, manifestData)
                try require((power.power_events ?? []).isEmpty && (power.power_events_omitted ?? 0) == 0,
                            "Recorded power interruption or unavailable monitoring requires review before automatic archiving.")
                try require(manifest.schema_version == 1 && manifest.session_id == sourceID
                            && manifest.timeline_offset_us >= 0
                            && abs(Double(manifest.timeline_offset_us) / 1_000_000 - offset) <= 0.000001
                            && manifest.completed && manifest.revision > 0 && manifest.committed_at != nil
                            && manifest.committed_at!.timeIntervalSinceReferenceDate.isFinite,
                            "The committed source manifest does not establish this session's completed identity and offset.")
                if manifest.losses.contains(where: { $0.reason == "initial_source_alignment" }) {
                    throw Failure(message: "Recorded source alignment requires review before automatic archiving; it is not evidence of lost speech.")
                }
                try require(manifest.problem_count == 0 && manifest.last_problem == nil && manifest.losses.isEmpty
                            && manifest.loss_details_omitted == 0 && Set(manifest.streams.keys) == ["mic", "system"],
                            "The source manifest records losses, problems or unknown streams.")
                var streamFiles: [String: ArchiveReceipt.FileRecord] = [:]
                var modelInputs: [String: ModelInput] = [:]
                var pcmDuration = 0.0
                for stream in ["mic", "system"] {
                    let state = manifest.streams[stream]!
                    try require(state.sample_rate == 16_000 && state.channels == 1 && state.committed_bytes >= 0
                                && state.committed_bytes <= 86_400 * 32_000 && state.committed_bytes % 2 == 0
                                && state.captured_frames == state.committed_bytes / 2
                                && state.gap_frames == 0 && state.overlap_frames == 0 && state.dropped_frames == 0,
                                "A source stream has gaps, overlap, drops, invalid format or unknown committed extent.")
                    let pcm = try file(session.audioFolder + "/\(stream).pcm")
                    try require(pcm.bytes == state.committed_bytes, "PCM contains an uncommitted tail or missing committed bytes.")
                    streamFiles[stream] = pcm
                    pcmDuration = max(pcmDuration, Double(pcm.bytes) / 32_000)
                    var hash = SHA256(); hash.update(data: wavHeader(UInt32(pcm.bytes)))
                    try reader.stream(pcm, maximumBytes: 86_400 * 32_000) { hash.update(data: $0) }
                    let input = ModelInput(bytes: pcm.bytes + 44, sha256: hex(hash.finalize()))
                    modelInputs[stream] = input
                    let wavPath = session.audioFolder + "/\(stream).wav"
                    if files[wavPath] != nil {
                        let wav = try file(wavPath)
                        try require(wav.bytes == input.bytes && wav.sha256 == input.sha256,
                                    "A compatibility WAV differs from the exact committed PCM and fixed header.")
                    }
                }
                // Logs/journal are inventoried, not semantic processing proof.
                if files[session.audioFolder + "/backend.log"] != nil { _ = try file(session.audioFolder + "/backend.log") }
                var verifiedEnd = offset + pcmDuration
                if let folder = session.artifactsFolder {
                    verifiedEnd = max(verifiedEnd, try artifacts(session, folder: folder, sourceID: sourceID,
                        offset: offset, timelineOffsetUs: manifest.timeline_offset_us))
                } else {
                    try require(session.artifactFinalization == nil, "Artifact finalization has no indexed source folder.")
                }
                try require(abs(duration - (verifiedEnd - offset)) <= 0.000002,
                            "Session duration is not established by committed source or completed capture evidence.")
                previousEnd = verifiedEnd
                result.append(Session(sourceSessionID: sourceID, audioFolder: session.audioFolder,
                    offsetSeconds: offset, durationSeconds: duration, streams: streamFiles, manifest: manifestFile,
                    manifestRevision: manifest.revision, timelineOffsetUs: manifest.timeline_offset_us, modelInputs: modelInputs))
            }
            try require(abs(metadata.durationSeconds - previousEnd) <= 0.000002,
                        "Meeting duration does not match every indexed source extent.")
            try attachments(result)
            try require(Set(inventory.directories) == usedDirectories, "Unindexed source/artifact directories require review, including empty directories.")
            for record in inventory.files where !usedFiles.contains(record.path) {
                // Only actual app-owned root projections/logs/locks have a
                // known role here. A media suffix denylist cannot classify
                // arbitrary M4A/MOV/extensionless material as ordinary evidence.
                // Future evidence names need their own typed integration.
                let ordinaryRootFiles: Set<String> = ["transcript.txt", "transcript.jsonl", "transcript_sources.json",
                    "backend.log", ".meeting-access.lock", ".meeting-transaction.lock", ".backend-owner.lock"]
                try require(ordinaryRootFiles.contains(record.path),
                            "Unindexed source or artifact material requires review: \(record.path)")
            }
            return result
        }

        mutating func artifacts(_ session: MeetingSessionMetadata, folder: String, sourceID: String,
                               offset: Double, timelineOffsetUs: Int64) throws -> Double {
            guard let final = session.artifactFinalization, let captureEnd = final.captureEndSeconds else {
                throw Failure(message: "Artifact closure evidence is missing.")
            }
            try require(folder == "artifacts/\(sourceID)" && final.sourceSessionID == sourceID && final.isComplete
                        && final.finishedVideos >= 0 && final.committedScreenshots >= 0 && captureEnd >= offset,
                        "Artifacts are pending, failed, legacy or scoped to another source.")
            try directory("artifacts"); try directory(folder)
            try directory(folder + "/screenshots"); try directory(folder + "/video")
            try lease(folder + "/.artifact-owner.lock")
            let data = try bytes(folder + "/assets.jsonl", cap: 16 * 1024 * 1024)
            try require(!data.isEmpty && data.last == 10, "The artifact ledger is empty or has an uncommitted tail.")
            var headerSeen = false, stopped = false, screenshots = 0, mediaEnd: Double?
            var requested: [String: Double] = [:], finished: Set<String> = [], assetIDs: Set<UUID> = []
            // Do not materialize an array of all lines: a bounded 16 MiB file
            // containing millions of LF bytes must not allocate millions of
            // slices before the record-count/empty-record guard runs.
            var start = 0
            for end in data.indices where data[end] == 10 {
                let length = end - start
                recordCount += 1
                try require(length > 0 && length <= 65_536 && recordCount <= 100_000, "The artifact ledger exceeds its record limit or contains an empty record.")
                let event = try decode(LedgerEvent.self, Data(data[start..<end]))
                start = end + 1
                try require(event.sourceSessionID == sourceID, "An artifact record belongs to another source.")
                if !headerSeen {
                    try require(event.type == "session" && event.timelineOffsetUs == timelineOffsetUs,
                                "The artifact ledger header has an unknown source offset.")
                    headerSeen = true; continue
                }
                switch event.type {
                case "capture_stopped":
                    try require(!stopped && event.t == captureEnd, "Capture termination is duplicated or disagrees with recorded closure.")
                    stopped = true
                case "screenshot":
                    guard let path = event.path, let t = event.t else { throw Failure(message: "A screenshot record is incomplete.") }
                    try require(finite(t) && t >= offset && t <= captureEnd, "A screenshot falls outside its recorded capture interval.")
                    let id = try assetID(path, prefix: folder + "/screenshots/", suffix: ".png")
                    try require(assetIDs.insert(id).inserted, "An artifact identity is duplicated.")
                    let image = try file(path)
                    try require(image.bytes > 0 && image.bytes <= 128 * 1024 * 1024, "A committed screenshot is empty or exceeds its size limit.")
                    screenshots += 1; mediaEnd = max(mediaEnd ?? 0, t)
                case "video":
                    guard let path = event.path, let t = event.requestedT else { throw Failure(message: "A video record is incomplete.") }
                    try require(finite(t) && t >= offset && t <= captureEnd, "A video request has an invalid source time.")
                    let id = try assetID(path, prefix: folder + "/video/", suffix: ".mp4")
                    if event.status == "requested" {
                        try require(requested[path] == nil && assetIDs.insert(id).inserted,
                                    "A video request is duplicate or ambiguous.")
                        requested[path] = t
                    } else {
                        guard let duration = event.durationSeconds, let size = event.fileSize else { throw Failure(message: "Video completion lacks real SDK extent evidence.") }
                        try require(event.status == "finished" && event.error == nil && finite(duration) && duration <= 86_400
                                    && size > 0 && requested[path] == t && finished.insert(path).inserted,
                                    "A video is failed, unrequested, duplicated or has invalid completion evidence.")
                        try require(try file(path).bytes == size, "A completed video differs from its SDK-recorded byte extent.")
                    }
                default: throw Failure(message: "An artifact ledger record is failed, unknown or duplicated.")
                }
            }
            try require(headerSeen && stopped && Set(requested.keys) == finished && finished.count == final.finishedVideos
                        && screenshots == final.committedScreenshots && mediaEnd == final.mediaEndSeconds,
                        "Artifact records and recorded finalization do not establish the same complete asset set.")
            return max(captureEnd, mediaEnd ?? offset)
        }

        mutating func attachments(_ sessions: [Session]) throws {
            guard files["attachments.json"] != nil else { return }
            let manifest = try read(AttachmentsManifest.self, "attachments.json", cap: 4 * 1024 * 1024, dates: true)
            try require(manifest.attachments.count <= 10_000, "The attachment index exceeds its limit.")
            var ids: Set<UUID> = [], names: Set<String> = []
            let bySource = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sourceSessionID, $0) })
            if directories.contains("attachments") { try directory("attachments") }
            for item in manifest.attachments {
                guard let source = item.sourceSessionID, let session = bySource[source],
                      let bytes = item.byteCount, let sha = item.sha256 else { throw Failure(message: "Legacy or unscoped attachments require review.") }
                let expected = "attachment-\(item.id.uuidString).\(item.type == .image ? "png" : "txt")"
                try require(item.filename == expected && ids.insert(item.id).inserted && names.insert(item.filename).inserted
                            && finite(item.timestamp) && item.timestamp >= session.offsetSeconds
                            && item.timestamp <= session.offsetSeconds + session.durationSeconds
                            && bytes > 0 && bytes <= (item.type == .image ? 32 * 1024 * 1024 : 1024 * 1024),
                            "Attachment identity, source time or extent is invalid.")
                try directory("attachments")
                let actual = try file("attachments/" + item.filename)
                try require(actual.bytes == bytes && actual.sha256 == sha, "An attachment differs from its recorded identity and hash.")
            }
        }
    }

    // Deliberately independent of the optional newer recorder schema. Every
    // nonempty event list (including unknown future kinds) conservatively
    // retains the source even if a later manifest incorrectly says completed.
    private struct PowerEvidence: Decodable {
        struct Event: Decodable {}
        let power_events: [Event]?
        let power_events_omitted: Int64?
    }

    /// Optional fields are constrained by an exact key set for each event kind.
    private struct LedgerEvent: Decodable {
        let type: String
        let sourceSessionID: String
        let timelineOffsetUs: Int64?
        let path: String?
        let t: Double?
        let status: String?
        let requestedT: Double?
        let durationSeconds: Double?
        let fileSize: Int64?
        let error: String?
        enum CodingKeys: String, CodingKey, CaseIterable {
            case type, path, t, status, error
            case sourceSessionID = "source_session_id", timelineOffsetUs = "timeline_offset_us"
            case requestedT = "requested_t", durationSeconds = "duration_seconds", fileSize = "file_size"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            sourceSessionID = try values.decode(String.self, forKey: .sourceSessionID)
            timelineOffsetUs = try values.decodeIfPresent(Int64.self, forKey: .timelineOffsetUs)
            path = try values.decodeIfPresent(String.self, forKey: .path); t = try values.decodeIfPresent(Double.self, forKey: .t)
            status = try values.decodeIfPresent(String.self, forKey: .status)
            requestedT = try values.decodeIfPresent(Double.self, forKey: .requestedT)
            durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
            fileSize = try values.decodeIfPresent(Int64.self, forKey: .fileSize)
            error = try values.decodeIfPresent(String.self, forKey: .error)
            let all = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            var expected: Set<String> = ["type", "source_session_id"]
            switch type {
            case "session": expected.insert("timeline_offset_us")
            case "screenshot": expected.formUnion(["path", "t"])
            case "capture_stopped": expected.insert("t")
            case "video":
                expected.formUnion(["status", "path", "requested_t"])
                if status == "finished" { expected.formUnion(["duration_seconds", "file_size"]) }
            default: throw Failure(message: "A failed or unknown artifact record requires review.")
            }
            try require(Set(all) == expected, "Artifact record fields are missing, unexpected or ambiguous.")
        }
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func assetID(_ path: String, prefix: String, suffix: String) throws -> UUID {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix),
              let value = UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(suffix.count))) else {
            throw Failure(message: "An artifact path is not a source-scoped UUID asset.")
        }
        return value
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, dates: Bool = false) throws -> T {
        try ArchiveSourceJSON.check(data)
        let decoder = JSONDecoder()
        if dates { decoder.dateDecodingStrategy = .iso8601 }
        return try decoder.decode(type, from: data)
    }
    private static func wavHeader(_ bytes: UInt32) -> Data {
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(bytes + 36); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(16_000)); word(UInt32(32_000))
        word(UInt16(2)); word(UInt16(16)); data.append(contentsOf: "data".utf8); word(bytes)
        return data
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func finite(_ value: Double) -> Bool { value.isFinite && value >= 0 }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
}
