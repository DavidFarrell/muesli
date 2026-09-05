import Foundation
import Darwin
import XCTest

@MainActor
final class BackendAdmissionTests: XCTestCase {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backend-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testJournalPrepareDeadlineKeepsAliasLockWhileSourceAndUIAdvance() async throws {
        let folder = try folder(), journal = folder.appendingPathComponent("events.jsonl")
        let source = folder.appendingPathComponent("source")
        let recorder = try LocalAudioRecorder(directory: source, commitInterval: 0.01)
        let probe = AdmissionProbe(), owner = BackendAdmissionOwner()
        let attempt = try owner.start(timeoutSeconds: 0.2) {
            let backend = try BackendProcess(command: ["/bin/sh", "-c", "touch launched"], workingDirectory: folder,
                eventJournalURL: journal, beforeEventJournalIO: { checkpoint in
                    if case .prepare = checkpoint { probe.block() }
                })
            probe.install(backend)
            return BackendAdmissionOwner.Resources(backend: backend, onClosed: { probe.scopeClosed.signal() })
        }
        defer { probe.release.signal(); attempt.cancel() }
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 2), .success)
        let ui = Task { @MainActor in 42 }
        let outcome = await attempt.waitUntilReady()
        if case .ready = outcome { XCTFail("a blocked journal cannot be ready") }
        let heartbeat = await ui.value
        XCTAssertEqual(heartbeat, 42)
        XCTAssertTrue(owner.isBusy)
        XCTAssertThrowsError(try owner.start { throw CancellationError() })
        XCTAssertEqual(probe.scopeClosed.wait(timeout: .now() + 0.01), .timedOut)
        let alias = folder.appendingPathComponent("journal-alias")
        try FileManager.default.linkItem(at: journal, to: alias)
        let competitor = try BackendProcess(command: ["/usr/bin/true"], eventJournalURL: alias)
        XCTAssertThrowsError(try competitor.start())
        let sourceCommitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let data = Data(repeating: 2, count: 3200)
            recorder.record(source: .mic, ptsUs: 0, payload: data)
            recorder.record(source: .system, ptsUs: 0, payload: data)
            let end = Date().addingTimeInterval(2)
            while Date() < end {
                if recorder.status().committedBytes == 6400 { sourceCommitted.signal(); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // The actual UI executor is held here while the real recorder commits.
        XCTAssertEqual(sourceCommitted.wait(timeout: .now() + 3), .success)
        probe.release.signal()
        let closed = await attempt.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(closed, .completed)
        XCTAssertFalse(owner.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("launched").path))
        XCTAssertEqual(probe.scopeClosed.wait(timeout: .now() + 1), .success)
        let final = await recorder.finish(timeoutSeconds: 3)
        XCTAssertEqual(final?.streams["system"]?.committed_bytes, 3200)
        let replacement = try owner.start {
            BackendAdmissionOwner.Resources(backend: try BackendProcess(command: ["/usr/bin/true"], eventJournalURL: alias))
        }
        if case .ready = await replacement.waitUntilReady() { _ = try replacement.claim() }
        else { XCTFail("actual journal closure must release the alias lease") }
        let replaced = await replacement.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(replaced, .completed)
    }

    func testOfferedButUnclaimedDeadlineDoesNotNeedMainActorAndCannotPublish() async throws {
        let folder = try folder(), owner = BackendAdmissionOwner(), probe = AdmissionProbe()
        let attempt = try owner.start(timeoutSeconds: 0.15) {
            let backend = try BackendProcess(command: ["/bin/sleep", "30"], eventJournalURL: folder.appendingPathComponent("events"))
            probe.install(backend)
            return BackendAdmissionOwner.Resources(backend: backend, onClosed: { probe.scopeClosed.signal() })
        }
        defer { attempt.cancel() }
        // No MainActor continuation is allowed to claim the ready result.
        XCTAssertEqual(probe.scopeClosed.wait(timeout: .now() + 4), .success)
        XCTAssertThrowsError(try attempt.claim())
        XCTAssertFalse(probe.backend?.isRunning ?? true)
        XCTAssertTrue(probe.backend?.stdoutStatus().closed ?? false)
    }

    func testRetiredOfferAndNewSourceCannotClaimOldBackend() async throws {
        let owner = BackendAdmissionOwner(), probe = AdmissionProbe()
        let old = try owner.start {
            let backend = try BackendProcess(command: ["/bin/sleep", "30"])
            probe.install(backend)
            return BackendAdmissionOwner.Resources(backend: backend)
        }
        if case .ready = await old.waitUntilReady() {} else { XCTFail("expected ready offer") }
        owner.retireAdmission() // Actual Stop entry seam, before publication.
        XCTAssertThrowsError(try old.claim())
        XCTAssertThrowsError(try owner.start { throw CancellationError() })
        let closed = await old.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(closed, .completed)
        let next = try owner.start { BackendAdmissionOwner.Resources(backend: try BackendProcess(command: ["/usr/bin/true"])) }
        if case .ready = await next.waitUntilReady() { _ = try next.claim() } else { XCTFail("new source should be admitted") }
        let nextClosed = await next.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(nextClosed, .completed)
        XCTAssertThrowsError(try old.claim())
    }

    func testNativeStartStallCancellationAndSnapshotsNeverHoldUI() async throws {
        for checkpoint in [BackendLaunchCheckpoint.beforeRun, .afterRun] {
            let owner = BackendAdmissionOwner(), probe = AdmissionProbe()
            let attempt = try owner.start(timeoutSeconds: 0.15) {
                let backend = try BackendProcess(command: ["/bin/sleep", "30"], launchCheckpoint: { hit in
                    switch (checkpoint, hit) {
                    case (.beforeRun, .beforeRun), (.afterRun, .afterRun): probe.block()
                    default: break
                    }
                })
                probe.install(backend)
                return BackendAdmissionOwner.Resources(backend: backend, onClosed: { probe.scopeClosed.signal() })
            }
            defer { probe.release.signal(); attempt.cancel() }
            XCTAssertEqual(probe.entered.wait(timeout: .now() + 2), .success)
            let start = ContinuousClock.now
            attempt.cancel()
            probe.backend?.terminate()
            probe.backend?.forceKill()
            _ = probe.backend?.isRunning
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
            _ = await attempt.waitUntilReady()
            XCTAssertTrue(owner.isBusy)
            XCTAssertThrowsError(try attempt.claim())
            XCTAssertEqual(probe.scopeClosed.wait(timeout: .now() + 0.01), .timedOut)
            probe.release.signal()
            let closed = await attempt.waitUntilClosed(timeoutSeconds: 3)
            XCTAssertEqual(closed, .completed)
            XCTAssertFalse(probe.backend?.isRunning ?? true)
            XCTAssertTrue(probe.backend?.stdoutStatus().closed ?? false)
        }
    }

    func testCancelledLateLaunchRetainsAdmissionThroughBlockedJournalClose() async throws {
        let folder = try folder(), owner = BackendAdmissionOwner()
        let run = AdmissionProbe(), write = AdmissionProbe()
        let attempt = try owner.start(timeoutSeconds: 0.2) {
            let backend = try BackendProcess(command: ["/bin/sh", "-c", "printf '{\"id\":1}\\n'; exec sleep 30"],
                eventJournalURL: folder.appendingPathComponent("events"), beforeEventJournalIO: { hit in
                    if case .write = hit { write.block() }
                }, launchCheckpoint: { hit in if case .afterRun = hit { run.block() } })
            run.install(backend)
            return BackendAdmissionOwner.Resources(backend: backend, onClosed: { run.scopeClosed.signal() })
        }
        defer { run.release.signal(); write.release.signal(); attempt.cancel() }
        XCTAssertEqual(run.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(write.entered.wait(timeout: .now() + 2), .success)
        attempt.cancel()
        run.release.signal()
        let pending = await attempt.waitUntilClosed(timeoutSeconds: 1.5)
        XCTAssertEqual(pending, .timedOut)
        XCTAssertTrue(owner.isBusy)
        XCTAssertFalse(run.backend?.isRunning ?? true)
        XCTAssertFalse(run.backend?.stdoutStatus().closed ?? true)
        XCTAssertEqual(run.scopeClosed.wait(timeout: .now() + 0.01), .timedOut)
        write.release.signal()
        let closed = await attempt.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(closed, .completed)
        XCTAssertEqual(run.scopeClosed.wait(timeout: .now() + 1), .success)
    }

    func testSetupAndLaunchThrowCloseTheOriginalResources() async throws {
        for failsSetup in [true, false] {
            let owner = BackendAdmissionOwner(), probe = AdmissionProbe(), folder = try folder()
            let attempt = try owner.start {
                let backend = try BackendProcess(command: [failsSetup ? "/usr/bin/true" : "/nonexistent-muesli-test-command"],
                    eventJournalURL: folder.appendingPathComponent("events"), beforeEventJournalIO: { hit in
                        if failsSetup, case .prepare = hit { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
                    })
                probe.install(backend)
                return BackendAdmissionOwner.Resources(backend: backend, onClosed: { probe.scopeClosed.signal() })
            }
            if case .failed = await attempt.waitUntilReady() {} else { XCTFail("expected real setup/launch error") }
            XCTAssertThrowsError(try attempt.claim())
            let closed = await attempt.waitUntilClosed(timeoutSeconds: 3)
            XCTAssertEqual(closed, .completed)
            XCTAssertTrue(probe.backend?.stdoutStatus().closed ?? false)
            XCTAssertEqual(probe.scopeClosed.wait(timeout: .now() + 1), .success)
        }
    }

    func testHealthyHandoffRetainsInitialDurableTailAndJournalOffset() async throws {
        let folder = try folder(), journal = folder.appendingPathComponent("events"), owner = BackendAdmissionOwner()
        let prefix = Data("{\"old\":1}\n".utf8)
        try prefix.write(to: journal)
        let attempt = try owner.start {
            BackendAdmissionOwner.Resources(backend: try BackendProcess(command: ["/usr/bin/python3", "-c",
                "import json\nfor i in range(800): print(json.dumps({'id':i}),flush=True)"], eventJournalURL: journal))
        }
        if case .ready = await attempt.waitUntilReady() {} else { XCTFail("expected ready") }
        let backend = try attempt.claim().backend
        _ = await backend.waitForExit(timeoutSeconds: 3)
        let closed = await attempt.waitUntilClosed(timeoutSeconds: 3)
        XCTAssertEqual(closed, .completed)
        let status = backend.stdoutStatus()
        XCTAssertEqual(status.journalStartOffset, UInt64(prefix.count))
        XCTAssertEqual(status.durableLines, 800)
        XCTAssertTrue(status.isComplete)
        let replay = TranscriptEventJournal.replay(url: journal, start: status.journalStartOffset, byteCount: status.durableBytes)
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.lines.count, 800)
        XCTAssertEqual(status.droppedUILines, 300)
    }

    func testBatchProductionAdmissionCancellationDuringPrepareIsBoundedAndBusy() async throws {
        let folder = try folder(), probe = AdmissionProbe(), runner = BatchRediarizer(timeoutSeconds: 10)
        let task = Task {
            try await runner.runCommand(["/usr/bin/true"], backendRoot: folder,
                eventJournalURL: folder.appendingPathComponent("events"), beforeEventJournalIO: { hit in
                    if case .prepare = hit { probe.block() }
                })
        }
        defer { probe.release.signal(); task.cancel() }
        // Let the production actor reach its off-UI factory before blocking UI.
        let entered = await Task.detached { probe.waitForEntry() }.value
        XCTAssertEqual(entered, .success)
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled batch must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        do {
            _ = try await runner.runCommand(["/usr/bin/true"], backendRoot: folder)
            XCTFail("original journal admission remains busy")
        } catch { XCTAssertTrue(error.localizedDescription.contains("previous transcription")) }
        probe.release.signal()
    }
}

nonisolated private final class AdmissionProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let scopeClosed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: BackendProcess?
    var backend: BackendProcess? { lock.withLock { stored } }
    func install(_ value: BackendProcess) { lock.withLock { stored = value } }
    func waitForEntry() -> DispatchTimeoutResult { entered.wait(timeout: .now() + 3) }
    func block() {
        entered.signal()
        _ = release.wait(timeout: .now() + 15)
    }
}
