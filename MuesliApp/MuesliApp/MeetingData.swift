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
