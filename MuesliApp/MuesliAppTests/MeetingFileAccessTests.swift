import XCTest
import Darwin

@MainActor
final class MeetingFileAccessTests: XCTestCase {
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        func block() { entered.markCompleted(); _ = release.wait(timeout: .now() + 8) }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// A real second process checks kernel ownership, independent of the Swift
    /// registry. Its alarm bounds even a broken fixture; no Trash is invoked.
    @concurrent private static func probe(_ folder: URL, name: String = MeetingFileAccess.accessName,
                                         exclusive: Bool = true) async throws -> Int32 {
        try probeSync(folder, name: name, exclusive: exclusive)
    }
    nonisolated private static func probeSync(_ folder: URL, name: String, exclusive: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, os, signal, sys
        signal.alarm(4)
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, (fcntl.LOCK_EX if sys.argv[2] == '1' else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(73)
        """, folder.appendingPathComponent(name).path, exclusive ? "1" : "0"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    private func assertProbe(_ folder: URL, busy: Bool, name: String = MeetingFileAccess.accessName,
                             exclusive: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws {
        let status = try await Self.probe(folder, name: name, exclusive: exclusive)
        XCTAssertEqual(status, busy ? 73 : 0, file: file, line: line)
    }

    func testSharedAccessExcludesArchiveInAnotherProcessUntilLastReferenceEnds() async throws {
        let root = try folder()
        do {
            let first = try MeetingFileAccess.acquire(in: root)
            let second = try MeetingFileAccess.acquire(in: root)
            defer { withExtendedLifetime((first, second)) {} }
            try await assertProbe(root, busy: true)
            try await assertProbe(root, busy: false, exclusive: false)
            XCTAssertEqual(first.identity, second.identity)
        }
        try await assertProbe(root, busy: false)
    }

    func testTransactionSerializesProcessesWithoutExcludingOtherSharedAccess() async throws {
        let root = try folder(), access = try MeetingFileAccess.acquire(in: root)
        defer { withExtendedLifetime(access) {} }
        do {
            let transaction = try access.transaction()
            defer { withExtendedLifetime(transaction) {} }
            try await assertProbe(root, busy: true, name: MeetingFileAccess.transactionName)
            try await assertProbe(root, busy: false, exclusive: false)
            XCTAssertThrowsError(try MeetingFileAccess.acquire(in: root).transaction())
        }
        try await assertProbe(root, busy: false, name: MeetingFileAccess.transactionName)
    }

    func testArchiveBlocksContextBeforeRecoveryOrMutation() async throws {
        let root = try folder(), archive = try MeetingFileAccess.acquire(in: root, mode: .archive)
        defer { withExtendedLifetime(archive) {} }
        let operation = try TranscriptPersistenceStore().start(in: root) { context in
            try context.commit(files: ["transcript.txt": Data("must not publish".utf8)])
        }
        guard case .failed = await operation.wait(timeoutSeconds: 2) else { return XCTFail("archive did not exclude Context") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.txt").path))
        try await assertProbe(root, busy: true, exclusive: false)
    }

    func testMovedFolderAndReplacedLockFailBeforeAdmission() throws {
        let base = try folder(), original = base.appendingPathComponent("meeting"), moved = base.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: original, afterOpen: {
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(MeetingFileAccess.accessName).path))
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: original, afterOpen: {
            let path = original.appendingPathComponent(MeetingFileAccess.accessName)
            try FileManager.default.moveItem(at: path, to: original.appendingPathComponent("old-lock"))
            try Data().write(to: path)
        }))
    }

    func testRejectsSymlinkAndHardLinkedOwnershipFiles() throws {
        let base = try folder(), other = base.appendingPathComponent("original")
        try Data("preserved".utf8).write(to: other)
        let lock = base.appendingPathComponent(MeetingFileAccess.accessName)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: other)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: base))
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: other, to: lock)
        XCTAssertThrowsError(try MeetingFileAccess.acquire(in: base))
        XCTAssertEqual(try Data(contentsOf: other), Data("preserved".utf8))
    }

    func testTimedOutOwnerHandsSameLeasesToQueuedTerminalOperation() async throws {
        let root = try folder(), first = Gate(), terminal = Gate(), store = TranscriptPersistenceStore()
        let operation = try store.start(in: root) { context in
            first.block()
            try context.commit(files: ["transcript.txt": Data("first".utf8)])
        }
        let firstEntered = await first.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(firstEntered, .completed)
        guard case .timedOut = await operation.wait(timeoutSeconds: 0.01) else { return XCTFail("deadline") }
        let next = try store.startAfterCurrent(in: root) { context in
            terminal.block()
            XCTAssertEqual(try context.readData(named: "transcript.txt"), Data("first".utf8))
            try context.commit(files: ["transcript.txt": Data("terminal".utf8)])
        }
        let cancelled = Task { await next.wait(timeoutSeconds: 2) }
        cancelled.cancel()
        guard case .cancelled = await cancelled.value else { return XCTFail("cancelled waiter") }
        try await assertProbe(root, busy: true)
        first.release.signal()
        let terminalEntered = await terminal.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(terminalEntered, .completed)
        try await assertProbe(root, busy: true)
        try await assertProbe(root, busy: true, name: MeetingFileAccess.transactionName)
        terminal.release.signal()
        _ = try await next.value(timeoutSeconds: 2)
        try await assertProbe(root, busy: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("transcript.txt")), Data("terminal".utf8))
    }

    func testStalledPreparationRetainsArchiveExclusionThroughAbandonedCleanup() async throws {
        let base = try folder(), gate = Gate()
        let owner = MeetingStartPreparationOwner(checkpoint: { if $0 == .beforeInitialFileCreation { gate.block() } })
        let preparing = Task { await owner.prepare(.init(title: "source", meetingsDirectory: base), timeoutSeconds: 0.1) }
        let gateEntered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(gateEntered, .completed)
        guard case .timedOut = await preparing.value else { return XCTFail("startup deadline") }
        let root = base.appendingPathComponent("source")
        try await assertProbe(root, busy: true)
        gate.release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(owner.isBusy)
        try await assertProbe(root, busy: false)
    }

    func testSourceCloseTimeoutRetainsPinAfterPreparationReferenceIsGone() async throws {
        let root = try folder(), gate = Gate()
        let recorder: LocalAudioRecorder
        do {
            let access = try MeetingFileAccess.acquire(in: root)
            recorder = try LocalAudioRecorder(directory: root.appendingPathComponent("audio"), beforeIO: {
                if case .export(.system) = $0 { gate.block() }
            })
            recorder.retainMeetingAccess(access)
        }
        recorder.requestFinish()
        let gateEntered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(gateEntered, .completed)
        let result = await recorder.finish(timeoutSeconds: 0.01)
        XCTAssertNil(result)
        try await assertProbe(root, busy: true)
        gate.release.signal()
        _ = await recorder.finish(timeoutSeconds: 2)
        try await assertProbe(root, busy: false)
    }

    func testDedicatedArchiveOperationRetainsExclusionAcrossTimeoutAndActualMoveCallback() async throws {
        let root = try folder(), gate = Gate(), store = TranscriptPersistenceStore()
        let operation = try store.startArchive(in: root) { _ in gate.block() } // injected move, never Trash
        let gateEntered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(gateEntered, .completed)
        guard case .timedOut = await operation.wait(timeoutSeconds: 0.01) else { return XCTFail("archive deadline") }
        try await assertProbe(root, busy: true, exclusive: false)
        gate.release.signal()
        _ = try await operation.value(timeoutSeconds: 2)
        try await assertProbe(root, busy: false)
    }
    func testNativeDeadlineKeepsOriginalAccessThroughLateCleanup() async throws {
        let root = try folder(), native = Gate(), cleanup = Gate(), owner = CaptureOperationOwner()
        let attempt = Task {
            let access = try MeetingFileAccess.acquire(in: root)
            try await owner.perform(timeoutSeconds: 0.05, operation: {
                defer { withExtendedLifetime(access) {} }
                native.block()
            }, cleanupIfAbandoned: {
                defer { withExtendedLifetime(access) {} }
                cleanup.block()
            })
        }
        let entered = await native.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed)
        do { try await attempt.value; XCTFail("native deadline") } catch {}
        try await assertProbe(root, busy: true)
        native.release.signal()
        let cleaning = await cleanup.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(cleaning, .completed)
        try await assertProbe(root, busy: true)
        cleanup.release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(owner.isBusy)
        try await assertProbe(root, busy: false)
    }

    func testLogQueueRetainsAccessUntilItsBlockedWriteAndRealCloseEnd() async throws {
        let root = try folder(), gate = Gate(), closed = TaskCompletion()
        let writer = BackendLogWriter(ringBufferLimit: 10, beforeWrite: { gate.block() })
        let path = root.appendingPathComponent("backend.log")
        try Data().write(to: path)
        do {
            let access = try MeetingFileAccess.acquire(in: root)
            writer.reset(handle: try FileHandle(forWritingTo: path), access: access)
        }
        writer.append("original operation", toTail: false)
        let entered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed)
        writer.close(onClosed: { closed.markCompleted() })
        let wait = await closed.wait(timeoutSeconds: 0.01)
        XCTAssertEqual(wait, .timedOut)
        try await assertProbe(root, busy: true)
        gate.release.signal()
        let end = await closed.wait(timeoutSeconds: 2)
        XCTAssertEqual(end, .completed)
        try await assertProbe(root, busy: false)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original operation\n")
    }

    func testLegacyScreenshotSnapshotCarriesAccessBeyondTransactionIntoImageReads() async throws {
        let root = try folder(), shots = root.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: false)
        try Data("image fixture".utf8).write(to: shots.appendingPathComponent("t+1.png"))
        do {
            let owner = try TranscriptPersistenceStore().start(in: root) { try MeetingScreenshotInput.snapshot(context: $0) }
            let input = try await owner.value(timeoutSeconds: 2)
            defer { withExtendedLifetime(input) {} }
            XCTAssertEqual(input.urls.map(\.lastPathComponent), ["t+1.png"])
            try await assertProbe(root, busy: true)
            try await assertProbe(root, busy: false, name: MeetingFileAccess.transactionName)
            XCTAssertEqual(try Data(contentsOf: input.urls[0]), Data("image fixture".utf8))
        }
        try await assertProbe(root, busy: false)
    }

    func testHandedOffTransactionIsActuallyReleasedBeforeItsCompletionCallback() async throws {
        let root = try folder(), gate = Gate(), callback = TaskCompletion(), store = TranscriptPersistenceStore()
        let first = try store.start(in: root) { _ in gate.block() }
        let entered = await gate.entered.wait(timeoutSeconds: 2)
        XCTAssertEqual(entered, .completed)
        let second = try store.startAfterCurrent(in: root, onCompletion: { _ in
            do {
                let status = try Self.probeSync(root, name: MeetingFileAccess.transactionName, exclusive: true)
                XCTAssertEqual(status, 0, "a real second process must acquire the completed transaction before publication")
            } catch { XCTFail(error.localizedDescription) }
            callback.markCompleted()
        }) { context in try context.commit(files: ["transcript.txt": Data("saved".utf8)]) }
        gate.release.signal()
        _ = try await first.value(timeoutSeconds: 2)
        _ = try await second.value(timeoutSeconds: 2)
        let published = await callback.wait(timeoutSeconds: 2)
        XCTAssertEqual(published, .completed)
    }

}
