import XCTest

final class MeetingRenamerTests: XCTestCase {
    private func makeMeetingFolder(title: String = "Original Title") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRenamerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let metadata = MeetingMetadata(
            version: 1,
            title: title,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 12,
            lastTimestamp: 12,
            status: .completed,
            sessions: [],
            segmentCount: 3,
            speakerNames: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: folder.appendingPathComponent("meeting.json"))
        return folder
    }

    private func readMetadata(from folderURL: URL) throws -> MeetingMetadata {
        let data = try Data(contentsOf: folderURL.appendingPathComponent("meeting.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingMetadata.self, from: data)
    }

    func testRenameWritesTrimmedTitleAndBumpsUpdatedAt() throws {
        let folder = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try MeetingRenamer.rename(folderURL: folder, to: "  New Title  ")
        XCTAssertEqual(result, "New Title")

        let metadata = try readMetadata(from: folder)
        XCTAssertEqual(metadata.title, "New Title")
        XCTAssertGreaterThan(metadata.updatedAt, Date(timeIntervalSince1970: 0))
    }

    func testRenameLeavesOtherFieldsUntouched() throws {
        let folder = try makeMeetingFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try MeetingRenamer.rename(folderURL: folder, to: "New Title")

        let metadata = try readMetadata(from: folder)
        XCTAssertEqual(metadata.durationSeconds, 12)
        XCTAssertEqual(metadata.segmentCount, 3)
        XCTAssertEqual(metadata.status, .completed)
    }

    func testEmptyTitleAfterTrimThrowsAndLeavesFileUntouched() throws {
        let folder = try makeMeetingFolder(title: "Untouched")
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertThrowsError(try MeetingRenamer.rename(folderURL: folder, to: "   ")) { error in
            XCTAssertEqual(error as? MeetingRenameError, .emptyTitle)
        }

        let metadata = try readMetadata(from: folder)
        XCTAssertEqual(metadata.title, "Untouched", "a rejected rename must not touch the file on disk")
    }

    func testMissingFolderPropagatesFailure() {
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRenamerTests-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try MeetingRenamer.rename(folderURL: missingFolder, to: "New Title"))
    }

    func testUnwritableFolderPropagatesFailure() throws {
        // An atomic write replaces the file via a temp-file-and-rename inside
        // its containing directory, so a read-only *file* doesn't block it -
        // the directory itself has to be unwritable to reject the write.
        let folder = try makeMeetingFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        XCTAssertThrowsError(try MeetingRenamer.rename(folderURL: folder, to: "New Title"))

        // Restore write permission before reading back, then verify the
        // rejected write never landed.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let metadata = try readMetadata(from: folder)
        XCTAssertEqual(metadata.title, "Original Title")
    }
}

extension MeetingRenameError: Equatable {
    public static func == (lhs: MeetingRenameError, rhs: MeetingRenameError) -> Bool {
        switch (lhs, rhs) {
        case (.emptyTitle, .emptyTitle), (.noActiveSession, .noActiveSession):
            return true
        default:
            return false
        }
    }
}
