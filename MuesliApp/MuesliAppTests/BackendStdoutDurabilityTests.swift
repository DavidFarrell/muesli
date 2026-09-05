import Foundation
import XCTest

@MainActor
final class BackendStdoutDurabilityTests: XCTestCase {
    private func journalURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stdout-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("transcript_events.jsonl")
    }

    private func python(_ script: String, journal: URL?, maximumLine: Int = 4 * 1024 * 1024,
                        beforeWrite: (@Sendable () throws -> Void)? = nil) throws -> BackendProcess {
        try BackendProcess(command: ["/usr/bin/python3", "-c", script], eventJournalURL: journal,
                           maximumStdoutLineBytes: maximumLine, beforeEventJournalIO: { checkpoint in
                               if case .write = checkpoint { try beforeWrite?() }
                           })
    }

    private func assertComplete(_ result: BackendStdoutDrainResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .drained(let status) = result else {
            XCTFail("Reader failed to drain: \(result)", file: file, line: line)
            return
        }
        XCTAssertTrue(status.isComplete, "\(status.firstError ?? "missing EOF or closure")", file: file, line: line)
    }

    func testJournalsMoreThan500FinalsWithStalledConsumerAndBlockedMainActor() async throws {
        let url = try journalURL()
        let backend = try python("import json\nfor i in range(1200): print(json.dumps({'type':'final','id':i}), flush=True)", journal: url)
        let evidence = StdoutProbe()
        backend.onJSONLine = { line in
            if line.contains("1199") {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                evidence.record(offMain: !Thread.isMainThread,
                                persisted: text.components(separatedBy: "\n").count == 1201)
                evidence.release.signal()
            }
        }
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        // This blocks the actual UI executor; neither the UI consumer nor
        // any main-actor test machinery can help the reader pass.
        XCTAssertEqual(evidence.blockMainActor(timeout: 15), .success)
        XCTAssertTrue(evidence.offMain)
        XCTAssertTrue(evidence.persisted)
        let result = await backend.finishStdout(timeoutSeconds: 5)
        assertComplete(result)
        XCTAssertEqual(result.status.journaledLines, 1200)
        XCTAssertEqual(result.status.droppedUILines, 700)
        XCTAssertEqual(result.status.journaledBytes, result.status.durableBytes)
        var visible = 0
        for await _ in backend.stdoutLines { visible += 1 }
        XCTAssertEqual(visible, 500)
        XCTAssertEqual(backend.stdoutStatus().bufferedUIBytes, 0)
    }

    func testTimedOutReaderKeepsExclusiveJournalOwnershipUntilActualClose() async throws {
        let url = try journalURL()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let old = try python("print('{\"id\":1}', flush=True)", journal: url, beforeWrite: {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        })
        try old.start()
        defer { release.signal(); old.forceKill(); old.cleanup() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let pending = await old.finishStdout(timeoutSeconds: 0.02)
        if case .timedOut = pending {} else { XCTFail("Expected blocked writer timeout") }
        old.cleanup()
        let competing = try python("print('{\"id\":2}')", journal: url)
        XCTAssertThrowsError(try competing.start())
        release.signal()
        _ = await old.finishStdout(timeoutSeconds: 5)
        let replacement = try python("print('{\"id\":3}')", journal: url)
        try replacement.start()
        defer { replacement.forceKill(); replacement.cleanup() }
        assertComplete(await replacement.finishStdout(timeoutSeconds: 5))
    }

    func testReplayUsesOnlyDurablePrefixAndSurvivesTornUTF8Tail() throws {
        let url = try journalURL()
        let prefix = Data((0..<601).map { "{\"type\":\"segment\",\"id\":\($0)}\n" }.joined().utf8)
        try (prefix + Data([0xE2])).write(to: url)
        let replay = TranscriptEventJournal.replay(url: url, start: 0, byteCount: UInt64(prefix.count))
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.lines.count, 601)
        let invalid = TranscriptEventJournal.replay(url: url, start: 0, byteCount: UInt64(prefix.count + 1))
        XCTAssertEqual(invalid.lines.count, 601)
        XCTAssertNotNil(invalid.error)
    }

    func testExitDoesNotDiscardTailAndValidFinalObjectWithoutNewline() async throws {
        let url = try journalURL()
        let backend = try python("import sys\nsys.stdout.write('{\"id\":1}\\n{\"id\":2}')", journal: url)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let status = await backend.waitForExit(timeoutSeconds: 5)
        XCTAssertEqual(status, 0)
        let result = await backend.finishStdout(timeoutSeconds: 5)
        assertComplete(result)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":1}\n{\"id\":2}\n")
    }

    func testPartialJSONAtEOFDoesNotBecomeAnAuthoritativeEvent() async throws {
        let url = try journalURL()
        let backend = try python("import sys\nsys.stdout.write('{\"id\":1}\\n{\"id\":')", journal: url)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 5)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertTrue(result.status.reachedEOF)
        XCTAssertEqual(result.status.rejectedLines, 1)
        XCTAssertTrue(result.status.firstError?.contains("incomplete JSON") == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":1}\n")
    }

    func testMalformedCompleteLinesFailVisiblyAndFollowingValidEventSurvives() async throws {
        let url = try journalURL()
        let backend = try python("import sys\nsys.stdout.buffer.write(b'\\xff\\nnot-json\\n{\"id\":1}\\n')", journal: url)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 5)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertEqual(result.status.rejectedLines, 2)
        XCTAssertEqual(result.status.journaledLines, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":1}\n")
    }

    func testCancellingUIConsumerDoesNotCancelJournalReader() async throws {
        let url = try journalURL()
        let backend = try python("import json,time\ntime.sleep(0.05)\nfor i in range(800): print(json.dumps({'id':i}), flush=True)", journal: url)
        let consumer = Task { for await _ in backend.stdoutLines {} }
        consumer.cancel()
        await consumer.value
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 10)
        assertComplete(result)
        XCTAssertEqual(result.status.journaledLines, 800)
        XCTAssertEqual(result.status.droppedUILines, 800)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 800)
    }

    func testTimeoutAndWaiterCancellationLeaveReaderRunningUntilEOF() async throws {
        let url = try journalURL()
        let backend = try python("import time\ntime.sleep(0.3)\nprint('{\"id\":1}', flush=True)", journal: url)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let first = await backend.finishStdout(timeoutSeconds: 0.01)
        guard case .timedOut(let status) = first else { return XCTFail("expected timeout") }
        XCTAssertFalse(status.closed)
        XCTAssertFalse(status.cleanupRequested)
        let waiter = Task { await backend.finishStdout(timeoutSeconds: 20) }
        waiter.cancel()
        guard case .cancelled = await waiter.value else { return XCTFail("expected cancelled wait") }
        let eventual = await backend.finishStdout(timeoutSeconds: 5)
        assertComplete(eventual)
        XCTAssertEqual(eventual.status.journaledLines, 1)
    }

    func testExplicitCleanupBeforeEOFIsIncompleteAndPreservesPersistedPrefix() async throws {
        let url = try journalURL()
        let backend = try python("import time\nprint('{\"id\":1}', flush=True)\ntime.sleep(30)", journal: url)
        let firstLine = TaskCompletion()
        backend.onJSONLine = { _ in firstLine.markCompleted() }
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let ready = await firstLine.wait(timeoutSeconds: 5)
        XCTAssertEqual(ready, .completed)
        backend.cleanup()
        let result = await backend.finishStdout(timeoutSeconds: 5)
        guard case .drained(let status) = result else { return XCTFail("cleanup did not close reader") }
        XCTAssertFalse(status.isComplete)
        XCTAssertFalse(status.reachedEOF)
        XCTAssertTrue(status.closed)
        XCTAssertTrue(status.cleanupRequested)
        XCTAssertTrue(status.firstError?.contains("before EOF") == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":1}\n")
    }

    func testWriteFailureReportsFailureWithoutPublishingUnpersistedEvents() async throws {
        let url = try journalURL()
        let fault = JournalFault()
        let backend = try python("for i in range(10): print('{\"id\":%d}' % i)", journal: url,
                                 beforeWrite: { try fault.failAfterFirstWrite() })
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 5)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertTrue(result.status.reachedEOF)
        XCTAssertEqual(result.status.journaledLines, 1)
        XCTAssertEqual(result.status.rejectedLines, 9)
        XCTAssertNotNil(result.status.firstError)
        var visible: [String] = []
        for await line in backend.stdoutLines { visible.append(line) }
        XCTAssertEqual(visible, ["{\"id\":0}"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":0}\n")
    }

    func testOversizedLineIsBoundedAndFollowingEventSurvives() async throws {
        let url = try journalURL()
        let backend = try python("print('x'*100000)\nprint('{\"id\":1}')", journal: url, maximumLine: 128)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 5)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertEqual(result.status.rejectedLines, 1)
        XCTAssertLessThanOrEqual(result.status.maximumBufferedLineBytes, 128)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"id\":1}\n")
    }

    func testSyncFailureDoesNotAdvanceDurablePrefixOrPublishTheEvent() async throws {
        let url = try journalURL()
        let backend = try BackendProcess(
            command: ["/usr/bin/python3", "-c", "print('{\"id\":1}')"],
            eventJournalURL: url,
            beforeEventJournalIO: { checkpoint in
                if case .synchronize = checkpoint {
                    throw NSError(domain: NSPOSIXErrorDomain, code: 28)
                }
            }
        )
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 5)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertTrue(result.status.reachedEOF)
        XCTAssertEqual(result.status.journaledLines, 1, "write completed before injected sync failure")
        XCTAssertEqual(result.status.durableLines, 0)
        XCTAssertEqual(result.status.durableBytes, 0)
        XCTAssertEqual(result.status.rejectedLines, 1)
        var visible = 0
        for await _ in backend.stdoutLines { visible += 1 }
        XCTAssertEqual(visible, 0, "unconfirmed persistence must not be published")
    }

    func testLargeEventsHaveByteBoundedUIViewButCompleteJournal() async throws {
        let url = try journalURL()
        let backend = try python("import json\nfor i in range(6): print(json.dumps({'id':i,'text':'x'*(2*1024*1024)}))", journal: url)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 10)
        assertComplete(result)
        XCTAssertEqual(result.status.journaledLines, 6)
        XCTAssertGreaterThan(result.status.droppedUILines, 0)
        XCTAssertLessThanOrEqual(result.status.bufferedUIBytes, 8 * 1024 * 1024)
        var count = 0
        for await _ in backend.stdoutLines { count += 1 }
        XCTAssertLessThan(count, 6)
        XCTAssertEqual(backend.stdoutStatus().bufferedUIBytes, 0)
    }

    func testAppendRetainsPriorSessionAndRawFormatting() async throws {
        let url = try journalURL()
        let prior = "{\"prior\":true}\n"
        try Data(prior.utf8).write(to: url)
        let backend = try python("print(' { \"id\" : 1 } ')", journal: url)
        try backend.start()
        defer { backend.forceKill(); backend.cleanup() }
        let result = await backend.finishStdout(timeoutSeconds: 5)
        assertComplete(result)
        XCTAssertEqual(result.status.journalStartOffset, UInt64(prior.utf8.count))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), prior + " { \"id\" : 1 } \n")
    }

    func testTornExistingJournalIsNotOverwrittenOrAppended() async throws {
        let url = try journalURL()
        let prior = "{\"prior\":"
        try Data(prior.utf8).write(to: url)
        let backend = try python("print('{\"id\":1}')", journal: url)
        XCTAssertThrowsError(try backend.start())
        backend.cleanup()
        let result = await backend.finishStdout(timeoutSeconds: 1)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertNotNil(result.status.firstError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), prior)
    }
}

nonisolated private final class StdoutProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedOffMain = false
    private var observedPersisted = false
    var offMain: Bool { lock.withLock { observedOffMain } }
    var persisted: Bool { lock.withLock { observedPersisted } }
    func record(offMain: Bool, persisted: Bool) {
        lock.withLock { observedOffMain = offMain; observedPersisted = persisted }
    }
    // Bounded synchronous block is intentional fault injection, with a
    // kernel timeout that cannot depend on MainActor being scheduled.
    @MainActor func blockMainActor(timeout: Double) -> DispatchTimeoutResult {
        release.wait(timeout: .now() + timeout)
    }
}

nonisolated private final class JournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func failAfterFirstWrite() throws {
        let shouldFail = lock.withLock { count += 1; return count > 1 }
        if shouldFail { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
    }
}
