import XCTest

final class AECModeTests: XCTestCase {
    func testOffNeverRequestsVoiceProcessing() {
        XCTAssertFalse(shouldRequestVoiceProcessing(mode: .off, outputIsBuiltInSpeaker: true))
        XCTAssertFalse(shouldRequestVoiceProcessing(mode: .off, outputIsBuiltInSpeaker: false))
    }

    func testOnAlwaysRequestsVoiceProcessing() {
        XCTAssertTrue(shouldRequestVoiceProcessing(mode: .on, outputIsBuiltInSpeaker: true))
        XCTAssertTrue(shouldRequestVoiceProcessing(mode: .on, outputIsBuiltInSpeaker: false))
    }

    func testAutoMirrorsBuiltInSpeaker() {
        XCTAssertTrue(shouldRequestVoiceProcessing(mode: .auto, outputIsBuiltInSpeaker: true))
        XCTAssertFalse(shouldRequestVoiceProcessing(mode: .auto, outputIsBuiltInSpeaker: false))
    }
}
