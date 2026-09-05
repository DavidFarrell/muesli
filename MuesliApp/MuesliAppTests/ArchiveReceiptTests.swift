import XCTest
import Foundation
import Darwin

final class ArchiveReceiptTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let receipt: ArchiveReceipt
        let receiptURL: URL
    }
    private func fixture(cleanup: ArchiveReceipt.Cleanup = .retained) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("archive-receipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = ArchiveReceipt.Source(folder: root.appendingPathComponent("meeting").path,
                                          directoryDevice: 1, directoryInode: 42,
                                          files: [.init(path: "audio/mic.pcm", bytes: 32000, sha256: String(repeating: "a", count: 64))],
                                          sessionIDs: ["source-1"])
        let outputs = try ArchiveReceipt.Output.Role.allCases.filter { $0 != .attachment }.map { role in
            let file = root.appendingPathComponent(role.rawValue + ".txt")
            try Data("verified output".utf8).write(to: file)
            return ArchiveReceipt.Output(role: role, file: try ArchiveReceipt.readFingerprint(at: file, maximumBytes: 1024),
                                         noteID: [.rawNote, .officialNote, .redactionReport].contains(role) ? "note-1" : nil)
        }
        let receipt = ArchiveReceipt(schemaVersion: 2, operationID: UUID(), source: source, outputs: outputs,
                                     checks: .init(reprocessExitCode: 0, finalResultCount: 1, errorEventCount: 0,
                                                   coveredSessionIDs: ["source-1"], deterministicRedactionsVerified: true,
                                                   imageLinksVerified: true, sourceIntegrityProblems: []), cleanup: cleanup)
        return Fixture(root: root, receipt: receipt, receiptURL: root.appendingPathComponent("receipt.json"))
    }
    func testRoundTripAndPersistedOutputsMatch() throws {
        let value = try fixture()
        let decoded = try ArchiveReceipt.decode(JSONEncoder().encode(value.receipt))
        try decoded.validate(currentSource: value.receipt.source, receiptURL: value.receiptURL)
    }
    func testOutputChangedWithoutChangingLengthIsRejected() throws {
        let value = try fixture()
        let output = value.receipt.outputs[0].file
        try Data(repeating: 120, count: Int(output.bytes)).write(to: URL(fileURLWithPath: output.path))
        XCTAssertThrowsError(try value.receipt.validate(currentSource: value.receipt.source, receiptURL: value.receiptURL))
    }
    func testUnindexedSourceAndReplacedDirectoryAreRejected() throws {
        let value = try fixture(); let source = value.receipt.source
        let extra = ArchiveReceipt.Source(folder: source.folder, directoryDevice: source.directoryDevice,
                                           directoryInode: source.directoryInode,
                                           files: source.files + [.init(path: "audio-session-2/mic.pcm", bytes: 10,
                                                                        sha256: String(repeating: "b", count: 64))],
                                           sessionIDs: source.sessionIDs)
        XCTAssertThrowsError(try value.receipt.validate(currentSource: extra, receiptURL: value.receiptURL))
        let replacement = ArchiveReceipt.Source(folder: source.folder, directoryDevice: source.directoryDevice,
                                                 directoryInode: source.directoryInode + 1, files: source.files,
                                                 sessionIDs: source.sessionIDs)
        XCTAssertThrowsError(try value.receipt.validate(currentSource: replacement, receiptURL: value.receiptURL))
    }
    func testPendingUncertainAndCompletedCannotBeRetried() throws {
        for state in [ArchiveReceipt.Cleanup.pending, .uncertain, .trashed] {
            let value = try fixture(cleanup: state)
            XCTAssertThrowsError(try value.receipt.validate(currentSource: value.receipt.source, receiptURL: value.receiptURL))
        }
    }
    func testSymlinkDirectoryHardlinkAndFIFOAreRejectedWithoutReading() throws {
        let value = try fixture()
        let file = URL(fileURLWithPath: value.receipt.outputs[0].file.path)
        let link = value.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ArchiveReceipt.readFingerprint(at: link, maximumBytes: 1024))
        let alias = value.root.appendingPathComponent("directory-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: value.root)
        XCTAssertThrowsError(try ArchiveReceipt.readFingerprint(at: alias.appendingPathComponent(file.lastPathComponent), maximumBytes: 1024))
        let hardlink = value.root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: file, to: hardlink)
        XCTAssertThrowsError(try ArchiveReceipt.readFingerprint(at: file, maximumBytes: 1024))
        let fifo = value.root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try ArchiveReceipt.readFingerprint(at: fifo, maximumBytes: 1024))
    }
    func testReceiptInsideSourceAndMissingOutputFailClosed() throws {
        let value = try fixture()
        XCTAssertThrowsError(try value.receipt.validate(currentSource: value.receipt.source,
                                                       receiptURL: URL(fileURLWithPath: value.receipt.source.folder).appendingPathComponent("receipt.json")))
        try FileManager.default.removeItem(atPath: value.receipt.outputs[0].file.path)
        XCTAssertThrowsError(try value.receipt.validate(currentSource: value.receipt.source, receiptURL: value.receiptURL))
    }
    func testOlderReceiptAndOversizedInputAreRejected() throws {
        let value = try fixture()
        let data = try JSONEncoder().encode(value.receipt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schema_version"] = 1
        XCTAssertThrowsError(try ArchiveReceipt.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try ArchiveReceipt.decode(Data(repeating: 32, count: 8 * 1024 * 1024 + 1)))
    }
    func testSplitMeetingRequiresCompleteOutputGroups() throws {
        let value = try fixture()
        var outputs = value.receipt.outputs
        for role in [ArchiveReceipt.Output.Role.rawNote, .officialNote, .redactionReport] {
            let file = value.root.appendingPathComponent("second-" + role.rawValue)
            try Data("second note".utf8).write(to: file)
            outputs.append(.init(role: role, file: try ArchiveReceipt.readFingerprint(at: file, maximumBytes: 1024), noteID: "note-2"))
        }
        let split = ArchiveReceipt(schemaVersion: 2, operationID: value.receipt.operationID, source: value.receipt.source,
                                   outputs: outputs, checks: value.receipt.checks, cleanup: .retained)
        try split.validate(currentSource: split.source, receiptURL: value.receiptURL)
        outputs.removeLast()
        let incomplete = ArchiveReceipt(schemaVersion: 2, operationID: split.operationID, source: split.source,
                                        outputs: outputs, checks: split.checks, cleanup: .retained)
        XCTAssertThrowsError(try incomplete.validate(currentSource: split.source, receiptURL: value.receiptURL))
    }
    func testFailedChecksAndDuplicateCoverageDoNotAuthorizeCleanup() throws {
        let value = try fixture()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value.receipt)) as? [String: Any])
        for (key, failure) in [("reprocess_exit_code", 1 as Any), ("error_event_count", 1 as Any),
                               ("final_result_count", 2 as Any), ("image_links_verified", false as Any),
                               ("deterministic_redactions_verified", false as Any),
                               ("source_integrity_problems", ["loss"] as Any),
                               ("covered_session_ids", ["source-1", "source-1"] as Any)] {
            var object = original
            var checks = try XCTUnwrap(object["checks"] as? [String: Any])
            checks[key] = failure
            object["checks"] = checks
            let receipt = try ArchiveReceipt.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try receipt.validate(currentSource: value.receipt.source, receiptURL: value.receiptURL), key)
        }
    }

}
