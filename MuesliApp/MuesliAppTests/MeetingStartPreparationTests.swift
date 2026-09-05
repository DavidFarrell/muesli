import XCTest

@MainActor
final class MeetingStartPreparationTests: XCTestCase {
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var visits = 0
        var count: Int { lock.withLock { visits } }
        func block() {
            XCTAssertFalse(Thread.isMainThread, "initial storage creation must not own the UI executor")
            lock.withLock { visits += 1 }
            entered.markCompleted()
            _ = release.wait(timeout: .now() + 5) // fail-safe even when assertions fail
        }
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func idle(_ owner: MeetingStartPreparationOwner) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while owner.isBusy && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(owner.isBusy)
    }
    private func metadata(_ folder: URL) throws -> MeetingMetadata {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
    }
    private func close(_ prepared: MeetingStartPreparationOwner.Prepared) async {
        _ = await prepared.recorder.finish(timeoutSeconds: 2)
        if let artifacts = prepared.artifacts { _ = await artifacts.finish(timeoutSeconds: 2) }
        try? prepared.logHandle.close()
    }

    func testStalledFirstFileCreationHasIndependentDeadlineAndBoundedAdmission() async throws {
        let base = try root(), gate = Gate()
        let owner = MeetingStartPreparationOwner(checkpoint: { step in
            if step == .beforeInitialFileCreation { gate.block() }
        })
        let request = MeetingStartPreparationOwner.Request(title: "Stalled", meetingsDirectory: base)
        let task = Task { await owner.prepare(request, timeoutSeconds: 0.1) }
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        let began = ContinuousClock.now
        guard case .timedOut = await task.value else { return XCTFail("storage wait did not expire") }
        XCTAssertLessThan(began.duration(to: .now), .seconds(1))
        XCTAssertTrue(owner.isBusy)
        for _ in 0..<20 {
            guard case .busy = await owner.prepare(request, timeoutSeconds: 0.01) else { return XCTFail("competing owner admitted") }
        }
        XCTAssertEqual(gate.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Stalled/audio/" + LocalAudioRecorder.manifestName).path))
        gate.release.signal()
        try await idle(owner)
        XCTAssertEqual(gate.count, 1, "late return cannot begin another preparation")
    }

    func testCancelledCreatedSourceStaysOwnedThenIndexedAndRecoverable() async throws {
        let base = try root(), gate = Gate()
        let owner = MeetingStartPreparationOwner(checkpoint: { step in if step == .afterRecorderCreation { gate.block() } })
        let request = MeetingStartPreparationOwner.Request(title: "Cancelled", meetingsDirectory: base, video: true)
        let task = Task { await owner.prepare(request, timeoutSeconds: 3) }
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        task.cancel()
        guard case .cancelled = await task.value else { return XCTFail("missing cancellation") }
        XCTAssertTrue(owner.isBusy)
        let folder = base.appendingPathComponent("Cancelled")
        let before = try metadata(folder)
        XCTAssertEqual(before.sessions.map(\.sessionID), [1])
        XCTAssertThrowsError(try LocalAudioRecorder.withInactiveSource(directory: folder.appendingPathComponent("audio")) {})
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in 1 }, "folder remains owned during late cleanup")
        gate.release.signal()
        try await idle(owner)
        let after = try metadata(folder)
        XCTAssertEqual(after.sessions.map(\.sessionID), [1])
        XCTAssertEqual(after.status, .interrupted)
        XCTAssertEqual(after.sessions[0].durationSeconds, 0)
        XCTAssertNil(after.sessions[0].artifactsFolder)
        XCTAssertEqual(try OrphanedMeetingRecovery.verifiedResumeOffset(folderURL: folder, metadata: after), 0)
        let source = try LocalAudioRecorder.readManifest(directory: folder.appendingPathComponent("audio"))
        XCTAssertTrue(source.completed)
    }

    func testLateReadyVideoIsClosedWithoutNativeReservationOrDeletingPreviousSources() async throws {
        let base = try root(), gate = Gate()
        let owner = MeetingStartPreparationOwner(checkpoint: { step in if step == .beforeHandoff { gate.block() } })
        let task = Task { await owner.prepare(.init(title: "Late", meetingsDirectory: base, video: true), timeoutSeconds: 0.1) }
        let entered = await gate.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        guard case .timedOut = await task.value else { return XCTFail("deadline") }
        let folder = base.appendingPathComponent("Late")
        let pending = try metadata(folder)
        let artifactFolder = try XCTUnwrap(pending.sessions[0].artifactsFolder)
        gate.release.signal()
        try await idle(owner)
        let closedMetadata = try metadata(folder)
        XCTAssertNil(closedMetadata.sessions[0].artifactsFolder)
        let ledger = try String(contentsOf: folder.appendingPathComponent(artifactFolder).appendingPathComponent("assets.jsonl"), encoding: .utf8)
        XCTAssertEqual(ledger.split(separator: "\n").count, 1, "only an unused session ledger, no video/screenshot request")
        let original = try Data(contentsOf: folder.appendingPathComponent("audio/" + LocalAudioRecorder.manifestName))
        let nextOwner = MeetingStartPreparationOwner()
        // Occupied orphan directories must never be reused, even after cancellation.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio-session-2"), withIntermediateDirectories: false)
        try Data("orphan source".utf8).write(to: folder.appendingPathComponent("audio-session-2/keep"))
        guard case .ready(let resumed) = await nextOwner.prepare(.init(title: "ignored", resumeFolder: folder), timeoutSeconds: 2) else { return XCTFail("resume failed") }
        XCTAssertEqual(resumed.audioDirectory.lastPathComponent, "audio-session-3")
        XCTAssertEqual(resumed.timestampOffset, 0)
        XCTAssertEqual(try metadata(folder).sessions.map(\.sessionID), [1, 3])
        XCTAssertEqual(try metadata(folder).sessions[0].finalizationStatus, "interrupted")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio/" + LocalAudioRecorder.manifestName)), original)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("audio-session-2/keep"), encoding: .utf8), "orphan source")
        await close(resumed)
        try await idle(nextOwner)
    }

    func testFailureAfterSourceCreationCleansBeforeReleasingOwner() async throws {
        let base = try root(), cleanup = Gate()
        let owner = MeetingStartPreparationOwner(checkpoint: { step in
            if step == .afterRecorderCreation { throw POSIXError(.ENOSPC) }
            if step == .beforeCleanup { cleanup.block() }
        })
        let task = Task { await owner.prepare(.init(title: "Failure", meetingsDirectory: base), timeoutSeconds: 0.1) }
        let entered = await cleanup.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        guard case .timedOut = await task.value else { return XCTFail("cleanup deadline") }
        XCTAssertTrue(owner.isBusy)
        cleanup.release.signal()
        try await idle(owner)
        let folder = base.appendingPathComponent("Failure")
        XCTAssertEqual(try metadata(folder).status, .interrupted)
        XCTAssertTrue(try LocalAudioRecorder.readManifest(directory: folder.appendingPathComponent("audio")).completed)
    }

    func testActualCloseStallRetainsPreparationAndFolderOwnership() async throws {
        let base = try root(), closing = Gate()
        let owner = MeetingStartPreparationOwner(createRecorder: { directory, id, offset in
            try LocalAudioRecorder(directory: directory, sessionID: id, timelineOffsetUs: offset,
                beforeIO: { step in if case .export(.system) = step { closing.block() } })
        }) { step in if step == .afterRecorderCreation { throw POSIXError(.ENOSPC) } }
        let task = Task { await owner.prepare(.init(title: "Closing", meetingsDirectory: base), timeoutSeconds: 0.1) }
        let entered = await closing.entered.wait(timeoutSeconds: 1)
        XCTAssertEqual(entered, .completed)
        guard case .timedOut = await task.value else { return XCTFail("close wait deadline") }
        let folder = base.appendingPathComponent("Closing")
        XCTAssertTrue(owner.isBusy)
        XCTAssertThrowsError(try LocalAudioRecorder.withInactiveSource(directory: folder.appendingPathComponent("audio")) {})
        XCTAssertThrowsError(try TranscriptPersistenceStore.shared.start(in: folder) { _ in 1 })
        closing.release.signal()
        try await idle(owner)
        XCTAssertNoThrow(try LocalAudioRecorder.withInactiveSource(directory: folder.appendingPathComponent("audio")) {})
        XCTAssertEqual(try metadata(folder).sessions[0].finalizationStatus, "interrupted")
    }

    func testReadyOwnershipTransferAndExclusiveLogsPreserveEarlierSession() async throws {
        let base = try root(), owner = MeetingStartPreparationOwner()
        guard case .ready(let first) = await owner.prepare(.init(title: "Ready", meetingsDirectory: base), timeoutSeconds: 2) else { return XCTFail("not ready") }
        let firstMetadata = try metadata(first.folderURL)
        XCTAssertEqual(firstMetadata.buildIdentity, .current)
        XCTAssertEqual(firstMetadata.sessions[0].buildIdentity, .current)
        XCTAssertEqual(firstMetadata.sessions[0].sourceSessionID, first.sourceID)
        XCTAssertNil(firstMetadata.sessions[0].observedRuntimeIdentity)
        try first.logHandle.write(contentsOf: Data("first diagnostic\n".utf8))
        await close(first)
        try await idle(owner)
        guard case .ready(let second) = await owner.prepare(.init(title: "Ready", resumeFolder: first.folderURL), timeoutSeconds: 2) else { return XCTFail("resume failed") }
        XCTAssertEqual(second.sourceID == first.sourceID, false)
        let resumedMetadata = try metadata(second.folderURL)
        XCTAssertEqual(resumedMetadata.buildIdentity, firstMetadata.buildIdentity)
        XCTAssertEqual(resumedMetadata.sessions.map(\.sourceSessionID), [first.sourceID, second.sourceID])
        XCTAssertEqual(resumedMetadata.sessions.map(\.buildIdentity), [.current, .current])
        XCTAssertNotEqual(first.logURL, second.logURL)
        XCTAssertNotEqual(first.eventsURL, second.eventsURL)
        XCTAssertEqual(try String(contentsOf: first.logURL, encoding: .utf8), "first diagnostic\n")
        await close(second)
        try await idle(owner)
    }

    func testCancellationBeforeAdmissionDoesNotCreateFiles() async throws {
        let base = try root(), owner = MeetingStartPreparationOwner(), begin = TaskCompletion()
        let task = Task {
            _ = await begin.wait(timeoutSeconds: 1)
            return await owner.prepare(.init(title: "No attempt", meetingsDirectory: base), timeoutSeconds: 1)
        }
        task.cancel(); begin.markCompleted()
        guard case .cancelled = await task.value else { return XCTFail("cancel before admission") }
        XCTAssertFalse(owner.isBusy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }
}
