import XCTest

final class DurationFormattingTests: XCTestCase {
    func testUnderAMinuteShowsSecondsOnly() {
        XCTAssertEqual(DurationFormatting.compact(0), "0s")
        XCTAssertEqual(DurationFormatting.compact(45), "45s")
    }

    func testMinutesAndSecondsBelowAnHour() {
        XCTAssertEqual(DurationFormatting.compact(65), "1m 5s")
        XCTAssertEqual(DurationFormatting.compact(3599), "59m 59s")
    }

    func testHoursAndMinutesAtOrAboveAnHour() {
        XCTAssertEqual(DurationFormatting.compact(3600), "1h 0m")
        XCTAssertEqual(DurationFormatting.compact(3900), "1h 5m")
    }

    func testRoundsToNearestSecond() {
        XCTAssertEqual(DurationFormatting.compact(59.6), "1m 0s")
    }
}
