import XCTest

final class TempTranscriptCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - qualifiesForDeletion (pure predicate)

    func testIgnoresFoldersWithoutTheMuesliPrefix() {
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

    func testRemovesMuesliFoldersOlderThanMaxAge() {
        let old = now.addingTimeInterval(-(TempTranscriptCleanup.maxAge + 60))
        XCTAssertTrue(TempTranscriptCleanup.qualifiesForDeletion(
            name: "Muesli-Standup-\(UUID().uuidString)", modificationDate: old, now: now
        ))
    }

    // MARK: - sweep (touches disk)

    func testSweepRemovesOnlyStaleMuesliFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempTranscriptCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleFolder = root.appendingPathComponent("Muesli-Old Meeting-\(UUID().uuidString)")
        let freshFolder = root.appendingPathComponent("Muesli-New Meeting-\(UUID().uuidString)")
        let unrelatedFolder = root.appendingPathComponent("SomeOtherApp-cache")
        for folder in [staleFolder, freshFolder, unrelatedFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let staleDate = now.addingTimeInterval(-(TempTranscriptCleanup.maxAge + 60))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleFolder.path)

        let removed = TempTranscriptCleanup.sweep(directory: root, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFolder.path))
    }
}
