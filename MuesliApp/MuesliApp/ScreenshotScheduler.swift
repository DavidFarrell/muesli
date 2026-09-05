import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// One request remains outstanding across stop/start. The OS callback has no
/// deadline/cancellation guarantee; a late reply only releases that request's
/// slot and cannot adopt the current session's destination or event sink.
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
    private let lock = NSLock()
    private var currentStore: SessionArtifactStore?
    private var timer: DispatchSourceTimer?
    private var run: Run?
    private var outstanding: UUID?

    func start(every intervalSeconds: Double, store: SessionArtifactStore,
               request: @escaping Request,
               onCommitted: @escaping @Sendable (ScreenshotArtifact) -> Void) {
        precondition(intervalSeconds.isFinite && intervalSeconds > 0)
        lock.withLock { currentStore?.stopScreenshots(); currentStore = store }
        let newRun = Run(id: UUID(), store: store, request: request, onCommitted: onCommitted)
        queue.async { [self] in
            timer?.cancel()
            run = newRun
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
        guard let run, outstanding == nil else { return }
        let requestID = UUID()
        outstanding = requestID
        run.request { [weak self] image in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.outstanding == requestID else { return }
                self.outstanding = nil
                guard self.run?.id == run.id else { return }
                guard let image else { run.store.recordScreenshotFailure(); return }
                run.store.submitScreenshot(image.image, captureTimeUs: image.captureTimeUs, onCommitted: run.onCommitted)
            }
        }
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
