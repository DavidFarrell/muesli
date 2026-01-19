import Foundation

// MARK: - Meeting Metadata

enum MeetingStatus: String, Codable {
    case recording
    case completed
}

struct MeetingStreamInfo: Codable, Hashable {
    let sampleRate: Int?
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
    }
}

struct MeetingSessionMetadata: Codable, Hashable {
    let sessionID: Int
    let startedAt: Date
    let endedAt: Date?
    let audioFolder: String
    let streams: [String: MeetingStreamInfo]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case audioFolder = "audio_folder"
        case streams
    }
}

struct MeetingMetadata: Codable {
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
