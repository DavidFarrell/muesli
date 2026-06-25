import Foundation
import os

/// Single unified audio-subsystem logger.
///
/// Everything in the mic/system/device path routes through one `os_log`
/// subsystem (`com.muesli.audio`) so device events, engine lifecycle, binding,
/// and the frame heartbeat all interleave on ONE timeline. The point is that a
/// failure the user cannot reproduce on demand can be reconstructed from the
/// logs alone: capture post-hoc with
///
///     log collect --last 30m --output ~/muesli-audio.logarchive
///
/// (or Console.app filtered on subsystem `com.muesli.audio`).
///
/// Every line is also mirrored into an optional in-app `sink` so it shows up in
/// the backend log tail without needing Console.
enum AudioLog {
    static let log = Logger(subsystem: "com.muesli.audio", category: "device")

    /// Optional mirror into the app UI, installed once by `AppModel`. It is read
    /// from CoreAudio listener callbacks on arbitrary queues, so the sink itself
    /// is responsible for hopping to the main actor. Set-once at launch.
    nonisolated(unsafe) static var sink: ((String) -> Void)?

    static func event(_ key: String, _ fields: [String: Any] = [:]) {
        let line = format(key, fields)
        log.info("\(line, privacy: .public)")
        sink?(line)
    }

    static func error(_ key: String, _ fields: [String: Any] = [:]) {
        let line = format(key, fields)
        log.error("\(line, privacy: .public)")
        sink?(line)
    }

    private static func format(_ key: String, _ fields: [String: Any]) -> String {
        guard !fields.isEmpty else { return key }
        // Sorted for a stable, greppable layout (dictionaries are unordered).
        let pairs = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        return "\(key) \(pairs)"
    }
}
