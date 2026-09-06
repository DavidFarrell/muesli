import XCTest
import Foundation
import Darwin

final class BackendCompletionEvidenceTests: XCTestCase {
    private typealias Evidence = BackendCompletionEvidence
    private let digest = String(repeating: "a", count: 64)
    private let otherDigest = String(repeating: "b", count: 64)
    private let identity = MeetingFileAccess.Identity(directoryDevice: 1, directoryInode: 2, lockDevice: 1, lockInode: 3)

    private func binding(operation: Evidence.Operation = .reprocess, stream: Evidence.Stream = .both,
                         snapshot: String? = String(repeating: "a", count: 64), request: String? = nil,
                         runtime: String? = nil, model: String? = nil) -> Evidence.XPCBinding {
        .init(jobID: UUID(), instanceID: UUID(), requestSHA256: request ?? digest,
              process: .init(pid: 100, startSeconds: 1_000, startMicroseconds: 500), sourceIdentity: identity,
              sourceSnapshotSHA256: snapshot, operation: operation, stream: stream,
              runtimeManifestSHA256: runtime ?? digest, modelSetSHA256: model ?? digest)
    }
    private func reply(_ binding: Evidence.XPCBinding, job: UUID? = nil, instance: UUID? = nil,
                       request: String? = nil, status: Int32 = 0) -> Evidence.XPCReply {
        .init(jobID: job ?? binding.jobID, instanceID: instance ?? binding.instanceID,
              requestSHA256: request ?? binding.requestSHA256, operationStatus: status)
    }
    private func kernel(_ binding: Evidence.XPCBinding, status: Int32 = 125 << 8,
                        process: Evidence.ProcessIdentity? = nil, exit: Bool = true, exitStatus: Bool = true) -> Evidence.KernelExit {
        .init(process: process ?? binding.process, rawWaitStatus: status, observedExit: exit, observedExitStatus: exitStatus)
    }

    func testExpectedCleanupPreservesActualKernelStatusSeparatelyFromOperationZero() throws {
        let request = binding()
        for (status, expected) in [(Int32(125 << 8), Evidence.OSTermination.exited(125)),
                                   (SIGKILL, Evidence.OSTermination.signalled(SIGKILL))] {
            let outcome = try Evidence.validateSuccessfulXPC(binding: request, reply: reply(request), kernel: kernel(request, status: status))
            XCTAssertEqual(outcome.operationStatus, 0)
            XCTAssertEqual(outcome.termination, expected)
            XCTAssertEqual(outcome.rawWaitStatus, status)
        }
        XCTAssertNoThrow(try Evidence.validateArchiveBinding(request, sourceIdentity: identity, snapshotSHA256: digest))
    }

    func testFailedOrUnqualifiedCleanupCannotBecomeSuccessfulEvidence() {
        let request = binding()
        for status: Int32 in [0, 126 << 8, 1 << 8, SIGTERM, 127, -1, Int32.max, SIGKILL | 0x80] {
            XCTAssertThrowsError(try Evidence.validateSuccessfulXPC(binding: request, reply: reply(request),
                kernel: kernel(request, status: status)), "Unexpected wait status \(status) was accepted")
        }
        XCTAssertThrowsError(try Evidence.validateSuccessfulXPC(binding: request, reply: reply(request, status: 66), kernel: kernel(request)))
    }

    func testReplayedReplyCannotMatchAnotherJobInstanceOrRequest() {
        let request = binding()
        for response in [reply(request, job: UUID()), reply(request, instance: UUID()), reply(request, request: otherDigest)] {
            XCTAssertThrowsError(try Evidence.validateSuccessfulXPC(binding: request, reply: response, kernel: kernel(request)))
        }
    }

    func testPIDReuseOrIncompleteKernelObservationCannotProveOriginalExit() {
        let request = binding()
        let changed: [Evidence.ProcessIdentity] = [
            .init(pid: 101, startSeconds: 1_000, startMicroseconds: 500),
            .init(pid: 100, startSeconds: 1_001, startMicroseconds: 500),
            .init(pid: 100, startSeconds: 1_000, startMicroseconds: 501)]
        for process in changed {
            XCTAssertThrowsError(try Evidence.validateSuccessfulXPC(binding: request, reply: reply(request),
                kernel: kernel(request, process: process)))
        }
        for observed in [kernel(request, exit: false), kernel(request, exitStatus: false)] {
            XCTAssertThrowsError(try Evidence.validateSuccessfulXPC(binding: request, reply: reply(request), kernel: observed))
        }
    }

    func testInvalidRequestRuntimeModelAndSnapshotDigestsFailClosed() {
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
                        String(repeating: "g", count: 64), String(repeating: "é", count: 64)] {
            for request in [binding(request: invalid), binding(runtime: invalid), binding(model: invalid), binding(snapshot: invalid)] {
                XCTAssertThrowsError(try Evidence.validateSuccessfulXPC(binding: request, reply: reply(request), kernel: kernel(request)))
            }
        }
    }

    func testArchiveRequiresBothStreamBatchAndExactPhysicalSourceSnapshot() throws {
        let request = binding()
        let changed = MeetingFileAccess.Identity(directoryDevice: 1, directoryInode: 4, lockDevice: 1, lockInode: 3)
        let changedLock = MeetingFileAccess.Identity(directoryDevice: 1, directoryInode: 2, lockDevice: 1, lockInode: 5)
        for source in [changed, changedLock] {
            XCTAssertThrowsError(try Evidence.validateArchiveBinding(request, sourceIdentity: source, snapshotSHA256: digest))
        }
        XCTAssertThrowsError(try Evidence.validateArchiveBinding(request, sourceIdentity: identity, snapshotSHA256: otherDigest))
        for incompatible in [binding(stream: .mic), binding(stream: .system), binding(operation: .live),
                             binding(operation: .preflight), binding(snapshot: nil)] {
            XCTAssertThrowsError(try Evidence.validateArchiveBinding(incompatible, sourceIdentity: identity, snapshotSHA256: digest))
        }
        // Live/preflight may lack a closed batch snapshot, but cannot turn
        // their otherwise valid native completion into archive eligibility.
        let live = binding(operation: .live, snapshot: nil)
        XCTAssertNoThrow(try Evidence.validateSuccessfulXPC(binding: live, reply: reply(live), kernel: kernel(live)))
    }

    func testLegacyEvidenceIsUnavailableUntilActualTermination() async throws {
        let backend = try BackendProcess(command: ["/bin/cat"])
        let writer = FramedWriter(stdinHandle: backend.stdin)
        defer { backend.forceKill(); backend.cleanup() }
        XCTAssertNil(backend.completionEvidence())
        try backend.start()
        let early = await backend.waitForExit(timeoutSeconds: 0.03)
        XCTAssertNil(early)
        XCTAssertNil(backend.completionEvidence())
        let closed = await writer.closeStdinAndWait(timeoutSeconds: 2)
        XCTAssertTrue(closed)
        let exit = await backend.waitForExit(timeoutSeconds: 3)
        XCTAssertEqual(exit, 0)
        let completion = try XCTUnwrap(backend.completionEvidence())
        XCTAssertEqual(completion.osTermination, .exited(0))
        XCTAssertEqual(completion.operationStatus, 0)
        XCTAssertNoThrow(try completion.requireSuccessfulArchive(sourceIdentity: identity, snapshotSHA256: digest))
        _ = await backend.finishStdout(timeoutSeconds: 3)
    }

    func testActualLegacyFailureAndSignalRemainIneligible() async throws {
        for kill in [false, true] {
            let backend = try BackendProcess(command: kill ? ["/bin/sleep", "30"] : ["/bin/sh", "-c", "exit 7"])
            let writer = FramedWriter(stdinHandle: backend.stdin)
            defer { backend.forceKill(); backend.cleanup() }
            try backend.start()
            if kill { backend.forceKill() }
            _ = await backend.waitForExit(timeoutSeconds: 3)
            let completion = try XCTUnwrap(backend.completionEvidence())
            XCTAssertEqual(completion.osTermination, kill ? .signalled(SIGKILL) : .exited(7))
            XCTAssertEqual(completion.operationStatus, kill ? SIGKILL : 7)
            XCTAssertThrowsError(try completion.requireSuccessfulArchive(sourceIdentity: identity, snapshotSHA256: digest))
            _ = await writer.closeStdinAndWait(timeoutSeconds: 2)
            _ = await backend.finishStdout(timeoutSeconds: 3)
        }
    }
}
