import XCTest
import Foundation
import Darwin

final class ArchiveSourceInventoryTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/muesli-inventory-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ root: URL, _ path: String, _ bytes: Data = Data("source".utf8)) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    func testIncludesHiddenUnindexedFilesAndEmptyDirectoriesAndActualHashes() throws {
        let folder = try fixture()
        try write(folder, "audio/mic.pcm", Data("abc".utf8))
        try write(folder, "audio-unindexed/.hidden")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("artifacts/unindexed-empty"), withIntermediateDirectories: true)
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        let result = try ArchiveSourceInventory.capture(access: access)
        XCTAssertEqual(result.files.map(\.path), [".meeting-access.lock", "audio-unindexed/.hidden", "audio/mic.pcm"])
        XCTAssertEqual(result.directories, ["artifacts", "artifacts/unindexed-empty", "audio", "audio-unindexed"])
        XCTAssertEqual(result.files.first { $0.path == "audio/mic.pcm" }?.sha256,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(result.files.first { $0.path == "audio/mic.pcm" }?.bytes, 3)
    }
    func testSharedOwnerCannotProduceArchiveInventory() throws {
        let folder = try fixture()
        let access = try MeetingFileAccess.acquire(in: folder)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access))
    }
    func testResultRetainsExclusiveOwnershipUntilActuallyReleased() throws {
        let folder = try fixture()
        var access: MeetingFileAccess? = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        var result: ArchiveSourceInventory.Snapshot? = try ArchiveSourceInventory.capture(access: access!)
        access = nil
        XCTAssertNotNil(result)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder))
        result = nil
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder))
    }
    func testUnresolvedTransactionRefusedAndNeverRecovered() throws {
        let folder = try fixture()
        try write(folder, ".transcript-transaction/pending.json", Data("unresolved".utf8))
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".transcript-transaction/pending.json")), Data("unresolved".utf8))
    }
    func testSymlinkAndFIFOAndHardlinkRefused() throws {
        for kind in ["symlink", "fifo", "hardlink"] {
            let folder = try fixture(), outside = try fixture()
            try write(outside, "original")
            let target = folder.appendingPathComponent("entry")
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside) }
            if kind == "fifo" { XCTAssertEqual(mkfifo(target.path, S_IRUSR | S_IWUSR), 0) }
            if kind == "hardlink" { try FileManager.default.linkItem(at: outside.appendingPathComponent("original"), to: target) }
            let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
            XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access))
        }
    }
    func testCaseAliasOfRecoveryTransactionIsAlsoRefused() throws {
        let folder = try fixture()
        try write(folder, ".TRANSCRIPT-TRANSACTION/pending.json")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".transcript-transaction").path) else {
            throw XCTSkip("This volume uses case-sensitive path lookup")
        }
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".TRANSCRIPT-TRANSACTION/pending.json").path))
    }
    func testRootAliasResolvesToTheActuallyOwnedPhysicalFolder() throws {
        let parent = try fixture(), aliases = try fixture()
        let folder = parent.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let alias = aliases.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let access = try MeetingFileAccess.acquire(in: alias.appendingPathComponent("meeting"), mode: .archive)
        let snapshot = try ArchiveSourceInventory.capture(access: access)
        XCTAssertEqual(snapshot.canonicalFolderURL.path, folder.path)
        XCTAssertEqual(snapshot.files.map(\.path), [".meeting-access.lock"])
    }
    func testSameSizeMutationDuringReadRefused() throws {
        let folder = try fixture()
        try write(folder, "audio/mic.pcm", Data("original".utf8))
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access) { path in
            if path == "audio/mic.pcm" { try Data("modified".utf8).write(to: folder.appendingPathComponent(path)) }
        })
    }
    func testReplacedRootIsRejectedBeforeAnySourceRead() throws {
        let parent = try fixture()
        let folder = parent.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write(folder, "original")
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access, afterRootResolution: { root in
            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("retained-original"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("foreign".utf8).write(to: root.appendingPathComponent("foreign"))
        }, beforeRead: { _ in throw CocoaError(.fileReadUnknown) })) { error in
            XCTAssertEqual((error as? ArchiveSourceInventory.Failure)?.message, "The source folder identity changed.")
        }
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("retained-original/original")), Data("source".utf8))
    }
    func testReplacedAncestorCannotSubstituteForeignBytes() throws {
        let folder = try fixture(), outside = try fixture()
        try write(folder, "audio/mic.pcm")
        try write(outside, "mic.pcm", Data("foreign".utf8))
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access) { path in
            if path == "audio/mic.pcm" {
                try FileManager.default.moveItem(at: folder.appendingPathComponent("audio"), to: folder.appendingPathComponent("old-audio"))
                try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("audio"), withDestinationURL: outside)
            }
        })
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("mic.pcm")), Data("foreign".utf8))
    }
    func testAddedEntryDuringScanRefused() throws {
        let folder = try fixture()
        try write(folder, "original")
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access) { path in
            if path == "original" { try Data().write(to: folder.appendingPathComponent("new-source")) }
        })
    }
    func testEntryDepthPathAndByteLimitsRefusePartialInventory() throws {
        let folder = try fixture()
        try write(folder, "audio/nested/mic.pcm", Data(repeating: 1, count: 10))
        let access = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        var cases: [ArchiveSourceInventory.Limits] = []
        var limit = ArchiveSourceInventory.Limits(); limit.entries = 1; cases.append(limit)
        limit = .init(); limit.depth = 1; cases.append(limit)
        limit = .init(); limit.pathBytes = 4; cases.append(limit)
        limit = .init(); limit.fileBytes = 9; cases.append(limit)
        limit = .init(); limit.totalBytes = 9; cases.append(limit)
        for limits in cases { XCTAssertThrowsError(try ArchiveSourceInventory.capture(access: access, limits: limits)) }
        XCTAssertEqual(try ArchiveSourceInventory.capture(access: access).files.count, 2)
    }
}
