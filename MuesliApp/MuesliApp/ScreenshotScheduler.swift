import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// One request remains outstanding across stop/start. The OS callback has no
/// deadline/cancellation guarantee. The slot requires both invocation return
/// and callback receipt; neither can adopt a new session's destination or sink.
nonisolated final class ScreenshotScheduler: @unchecked Sendable {
    struct Image: @unchecked Sendable {
        let image: CGImage
        let captureTimeUs: Int64
    }
    typealias Request = @Sendable (@escaping @Sendable (Image?) -> Void) -> Void
    private struct Run: Sendable {
        let id: UUID
        let store: SessionArtifactStore
        let request: Request
        let onCommitted: @Sendable (ScreenshotArtifact) -> Void
    }
    private let queue = DispatchQueue(label: "muesli.screenshots", qos: .utility)
    // Framework invocation itself can block before returning, independently
    // of whether its completion callback eventually fires. Keep it off the
    // scheduler/deadline lane, with only one admitted invocation at a time.
    private let requestQueue = DispatchQueue(label: "muesli.screenshot-request", qos: .utility)
    private let lock = NSLock()
    private let requestTimeoutSeconds: Double
    private let now: @Sendable () -> Double
    private var currentStore: SessionArtifactStore?
    private var pendingSince: Double?
    private var timer: DispatchSourceTimer?
    private var requestDeadlineTimer: DispatchSourceTimer?
    private var run: Run?
    private var outstanding: UUID?
    private var invocationReturned = false
    private var callbackReceived = false
    private var unavailableReportedForRun: UUID?

    init(requestTimeoutSeconds: Double = 10,
         now: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) {
        precondition(requestTimeoutSeconds.isFinite && requestTimeoutSeconds > 0)
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.now = now
    }

    func start(every intervalSeconds: Double, store: SessionArtifactStore,
               request: @escaping Request,
               onCommitted: @escaping @Sendable (ScreenshotArtifact) -> Void) {
        precondition(intervalSeconds.isFinite && intervalSeconds > 0)
        let newRun = Run(id: UUID(), store: store, request: request, onCommitted: onCommitted)
        let unavailable = lock.withLock {
            currentStore?.stopScreenshots(); currentStore = store
            return pendingSince.map { now() - $0 >= requestTimeoutSeconds } ?? false
        }
        if unavailable { store.recordScreenshotFailure(ownershipUnavailable: true) }
        queue.async { [self] in
            timer?.cancel()
            run = newRun
            unavailableReportedForRun = unavailable ? newRun.id : nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lock.withLock { currentStore?.stopScreenshots(); currentStore = nil }
        queue.async { [self] in timer?.cancel(); timer = nil; run = nil }
    }

    /// Also used to drive deterministic tests without sleeping for a timer.
    func requestNow() { queue.async { [self] in tick() } }

    private func tick() {
        guard let run else { return }
        guard outstanding == nil else {
            let unavailable = lock.withLock { pendingSince.map { now() - $0 >= requestTimeoutSeconds } ?? false }
            if unavailable, unavailableReportedForRun != run.id {
                unavailableReportedForRun = run.id
                run.store.recordScreenshotFailure(ownershipUnavailable: true)
            }
            return
        }
        let requestID = UUID()
        outstanding = requestID
        invocationReturned = false
        callbackReceived = false
        lock.withLock { pendingSince = now() }
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + requestTimeoutSeconds)
        deadline.setEventHandler { [weak self] in self?.tick() }
        requestDeadlineTimer = deadline
        deadline.resume()
        requestQueue.async { [weak self] in
            run.request { [weak self] image in
                guard let self else { return }
                self.queue.async { [self] in
                    guard self.outstanding == requestID, !self.callbackReceived else { return }
                    self.callbackReceived = true
                    self.releaseResolvedRequest(requestID)
                    guard self.run?.id == run.id else { return }
                    guard let image else { run.store.recordScreenshotFailure(); return }
                    run.store.submitScreenshot(image.image, captureTimeUs: image.captureTimeUs, onCommitted: run.onCommitted)
                }
            }
            self?.queue.async { [weak self] in
                guard let self, self.outstanding == requestID else { return }
                self.invocationReturned = true
                self.releaseResolvedRequest(requestID)
            }
        }
    }

    private func releaseResolvedRequest(_ requestID: UUID) {
        guard outstanding == requestID, invocationReturned, callbackReceived else { return }
        outstanding = nil
        requestDeadlineTimer?.cancel()
        requestDeadlineTimer = nil
        lock.withLock { pendingSince = nil }
    }

    /// ScreenCaptureKit objects are immutable after setup and used by this
    /// request owner. Conversion runs on the reply queue, never on MainActor.
    final class NativeRequest: @unchecked Sendable {
        private let filter: SCContentFilter
        private let configuration: SCStreamConfiguration
        private let queue = DispatchQueue(label: "muesli.screenshot-image", qos: .utility)
        private let context = CIContext()
        init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
            self.filter = filter
            self.configuration = configuration
        }
        private struct Sample: @unchecked Sendable { let buffer: CMSampleBuffer }
        func capture(_ reply: @escaping @Sendable (Image?) -> Void) {
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration) { [self] sample, error in
                guard error == nil, let sample else { reply(nil); return }
                let owned = Sample(buffer: sample)
                queue.async { [self] in
                    guard let time = CaptureTimeline.microseconds(owned.buffer.presentationTimeStamp),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(owned.buffer) else { reply(nil); return }
                    let image = CIImage(cvImageBuffer: pixelBuffer)
                    guard let cg = context.createCGImage(image, from: image.extent) else { reply(nil); return }
                    reply(Image(image: cg, captureTimeUs: time))
                }
            }
        }
    }
}
