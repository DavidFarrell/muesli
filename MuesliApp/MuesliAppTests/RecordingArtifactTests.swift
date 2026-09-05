import XCTest
import ScreenCaptureKit

@MainActor
final class RecordingArtifactTests: XCTestCase {
    private func pair() -> (RecordingDelegate, SCRecordingOutput) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let delegate = RecordingDelegate(url: url)
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        return (delegate, SCRecordingOutput(configuration: configuration, delegate: delegate))
    }

    func testStartDoesNotEstablishFileCompletion() async {
        let (delegate, output) = pair()
        delegate.recordingOutputDidStartRecording(output)
        guard case .timedOut(let state) = await delegate.waitForCompletion(timeoutSeconds: 0) else {
            return XCTFail("start callback must not complete the artifact")
        }
        XCTAssertEqual(state.status, .recording)
    }

    func testLateFinishAfterDeadlineRemainsObservable() async {
        let (delegate, output) = pair()
        guard case .timedOut = await delegate.waitForCompletion(timeoutSeconds: 0.001) else {
            return XCTFail("missing callback must expire")
        }
        delegate.recordingOutputDidFinishRecording(output)
        guard case .finished(let state) = await delegate.waitForCompletion(timeoutSeconds: 0) else {
            return XCTFail("late owner callback should establish completion")
        }
        XCTAssertEqual(state.id, delegate.id)
        XCTAssertEqual(state.url, delegate.url)
    }

    func testFailureIsTerminalAndCannotBeOverwrittenByLateFinish() async {
        let (delegate, output) = pair()
        delegate.recordingOutput(output, didFailWithError: NSError(domain: "recording-test", code: 7))
        delegate.recordingOutputDidFinishRecording(output)
        delegate.recordingOutputDidStartRecording(output)
        guard case .failed(let state) = await delegate.waitForCompletion(timeoutSeconds: 0) else {
            return XCTFail("failure must remain explicit")
        }
        XCTAssertEqual(state.status, .failed)
        XCTAssertNotNil(state.error)
    }

    func testWaitingCancellationDoesNotCompleteAnotherRecording() async {
        let (first, firstOutput) = pair()
        let (second, _) = pair()
        let waiter = Task { await first.waitForCompletion(timeoutSeconds: 10) }
        waiter.cancel()
        guard case .cancelled = await waiter.value else { return XCTFail("wait should cancel") }
        first.recordingOutputDidFinishRecording(firstOutput)
        XCTAssertEqual(second.snapshot().status, .requested)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.url, second.url)
    }
}
