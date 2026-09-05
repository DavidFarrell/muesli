import XCTest
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class SessionArtifactStoreTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func pixel() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
    private func store(_ folder: URL, offset: Int64 = 0,
                       png: SessionArtifactStore.PNGWriter? = nil) throws -> SessionArtifactStore {
        if let png {
            return try SessionArtifactStore(meetingDirectory: folder, sourceSessionID: UUID().uuidString,
                timeline: CaptureTimeline(epochMicroseconds: 1_000_000), timelineOffsetUs: offset, pngWriter: png)
        }
        return try SessionArtifactStore(meetingDirectory: folder, sourceSessionID: UUID().uuidString,
            timeline: CaptureTimeline(epochMicroseconds: 1_000_000), timelineOffsetUs: offset)
    }
    private func ledger(_ store: SessionArtifactStore) throws -> [[String: Any]] {
        try String(contentsOf: store.directory.appendingPathComponent("assets.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    nonisolated private final class Requests: @unchecked Sendable {
        let lock = NSLock()
        var replies: [@Sendable (ScreenshotScheduler.Image?) -> Void] = []
        let received = DispatchSemaphore(value: 0)
        func request(_ reply: @escaping @Sendable (ScreenshotScheduler.Image?) -> Void) {
            lock.withLock { replies.append(reply) }; received.signal()
        }
        func reply(_ image: ScreenshotScheduler.Image) {
            let callback = lock.withLock { replies.removeFirst() }; callback(image)
        }
        var count: Int { lock.withLock { replies.count } }
    }

    func testThreeSessionsUseUniquePathsAndCommonOffsets() async throws {
        let folder = try folder()
        var paths: [String] = []
        for offset in [0, 10_000_000, 25_000_000] {
            let store = try store(folder, offset: Int64(offset))
            let event = expectation(description: "committed screenshot")
            let expectedTime = Double(offset) / 1_000_000 + 2
            XCTAssertTrue(store.submitScreenshot(pixel(), captureTimeUs: 3_000_000) { screenshot in
                XCTAssertEqual(screenshot.t, expectedTime)
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(screenshot.path).path))
                event.fulfill()
            })
            await fulfillment(of: [event], timeout: 3)
            let result = await store.finish(timeoutSeconds: 3)
            XCTAssertTrue(result.status.isComplete)
            let row = try XCTUnwrap(ledger(store).last)
            paths.append(try XCTUnwrap(row["path"] as? String))
            XCTAssertEqual(row["t"] as? Double, expectedTime)
        }
        XCTAssertEqual(Set(paths).count, 3)
    }

    func testPNGFailureNeverCommitsOrEmitsScreenshot() async throws {
        let store = try store(folder())
        let screenshots = store.directory.appendingPathComponent("screenshots")
        // Make the actual ImageIO destination fail, using only this fixture's
        // directory. The production PNG encoder and error checks still run.
        try FileManager.default.removeItem(at: screenshots)
        try Data([0]).write(to: screenshots)
        let event = expectation(description: "no false screenshot"); event.isInverted = true
        XCTAssertTrue(store.submitScreenshot(pixel(), captureTimeUs: 2_000_000) { _ in event.fulfill() })
        await fulfillment(of: [event], timeout: 0.1)
        let result = await store.finish(timeoutSeconds: 2)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertEqual(result.status.committedScreenshots, 0)
        XCTAssertEqual(try ledger(store).last?["kind"] as? String, "screenshot_write")
    }

    func testVideoReservationsStayUniqueAcrossTwoResumes() async throws {
        let folder = try folder()
        let stores = try (0..<3).map { _ in try store(folder) }
        let urls = try stores.map { try XCTUnwrap($0.nextVideoURL()) }
        XCTAssertEqual(Set(urls).count, 3)
        XCTAssertEqual(Set(urls.map { $0.deletingLastPathComponent() }).count, 3)
        for store in stores {
            let result = await store.finish(timeoutSeconds: 2)
            XCTAssertFalse(result.status.isComplete, "reservation is not evidence of a real output")
        }
    }

    func testStopDuringEncodingSuppressesLateSuccess() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let store = try store(folder(), png: { _, _ in entered.signal(); _ = release.wait(timeout: .now() + 3) })
        let event = expectation(description: "stopped result"); event.isInverted = true
        store.submitScreenshot(pixel(), captureTimeUs: 2_000_000) { _ in event.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        store.stopScreenshots()
        release.signal()
        await fulfillment(of: [event], timeout: 0.1)
        let result = await store.finish(timeoutSeconds: 2)
        XCTAssertEqual(result.status.committedScreenshots, 0)
        XCTAssertEqual(try ledger(store).count, 1)
    }

    func testOneOutstandingRequestSurvivesStopAndTwoResumes() async throws {
        let folder = try folder(), scheduler = ScreenshotScheduler(), requests = Requests()
        let stores = try (0..<3).map { _ in try store(folder) }
        let stale = expectation(description: "old screenshot"); stale.isInverted = true
        scheduler.start(every: 60, store: stores[0], request: requests.request) { _ in stale.fulfill() }
        scheduler.requestNow()
        XCTAssertEqual(requests.received.wait(timeout: .now() + 2), .success)
        for store in stores.dropFirst() {
            scheduler.stop()
            scheduler.start(every: 60, store: store, request: requests.request) { _ in stale.fulfill() }
            scheduler.requestNow()
        }
        // This barrier is another request job; it cannot admit while the first
        // framework callback owns the slot.
        XCTAssertEqual(requests.received.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertEqual(requests.count, 1)
        requests.reply(.init(image: pixel(), captureTimeUs: 2_000_000))
        await fulfillment(of: [stale], timeout: 0.1)
        for store in stores { XCTAssertEqual(try ledger(store).count, 1) }
        scheduler.stop()
        for store in stores { _ = await store.finish(timeoutSeconds: 2) }
    }

    func testVideoTimeoutThenRealSDKCompletionPersistsOriginalOutput() async throws {
        let store = try store(folder())
        let url = try XCTUnwrap(store.nextVideoURL())
        try Data([1, 2, 3]).write(to: url)
        let delegate = RecordingDelegate(url: url)
        let configuration = SCRecordingOutputConfiguration(); configuration.outputURL = url
        let output = SCRecordingOutput(configuration: configuration, delegate: delegate)
        store.retainRecording(delegate)
        // Native startup can be delayed arbitrarily after URL reservation.
        // Neither reservation nor SDK start callback supplies first-frame PTS.
        try await Task.sleep(for: .milliseconds(20))
        delegate.recordingOutputDidStartRecording(output)
        guard case .timedOut(let pending) = await store.finish(timeoutSeconds: 0.02) else { return XCTFail("missing SDK finish") }
        XCTAssertEqual(pending.pendingVideos, 1)
        XCTAssertThrowsError(try SessionArtifactStore.acquireInactiveLease(directory: store.directory))
        XCTAssertNil(store.nextVideoURL())
        delegate.recordingOutputDidFinishRecording(output)
        guard case .completed(let status) = await store.finish(timeoutSeconds: 2) else { return XCTFail("late completion") }
        XCTAssertTrue(status.isComplete)
        XCTAssertEqual(status.finishedVideos, 1)
        let inactiveLease = try SessionArtifactStore.acquireInactiveLease(directory: store.directory)
        try inactiveLease?.close()
        XCTAssertEqual(try ledger(store).last?["status"] as? String, "finished")
        XCTAssertNotNil(try ledger(store).last?["requested_t"])
        XCTAssertNil(try ledger(store).last?["t"])
        XCTAssertNil(status.mediaEndSeconds)
    }

    func testDroppingUnusedArtifactStoreReleasesKernelLease() throws {
        var current: SessionArtifactStore? = try store(folder())
        let directory = try XCTUnwrap(current?.directory)
        XCTAssertThrowsError(try SessionArtifactStore.acquireInactiveLease(directory: directory))
        current = nil
        let released = try SessionArtifactStore.acquireInactiveLease(directory: directory)
        XCTAssertNotNil(released)
        try released?.close()
    }

    func testNativeFailureAndUnregisteredReservationRemainIncomplete() async throws {
        let store = try store(folder()), url = try XCTUnwrap(store.nextVideoURL())
        let delegate = RecordingDelegate(url: url)
        store.retainRecording(delegate)
        delegate.recordingSetupFailed(NSError(domain: "native", code: 3))
        let result = await store.finish(timeoutSeconds: 2)
        XCTAssertFalse(result.status.isComplete)
        XCTAssertEqual(try ledger(store).last?["status"] as? String, "failed")
        let other = try self.store(folder())
        for _ in 0..<16 { XCTAssertNotNil(other.nextVideoURL()) }
        XCTAssertNil(other.nextVideoURL())
        let unregistered = await other.finish(timeoutSeconds: 2)
        XCTAssertFalse(unregistered.status.isComplete)
        XCTAssertEqual(try ledger(other).last?["kind"] as? String, "video_not_created")
    }

    func testCaptureFailureIsDurableWithoutDisablingLaterScreenshotOrVideo() async throws {
        let store = try store(folder())
        store.recordScreenshotFailure()
        XCTAssertNotNil(store.nextVideoURL(), "screenshot failure cannot park system recovery")
        let event = expectation(description: "healthy screenshot after failure")
        XCTAssertTrue(store.submitScreenshot(pixel(), captureTimeUs: 2_000_000) { _ in event.fulfill() })
        await fulfillment(of: [event], timeout: 2)
        let result = await store.finish(timeoutSeconds: 2)
        XCTAssertFalse(result.status.isComplete, "prior failed artifact remains a truthful degraded outcome")
        let rows = try ledger(store)
        XCTAssertTrue(rows.contains { $0["kind"] as? String == "screenshot_capture" })
        XCTAssertTrue(rows.contains { $0["type"] as? String == "screenshot" })
    }

    func testNeverReturningRequestIsReportedToEveryLaterSessionWithoutExtraRequest() async throws {
        nonisolated final class Time: @unchecked Sendable {
            let lock = NSLock(); var value = 0.0
            nonisolated func read() -> Double { lock.withLock { value } }
            nonisolated func advance() { lock.withLock { value = 20 } }
        }
        let time = Time(), requests = Requests(), root = try folder()
        let scheduler = ScreenshotScheduler(requestTimeoutSeconds: 10, now: time.read)
        let first = try store(root)
        scheduler.start(every: 60, store: first, request: requests.request) { _ in XCTFail("no reply") }
        scheduler.requestNow()
        XCTAssertEqual(requests.received.wait(timeout: .now() + 2), .success)
        time.advance()
        scheduler.requestNow()
        // Request queue processing reports expiration before this barrier can
        // produce another request; the unresolved SDK owner is still retained.
        XCTAssertEqual(requests.received.wait(timeout: .now() + 0.1), .timedOut)
        scheduler.stop()
        let firstResult = await first.finish(timeoutSeconds: 2)
        XCTAssertFalse(firstResult.status.isComplete)
        let second = try store(root)
        scheduler.start(every: 60, store: second, request: requests.request) { _ in XCTFail("no reply") }
        scheduler.requestNow()
        XCTAssertEqual(requests.received.wait(timeout: .now() + 0.1), .timedOut)
        scheduler.stop()
        let secondResult = await second.finish(timeoutSeconds: 2)
        XCTAssertFalse(secondResult.status.isComplete)
        XCTAssertEqual(requests.count, 1)
        for store in [first, second] {
            XCTAssertTrue(try ledger(store).contains { $0["kind"] as? String == "screenshot_unavailable" })
        }
    }

    func testBlockedNativeInvocationCannotBlockDeadlineOrAdmitAnotherRequest() async throws {
        try await assertBlockedInvocationIsReported(callbackBeforeBlocking: false)
    }

    func testEarlyCallbackCannotReleaseAnInvocationThatStillBlocks() async throws {
        try await assertBlockedInvocationIsReported(callbackBeforeBlocking: true)
    }

    private func assertBlockedInvocationIsReported(callbackBeforeBlocking: Bool) async throws {
        nonisolated final class Invocation: @unchecked Sendable {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let returned = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var count = 0
            func invoke(_ reply: @escaping @Sendable (ScreenshotScheduler.Image?) -> Void, early: Bool) {
                lock.withLock { count += 1 }
                if early { reply(nil) }
                entered.signal()
                // Fail-safe release: a regression cannot leave a blocked test
                // worker or suspend XCTest indefinitely.
                _ = release.wait(timeout: .now() + 5)
                if !early { reply(nil) }
                returned.signal()
            }
            var invocationCount: Int { lock.withLock { count } }
        }
        let invocation = Invocation(), root = try folder()
        defer { invocation.release.signal() }
        let scheduler = ScreenshotScheduler(requestTimeoutSeconds: 0.05)
        let first = try store(root)
        let request: ScreenshotScheduler.Request = { reply in invocation.invoke(reply, early: callbackBeforeBlocking) }
        scheduler.start(every: 60, store: first, request: request) { _ in XCTFail("unexpected image") }
        scheduler.requestNow()
        XCTAssertEqual(invocation.entered.wait(timeout: .now() + 2), .success)
        // Only the independent deadline can report this: no scheduler tick is
        // manually requested after the invocation blocks.
        try await Task.sleep(for: .milliseconds(150))
        let firstResult = await first.finish(timeoutSeconds: 1)
        XCTAssertFalse(firstResult.status.isComplete)
        XCTAssertTrue(try ledger(first).contains { $0["kind"] as? String == "screenshot_unavailable" })
        XCTAssertEqual(invocation.returned.wait(timeout: .now()), .timedOut,
                       "the failure must be durable while native invocation is still blocked")

        scheduler.stop()
        let second = try store(root)
        scheduler.start(every: 60, store: second, request: request) { _ in XCTFail("unexpected image") }
        for _ in 0..<20 { scheduler.requestNow() }
        let secondResult = await second.finish(timeoutSeconds: 1)
        XCTAssertFalse(secondResult.status.isComplete)
        XCTAssertTrue(try ledger(second).contains { $0["kind"] as? String == "screenshot_unavailable" })
        XCTAssertEqual(invocation.invocationCount, 1)
        scheduler.stop()
        invocation.release.signal()
        XCTAssertEqual(invocation.returned.wait(timeout: .now() + 2), .success)
    }
}
