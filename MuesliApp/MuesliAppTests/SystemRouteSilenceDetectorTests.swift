import XCTest
import AVFoundation

final class SystemRouteSilenceDetectorTests: XCTestCase {
    private let s: Int64 = 1_000_000

    /// Replays the 2 Nov 2026 GuardIAS timeline (seconds into the recording):
    /// route notifications at 4430 (audio unaffected) and 4515 (samples are
    /// exact zeros from 4518 to the end, callbacks still on time).
    func testIncidentTimelineRecoversOnceAfterSilentRouteChange() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 4430 * s)
        // Audio keeps flowing after the first notification: never recover.
        var t: Int64 = 4430 * s
        while t <= 4466 * s {
            if case .recover = detector.evaluate(nowUs: t, lastCaptureUs: t - s / 10, lastNonZeroEndUs: t) { XCTFail("false recovery at \(t)") }
            t += s
        }
        XCTAssertNil(detector.routeChangeUs, "The unaffected notification expires")

        detector.noteRouteChange(atUs: 4515 * s)
        let silenceStart = 4518 * s
        XCTAssertEqual(detector.evaluate(nowUs: 4520 * s, lastCaptureUs: 4520 * s, lastNonZeroEndUs: silenceStart), .none,
                       "Two seconds of zeros is below the threshold")
        XCTAssertEqual(detector.evaluate(nowUs: 4521 * s, lastCaptureUs: 4521 * s, lastNonZeroEndUs: silenceStart),
                       .recover(silentForUs: 3 * s))
        XCTAssertEqual(detector.evaluate(nowUs: 4530 * s, lastCaptureUs: 4530 * s, lastNonZeroEndUs: silenceStart), .none,
                       "One recovery request per notification")
    }

    func testRepeatedNotificationAfterSilenceBeganStillRecovers() {
        var detector = SystemRouteSilenceDetector()
        // One burst: fires at 4515 and again at 4519, after zeros began at 4518.
        detector.noteRouteChange(atUs: 4515 * s)
        XCTAssertEqual(detector.evaluate(nowUs: 4519 * s, lastCaptureUs: 4519 * s, lastNonZeroEndUs: 4518 * s), .none)
        detector.noteRouteChange(atUs: 4519 * s + s / 2)
        XCTAssertEqual(detector.evaluate(nowUs: 4521 * s, lastCaptureUs: 4521 * s, lastNonZeroEndUs: 4518 * s),
                       .recover(silentForUs: 3 * s))
    }

    func testLaterNotificationExtendsTheWindow() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        detector.noteRouteChange(atUs: 125 * s)
        // Zeros begin 31 s after the first fire but 6 s after the latest.
        XCTAssertEqual(detector.evaluate(nowUs: 134 * s, lastCaptureUs: 134 * s, lastNonZeroEndUs: 131 * s),
                       .recover(silentForUs: 3 * s))
    }

    func testSilenceThatBeganBeforeTheRouteChangeIsNotAFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Nothing has played since t=50 (for example, between calls).
        XCTAssertEqual(detector.evaluate(nowUs: 110 * s, lastCaptureUs: 110 * s, lastNonZeroEndUs: 50 * s), .none)
    }

    func testNoAudioEverPlayedIsNotAFault() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertEqual(detector.evaluate(nowUs: 110 * s, lastCaptureUs: 110 * s, lastNonZeroEndUs: nil), .none)
    }

    func testStaleCallbacksDoNotTrigger() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        // Buffers stopped arriving at 101; that is a different condition.
        XCTAssertEqual(detector.evaluate(nowUs: 106 * s, lastCaptureUs: 101 * s, lastNonZeroEndUs: 100 * s), .none)
    }

    func testSilenceBeginningJustBeforeTheNotificationCounts() {
        var detector = SystemRouteSilenceDetector()
        // The device can change a fraction of a second before CoreAudio notifies.
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertEqual(detector.evaluate(nowUs: 103 * s, lastCaptureUs: 103 * s, lastNonZeroEndUs: 100 * s - s / 2),
                       .recover(silentForUs: 3 * s + s / 2))
    }

    func testNotificationExpiresWithoutSilence() {
        var detector = SystemRouteSilenceDetector()
        detector.noteRouteChange(atUs: 100 * s)
        XCTAssertEqual(detector.evaluate(nowUs: 136 * s, lastCaptureUs: 136 * s, lastNonZeroEndUs: 136 * s), .expired)
        XCTAssertEqual(detector.evaluate(nowUs: 137 * s, lastCaptureUs: 137 * s, lastNonZeroEndUs: 100 * s), .none)
    }

    func testRecoveryRequestArmsTheExistingHealthRetryPath() {
        var health = CaptureSourceHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.begin(generation: 3, now: now)
        XCTAssertTrue(health.progress(frames: 160, generation: 3, at: now))
        health.fail("System audio went silent after an output-device change; restarting system capture.", now: now)
        XCTAssertEqual(health.phase, .recovering)
        XCTAssertTrue(health.shouldRecover(now: now.addingTimeInterval(1), requireContinuousCallbacks: false))
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
