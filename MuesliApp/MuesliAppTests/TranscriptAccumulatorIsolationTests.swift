import XCTest
import Synchronization

@MainActor
final class TranscriptAccumulatorIsolationTests: XCTestCase {
    func testEchoReductionFinishesWhileMainActorIsBlocked() {
        let completed = DispatchSemaphore(value: 0)
        let result = Mutex<[String]>([])
        DispatchQueue.global().async {
            let system = #"{"type":"segment","stream":"system","speaker_id":"system:unknown","source_session_id":"session-a","t0":1,"t1":2,"text":"Hello from the remote speaker"}"#
            let micEcho = #"{"type":"segment","stream":"mic","speaker_id":"mic:unknown","source_session_id":"session-a","t0":1.1,"t1":2,"text":"hello from the remote speaker"}"#
            var systemFirst = TranscriptAccumulator()
            systemFirst.ingest(jsonLine: system)
            systemFirst.ingest(jsonLine: micEcho)
            var micFirst = TranscriptAccumulator()
            micFirst.ingest(jsonLine: micEcho)
            micFirst.ingest(jsonLine: system)
            result.withLock { value in
                value = systemFirst.segments.map(\.stream) + micFirst.segments.map(\.stream)
            }
            completed.signal()
        }
        // A hidden actor hop would wait behind this test and hit the timeout.
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.withLock { $0 }, ["system", "system"])
    }
}
