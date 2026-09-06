import Foundation
import Darwin
import XCTest

@MainActor
final class BackendChildLifetimeTests: XCTestCase {
    func testActualCatalogRefusesSurvivingChildAfterOriginalNativeOwnerCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-lease-" + UUID().uuidString)
        let meeting = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try LocalAudioRecorder(directory: meeting.appendingPathComponent("audio"))
        _ = await recorder.finish(timeoutSeconds: 2)
        let metadata = MeetingMetadata(version: 1, title: "Stopped", createdAt: Date(), updatedAt: Date(),
            durationSeconds: 0, lastTimestamp: 0, status: .degraded,
            sessions: [.init(sessionID: 1, startedAt: Date(), audioFolder: "audio", streams: [:])],
            segmentCount: 0, speakerNames: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: meeting.appendingPathComponent("meeting.json"))
        let ready = root.appendingPathComponent("ready"), finish = root.appendingPathComponent("finish")
        let script = root.appendingPathComponent("child.py")
        try """
        import os, sys, time
        from pathlib import Path
        import diarise_transcribe
        from diarise_transcribe.meeting_lease import validate_source_path
        root = Path(sys.argv[1])
        validate_source_path(root / 'meeting', meeting_root=True)
        (root / 'ready').write_text(str(os.getpid()))
        while not (root / 'finish').exists(): time.sleep(0.01)
        """.write(to: script, atomically: true, encoding: .utf8)
        let parent = """
        import os, subprocess, sys, time
        from pathlib import Path
        root = Path(sys.argv[1])
        subprocess.Popen([sys.executable, '-B', str(root / 'child.py'), str(root)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True)
        while not (root / 'ready').exists(): time.sleep(0.01)
        os._exit(0)
        """
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let modulePath = repo.appendingPathComponent("backend/fast_mac_transcribe_diarise_local_models_only/src").path
        let owner = BackendAdmissionOwner()
        let attempt = try owner.start(protecting: meeting, timeoutSeconds: 5) {
            BackendAdmissionOwner.Resources(backend: try BackendProcess(command: ["/usr/bin/python3", "-B", "-c", parent, root.path],
                environment: ["PYTHONPATH": modulePath]))
        }
        defer { attempt.cancel(); try? Data().write(to: finish) }
        if case .ready = await attempt.waitUntilReady() { _ = try attempt.claim() } else { return XCTFail("Parent did not start") }
        let closed = await attempt.waitUntilClosed(timeoutSeconds: 5)
        XCTAssertEqual(closed, .completed, "Original process/writer/reader/access owner must really close")
        let childPID = try XCTUnwrap(Int32(String(contentsOf: ready, encoding: .utf8)))
        defer { _ = kill(childPID, SIGKILL) }
        XCTAssertEqual(kill(childPID, 0), 0)
        let denied = try MeetingCatalogOwner.trash(in: meeting, onCompletion: { _ in }, move: { _ in
            XCTFail("A surviving child owns this source even though the original native owner completed")
        })
        if case .failed = await denied.wait(timeoutSeconds: 2) {} else { XCTFail("Surviving child failed to prevent deletion") }
        try Data().write(to: finish)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var released = false
        while !released && ContinuousClock.now < deadline {
            do {
                let lease = try BackendMeetingLease.acquire(in: meeting, exclusive: true)
                try lease.close()
                released = true
            } catch { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(released, "Only the actual child exit releases its pin")
        let allowed = try MeetingCatalogOwner.trash(in: meeting, onCompletion: { _ in }, move: { _ in })
        if case .completed = await allowed.wait(timeoutSeconds: 2) {} else { XCTFail("Actual child exit must permit the fixture move") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.path), "No actual Trash operation is used")
    }
}
