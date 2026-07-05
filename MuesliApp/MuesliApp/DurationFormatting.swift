import Foundation

/// Shared duration formatting for meeting summaries (recent-meetings list,
/// meeting viewer header). Deliberately free of SwiftUI/AppKit so it's
/// unit-testable on its own.
enum DurationFormatting {
    static func compact(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%dh %dm", hrs, mins)
        }
        if mins > 0 {
            return String(format: "%dm %ds", mins, secs)
        }
        return "\(secs)s"
    }
}
