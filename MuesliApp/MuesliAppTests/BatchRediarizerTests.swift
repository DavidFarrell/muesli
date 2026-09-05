import XCTest
import Darwin

@MainActor
final class BatchRediarizerTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testFinalResultSurvivesMoreThanUIBufferAndEOFWithoutNewline() async throws {
        let runner = BatchRediarizer(timeoutSeconds: 10)
        let script = "for i in $(seq 1 700); do printf '{\"type\":\"status\",\"stage\":\"transcribing\"}\\n'; done; printf '{\"type\":\"result\",\"turns\":[],\"speakers\":[\"tail\"],\"duration\":12.5}'"
        let result = try await runner.runCommand(["/bin/sh", "-c", script], backendRoot: folder())
        XCTAssertEqual(result.duration, 12.5)
        XCTAssertEqual(result.speakers, ["tail"])
        XCTAssertNil(result.sources, "old batch results remain compatible")
    }

    func testSourceInventoryAndTurnProvenanceSurviveAuthoritativeReader() async throws {
        let runner = BatchRediarizer(timeoutSeconds: 10)
        let payload = #"{"type":"result","turns":[{"speaker_id":"system:SPEAKER_01","stream":"system","source_session_id":"session-two","t0":10,"t1":11,"text":"a"}],"speakers":["system:SPEAKER_01"],"duration":12,"sources":[{"source_session_id":"session-two","audio_folder":"audio-session-2","timeline_offset_seconds":10,"duration_seconds":2,"storage_kind":"committed_pcm"}]}"#
        let result = try await runner.runCommand(["/bin/sh", "-c", "printf '%s\\n' '\(payload)'"], backendRoot: folder())
        XCTAssertEqual(result.turns.first?.sourceSessionID, "session-two")
        XCTAssertEqual(result.turns.first?.speakerId, "system:SPEAKER_01")
        XCTAssertEqual(result.sources?.first?.sourceSessionID, "session-two")
        XCTAssertEqual(result.sources?.first?.timelineOffsetSeconds, 10)
    }
    func testFinalErrorCannotBeOverwrittenByEarlierResult() async throws {
        let runner = BatchRediarizer(timeoutSeconds: 10)
        let script = "printf '%s\\n' '{\"type\":\"result\",\"turns\":[],\"speakers\":[],\"duration\":1}' '{\"type\":\"error\",\"message\":\"final failure\"}'"
        do {
            _ = try await runner.runCommand(["/bin/sh", "-c", script], backendRoot: folder())
            XCTFail("a result does not supersede a terminal failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("final failure")) }
    }
    func testMalformedEOFTailCannotLeaveAnEarlierResultSuccessful() async throws {
        let runner = BatchRediarizer(timeoutSeconds: 10)
        for tail in ["{\"type\":", "{\"type\":\"result\"}"] {
            let script = "printf '%s\\n' '{\"type\":\"result\",\"turns\":[],\"speakers\":[],\"duration\":1}'; printf '%s' '\(tail)'"
            do {
                _ = try await runner.runCommand(["/bin/sh", "-c", script], backendRoot: folder())
                XCTFail("malformed final output must be explicit")
            } catch { XCTAssertTrue(error.localizedDescription.contains("malformed JSON")) }
        }
    }
    func testTimeoutKillsProcessThatIgnoresSIGTERM() async throws {
        let folder = try folder(), pidFile = folder.appendingPathComponent("pid")
        let script = "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open('pid','w').write(str(os.getpid())); time.sleep(60)"
        let runner = BatchRediarizer(timeoutSeconds: 0.5)
        let started = ContinuousClock.now
        do {
            _ = try await runner.runCommand(["/usr/bin/python3", "-c", script], backendRoot: folder)
            XCTFail("expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(4))
        if let pid = try? String(contentsOf: pidFile, encoding: .utf8), let number = Int32(pid) {
            XCTAssertEqual(kill(number, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
    func testCancellationOwnsBoundedKillAndDoesNotReturnPartialResult() async throws {
        let folder = try folder()
        let script = "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open('pid','w').write(str(os.getpid())); print('{\"type\":\"result\",\"turns\":[],\"speakers\":[],\"duration\":1}',flush=True); time.sleep(60)"
        let runner = BatchRediarizer(timeoutSeconds: 10)
        let task = Task { try await runner.runCommand(["/usr/bin/python3", "-c", script], backendRoot: folder) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let start = ContinuousClock.now
        do { _ = try await task.value; XCTFail("cancelled run must not return its earlier result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        if let pid = try? String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8), let number = Int32(pid) {
            XCTAssertEqual(kill(number, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
}
