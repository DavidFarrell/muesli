import XCTest

final class MicDeliverySurfaceDecisionTests: XCTestCase {
    func testFirstFrameAlwaysSurfacesRegardlessOfGap() {
        XCTAssertTrue(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: true, secondsSinceLastFrame: nil, resumptionGapThresholdSeconds: 2.0
        ))
        XCTAssertTrue(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: true, secondsSinceLastFrame: 0.01, resumptionGapThresholdSeconds: 2.0
        ))
    }

    func testNoPriorFrameAndNotFirstFrameDoesNotSurface() {
        // Should not happen in practice (a non-first frame always has a
        // prior lastFrameAt), but the decision must not crash or force a
        // surface on missing data.
        XCTAssertFalse(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: false, secondsSinceLastFrame: nil, resumptionGapThresholdSeconds: 2.0
        ))
    }

    func testShortGapDoesNotSurface() {
        XCTAssertFalse(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: false, secondsSinceLastFrame: 0.5, resumptionGapThresholdSeconds: 2.0
        ))
        XCTAssertFalse(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: false, secondsSinceLastFrame: 2.0, resumptionGapThresholdSeconds: 2.0
        ), "exactly at the threshold must not surface - only strictly greater")
    }

    func testGapBeyondThresholdSurfacesEvenWhenSilent() {
        // The core regression this type fixes: a parked recovery ladder
        // resumes on the SAME generation (no isFirstFrame), and the resumed
        // audio may itself be silent - the gap alone must be enough.
        XCTAssertTrue(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: false, secondsSinceLastFrame: 2.001, resumptionGapThresholdSeconds: 2.0
        ))
        XCTAssertTrue(MicDeliverySurfaceDecision.mustSurface(
            isFirstFrame: false, secondsSinceLastFrame: 60, resumptionGapThresholdSeconds: 2.0
        ))
    }
}
