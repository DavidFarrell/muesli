import XCTest
import Foundation
import Darwin

final class ArchiveMoveJournalTests: XCTestCase {
    private let sessionID = "ABEA3E61-2D0A-4AE4-9003-EB7953975E6C"
    private let receipt = ArchiveReceipt.FileRecord(path: "/private/tmp/synthetic-receipt.json", bytes: 100, sha256: String(repeating: "a", count: 64))
    private func directory() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp/muesli-move-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func journal(_ root: URL, _ source: MeetingFileAccess,
                         checkpoint: (@Sendable (ArchiveMoveJournal.Checkpoint) throws -> Void)? = nil) throws -> ArchiveMoveJournal {
        try .init(rootURL: root, source: source, sessionIDs: [sessionID], receipt: receipt, checkpoint: checkpoint)
    }
    func testDurablePendingSurvivesOwnerReleaseAndBlocksBlindRetry() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        var value: ArchiveMoveJournal? = try journal(root, source)
        let id = value!.record.operationID
        XCTAssertEqual(value!.record.phase, .pending)
        value = nil
        let persisted = try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity)
        XCTAssertEqual(persisted.operationID, id); XCTAssertEqual(persisted.phase, .pending)
        XCTAssertThrowsError(try journal(root, source))
    }
    func testPrivateJournalAndExclusiveSourceAreRequired() throws {
        let root = try directory(), folder = try directory()
        var shared: MeetingFileAccess? = try .acquire(in: folder)
        XCTAssertThrowsError(try journal(root, shared!)); shared = nil
        let source = try MeetingFileAccess.acquire(in: folder, mode: .archive)
        let inside = folder.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try journal(inside, source))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inside.path).isEmpty, "Rejected intent must not mutate the source")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try journal(root, source))
    }
    func testActualTemporaryMoveRecordsVerifiedReturnedDirectory() throws {
        let root = try directory(), original = try directory(), destinationParent = try directory()
        let source = try MeetingFileAccess.acquire(in: original, mode: .archive), destination = destinationParent.appendingPathComponent("moved")
        let bytes = Data("synthetic original".utf8)
        try bytes.write(to: original.appendingPathComponent("source.txt"))
        var value: ArchiveMoveJournal? = try journal(root, source)
        try FileManager.default.moveItem(at: original, to: destination) // Temporary fixture; never Finder Trash.
        try value!.recordMoved(to: destination)
        XCTAssertEqual(value!.record.phase, .moved)
        XCTAssertThrowsError(try value!.recordUncertain(code: "late_callback"))
        value = nil
        let persisted = try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity)
        XCTAssertEqual(persisted.phase, .moved); XCTAssertEqual(persisted.destination, destination.path)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("source.txt")), bytes)
    }
    func testNoMoveAndWrongDestinationCannotBecomeMoved() throws {
        let root = try directory(), original = try directory(), targetParent = try directory(), wrong = try directory()
        let source = try MeetingFileAccess.acquire(in: original, mode: .archive), value = try journal(root, source)
        XCTAssertThrowsError(try value.recordMoved(to: wrong))
        let target = targetParent.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: original, to: target)
        XCTAssertThrowsError(try value.recordMoved(to: wrong))
        XCTAssertEqual(value.record.phase, .pending)
        try value.recordMoved(to: target)
    }
    func testInitialSyncFailureReturnsNoJournalAndLeavesMarkerForReconciliation() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        XCTAssertThrowsError(try journal(root, source) { if case .fileSync = $0 { throw CocoaError(.fileWriteUnknown) } })
        XCTAssertThrowsError(try journal(root, source))
        XCTAssertEqual(try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity).phase, .pending)
    }
    func testFailedOutcomePublicationKeepsPendingAndCannotStageRepeatedly() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        var value: ArchiveMoveJournal? = try journal(root, source) { if case .publish = $0 { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try value!.recordUncertain(code: "native_move_failed"))
        let count = try FileManager.default.contentsOfDirectory(atPath: root.path).count
        XCTAssertThrowsError(try value!.recordUncertain(code: "retry"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, count)
        value = nil
        XCTAssertEqual(try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity).phase, .pending)
        XCTAssertThrowsError(try journal(root, source))
    }
    func testUncertainOutcomeAlwaysBlocksAutomaticReuse() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        var value: ArchiveMoveJournal? = try journal(root, source)
        try value!.recordUncertain(code: "native_move_failed"); value = nil
        let record = try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity)
        XCTAssertEqual(record.phase, .uncertain); XCTAssertEqual(record.diagnosticCode, "native_move_failed")
        XCTAssertThrowsError(try journal(root, source))
    }
    func testChangedRootAncestorDoesNotWriteIntoReplacement() throws {
        let root = try directory(), parent = try directory(), foreign = try directory()
        let source = try MeetingFileAccess.acquire(in: directory(), mode: .archive), value = try journal(root, source)
        let moved = parent.appendingPathComponent("old-journal")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: foreign)
        XCTAssertThrowsError(try value.recordUncertain(code: "native_move_failed"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }
    func testJournalOwnershipAndChangedMarkerIdentityAreEnforced() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        let second = try MeetingFileAccess.acquire(in: directory(), mode: .archive), value = try journal(root, source)
        XCTAssertThrowsError(try journal(root, second))
        let marker = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).json")
        let original = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: marker); try original.write(to: marker)
        XCTAssertThrowsError(try value.recordUncertain(code: "native_move_failed"))
    }
    func testJournalItselfRetainsExclusiveSourceUntilActualRelease() throws {
        let root = try directory(), folder = try directory()
        var source: MeetingFileAccess? = try .acquire(in: folder, mode: .archive)
        var value: ArchiveMoveJournal? = try journal(root, source!)
        source = nil
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: folder))
        XCTAssertEqual(value?.record.phase, .pending)
        value = nil
        XCTAssertNoThrow(try MeetingFileAccess.acquire(in: folder))
    }
    func testDirectorySyncFailureAfterMoveNeverPermitsAnAutomaticRetry() throws {
        let root = try directory(), original = try directory(), parent = try directory()
        let source = try MeetingFileAccess.acquire(in: original, mode: .archive), destination = parent.appendingPathComponent("moved")
        var value: ArchiveMoveJournal? = try journal(root, source) { checkpoint in
            if case .directorySync = checkpoint, !FileManager.default.fileExists(atPath: original.path) {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.moveItem(at: original, to: destination)
        XCTAssertThrowsError(try value!.recordMoved(to: destination))
        XCTAssertEqual(value!.record.phase, .pending, "The failed caller cannot claim a durable outcome")
        XCTAssertThrowsError(try value!.recordMoved(to: destination))
        value = nil
        // The rename is visible on this running filesystem. Following a real
        // power interruption either old pending or new moved is nonretryable.
        XCTAssertEqual(try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity).phase, .moved)
    }
    func testReadOnlyInspectionDoesNotCreateOwnershipFiles() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        XCTAssertThrowsError(try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testIndependentMarkerSwapAtPublicationCannotBeSilentlyOverwritten() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        let marker = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).json")
        let displaced = root.appendingPathComponent("previous-marker")
        let otherEvidence = Data("replacement journal evidence".utf8)
        let value = try journal(root, source) { point in
            if case .publish = point {
                try FileManager.default.moveItem(at: marker, to: displaced)
                try otherEvidence.write(to: marker, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
        }
        XCTAssertThrowsError(try value.recordUncertain(code: "native_move_failed"), "Changed marker identity at publication must not report success")
        XCTAssertEqual(try Data(contentsOf: marker), otherEvidence, "Do not erase evidence placed at the changed marker path")
    }

    func testAtomicExchangeRetainsSubstitutedEvidenceAndNeverReportsSuccess() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        let marker = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).json")
        let displaced = root.appendingPathComponent("original-before-exchange")
        let unexpected = Data("unexpected evidence at the actual atomic boundary".utf8)
        var value: ArchiveMoveJournal? = try journal(root, source) { point in
            if case .exchange = point {
                try FileManager.default.moveItem(at: marker, to: displaced)
                try unexpected.write(to: marker, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
        }
        XCTAssertThrowsError(try value!.recordUncertain(code: "native_move_failed"))
        XCTAssertEqual(value!.record.phase, .pending)
        let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".outcome-") }
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), unexpected)
        XCTAssertThrowsError(try value!.recordUncertain(code: "retry"))
        value = nil
        XCTAssertThrowsError(try journal(root, source))
    }
    func testRemovedMarkerAtExchangeLeavesAnchorAndBlocksNextInitializer() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        let marker = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).json")
        var value: ArchiveMoveJournal? = try journal(root, source) { point in
            if case .exchange = point { try FileManager.default.removeItem(at: marker) }
        }
        XCTAssertThrowsError(try value!.recordUncertain(code: "native_move_failed"))
        XCTAssertEqual(value!.record.phase, .pending)
        value = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try journal(root, source), "Missing mutable marker cannot erase durable intent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Rejected retry cannot recreate the marker")
        XCTAssertThrowsError(try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity))
    }
    func testAnchorWithoutMarkerStillRefusesAfterInitialWriteFailure() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        XCTAssertThrowsError(try journal(root, source) { if case .initialWrite = $0 { throw CocoaError(.fileWriteUnknown) } })
        let marker = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).json")
        try FileManager.default.removeItem(at: marker)
        XCTAssertThrowsError(try journal(root, source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testChangedImmutableAnchorRefusesTerminalPublicationAndInspection() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        var value: ArchiveMoveJournal? = try journal(root, source)
        let anchor = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).anchor.json")
        try Data("unexpected anchor".utf8).write(to: anchor)
        XCTAssertThrowsError(try value!.recordUncertain(code: "native_move_failed"))
        value = nil
        XCTAssertThrowsError(try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity))
        XCTAssertThrowsError(try journal(root, source))
    }

    func testAtomicExchangeRejectsInPlaceMutationOfOriginalMarkerBytes() throws {
        let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
        let marker = root.appendingPathComponent("source-\(source.identity.directoryDevice)-\(source.identity.directoryInode).json")
        let unexpected = Data("changed original marker bytes".utf8)
        let value = try journal(root, source) { point in
            if case .exchange = point {
                let handle = try FileHandle(forWritingTo: marker)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: unexpected)
            }
        }
        XCTAssertThrowsError(try value.recordUncertain(code: "native_move_failed"))
        XCTAssertEqual(value.record.phase, .pending)
        let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".outcome-") }
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), unexpected)
    }

    func testAbsentGateRejectsMarkerOnlyAnchorOnlyAndDanglingMaterial() throws {
        for keep in ["none", "marker", "anchor", "dangling"] {
            let root = try directory(), source = try MeetingFileAccess.acquire(in: directory(), mode: .archive)
            try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: root, sourceIdentity: source.identity)
            if keep == "none" { continue }
            var value: ArchiveMoveJournal? = try journal(root, source)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }
            XCTAssertEqual(files.count, 2); value = nil
            _ = value
            for name in files {
                let isAnchor = name.contains("anchor")
                if (keep == "marker" && isAnchor) || (keep == "anchor" && !isAnchor) || keep == "dangling" {
                    try FileManager.default.removeItem(at: root.appendingPathComponent(name))
                }
            }
            if keep == "dangling" {
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(files[0]).path, withDestinationPath: "/definitely-missing-archive-fixture")
            }
            XCTAssertThrowsError(try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: root, sourceIdentity: source.identity), keep)
        }
    }
    func testAbsentGateRejectsUnsafeRootBeforeCreatingOwnerFile() throws {
        let source = try MeetingFileAccess.acquire(in: directory(), mode: .archive), root = try directory()
        let inside = source.folderURL.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: inside, sourceIdentity: source.identity))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inside.path).isEmpty)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)
        XCTAssertThrowsError(try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: alias, sourceIdentity: source.identity))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inside.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try ArchiveMoveJournal.requireNoPreviousIntent(rootURL: root, sourceIdentity: source.identity))
    }
    func testPlannedPrivateStagingSurvivesPendingAndTerminalAndCannotBeOccupied() throws {
        let root = try directory(), original = try directory(), parent = try directory()
        let source = try MeetingFileAccess.acquire(in: original, mode: .archive), stage = parent.appendingPathComponent("source")
        var value: ArchiveMoveJournal? = try .init(rootURL: root, source: source, sessionIDs: [sessionID], receipt: receipt, plannedStagingURL: stage)
        XCTAssertEqual(value!.record.plannedStagingPath, stage.path)
        try value!.recordUncertain(code: "synthetic_failure"); value = nil
        let record = try ArchiveMoveJournal.inspect(rootURL: root, sourceIdentity: source.identity)
        XCTAssertEqual(record.plannedStagingPath, stage.path); XCTAssertEqual(record.phase, .uncertain)
        let otherRoot = try directory(); try Data().write(to: stage)
        XCTAssertThrowsError(try ArchiveMoveJournal(rootURL: otherRoot, source: source, sessionIDs: [sessionID], receipt: receipt, plannedStagingURL: stage))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: otherRoot.path).isEmpty)
    }

}
