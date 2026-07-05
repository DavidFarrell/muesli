import Foundation

/// Sweeps stale `Muesli-<title>-<uuid>` staging folders that
/// `AppModel.saveTranscriptFiles` drops into the system temp directory as a
/// transient copy of the transcript (see AppModel.swift, `tempTranscriptFolderPath`).
/// Nothing currently deletes them - they're a debug-info convenience, not
/// something Finder or a share sheet holds open - so they've been accumulating
/// since May. The "which folders qualify" decision is kept pure/nonisolated so
/// it's unit-testable without touching disk; `sweep` does the actual I/O.
enum TempTranscriptCleanup {
    static let folderPrefix = "Muesli-"

    /// A folder qualifies for deletion once it's older than this, measured from
    /// its last modification date. Generous on purpose - these folders are
    /// meant to be short-lived, so a folder from the current launch should
    /// never be anywhere near this old.
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func qualifiesForDeletion(name: String, modificationDate: Date?, now: Date) -> Bool {
        guard name.hasPrefix(folderPrefix) else { return false }
        guard let modificationDate else { return false }
        return now.timeIntervalSince(modificationDate) > maxAge
    }

    /// Removes stale staging folders directly under `directory`. Best-effort:
    /// unreadable directories or individual removal failures are skipped rather
    /// than thrown. Returns the number of folders removed.
    @discardableResult
    static func sweep(
        directory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removed = 0
        for url in entries {
            guard let resourceValues = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ), resourceValues.isDirectory == true else {
                continue
            }
            guard qualifiesForDeletion(
                name: url.lastPathComponent,
                modificationDate: resourceValues.contentModificationDate,
                now: now
            ) else {
                continue
            }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
