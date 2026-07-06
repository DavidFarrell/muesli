import XCTest

final class MeterPublishGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstReadingAlwaysPublishesEvenAtZero() {
        var gate = MeterPublishGate(minPublishInterval: 0.066)
        XCTAssertTrue(gate.shouldPublish(level: 0, now: t0))
    }

    func testTransitionToZeroBypassesThrottle() {
        var gate = MeterPublishGate(minPublishInterval: 1.0)
        XCTAssertTrue(gate.shouldPublish(level: 0.5, now: t0))
        // Immediately after (no time elapsed) - would normally be throttled,
        // but a transition to exactly zero must always get through.
        XCTAssertTrue(gate.shouldPublish(level: 0, now: t0))
    }

    func testSustainedZeroStopsRepublishingAfterFirstLanding() {
        var gate = MeterPublishGate(minPublishInterval: 0.01)
        XCTAssertTrue(gate.shouldPublish(level: 0.5, now: t0))
        XCTAssertTrue(gate.shouldPublish(level: 0, now: t0.addingTimeInterval(1)))
        // At rest at zero now - every subsequent zero reading, even well
        // past the throttle interval, must stay quiet (audit: 2026-07-06
        // livelock - meters "not going quiet" was a persistent invalidation
        // driver).
        XCTAssertFalse(gate.shouldPublish(level: 0, now: t0.addingTimeInterval(2)))
        XCTAssertFalse(gate.shouldPublish(level: 0, now: t0.addingTimeInterval(100)))
    }

    func testNonzeroReadingsStillThrottleNormally() {
        var gate = MeterPublishGate(minPublishInterval: 1.0)
        XCTAssertTrue(gate.shouldPublish(level: 0.2, now: t0))
        XCTAssertFalse(gate.shouldPublish(level: 0.3, now: t0.addingTimeInterval(0.1)), "too soon since last publish")
        XCTAssertTrue(gate.shouldPublish(level: 0.3, now: t0.addingTimeInterval(1.1)))
    }

    func testForceAlwaysPublishesRegardlessOfRestState() {
        var gate = MeterPublishGate(minPublishInterval: 10.0)
        XCTAssertTrue(gate.shouldPublish(level: 0, now: t0))
        XCTAssertFalse(gate.shouldPublish(level: 0, now: t0.addingTimeInterval(0.001)))
        XCTAssertTrue(gate.shouldPublish(level: 0, now: t0.addingTimeInterval(0.002), force: true))
    }

    func testQuantizeRoundsToNearestOnePercent() {
        XCTAssertEqual(MeterPublishGate.quantize(0.1234), 0.12, accuracy: 0.0001)
        XCTAssertEqual(MeterPublishGate.quantize(0.005), 0.01, accuracy: 0.0001)
        XCTAssertEqual(MeterPublishGate.quantize(0.004), 0.0, accuracy: 0.0001)
    }

    func testTinyJitterBelowQuantizationDoesNotBypassAtRestZero() {
        var gate = MeterPublishGate(minPublishInterval: 0.01)
        XCTAssertTrue(gate.shouldPublish(level: 0.5, now: t0))
        XCTAssertTrue(gate.shouldPublish(level: 0.001, now: t0.addingTimeInterval(1)), "quantizes to zero - transition")
        // Sub-quantization jitter around zero must not be mistaken for a
        // fresh transition away from rest.
        XCTAssertFalse(gate.shouldPublish(level: 0.002, now: t0.addingTimeInterval(2)))
    }

    func testRealLevelAfterRestStillThrottlesLikeAnyOtherNonzeroReading() {
        // Only the transition TO zero is exempt from the throttle - a
        // resumed nonzero level is not a special case (matches the
        // pre-existing behaviour this gate replaces).
        var gate = MeterPublishGate(minPublishInterval: 10.0)
        XCTAssertTrue(gate.shouldPublish(level: 0, now: t0))
        XCTAssertFalse(gate.shouldPublish(level: 0, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(gate.shouldPublish(level: 0.4, now: t0.addingTimeInterval(1.001)))
        XCTAssertTrue(gate.shouldPublish(level: 0.4, now: t0.addingTimeInterval(10.001)))
    }
}
