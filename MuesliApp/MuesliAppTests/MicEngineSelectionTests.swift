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

    // MARK: shouldRestartForSelection

    func testNoRestartWhenSameIDAndSameKind() {
        XCTAssertFalse(shouldRestartForSelection(
            desiredID: 42, boundID: 42, desiredUsesCaptureSession: true, currentUsesCaptureSession: true
        ))
        XCTAssertFalse(shouldRestartForSelection(
            desiredID: 7, boundID: 7, desiredUsesCaptureSession: false, currentUsesCaptureSession: false
        ))
    }

    func testRestartsWhenIDChanges() {
        XCTAssertTrue(shouldRestartForSelection(
            desiredID: 42, boundID: 7, desiredUsesCaptureSession: false, currentUsesCaptureSession: false
        ))
    }

    /// THE incident case: pinned device == default at start (AVAudioEngine
    /// bound), the default then moves away - same desiredID, but the kind
    /// that can capture it flips to capture-session.
    func testRestartsOnSameIDKindUpgradeToCaptureSession() {
        XCTAssertTrue(shouldRestartForSelection(
            desiredID: 42, boundID: 42, desiredUsesCaptureSession: true, currentUsesCaptureSession: false
        ))
    }

    /// The reverse: the default comes back onto the pinned device, so
    /// AVAudioEngine+VPIO is preferred again over the capture-session engine.
    func testRestartsOnSameIDKindDowngradeToAVAudioEngine() {
        XCTAssertTrue(shouldRestartForSelection(
            desiredID: 42, boundID: 42, desiredUsesCaptureSession: false, currentUsesCaptureSession: true
        ))
    }

    func testUnresolvedDesiredIDNeverRestarts() {
        XCTAssertFalse(shouldRestartForSelection(
            desiredID: 0, boundID: 42, desiredUsesCaptureSession: true, currentUsesCaptureSession: false
        ))
    }
}
