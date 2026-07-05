import XCTest

final class MicRecoveryLadderTests: XCTestCase {
    func testFirstTwoAttemptsAlwaysRebuild() {
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 1, isPinnedAwayFromDefault: false), .rebuild)
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 1, isPinnedAwayFromDefault: true), .rebuild)
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 2, isPinnedAwayFromDefault: false), .rebuild)
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 2, isPinnedAwayFromDefault: true), .rebuild)
    }

    func testThirdAttemptFallsBackWhenPinnedAwayFromDefault() {
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 3, isPinnedAwayFromDefault: true), .fallbackToSystemDefault)
    }

    func testThirdAttemptGivesUpWhenAlreadyFollowingDefault() {
        // Nothing to fall back to - following-system is already the case, so
        // attempt 3 skips straight to give-up rather than retrying a rebuild
        // that already failed twice.
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 3, isPinnedAwayFromDefault: false), .giveUp)
    }

    func testFourthAttemptAndBeyondAlwaysGivesUp() {
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 4, isPinnedAwayFromDefault: true), .giveUp)
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 4, isPinnedAwayFromDefault: false), .giveUp)
        XCTAssertEqual(MicRecoveryLadder.step(forAttempt: 10, isPinnedAwayFromDefault: true), .giveUp)
    }
}
