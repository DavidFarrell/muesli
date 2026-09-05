import XCTest

@MainActor
final class TranscriptExportOwnerTests: XCTestCase {
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        func block() {
            XCTAssertFalse(Thread.isMainThread)
            entered.markCompleted()
            _ = release.wait(timeout: .now() + 5)
        }
    }
    private func fixture() throws -> (root: URL, source: URL, destination: URL, jsonl: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Selected meeting")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let segment = TranscriptSegment(speakerID: "mic:0", stream: "mic", sourceSessionID: "source-A",
            t0: 2, t1: 3, text: "Only the selected meeting", isPartial: false)
        let metadata = MeetingMetadata(version: 1, title: "Selected", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 3, lastTimestamp: 3, status: .completed, sessions: [], segmentCount: 1,
            speakerNames: [segment.speakerKey: "Fresh reviewed name"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: source.appendingPathComponent("meeting.json"))
        let jsonl = Data(try TranscriptModel.jsonLines(from: [segment]).utf8)
        try jsonl.write(to: source.appendingPathComponent("transcript.jsonl"))
        try Data("Stale text with a different speaker".utf8).write(to: source.appendingPathComponent("transcript.txt"))
        return (root, source, root.appendingPathComponent("Exported transcript"), jsonl)
    }
    private func outcome(_ attempt: TranscriptExportOwner.Attempt) async throws -> Result<TranscriptExportOwner.Receipt, TranscriptExportOwner.Failure> {
        guard case .completed(let result) = await attempt.wait(timeoutSeconds: 3) else {
            XCTFail("Fixture operation did not complete")
            throw CocoaError(.fileReadUnknown)
        }
        return result
    }
    private func assertPair(_ destination: URL, jsonl: Data) throws {
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("transcript.jsonl")), jsonl)
        let text = try String(contentsOf: destination.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Fresh reviewed name: Only the selected meeting"))
        XCTAssertTrue(text.contains("[source source-A] [mic]"))
        XCTAssertFalse(text.contains("Stale"))
    }

    func testExportUsesSelectedOwnedRecordsAndFreshNamesForBothFiles() async throws {
        let f = try fixture()
        let originalMetadata = try Data(contentsOf: f.source.appendingPathComponent("meeting.json"))
        let owner = TranscriptExportOwner { _ in XCTAssertFalse(Thread.isMainThread) }
        let result = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination))
        XCTAssertEqual(try result.get().segmentCount, 1)
        try assertPair(f.destination, jsonl: f.jsonl)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("meeting.json")), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("transcript.jsonl")), f.jsonl)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("transcript.txt"), encoding: .utf8), "Stale text with a different speaker")
    }

    func testStalledSourceHasIndependentDeadlineAndRetainsOriginalOwner() async throws {
        let f = try fixture(), other = try fixture(), gate = Gate()
        defer { gate.release.signal() }
        let owner = TranscriptExportOwner { if $0 == .readSource { gate.block() } }
        let attempt = try owner.start(sourceDirectory: f.source, destinationDirectory: f.destination)
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        guard case .timedOut = await attempt.wait(timeoutSeconds: 0.02) else { return XCTFail("No independent deadline") }
        XCTAssertTrue(owner.isBusy)
        for _ in 0..<20 {
            XCTAssertThrowsError(try owner.start(sourceDirectory: other.source, destinationDirectory: other.destination))
        }
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: f.source) { _ in 1 })
        let unrelated = try TranscriptPersistenceStore.shared.start(in: other.source) { try $0.readMetadata().title }
        let unrelatedTitle = try await unrelated.value()
        XCTAssertEqual(unrelatedTitle, "Selected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        gate.release.signal()
        _ = try await outcome(attempt).get()
        XCTAssertFalse(owner.isBusy)
        try assertPair(f.destination, jsonl: f.jsonl)
    }

    func testCancelledWaitDoesNotReleaseBlockedDestinationOrStartAnotherExport() async throws {
        let f = try fixture(), gate = Gate()
        defer { gate.release.signal() }
        let owner = TranscriptExportOwner { if $0 == .writeText { gate.block() } }
        let attempt = try owner.start(sourceDirectory: f.source, destinationDirectory: f.destination)
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        let waiter = Task { await attempt.wait(timeoutSeconds: 30) }
        waiter.cancel()
        guard case .cancelled = await waiter.value else { return XCTFail("Cancelled waiter remained blocked") }
        XCTAssertTrue(owner.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertThrowsError(try owner.start(sourceDirectory: f.source, destinationDirectory: f.destination))
        gate.release.signal()
        _ = try await outcome(attempt).get()
        try assertPair(f.destination, jsonl: f.jsonl)
    }

    func testActualExportFinishesWhileMainActorIsBlocked() throws {
        let f = try fixture(), done = DispatchSemaphore(value: 0)
        let owner = TranscriptExportOwner()
        _ = try owner.start(sourceDirectory: f.source, destinationDirectory: f.destination) { result in
            XCTAssertFalse(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        try assertPair(f.destination, jsonl: f.jsonl)
    }

    func testFailuresBeforePublicationNeverExposePartialPair() async throws {
        for step in [TranscriptExportOwner.Step.readSource, .createDirectory, .writeJSONL, .writeText, .publish] {
            let f = try fixture()
            let owner = TranscriptExportOwner { if $0 == step { throw POSIXError(.ENOSPC) } }
            let result = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination))
            guard case .failure = result else { return XCTFail("Injected failure reported success") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("transcript.jsonl")), f.jsonl)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".muesli-export-") })
        }
    }

    func testPostPublicationSyncFailureReportsExistingCompletePairTruthfully() async throws {
        let f = try fixture()
        let owner = TranscriptExportOwner { if $0 == .syncPublishedDirectory { throw POSIXError(.EIO) } }
        let result = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination))
        guard case .failure(.publishedUnconfirmed(let url, _)) = result else { return XCTFail("Durability failure was hidden") }
        XCTAssertEqual(url.path, f.destination.path)
        try assertPair(f.destination, jsonl: f.jsonl)
    }

    func testExistingDestinationAndSourceTargetsAreNeverOverwritten() async throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        let sentinel = f.destination.appendingPathComponent("unrelated")
        try Data("Retain me".utf8).write(to: sentinel)
        let owner = TranscriptExportOwner()
        guard case .failure(.destinationExists) = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination)) else {
            return XCTFail("Existing destination replaced")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("Retain me".utf8))
        let alias = f.root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        for target in [f.source, f.source.appendingPathComponent("transcript.txt"), alias.appendingPathComponent("new-export")] {
            guard case .failure(.sourceDestination) = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: target)) else {
                return XCTFail("Source target admitted")
            }
        }
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("transcript.jsonl")), f.jsonl)
    }

    func testCorruptMissingOversizedAndIncompleteSourceNeverFallsBack() async throws {
        for mode in 0..<5 {
            let f = try fixture(), transcript = f.source.appendingPathComponent("transcript.jsonl")
            switch mode {
            case 0: try Data("broken JSON".utf8).write(to: transcript)
            case 1: try FileManager.default.removeItem(at: transcript)
            case 2: try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: transcript)
            case 3: try Data().write(to: transcript) // Metadata still records one segment.
            default: try Data("broken metadata".utf8).write(to: f.source.appendingPathComponent("meeting.json"))
            }
            let owner = TranscriptExportOwner()
            guard case .failure = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination)) else {
                return XCTFail("Unusable source reported success")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        }
    }

    func testRecordingMetadataRejectsAnOlderSavedResumePrefix() async throws {
        let f = try fixture()
        let edit = try TranscriptPersistenceStore.shared.start(in: f.source) { context in
            var metadata = try context.readMetadata()
            metadata.status = .recording
            try MeetingCatalogOwner.commit(metadata, context: context)
        }
        _ = try await edit.value()
        let owner = TranscriptExportOwner()
        guard case .failure(.recording) = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination)) else {
            return XCTFail("Active resumed source exported an older canonical transcript")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
    }

    func testSourceSymlinkIsRejectedAndExistingDestinationSymlinkIsRetained() async throws {
        let f = try fixture()
        try FileManager.default.createSymbolicLink(at: f.destination, withDestinationURL: f.source)
        let owner = TranscriptExportOwner()
        guard case .failure(.destinationExists) = try await outcome(owner.start(sourceDirectory: f.source, destinationDirectory: f.destination)) else {
            return XCTFail("Existing symlink destination was replaced or followed")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.destination.path), f.source.path)
        let transcript = f.source.appendingPathComponent("transcript.jsonl")
        let external = f.root.appendingPathComponent("external.jsonl")
        try f.jsonl.write(to: external)
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: external)
        guard case .failure(.invalidSource) = try await outcome(owner.start(sourceDirectory: f.source,
            destinationDirectory: f.root.appendingPathComponent("Another export"))) else {
            return XCTFail("Source symlink was followed")
        }
        XCTAssertEqual(try Data(contentsOf: external), f.jsonl)
    }
}
