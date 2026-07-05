import Foundation

/// Sweeps stale transcript staging folders that `AppModel.saveTranscriptFiles`
/// drops into the system temp directory as a transient copy of the transcript
/// (see AppModel.swift, `tempTranscriptFolderPath`). Nothing currently deletes
/// them - they're a debug-info convenience, not something Finder or a share
/// sheet holds open - so they've accumulated since May.
///
/// `FileManager.default.temporaryDirectory` is the SHARED per-user temp
/// directory, not sandboxed to this app, so a bare name-prefix match (the
/// original approach) isn't proof that Muesli owns a given folder - some other
/// process could have created a `Muesli-*` directory of its own. Two sweeps
/// instead:
///   1. `sweepStagingDirectory` - the current/going-forward layout, everything
///      staged inside our own `MuesliTranscriptStaging` subdirectory. Nothing
///      else writes there, so age is the only check needed.
///   2. `sweepLegacyTopLevelFolders` - one-shot cleanup of the ~84 pre-existing
///      top-level `Muesli-<title>-<uuid>` folders from before this subdirectory
///      existed. Prefix match alone isn't ownership proof, so this also
///      verifies the folder's *contents* look exactly like what
///      `saveTranscriptFiles` used to write (only `transcript.jsonl` /
///      `transcript.txt`, no subfolders, nothing else) before removing it.
///      Anything that doesn't match that shape is left alone permanently.
///
/// The "which folders/contents qualify" decisions are kept pure/nonisolated so
/// they're unit-testable without touching disk; the `sweep*` functions do the
/// actual (best-effort) I/O.
enum TempTranscriptCleanup {
    /// Subdirectory of the system temp dir that `saveTranscriptFiles` now
    /// stages into. Wholly owned by Muesli - nothing else should ever write
    /// here - so folders found inside it don't need a content check, only age.
    static let stagingDirectoryName = "MuesliTranscriptStaging"

    /// Prefix used by the legacy (pre-subdirectory) top-level staging folders.
    static let legacyFolderPrefix = "Muesli-"

    /// The exact set of filenames `saveTranscriptFiles` writes into a staging
    /// folder. Used to verify a legacy `Muesli-*` folder is plausibly ours
    /// before deleting it.
    static let legacyStagingFilenames: Set<String> = ["transcript.jsonl", "transcript.txt"]

    /// A folder qualifies for deletion once it's older than this, measured from
    /// its last modification date. Generous on purpose - these folders are
    /// meant to be short-lived, so a folder from the current launch should
    /// never be anywhere near this old.
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func isOlderThanMaxAge(modificationDate: Date?, now: Date) -> Bool {
        guard let modificationDate else { return false }
        return now.timeIntervalSince(modificationDate) > maxAge
    }

    /// Legacy-folder age/name gate (prefix + age only - NOT sufficient proof of
    /// ownership on its own; pair with `matchesLegacyStagingContents`).
    static func qualifiesForDeletion(name: String, modificationDate: Date?, now: Date) -> Bool {
        guard name.hasPrefix(legacyFolderPrefix) else { return false }
        return isOlderThanMaxAge(modificationDate: modificationDate, now: now)
    }

    /// True when a legacy top-level folder's direct children look exactly like
    /// what `saveTranscriptFiles` used to write - only files named
    /// `transcript.jsonl` / `transcript.txt`, no subdirectories, nothing else.
    /// An empty folder (no children at all) also qualifies: it holds nothing,
    /// muesli's or anyone else's, so there's nothing to lose by removing it.
    /// Anything else (a foreign file, a subdirectory) means "don't touch this,
    /// it isn't recognisably ours" - skip it forever rather than guess.
    static func matchesLegacyStagingContents(entries: [(name: String, isDirectory: Bool)]) -> Bool {
        if entries.isEmpty { return true }
        for entry in entries {
            if entry.isDirectory { return false }
            guard legacyStagingFilenames.contains(entry.name) else { return false }
        }
        return true
    }

    /// Removes stale subfolders of `stagingDir` (the current staging layout).
    /// Wholly app-owned, so only age (and basic directory/symlink sanity) gates
    /// deletion - no content check needed. Best-effort: unreadable entries or
    /// individual removal failures are skipped rather than thrown.
    @discardableResult
    static func sweepStagingDirectory(
        _ stagingDir: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removed = 0
        for url in entries {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            guard isOlderThanMaxAge(modificationDate: values.contentModificationDate, now: now) else {
                continue
            }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// One-shot cleanup of legacy top-level `Muesli-*` folders (from before the
    /// staging subdirectory existed). Requires prefix + age + a content match
    /// against `legacyStagingFilenames` before removing anything, and skips
    /// symlinked entries explicitly so a `Muesli-*` symlink pointing elsewhere
    /// is never followed and deleted through.
    @discardableResult
    static func sweepLegacyTopLevelFolders(
        in tempDir: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removed = 0
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(legacyFolderPrefix) else { continue }

            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            guard qualifiesForDeletion(name: name, modificationDate: values.contentModificationDate, now: now) else {
                continue
            }

            guard let children = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue // Can't verify contents - skip rather than guess.
            }

            var childEntries: [(name: String, isDirectory: Bool)] = []
            var readFailure = false
            for child in children {
                guard let childValues = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ) else {
                    readFailure = true
                    break
                }
                // A symlinked child is treated as "unexpected" (counts as a
                // directory for the purposes of the shape check) so it always
                // disqualifies the folder rather than being silently ignored.
                let isDirectory = childValues.isSymbolicLink == true ? true : (childValues.isDirectory ?? false)
                childEntries.append((child.lastPathComponent, isDirectory))
            }
            guard !readFailure else { continue }

            guard matchesLegacyStagingContents(entries: childEntries) else { continue }

            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Runs both sweeps against the system temp directory. Returns the total
    /// number of folders removed.
    @discardableResult
    static func sweep(
        temporaryDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let stagingDir = temporaryDirectory.appendingPathComponent(stagingDirectoryName, isDirectory: true)
        let removedFromStaging = sweepStagingDirectory(stagingDir, now: now, fileManager: fileManager)
        let removedLegacy = sweepLegacyTopLevelFolders(in: temporaryDirectory, now: now, fileManager: fileManager)
        return removedFromStaging + removedLegacy
    }
}
