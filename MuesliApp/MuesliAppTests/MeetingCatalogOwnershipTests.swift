import XCTest

@MainActor
final class MeetingCatalogOwnershipTests: XCTestCase {
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        var visits: Int { lock.withLock { count } }
        func blockOnce() {
            XCTAssertFalse(Thread.isMainThread)
            let first = lock.withLock { count += 1; return count == 1 }
            if first { entered.markCompleted(); _ = release.wait(timeout: .now() + 5) }
        }
    }
    private func fixture(status: MeetingStatus = .completed) throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let metadata = MeetingMetadata(version: 1, title: "Original", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 2, lastTimestamp: 1, status: status,
            sessions: [.init(sessionID: 1, startedAt: Date(), audioFolder: "audio", streams: [:])],
            segmentCount: 1, speakerNames: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("meeting.json"))
        return (base, folder)
    }
    private func read(_ folder: URL) async throws -> MeetingMetadata {
        try await TranscriptPersistenceStore.shared.start(in: folder) { try $0.readMetadata() }.value()
    }

    func testStalledCatalogHasBoundedWaitRetainsOneOwnerAndUnrelatedFolderProgress() async throws {
        let (base, folder) = try fixture(), (_, other) = try fixture(), gate = Gate()
        let owner = MeetingCatalogOwner { step in if case .inspect = step { gate.blockOnce() } }
        let completed = TaskCompletion()
        let scan = Task { await owner.scan(in: base, timeoutSeconds: 0.04) { _ in completed.markCompleted() } }
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        guard case .timedOut = await scan.value else { return XCTFail("Expected independent deadline") }
        XCTAssertTrue(owner.isBusy)
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in 1 })
        for _ in 0..<20 {
            guard case .busy = await owner.scan(in: base, timeoutSeconds: 0.01) else { return XCTFail("Duplicate scan admitted") }
        }
        let independent = try await MeetingMetadataMutation.start(in: other, patch: .init(title: "Other")).value()
        XCTAssertEqual(independent.title, "Other")
        XCTAssertEqual(gate.visits, 1)
        gate.release.signal()
        let done = await completed.wait(timeoutSeconds: 2)
        XCTAssertEqual(done, .completed)
        XCTAssertFalse(owner.isBusy)
    }

    func testActualCatalogWorkerFinishesWhileMainActorIsBlocked() throws {
        let (base, _) = try fixture()
        let owner = MeetingCatalogOwner(), done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await owner.scan(in: base) { _ in
                XCTAssertFalse(Thread.isMainThread)
                done.signal()
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success,
                       "Actual catalog enumeration/metadata work must not inherit MainActor")
    }

    func testStartInvalidatesOlderRecoveryBeforeItCanChangeRecordingMetadata() async throws {
        let (base, folder) = try fixture(status: .recording), gate = Gate()
        let owner = MeetingCatalogOwner { step in if case .beforeRecovery = step { gate.blockOnce() } }
        let scan = Task { await owner.scan(in: base, timeoutSeconds: 2) }
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        owner.invalidateRecovery()
        gate.release.signal()
        guard case .completed(let snapshot) = await scan.value else { return XCTFail("Scan did not finish") }
        XCTAssertEqual(snapshot.items.first?.status, .recording)
        let saved = try await read(folder)
        XCTAssertEqual(saved.status, .recording)
    }

    func testActiveNativeSourceLeasePreventsOrphanRewrite() async throws {
        let (base, folder) = try fixture(status: .recording)
        let recorder = try LocalAudioRecorder(directory: folder.appendingPathComponent("audio"))
        let owner = MeetingCatalogOwner()
        guard case .completed(let snapshot) = await owner.scan(in: base) else { return XCTFail("Scan") }
        XCTAssertEqual(snapshot.items.first?.status, .recording)
        let stillActive = try await read(folder)
        XCTAssertEqual(stillActive.status, .recording)
        _ = await recorder.finish(timeoutSeconds: 2)
        guard case .completed(let closed) = await owner.scan(in: base) else { return XCTFail("Recovery") }
        XCTAssertEqual(closed.items.first?.status, .interrupted)
    }

    func testAppOwnedSessionRemainsProtectedAfterActualSourceClose() async throws {
        let (base, folder) = try fixture(status: .recording)
        let owner = MeetingCatalogOwner()
        owner.protect(folder)
        let recorder = try LocalAudioRecorder(directory: folder.appendingPathComponent("audio"))
        _ = await recorder.finish(timeoutSeconds: 2)
        guard case .completed(let snapshot) = await owner.scan(in: base) else { return XCTFail("Scan") }
        XCTAssertEqual(snapshot.items.first?.status, .recording,
                       "The app's finalizer, not orphan discovery, owns the source-close to metadata-save gap")
        let saved = try await read(folder)
        XCTAssertEqual(saved.status, .recording)
    }

    func testDeleteMoveUsesOriginalFolderOwnerAndRejectsActiveSource() async throws {
        let (_, folder) = try fixture(status: .recording), gate = Gate()
        let recorder = try LocalAudioRecorder(directory: folder.appendingPathComponent("audio"))
        let rejected = try MeetingCatalogOwner.trash(in: folder, onCompletion: { _ in }, move: { _ in
            XCTFail("An active source must prevent deletion")
        })
        guard case .failed = await rejected.wait(timeoutSeconds: 1) else { return XCTFail("Active source accepted") }
        _ = await recorder.finish(timeoutSeconds: 2)
        let completed = TaskCompletion()
        let moving = try MeetingCatalogOwner.trash(in: folder, onCompletion: { _ in completed.markCompleted() }, move: { _ in
            gate.blockOnce() // A fixture seam: no actual Trash operation is executed.
        })
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        guard case .timedOut = await moving.wait(timeoutSeconds: 0.02) else { return XCTFail("Expected deadline") }
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in 1 })
        gate.release.signal()
        let done = await completed.wait(timeoutSeconds: 1)
        XCTAssertEqual(done, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCorruptExistingMetadataIsPreservedRatherThanReplacedByLegacyFallback() async throws {
        let (base, folder) = try fixture()
        let original = Data("broken JSON".utf8)
        try original.write(to: folder.appendingPathComponent("meeting.json"))
        guard case .completed(let snapshot) = await MeetingCatalogOwner().scan(in: base) else { return XCTFail("Scan") }
        XCTAssertEqual(Set(snapshot.unresolved.map { $0.standardizedFileURL.path }), [folder.standardizedFileURL.path])
        XCTAssertEqual(snapshot.items.count, 0)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("meeting.json")), original)
    }

    func testLegacyMigrationStreamsCompleteRecordsAndPreservesInterruptedTail() async throws {
        let (base, folder) = try fixture()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("meeting.json"))
        let journal = Data((#"{"type":"segment","speaker_id":"mic:0","t0":0,"t1":3,"text":"original"}"# + "\n" + #"{"type":"segment","text":"unfinished""#).utf8)
        try journal.write(to: folder.appendingPathComponent("transcript_events.jsonl"))
        guard case .completed(let snapshot) = await MeetingCatalogOwner().scan(in: base) else { return XCTFail("Scan") }
        XCTAssertEqual(snapshot.items.first?.segmentCount, 1)
        XCTAssertEqual(snapshot.items.first?.status, .interrupted)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcript_events.jsonl")), journal)
    }

    func testMigrationIndexesEveryCommittedSourceWithoutTranscriptOrSourceMutation() async throws {
        let (base, folder) = try fixture()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("meeting.json"))
        var originalPCM: [URL: Data] = [:]
        for (name, offset) in [("audio", Int64(0)), ("audio-session-2", Int64(5_000_000))] {
            let audio = folder.appendingPathComponent(name)
            let recorder = try LocalAudioRecorder(directory: audio, timelineOffsetUs: offset)
            recorder.record(source: .mic, ptsUs: 0, payload: Data(repeating: 7, count: 32_000))
            _ = await recorder.finish(timeoutSeconds: 2)
            let pcm = audio.appendingPathComponent("mic.pcm")
            originalPCM[pcm] = try Data(contentsOf: pcm)
        }
        guard case .completed(let snapshot) = await MeetingCatalogOwner().scan(in: base) else { return XCTFail("Migration") }
        XCTAssertEqual(snapshot.items.first?.segmentCount, 0)
        XCTAssertEqual(snapshot.items.first?.durationSeconds, 6)
        let metadata = try await read(folder)
        XCTAssertEqual(metadata.sessions.map(\.audioFolder), ["audio", "audio-session-2"])
        XCTAssertEqual(metadata.sessions.map(\.timelineOffsetSeconds), [0, 5])
        for (url, bytes) in originalPCM { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    func testOversizedLegacyRecordFailsWithoutPublishingZeroCountMetadata() async throws {
        let (base, folder) = try fixture()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("meeting.json"))
        try Data(repeating: 65, count: 300_000).write(to: folder.appendingPathComponent("transcript.jsonl"))
        guard case .completed(let snapshot) = await MeetingCatalogOwner().scan(in: base) else { return XCTFail("Scan") }
        XCTAssertEqual(Set(snapshot.unresolved.map { $0.standardizedFileURL.path }), [folder.standardizedFileURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.json").path))
    }

    func testLateSnapshotCannotPublishAfterCatalogIntentChanges() async throws {
        let (base, _) = try fixture(), gate = Gate()
        var events: [String] = []
        let controller = MeetingCatalogController(owner: MeetingCatalogOwner { step in
            if case .inspect = step { gate.blockOnce() }
        }, timeoutSeconds: 0.03) { event in
            switch event {
            case .committed: events.append("committed")
            case .pending: events.append("pending")
            case .discarded: events.append("discarded")
            case .failed: events.append("failed")
            }
        }
        controller.refresh(in: base)
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        try await Task.sleep(for: .milliseconds(60))
        controller.invalidate()
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(events.contains("committed"))
        XCTAssertEqual(events.last, "discarded", "An invalidated terminal callback clears its old pending notice")
    }
}
