import XCTest

final class MicEngineSelectionTests: XCTestCase {
    func testFollowModeNeverUsesCaptureSession() {
        XCTAssertFalse(shouldUseCaptureSessionEngine(resolvedID: 42, pinned: false, liveDefaultInputID: 7))
    }

    func testUnresolvedDeviceNeverUsesCaptureSession() {
        XCTAssertFalse(shouldUseCaptureSessionEngine(resolvedID: 0, pinned: true, liveDefaultInputID: 7))
    }

    func testPinnedEqualToDefaultUsesAVAudioEngine() {
        XCTAssertFalse(shouldUseCaptureSessionEngine(resolvedID: 7, pinned: true, liveDefaultInputID: 7))
    }

    func testPinnedAwayFromDefaultUsesCaptureSession() {
        XCTAssertTrue(shouldUseCaptureSessionEngine(resolvedID: 42, pinned: true, liveDefaultInputID: 7))
    }
}
