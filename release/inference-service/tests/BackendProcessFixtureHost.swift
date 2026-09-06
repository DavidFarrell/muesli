import Foundation
import Darwin

/// Actual production owners with generated, signed, model-free service output.
/// No test substitutes a synthetic native completion or consumes a UI stream.
nonisolated private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var bookmarks = 0
    private var value: BackendAdmissionOwner.Resources?
    private var callbacks = 0
    private var callbackPinsHeld = false
    let factoryReady = TaskCompletion()
    let journalEntered = TaskCompletion()
    let journalRelease = DispatchSemaphore(value: 0)
    private var gated = false

    func check(_ condition: Bool, _ message: String) { if !condition { lock.withLock { failures.append(message) } } }
    func bookmark() { lock.withLock { bookmarks += 1 } }
    func installed(_ resources: BackendAdmissionOwner.Resources) {
        lock.withLock { value = resources }; factoryReady.markCompleted()
    }
    var resources: BackendAdmissionOwner.Resources? { lock.withLock { value } }
    func closed(pinsHeld: Bool) { lock.withLock { callbacks += 1; callbackPinsHeld = pinsHeld } }
    func gateOnce() {
        let first = lock.withLock { if gated { return false }; gated = true; return true }
        if first {
            journalEntered.markCompleted()
            check(journalRelease.wait(timeout: .now() + 25) == .success, "Journal release failsafe expired.")
        }
    }
    var summary: (failures: [String], bookmarks: Int, callbacks: Int, callbackPinsHeld: Bool) {
        lock.withLock { (failures, bookmarks, callbacks, callbackPinsHeld) }
    }
}

@main nonisolated enum BackendProcessFixtureHost {
    static func exclusiveAvailable(_ root: URL, names: [String] = [".meeting-access.lock", ".backend-owner.lock"]) -> Bool {
        for name in names {
            let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return false }
            let available = flock(fd, LOCK_EX | LOCK_NB) == 0
            close(fd)
            if !available { return false }
        }
        return true
    }

    static func waitForTrace(_ name: String, at url: URL, timeout: Double = 12) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.split(separator: "\n").contains(where: { $0.hasPrefix(name + " ") }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    static func main() async throws {
        alarm(60)
        signal(SIGPIPE, SIG_IGN)
        guard CommandLine.arguments.count == 4 else { throw POSIXError(.EINVAL) }
        let scenario = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let trace = URL(fileURLWithPath: CommandLine.arguments[3])
        // The driver creates only these new private generated directories.
        let traceDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/paidiaconsulting.MuesliApp.InferenceService/Data/tmp", isDirectory: true)
        guard root.path.hasPrefix("/private/tmp/"), trace.deletingLastPathComponent() == traceDirectory,
              trace.lastPathComponent.hasPrefix("backend-fixture-"), trace.pathExtension == "txt" else { throw POSIXError(.EINVAL) }
        let state = FixtureState(), registry = ShutdownWorkRegistry()
        let owner = BackendAdmissionOwner(shutdown: registry)
        let journal = root.appendingPathComponent("transcript_events.jsonl")
        let began = ContinuousClock.now
        let attempt = try owner.start(protecting: root, timeoutSeconds: 53) {
            let backend = try BackendProcess(inference: .init(operation: .preflight, streams: .both,
                liveSource: nil, expectedRuntimeSHA256: Data(repeating: 1, count: 32),
                expectedModelsSHA256: Data(repeating: 2, count: 32), sourceBookmark: {
                    state.bookmark()
                    return try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                }), eventJournalURL: journal, beforeEventJournalIO: { checkpoint in
                    if (scenario == "blocked_write" && checkpoint == .write)
                        || (scenario == "blocked_finalsync" && checkpoint == .finalSynchronize) { state.gateOnce() }
                    if (scenario == "write_failure" && checkpoint == .write)
                        || (scenario == "finalsync_failure" && checkpoint == .finalSynchronize) { throw POSIXError(.ENOSPC) }
                })
            let resources = BackendAdmissionOwner.Resources(backend: backend, onClosed: {
                state.closed(pinsHeld: !exclusiveAvailable(root))
                state.check(!registry.snapshot().pending.isEmpty, "Scope callback ran after its shutdown token was released.")
            })
            state.installed(resources)
            return resources
        }
        state.check(await state.factoryReady.wait(timeoutSeconds: 5) == .completed, "Actual backend factory was not reached.")
        guard let resources = state.resources else { throw POSIXError(.EIO) }
        let backend = resources.backend
        var heldAtRetirement = false
        if scenario == "retired_reserve" {
            state.check(await waitForTrace("reserved", at: trace), "No actual delayed service reservation.")
            heldAtRetirement = owner.isBusy && !exclusiveAvailable(root) && !registry.snapshot().pending.isEmpty
            owner.retireAdmission()
        } else if scenario == "cancel_before_ack" {
            state.check(await waitForTrace("source_pinned", at: trace), "Service did not actually pin the original source.")
            state.check(backend.hasStarted && backend.isRunning, "Native observer was not active before cancellation.")
            attempt.cancel()
            state.check(await waitForTrace("cancel_received", at: trace), "Service did not receive cancellation while startup was waiting.")
            heldAtRetirement = owner.isBusy && !exclusiveAvailable(root) && !registry.snapshot().pending.isEmpty
            state.check(await backend.waitForExit(timeoutSeconds: 0.05) == nil, "Cancellation reply was mistaken for actual exit.")
            state.check(owner.isBusy && !exclusiveAvailable(root), "Source pins released before the original kernel exit.")
        }

        let ready = await attempt.waitUntilReady()
        let expectedReady = scenario != "reject" && scenario != "cancel_before_ack" && scenario != "retired_reserve"
        var claimed = false
        var startOutcome: String
        switch ready {
        case .ready:
            startOutcome = "ready"
            let claimedResources = try attempt.claim()
            claimed = true
            state.check(expectedReady, "Unexpected successful native source admission.")
            state.check(owner.isBusy && !exclusiveAvailable(root), "Claim released source ownership before actual exit.")
            claimedResources.writer.send(type: .meetingStart, stream: .system, ptsUs: 0,
                payload: Data("{\"type\":\"fixture_control\"}".utf8))
        case .failed(let message): startOutcome = "failed: " + message
        case .cancelled: startOutcome = "cancelled"
        case .timedOut: startOutcome = "timedOut"
        }
        state.check(claimed == expectedReady, "Readiness did not match the fixture scenario.")

        var heldAfterDisconnect = false
        if scenario == "disconnect" {
            state.check(await waitForTrace("disconnected", at: trace), "Actual connection invalidation was not observed.")
            heldAfterDisconnect = backend.isRunning && owner.isBusy && !exclusiveAvailable(root)
            state.check(await backend.waitForExit(timeoutSeconds: 0.05) == nil, "Transport disconnection was mistaken for kernel exit.")
        }
        let blocked = scenario == "blocked_write" || scenario == "blocked_finalsync"
        if blocked { state.check(await state.journalEntered.wait(timeoutSeconds: 5) == .completed, "Journal stall was not entered.") }
        let exitStatus = await backend.waitForExit(timeoutSeconds: 15)
        let evidence = backend.completionEvidence()
        var heldAfterKernel = false
        var duplicateRejected = false
        if blocked {
            // Exceeds maintain()'s own five-second stdout wait. Neither its
            // timeout nor the caller's timeout may discard the real journal FD.
            state.check(await attempt.waitUntilClosed(timeoutSeconds: 5.5) == .timedOut, "Blocked journal unexpectedly retired.")
            let drain = await backend.finishStdout(timeoutSeconds: 0.05)
            state.check(!drain.status.closed && !drain.status.isComplete, "Blocked journal advertised complete EOF.")
            heldAfterKernel = exitStatus == 0 && !backend.isRunning && owner.isBusy
                && !exclusiveAvailable(root) && !exclusiveAvailable(root, names: ["transcript_events.jsonl"])
                && !registry.snapshot().pending.isEmpty
            do {
                _ = try owner.start(protecting: root) {
                    state.check(false, "Competing backend factory ran while original journal was blocked.")
                    return resources
                }
            } catch { duplicateRejected = true }
            state.journalRelease.signal()
        }
        state.check(await attempt.waitUntilClosed(timeoutSeconds: 12) == .completed, "Original owner did not actually finish.")
        let drain = await backend.finishStdout(timeoutSeconds: 1)
        let status = drain.status
        let successfulNative = expectedReady
        state.check((evidence != nil) == successfulNative, "Typed native evidence did not match the real outcome.")
        if scenario == "signal" { state.check(evidence?.osTermination == .signalled(SIGKILL), "Actual SIGKILL was not preserved.") }
        else if successfulNative { state.check(evidence?.osTermination == .exited(125), "Actual exit125 was not preserved.") }
        if scenario == "reject" { state.check(exitStatus == 66 && evidence == nil, "Rejected operation66 became successful native evidence.") }
        if scenario == "cancel_before_ack" { state.check(exitStatus != nil && exitStatus != 0 && heldAtRetirement, "Cancellation released or certified the original owner early.") }
        if scenario == "retired_reserve" {
            state.check(state.summary.bookmarks == 0 && !backend.hasStarted && heldAtRetirement,
                        "Retired original reservation requested a source bookmark or lost ownership early.")
        }
        if scenario == "disconnect" { state.check(heldAfterDisconnect, "Disconnect released original source pins before kernel exit.") }
        if blocked { state.check(heldAfterKernel && duplicateRejected, "Journal stall lost original admission, lock, or shutdown ownership.") }
        let failedJournal = scenario == "write_failure" || scenario == "finalsync_failure"
        if failedJournal {
            state.check(evidence?.operationStatus == 0 && !status.isComplete && status.firstError != nil,
                        "Native operation0 hid journal failure or advertised complete output.")
        } else if successfulNative { state.check(status.isComplete, "Successful fixture did not durably drain its complete stdout.") }
        if successfulNative {
            let backlog = resources.writer.backlogSnapshot()
            state.check(backlog.totalCompletedFrames == 1 && backlog.failedWrites == 0, "Actual framed input did not complete successfully.")
            state.check(await waitForTrace("frame_verified", at: trace, timeout: 1), "Service did not verify the actual frame.")
        }
        state.check(resources.writer.stdinCloseSnapshot.closed, "Original framed writer did not actually close.")
        state.check(!owner.isBusy && exclusiveAvailable(root) && registry.snapshot().pending.isEmpty,
                    "Close publication preceded actual source/registry release.")
        let snapshot = state.summary
        state.check(snapshot.callbacks == 1 && snapshot.callbackPinsHeld, "Original resource scope did not close exactly once under its pins.")
        let bytes = try Data(contentsOf: journal)
        let journalLines = bytes.split(separator: 10)
        if scenario == "normal" {
            state.check(status.durableLines == 601 && journalLines.count == 601 && status.droppedUILines > 0,
                        "Stalled lossy UI consumer lost authoritative final events.")
        }
        if !failedJournal && successfulNative {
            for (index, line) in journalLines.enumerated() {
                let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                state.check(object?["type"] as? String == "fixture_result" && object?["index"] as? Int == index,
                            "Journal bytes changed or final event ordering was lost.")
            }
        }
        var archiveBindingRejected = true
        if let evidence {
            do {
                let access = try MeetingFileAccess.acquire(in: root)
                try evidence.requireSuccessfulArchive(sourceIdentity: access.identity, snapshotSHA256: String(repeating: "a", count: 64))
                archiveBindingRejected = false
            } catch {}
        }
        state.check(archiveBindingRejected, "Model-free preflight fixture unexpectedly authorized archive processing.")
        let elapsed = began.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if scenario == "slow_reserve" { state.check(elapsedSeconds >= 9 && elapsedSeconds < 20 && state.summary.bookmarks == 1,
                                                    "Nine-second reservation did not fit the real outer53-second admission.") }
        let json: [String: Any] = ["scenario": scenario, "scope": "signed model-free production owner integration; no model, private grant, or archive authorization",
            "passed": state.summary.failures.isEmpty, "failures": state.summary.failures,
            "start_outcome": startOutcome, "exit_status": exitStatus.map { $0 as Any } ?? NSNull(),
            "typed_native_candidate": evidence != nil, "native_termination": evidence.map { String(describing: $0.osTermination) } ?? "none",
            "bookmark_calls": state.summary.bookmarks, "held_at_retirement": heldAtRetirement,
            "held_after_disconnect": heldAfterDisconnect, "held_after_kernel_exit": heldAfterKernel,
            "duplicate_admission_rejected": duplicateRejected, "journal_complete": status.isComplete,
            "journal_error": status.firstError.map { $0 as Any } ?? NSNull(), "journal_lines": journalLines.count,
            "durable_lines": status.durableLines, "dropped_ui_lines": status.droppedUILines,
            "writer_closed": resources.writer.stdinCloseSnapshot.closed, "archive_binding_rejected": archiveBindingRejected,
            "elapsed_seconds": elapsedSeconds, "source": root.path]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
        if !state.summary.failures.isEmpty { exit(1) }
    }
}
