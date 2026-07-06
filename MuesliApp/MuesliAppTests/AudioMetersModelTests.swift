import XCTest

@MainActor
final class AudioMetersModelTests: XCTestCase {
    // Keep every model created by a test alive for the process lifetime.
    // Xcode 26's isolated-deinit path for @MainActor-isolated ObservableObjects
    // races XCTest's post-test memory checker and aborts with a spurious
    // "pointer being freed was not allocated" - reproduces even for a bare
    // ObservableObject with no Muesli code involved. Retaining sidesteps it
    // (see TranscriptModelTests.swift, same workaround).
    private static var keepAlive: [AudioMetersModel] = []

    private func makeModel() -> AudioMetersModel {
        let model = AudioMetersModel()
        Self.keepAlive.append(model)
        return model
    }

    func testUpdateMicPublishesFirstReadingImmediately() {
        let model = makeModel()
        model.updateMic(level: 0.3, buffers: 1, frames: 160, pts: 0.01, format: "s16le")
        XCTAssertEqual(model.mic.level, 0.3, accuracy: 0.001)
        XCTAssertEqual(model.mic.debugBuffers, 1)
        XCTAssertEqual(model.publishCount, 1)
    }

    func testSustainedZeroStopsIncrementingPublishCount() {
        let model = makeModel()
        model.updateMic(level: 0.5, buffers: 1, frames: 160, pts: 0.01, format: "s16le")
        model.updateMic(level: 0, buffers: 2, frames: 160, pts: 0.02, format: "s16le") // transition to zero
        let afterTransition = model.publishCount
        // Steady-state silence: counters must freeze, not keep ticking.
        model.updateMic(level: 0, buffers: 3, frames: 160, pts: 0.03, format: "s16le")
        model.updateMic(level: 0, buffers: 4, frames: 160, pts: 0.04, format: "s16le")
        XCTAssertEqual(model.publishCount, afterTransition)
        XCTAssertEqual(model.mic.debugBuffers, 2, "frozen at the transition-to-zero snapshot")
    }

    func testForceAlwaysPublishesAndUpdatesEvenAtRestZero() {
        let model = makeModel()
        model.updateMic(level: 0, buffers: 1, frames: 0, pts: 0, format: "-")
        model.updateMic(level: 0, buffers: 2, frames: 0, pts: 0, format: "-") // now at rest, ignored
        XCTAssertEqual(model.mic.debugBuffers, 1)
        model.updateMic(level: 0, buffers: 99, frames: 0, pts: 0, format: "-", force: true)
        XCTAssertEqual(model.mic.debugBuffers, 99, "force must bypass the at-rest gate")
    }

    func testMicAndSystemStreamsAreIndependent() {
        let model = makeModel()
        model.updateMic(level: 0.4, buffers: 1, frames: 160, pts: 0.01, format: "mic-format")
        model.updateSystem(level: 0.6, buffers: 5, frames: 320, pts: 0.02, format: "system-format")
        XCTAssertEqual(model.mic.level, 0.4, accuracy: 0.001)
        XCTAssertEqual(model.system.level, 0.6, accuracy: 0.001)
        XCTAssertEqual(model.mic.debugFormat, "mic-format")
        XCTAssertEqual(model.system.debugFormat, "system-format")
        XCTAssertEqual(model.publishCount, 2)
    }

    func testSetMicErrorUpdatesOnlyErrorFields() {
        let model = makeModel()
        model.updateMic(level: 0.2, buffers: 1, frames: 160, pts: 0.01, format: "s16le")
        model.setMicError(message: "boom", errorCount: 3)
        XCTAssertEqual(model.mic.debugErrorMessage, "boom")
        XCTAssertEqual(model.mic.debugErrors, 3)
        XCTAssertEqual(model.mic.level, 0.2, accuracy: 0.001, "unrelated fields untouched")
    }

    func testMicAlertLifecycle() {
        let model = makeModel()
        XCTAssertNil(model.micAlert)
        model.setMicAlert("reconnecting...")
        XCTAssertEqual(model.micAlert, "reconnecting...")
        model.clearMicAlert()
        XCTAssertNil(model.micAlert)
    }

    func testForceAlwaysPublishesEvenWhenCandidateIsIdentical() {
        // `force` is for one-shot, non-buffer-rate callers (reset/stop/
        // restart) that need a GUARANTEED publish, unlike the buffer-rate
        // dedupe path - so force must bypass the `candidate != mic` dedupe
        // too, not just the rest-at-zero gate.
        let model = makeModel()
        model.updateMic(level: 0.5, buffers: 1, frames: 160, pts: 0.01, format: "s16le")
        let afterFirst = model.publishCount
        model.updateMic(level: 0.5, buffers: 1, frames: 160, pts: 0.01, format: "s16le", force: true)
        XCTAssertEqual(model.publishCount, afterFirst + 1, "force must publish even an identical candidate")

        model.updateMic(level: 0.5, buffers: 1, frames: 160, pts: 0.01, format: "s16le")
        XCTAssertEqual(model.publishCount, afterFirst + 1, "immediately repeated without force stays throttled")
    }
}
