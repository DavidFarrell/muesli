import XCTest

final class OrphanedMeetingRecoveryTests: XCTestCase {
    private func makeMetadata(
        status: MeetingStatus = .recording,
        durationSeconds: Double = 0,
        sessionEndedAt: Date? = nil
    ) -> MeetingMetadata {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        return MeetingMetadata(
            version: 1,
            title: "2026_07_06 - Meeting 1 - ",
            createdAt: createdAt,
            updatedAt: createdAt,
            durationSeconds: durationSeconds,
            lastTimestamp: 0,
            status: status,
            sessions: [
                MeetingSessionMetadata(
                    sessionID: 1,
                    startedAt: createdAt,
                    endedAt: sessionEndedAt,
                    audioFolder: "audio",
                    streams: [:]
                )
            ],
            segmentCount: 5,
            speakerNames: [:]
        )
    }

    // MARK: needsRecovery

    func testNeedsRecoveryTrueOnlyForRecording() {
        XCTAssertTrue(OrphanedMeetingRecovery.needsRecovery(makeMetadata(status: .recording)))
        XCTAssertFalse(OrphanedMeetingRecovery.needsRecovery(makeMetadata(status: .completed)))
    }

    // MARK: recoveredDuration

    func testRecoveredDurationPrefersWavOverFallbackWhenLarger() {
        let duration = OrphanedMeetingRecovery.recoveredDuration(
            existingDurationSeconds: 0, wavDurationSeconds: 4102, fallbackDurationSeconds: 10
        )
        XCTAssertEqual(duration, 4102)
    }

    func testRecoveredDurationFallsBackWhenWavUnreadable() {
        let duration = OrphanedMeetingRecovery.recoveredDuration(
            existingDurationSeconds: 0, wavDurationSeconds: nil, fallbackDurationSeconds: 42
        )
        XCTAssertEqual(duration, 42)
    }

    func testRecoveredDurationUsesFallbackIfLargerThanWav() {
        // e.g. a screenshot/recording.mp4 artifact outlived the wav for some
        // reason - never report something smaller than the best evidence.
        let duration = OrphanedMeetingRecovery.recoveredDuration(
            existingDurationSeconds: 0, wavDurationSeconds: 100, fallbackDurationSeconds: 250
        )
        XCTAssertEqual(duration, 250)
    }

    func testRecoveredDurationNeverGoesBelowWhatWasAlreadyOnDisk() {
        let duration = OrphanedMeetingRecovery.recoveredDuration(
            existingDurationSeconds: 9999, wavDurationSeconds: 100, fallbackDurationSeconds: 100
        )
        XCTAssertEqual(duration, 9999)
    }

    // MARK: finalize

    func testFinalizeFlipsStatusAndBumpsUpdatedAt() {
        let metadata = makeMetadata()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let result = OrphanedMeetingRecovery.finalize(
            metadata, wavDurationSeconds: 873, fallbackDurationSeconds: 0, now: now
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.updatedAt, now)
        XCTAssertEqual(result.durationSeconds, 873)
    }

    func testFinalizeClosesOpenLastSessionEndedAt() {
        let metadata = makeMetadata(sessionEndedAt: nil)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let result = OrphanedMeetingRecovery.finalize(
            metadata, wavDurationSeconds: 60, fallbackDurationSeconds: 0, now: now
        )
        XCTAssertEqual(result.sessions.last?.endedAt, now)
    }

    func testFinalizeLeavesAlreadyClosedSessionEndedAtUntouched() {
        let existingEnd = Date(timeIntervalSince1970: 1_500_000)
        let metadata = makeMetadata(sessionEndedAt: existingEnd)
        let result = OrphanedMeetingRecovery.finalize(
            metadata, wavDurationSeconds: 60, fallbackDurationSeconds: 0, now: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertEqual(result.sessions.last?.endedAt, existingEnd)
    }

    func testFinalizeLeavesSegmentCountAndTitleUntouched() {
        let metadata = makeMetadata()
        let result = OrphanedMeetingRecovery.finalize(
            metadata, wavDurationSeconds: 60, fallbackDurationSeconds: 0, now: Date()
        )
        XCTAssertEqual(result.segmentCount, metadata.segmentCount)
        XCTAssertEqual(result.title, metadata.title)
    }
}
