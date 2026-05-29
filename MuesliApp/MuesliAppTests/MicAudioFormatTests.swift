import XCTest

final class MicAudioFormatTests: XCTestCase {
    func testRejectsZeroSampleRate() {
        XCTAssertFalse(isUsableInputFormat(sampleRate: 0, channelCount: 1))
    }

    func testRejectsZeroChannels() {
        XCTAssertFalse(isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
    }

    func testAcceptsMono() {
        XCTAssertTrue(isUsableInputFormat(sampleRate: 48_000, channelCount: 1))
    }

    func testAcceptsStereo() {
        XCTAssertTrue(isUsableInputFormat(sampleRate: 48_000, channelCount: 2))
    }
}
