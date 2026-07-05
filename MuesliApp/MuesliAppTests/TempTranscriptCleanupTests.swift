import XCTest

final class TempTranscriptCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - qualifiesForDeletion (legacy name + age gate)

    func testIgnoresFoldersWithoutTheLegacyPrefix() {
        let old = now.addingTimeInterval(-2 * 24 * 60 * 60)
        XCTAssertFalse(TempTranscriptCleanup.qualifiesForDeletion(
            name: "SomeOtherApp-staging", modificationDate: old, now: now
        ))
    }

    func testIgnoresFoldersWithoutAModificationDate() {
        XCTAssertFalse(TempTranscriptCleanup.qualifiesForDeletion(
            name: "Muesli-Standup-\(UUID().uuidString)", modificationDate: nil, now: now
        ))
    }

    func testKeepsRecentMuesliFolders() {
        let recent = now.addingTimeInterval(-60) // one minute old
        XCTAssertFalse(TempTranscriptCleanup.qualifiesForDeletion(
            name: "Muesli-Standup-\(UUID().uuidString)", modificationDate: recent, now: now
        ))
    }

    func testMatchesMuesliFoldersOlderThanMaxAge() {
        let old = now.addingTimeInterval(-(TempTranscriptCleanup.maxAge + 60))
        XCTAssertTrue(TempTranscriptCleanup.qualifiesForDeletion(
            name: "Muesli-Standup-\(UUID().uuidString)", modificationDate: old, now: now
        ))
    }

    // MARK: - matchesLegacyStagingContents (ownership-by-content check)

    func testExpectedStagingFilesMatch() {
        XCTAssertTrue(TempTranscriptCleanup.matchesLegacyStagingContents(entries: [
            ("transcript.jsonl", false),
            ("transcript.txt", false),
        ]))
    }

    func testPartialStagingFilesStillMatch() {
        // saveTranscriptFiles skips a file if its data failed to encode, so a
        // folder with just one of the two expected files is still plausibly ours.
        XCTAssertTrue(TempTranscriptCleanup.matchesLegacyStagingContents(entries: [
            ("transcript.txt", false),
        ]))
    }

    func testEmptyFolderMatches() {
        // Holds nothing - muesli's or anyone else's - so there's nothing to
        // lose by treating it as removable.
        XCTAssertTrue(TempTranscriptCleanup.matchesLegacyStagingContents(entries: []))
    }

    func testForeignFilePresentDoesNotMatch() {
        XCTAssertFalse(TempTranscriptCleanup.matchesLegacyStagingContents(entries: [
            ("transcript.jsonl", false),
            ("some-other-process-lockfile", false),
        ]))
    }

    func testSubdirectoryPresentDoesNotMatch() {
        XCTAssertFalse(TempTranscriptCleanup.matchesLegacyStagingContents(entries: [
            ("transcript.jsonl", false),
            ("nested", true),
        ]))
    }

    // MARK: - sweepStagingDirectory (current layout - fully app-owned)

    func testSweepStagingDirectoryRemovesOnlyStaleSubfolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempTranscriptCleanupTests-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleFolder = root.appendingPathComponent("Old Meeting-\(UUID().uuidString)")
        let freshFolder = root.appendingPathComponent("New Meeting-\(UUID().uuidString)")
        for folder in [staleFolder, freshFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let staleDate = now.addingTimeInterval(-(TempTranscriptCleanup.maxAge + 60))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleFolder.path)

        let removed = TempTranscriptCleanup.sweepStagingDirectory(root, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFolder.path))
    }

    // MARK: - sweepLegacyTopLevelFolders (prefix + age + content ownership check)

    func testSweepLegacyTopLevelFoldersRemovesOnlyStaleRecognisableMuesliFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempTranscriptCleanupTests-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleRecognisable = root.appendingPathComponent("Muesli-Old Meeting-\(UUID().uuidString)")
        let freshRecognisable = root.appendingPathComponent("Muesli-New Meeting-\(UUID().uuidString)")
        let staleButForeign = root.appendingPathComponent("Muesli-Not Ours-\(UUID().uuidString)")
        let unrelatedFolder = root.appendingPathComponent("SomeOtherApp-cache")

        try FileManager.default.createDirectory(at: staleRecognisable, withIntermediateDirectories: true)
        try "jsonl".data(using: .utf8)!.write(to: staleRecognisable.appendingPathComponent("transcript.jsonl"))
        try "text".data(using: .utf8)!.write(to: staleRecognisable.appendingPathComponent("transcript.txt"))

        try FileManager.default.createDirectory(at: freshRecognisable, withIntermediateDirectories: true)
        try "text".data(using: .utf8)!.write(to: freshRecognisable.appendingPathComponent("transcript.txt"))

        // Stale, prefix matches, but a foreign process wrote something we
        // don't recognise into it - a decoy that must survive the sweep.
        try FileManager.default.createDirectory(at: staleButForeign, withIntermediateDirectories: true)
        try "not ours".data(using: .utf8)!.write(to: staleButForeign.appendingPathComponent("unexpected-file.dat"))

        try FileManager.default.createDirectory(at: unrelatedFolder, withIntermediateDirectories: true)

        for folder in [staleRecognisable, staleButForeign] {
            let staleDate = now.addingTimeInterval(-(TempTranscriptCleanup.maxAge + 60))
            try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: folder.path)
        }

        let removed = TempTranscriptCleanup.sweepLegacyTopLevelFolders(in: root, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRecognisable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshRecognisable.path), "fresh folder is not stale, must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleButForeign.path), "foreign contents must survive even though stale and prefix-matched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFolder.path), "non-Muesli-prefixed folder must never be touched")
    }

    // MARK: - sweep (orchestrates both)

    func testSweepCombinesStagingAndLegacyResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempTranscriptCleanupTests-combined-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stagingDir = root.appendingPathComponent(TempTranscriptCleanup.stagingDirectoryName, isDirectory: true)
        let staleStagingSubfolder = stagingDir.appendingPathComponent("Old Meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staleStagingSubfolder, withIntermediateDirectories: true)
        let staleDate = now.addingTimeInterval(-(TempTranscriptCleanup.maxAge + 60))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleStagingSubfolder.path)

        let staleLegacyFolder = root.appendingPathComponent("Muesli-Old Meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staleLegacyFolder, withIntermediateDirectories: true)
        try "text".data(using: .utf8)!.write(to: staleLegacyFolder.appendingPathComponent("transcript.txt"))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleLegacyFolder.path)

        let removed = TempTranscriptCleanup.sweep(temporaryDirectory: root, now: now)

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleStagingSubfolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLegacyFolder.path))
    }
}
