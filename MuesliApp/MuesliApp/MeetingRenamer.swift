import Foundation

enum MeetingRenameError: LocalizedError {
    case emptyTitle
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "Title can't be empty."
        case .noActiveSession:
            return "No active meeting session to rename."
        }
    }
}

// MARK: - Meeting Renamer

/// Pure I/O half of the meeting rename path: read meeting.json, set the
/// (trimmed) title and updatedAt, write it back. Deliberately free of
/// AppModel state so it's unit-testable on its own - AppModel wraps this
/// with the in-memory mirror updates (meetingHistory, activeScreen,
/// currentSession) that only make sense in the context of the running app.
enum MeetingRenamer {
    static func rename(folderURL: URL, to newTitle: String) throws -> String {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingRenameError.emptyTitle }

        let metadataURL = folderURL.appendingPathComponent("meeting.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: metadataURL))
        metadata.title = trimmed
        metadata.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: [.atomic])

        return trimmed
    }
}
