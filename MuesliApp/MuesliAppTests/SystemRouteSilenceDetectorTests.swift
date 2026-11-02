import XCTest
import AVFoundation

final class SystemRouteSilenceDetectorTests: XCTestCase {
    private let s: Int64 = 1_000_000

    /// Supervision ticks once a second with fresh buffers; returns the
    /// decisions made, keyed by tick time.
    private func run(_ detector: inout SystemRouteSilenceDetector, from start: Int64, to end: Int64,
                     lastNonZero: (Int64) -> Int64?) -> [(Int64, SystemRouteSilenceDetector.Decision)] {
        var out: [(Int64, SystemRouteSilenceDetector.Decision)] = []
        var t = start
        while t <= end {
            let d = detector.evaluate(nowUs: t, lastCaptureUs: t, lastNonZeroEndUs: lastNonZero(t))
            if d != .none { out.append((t, d)) }
            t += s
        }
        return out
    }

    private func recoveries(_ decisions: [(Int64, SystemRouteSilenceDetector.Decision)]) -> [Int64] {
        decisions.compactMap { if case .recover = $0.1 { return $0.0 } else { return nil } }
    }

    /// Replays the 2 Nov 2026 GuardIAS timeline (seconds into the recording):
    /// a notification at 4430 (audio unaffected) and one at 4515 (samples are
    /// exact zeros from 4518 to the end, callbacks still on time).
    func testIncidentTimelineRecoversOnceAfterSilentRouteChange() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 4430 * s)
        let benign = run(&detector, from: 4430 * s, to: 4470 * s) { $0 }
        XCTAssertTrue(recoveries(benign).isEmpty, "Audio kept flowing after the first notification")
        XCTAssertNil(detector.routeChangeUs, "The unaffected notification expires")

        detector.noteRouteChange(atUs: 4515 * s)
        let silenceStart = 4518 * s
        let decisions = run(&detector, from: 4515 * s, to: 4560 * s) { $0 < silenceStart ? $0 : silenceStart }
        XCTAssertEqual(decisions.first?.1, .suspect)
        XCTAssertEqual(decisions.first?.0, 4521 * s, "Three seconds of zeros raises suspicion")
        XCTAssertEqual(recoveries(decisions), [4523 * s], "Confirmed two seconds later, exactly once")
    }

    func testNotificationStampedBeforeDelayedDeliveryStillMatches() {
        var detector = SystemRouteSilenceDetector()
        // CoreAudio fired at 100 (stamped there); zeros from 101; the main
        // thread only delivered it at 105. The stamp, not delivery, counts.
        detector.noteRouteChange(atUs: 100 * s)
        let decisions = run(&detector, from: 105 * s, to: 115 * s) { _ in 101 * s }
        XCTAssertEqual(recoveries(decisions).count, 1)
    }

    func testLateWatchdogStillActsOnAFaultThatBeganInTheWindow() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // The watchdog was starved until well past the expiry point.
        XCTAssertEqual(detector.evaluate(nowUs: 140 * s, lastCaptureUs: 140 * s, lastNonZeroEndUs: 103 * s), .suspect)
        XCTAssertEqual(detector.evaluate(nowUs: 142 * s, lastCaptureUs: 142 * s, lastNonZeroEndUs: 103 * s),
                       .recover(silentForUs: 39 * s))
    }

    func testMuteLongAfterTheRouteChangeIsNotAFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Audio fine after the change; the other side mutes at 115 (exact zeros).
        let decisions = run(&detector, from: 100 * s, to: 140 * s) { min($0, 115 * s) }
        XCTAssertTrue(recoveries(decisions).isEmpty)
    }

    func testPauseThatEndsBeforeConfirmationIsNotAFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Zeros 101-105 (suspected at 104), speech resumes at 105.
        let decisions = run(&detector, from: 100 * s, to: 130 * s) { $0 < 101 * s ? $0 : ($0 < 105 * s ? 101 * s : $0) }
        XCTAssertTrue(decisions.contains { $0.1 == .suspect })
        XCTAssertTrue(decisions.contains { $0.1 == .cleared })
        XCTAssertTrue(recoveries(decisions).isEmpty)
    }

    func testRealFaultAfterAClearedSuspicionInTheSameWindowRecovers() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Zeros 101-105 (cleared when audio returns), then the persistent fault from 108.
        let decisions = run(&detector, from: 100 * s, to: 130 * s) {
            if $0 < 101 * s { return $0 }
            if $0 < 105 * s { return 101 * s }
            if $0 < 108 * s { return $0 }
            return 108 * s
        }
        XCTAssertTrue(decisions.contains { $0.1 == .cleared })
        XCTAssertEqual(recoveries(decisions), [113 * s], "Suspected at 111, confirmed at 113")
    }

    func testWithdrawalLiftsCooldown() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertEqual(recoveries(run(&detector, from: 100 * s, to: 110 * s) { _ in 101 * s }).count, 1)
        XCTAssertFalse(detector.noteRouteChange(atUs: 110 * s))
        detector.withdrawRequest() // the request was a false alarm
        XCTAssertTrue(detector.noteRouteChange(atUs: 111 * s))
    }

    func testWithdrawalKeepsTheRouteWindowForALaterFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Zeros from 101 -> request at 106; audio resumes 106.5 -> withdrawn at 107;
        // persistent zeros from 108, still inside the original window.
        XCTAssertEqual(recoveries(run(&detector, from: 100 * s, to: 106 * s) { _ in 101 * s }), [106 * s])
        detector.withdrawRequest()
        let later = run(&detector, from: 107 * s, to: 130 * s) { $0 < 108 * s ? $0 : 108 * s }
        XCTAssertEqual(recoveries(later), [113 * s])
    }

    func testQueuedAutomaticRestartIsDroppedAfterWithdrawal() {
        // Queue -> supervision withdraws -> queued restart runs.
        var health = CaptureSourceHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.begin(generation: 5, now: now)
        XCTAssertTrue(health.progress(frames: 160, generation: 5, at: now))
        health.fail("silent", now: now)
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(1), requireContinuousCallbacks: false), "Watchdog queues the restart")
        XCTAssertTrue(CaptureEngine.automaticRestartStillRequired(isAutomatic: true, sourceInvalidated: health.invalidated))
        XCTAssertTrue(health.withdrawRecovery(generation: 5), "Refresh-driven supervision withdraws it")
        XCTAssertFalse(CaptureEngine.automaticRestartStillRequired(isAutomatic: true, sourceInvalidated: health.invalidated),
                       "The queued restart must reserve no video and stop nothing")
        XCTAssertTrue(CaptureEngine.automaticRestartStillRequired(isAutomatic: false, sourceInvalidated: false),
                      "A user-initiated restart is unaffected")
    }

    func testWithdrawalDecisionBeforeNativeStop() {
        XCTAssertTrue(CaptureEngine.audioReturned(pendingGeneration: 4, currentGeneration: 4, runStartUs: 100, lastNonZeroEndUs: 101),
                      "Speech arrived while the restart was queued: cancel before stopping")
        XCTAssertFalse(CaptureEngine.audioReturned(pendingGeneration: 4, currentGeneration: 4, runStartUs: 100, lastNonZeroEndUs: 100))
        XCTAssertFalse(CaptureEngine.audioReturned(pendingGeneration: 4, currentGeneration: 4, runStartUs: 100, lastNonZeroEndUs: nil))
        XCTAssertFalse(CaptureEngine.audioReturned(pendingGeneration: 3, currentGeneration: 4, runStartUs: 100, lastNonZeroEndUs: 500),
                       "A replacement generation's audio says nothing about the old one")
    }

    func testTrailingNotificationAfterRecoveryCannotArmTheReplacement() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertEqual(recoveries(run(&detector, from: 100 * s, to: 110 * s) { _ in 101 * s }).count, 1)
        // Restart: new generation resets the burst but not the cooldown.
        detector.reset()
        XCTAssertFalse(detector.noteRouteChange(atUs: 112 * s), "Same burst, inside the cooldown")
        let after = run(&detector, from: 112 * s, to: 130 * s) { _ in 113 * s }
        XCTAssertTrue(recoveries(after).isEmpty, "An ordinary pause on the replacement cannot restart it again")
        XCTAssertTrue(detector.noteRouteChange(atUs: 200 * s), "A genuinely later route change arms again")
    }

    func testRepeatedNotificationAfterSilenceBeganStillRecovers() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 4515 * s)
        _ = detector.evaluate(nowUs: 4519 * s, lastCaptureUs: 4519 * s, lastNonZeroEndUs: 4518 * s)
        detector.noteRouteChange(atUs: 4519 * s + s / 2)
        let decisions = run(&detector, from: 4520 * s, to: 4530 * s) { _ in 4518 * s }
        XCTAssertEqual(recoveries(decisions).count, 1)
    }

    func testSilenceThatBeganBeforeTheRouteChangeIsNotAFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Nothing has played since t=50 (for example, between calls).
        XCTAssertTrue(recoveries(run(&detector, from: 100 * s, to: 130 * s) { _ in 50 * s }).isEmpty)
    }

    func testNoAudioEverPlayedIsNotAFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertTrue(recoveries(run(&detector, from: 100 * s, to: 130 * s) { _ in nil }).isEmpty)
    }

    func testStaleOrFutureCallbacksDoNotTrigger() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertEqual(detector.evaluate(nowUs: 106 * s, lastCaptureUs: 101 * s, lastNonZeroEndUs: 100 * s), .none,
                       "Buffers stopped arriving: a different condition")
        XCTAssertEqual(detector.evaluate(nowUs: 106 * s, lastCaptureUs: 120 * s, lastNonZeroEndUs: 100 * s), .none,
                       "A timestamp from the future is not fresh evidence")
        XCTAssertEqual(detector.evaluate(nowUs: 103 * s, lastCaptureUs: 104 * s, lastNonZeroEndUs: 101 * s), .none,
                       "One second ahead cannot shorten the required silence")
    }

    func testHealthWithdrawalUntilNativeStop() {
        var health = CaptureSourceHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.begin(generation: 3, now: now)
        XCTAssertTrue(health.progress(frames: 160, generation: 3, at: now))
        health.fail("silent", now: now)
        XCTAssertEqual(health.phase, .recovering)
        XCTAssertFalse(health.withdrawRecovery(generation: 2), "Other generations cannot withdraw")
        XCTAssertTrue(health.withdrawRecovery(generation: 3))
        XCTAssertEqual(health.phase, .healthy)
        XCTAssertTrue(health.progress(frames: 320, generation: 3, at: now), "Progress counts again after withdrawal")
        health.fail("silent", now: now)
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(1), requireContinuousCallbacks: false))
        XCTAssertTrue(health.withdrawRecovery(generation: 3), "A claimed restart can still be cancelled before the native stop")
        XCTAssertEqual(health.phase, .healthy)
    }

    func testProcessorTracksLastNonZeroSampleAndIgnoresDigitalSilence() {
        let processor = MicCaptureProcessor(generation: 1) { _ in }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            pcm.frameLength = 160
            pcm.floatChannelData![0].update(repeating: value, count: 160)
            return pcm
        }
        XCTAssertNil(processor.snapshot().lastNonZeroEndUs)
        for index in 0..<10 { processor.receive(buffer(0.25), captureTimeUs: 1_000_000 + Int64(index) * 10_000) }
        XCTAssertEqual(processor.snapshot().lastNonZeroEndUs, 1_100_000, "End of the tenth 10 ms buffer")
        for index in 10..<400 { processor.receive(buffer(0), captureTimeUs: 1_000_000 + Int64(index) * 10_000) }
        let snapshot = processor.snapshot()
        XCTAssertEqual(snapshot.lastNonZeroEndUs, 1_100_000, "Exact zeros never advance it")
        XCTAssertEqual(snapshot.lastCaptureTimeUs, 4_990_000)
        processor.finish()
    }
}
