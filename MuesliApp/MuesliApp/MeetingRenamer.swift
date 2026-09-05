import Foundation

nonisolated enum MeetingRenameError: LocalizedError, Equatable {
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
