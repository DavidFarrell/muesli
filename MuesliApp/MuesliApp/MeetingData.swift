import Foundation

// MARK: - Meeting Metadata

nonisolated enum MeetingStatus: String, Codable, Sendable {
    case recording
    case completed
    case degraded
    case interrupted
}

nonisolated struct MeetingStreamInfo: Codable, Hashable, Sendable {
    let sampleRate: Int?
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
    }
}

nonisolated struct MeetingSessionMetadata: Codable, Hashable, Sendable {
    let sessionID: Int
    let startedAt: Date
    var endedAt: Date?
    let audioFolder: String
    var streams: [String: MeetingStreamInfo]
    var timelineOffsetSeconds: Double? = nil
    var durationSeconds: Double? = nil
    var artifactsFolder: String? = nil
    var artifactFinalization: MeetingArtifactFinalization? = nil
    var finalizationStatus: String? = nil
    var buildIdentity: BuildIdentity? = nil
    var sourceSessionID: String? = nil
    var observedRuntimeIdentity: ObservedRuntimeIdentity? = nil

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case audioFolder = "audio_folder"
        case streams
        case timelineOffsetSeconds = "timeline_offset_seconds"
        case durationSeconds = "duration_seconds"
        case artifactsFolder = "artifacts_folder"
        case artifactFinalization = "artifact_finalization"
        case finalizationStatus = "finalization_status"
        case buildIdentity = "build_identity"
        case sourceSessionID = "source_session_id"
        case observedRuntimeIdentity = "observed_runtime_identity"
    }
}

/// A caller's observed finish outcome is retained even if the original SDK
/// owner later updates its asset ledger after a deadline.
nonisolated struct MeetingArtifactFinalization: Codable, Hashable, Sendable {
    let outcome: String
    let sourceSessionID: String
    let pendingVideos: Int
    let finishedVideos: Int
    let committedScreenshots: Int
    let error: String?
    let mediaEndSeconds: Double?
    let captureEndSeconds: Double?
    let closed: Bool
    var isComplete: Bool {
        outcome == "completed" && closed && pendingVideos == 0 && error == nil
            && captureEndSeconds.map { $0.isFinite && $0 >= 0 } == true
    }

    init(_ result: SessionArtifactFinishResult) {
        switch result {
        case .completed: outcome = "completed"
        case .timedOut: outcome = "timed_out"
        case .cancelled: outcome = "cancelled"
        }
        let status = result.status
        sourceSessionID = status.sourceSessionID
        pendingVideos = status.pendingVideos
        finishedVideos = status.finishedVideos
        committedScreenshots = status.committedScreenshots
        error = status.error
        mediaEndSeconds = status.mediaEndSeconds
        captureEndSeconds = status.captureEndSeconds
        closed = status.closed
    }

    enum CodingKeys: String, CodingKey {
        case outcome, error, closed
        case sourceSessionID = "source_session_id"
        case pendingVideos = "pending_videos"
        case finishedVideos = "finished_videos"
        case committedScreenshots = "committed_screenshots"
        case mediaEndSeconds = "media_end_seconds"
        case captureEndSeconds = "capture_end_seconds"
    }
}

nonisolated struct MeetingMetadata: Codable, Sendable {
    var version: Int
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var lastTimestamp: Double
    var status: MeetingStatus
    var sessions: [MeetingSessionMetadata]
    var segmentCount: Int
    var speakerNames: [String: String]
    var buildIdentity: BuildIdentity? = nil
    var lastReprocessIdentity: ObservedRuntimeIdentity? = nil

    /// Preserve the observed previous outcome before Resume changes the meeting
    /// status to recording. Missing historical session evidence stays unknown.
    mutating func preservePreviousSessionOutcome() {
        guard let last = sessions.indices.last, sessions[last].finalizationStatus == nil else { return }
        sessions[last].finalizationStatus = status == .recording ? "unknown" : status.rawValue
    }

    /// Pure metadata preparation for a folder-owned off-UI persistence operation.
    func finalized(segments finalizedSegments: [TranscriptSegment],
                   sourceManifest: LocalAudioRecorder.Manifest?,
                   artifactResult: SessionArtifactFinishResult?,
                   incomplete: Bool, sourceProblems: [String] = [], now: Date = Date()) -> MeetingMetadata {
        var metadata = self
        let artifacts = artifactResult.map(MeetingArtifactFinalization.init)
        let artifactsRequired = metadata.sessions.last?.artifactsFolder != nil
        let artifactsIncomplete = artifactsRequired && artifacts?.isComplete != true
        let lastTimestamp = max(
            metadata.lastTimestamp,
            finalizedSegments.map { $0.t1 ?? $0.t0 }.max() ?? 0
        )
        let segmentCount = max(metadata.segmentCount, finalizedSegments.count)
        let savedDuration = sourceManifest.map { manifest in
            Double(manifest.timeline_offset_us) / 1_000_000
            + Double(manifest.streams.values.map { $0.committed_bytes }.max() ?? 0) / 32_000
        } ?? metadata.durationSeconds
        // A verified source offset already includes earlier sessions. Do
        // not carry old wall-clock durations or ASR timing into media time.
        let durationSeconds = max(savedDuration, artifacts?.mediaEndSeconds ?? 0,
                                  artifacts?.captureEndSeconds ?? 0)

        metadata.updatedAt = now
        metadata.durationSeconds = durationSeconds
        metadata.lastTimestamp = lastTimestamp
        metadata.segmentCount = segmentCount
        let currentComplete = !incomplete && !artifactsIncomplete
            && sourceManifest?.completed == true && sourceManifest?.problem_count == 0
            && sourceManifest?.streams.values.allSatisfy { $0.dropped_frames == 0 } == true
        if let lastIndex = metadata.sessions.indices.last {
            var lastSession = metadata.sessions[lastIndex]
            lastSession.artifactFinalization = artifacts
            lastSession.finalizationStatus = currentComplete ? "completed" : "degraded"
            if lastSession.endedAt == nil {
                lastSession.endedAt = now
            }
            if let sourceManifest {
                lastSession.timelineOffsetSeconds = Double(sourceManifest.timeline_offset_us) / 1_000_000
                lastSession.durationSeconds = Double(sourceManifest.streams.values.map { $0.committed_bytes }.max() ?? 0) / 32_000
            }
            if let mediaEnd = artifacts?.mediaEndSeconds, let offset = lastSession.timelineOffsetSeconds {
                lastSession.durationSeconds = max(lastSession.durationSeconds ?? 0, mediaEnd - offset)
            }
            if let captureEnd = artifacts?.captureEndSeconds, let offset = lastSession.timelineOffsetSeconds {
                lastSession.durationSeconds = max(lastSession.durationSeconds ?? 0, captureEnd - offset)
            }
            metadata.sessions[lastIndex] = lastSession
        }
        let allSessionsComplete = !metadata.sessions.isEmpty && metadata.sessions.allSatisfy {
            $0.finalizationStatus == "completed"
                && ($0.artifactsFolder == nil || $0.artifactFinalization?.isComplete == true)
        }
        metadata.status = allSessionsComplete && sourceProblems.isEmpty ? .completed : .degraded
        return metadata
    }

    enum CodingKeys: String, CodingKey {
        case version
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case durationSeconds = "duration_seconds"
        case lastTimestamp = "last_timestamp"
        case status
        case sessions
        case segmentCount = "segment_count"
        case speakerNames = "speaker_names"
        case buildIdentity = "build_identity"
        case lastReprocessIdentity = "last_reprocess_identity"
    }
}

struct MeetingHistoryItem: Identifiable {
    let id: String
    let folderURL: URL
    let title: String
    let createdAt: Date
    let durationSeconds: Double
    let segmentCount: Int
    let status: MeetingStatus
}

/// UI publication has its own generation: waiter deadlines never overrule an
/// observed terminal result, and old callbacks cannot replace newer saves.
nonisolated struct MeetingSavePublicationGate {
    private struct State { let id: UUID; var terminal = false }
    private var states: [URL: State] = [:]
    mutating func begin(folder: URL) -> UUID {
        let id = UUID()
        states[folder] = State(id: id)
        return id
    }
    func isPending(folder: URL, id: UUID) -> Bool {
        states[folder].map { $0.id == id && !$0.terminal } == true
    }
    mutating func markTerminal(folder: URL, id: UUID) -> Bool {
        guard states[folder]?.id == id else { return false }
        states[folder]?.terminal = true
        return true
    }
}
