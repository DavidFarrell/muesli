import Foundation
import ScreenCaptureKit
import CoreMedia

nonisolated struct RecordingArtifactSnapshot: Sendable, Equatable {
    enum Status: String, Codable, Sendable { case requested, recording, finished, failed }
    let id: UUID
    let url: URL
    let status: Status
    let durationSeconds: Double?
    let fileSize: Int64?
    let error: String?
}

nonisolated enum RecordingArtifactWaitResult: Sendable {
    case finished(RecordingArtifactSnapshot)
    case failed(RecordingArtifactSnapshot)
    case timedOut(RecordingArtifactSnapshot)
    case cancelled(RecordingArtifactSnapshot)

    var snapshot: RecordingArtifactSnapshot {
        switch self {
        case .finished(let value), .failed(let value), .timedOut(let value), .cancelled(let value): return value
        }
    }
}

/// One delegate per recording output. SDK finish/failure callbacks are the
/// completion authority; SCStream.stopCapture returning is not. An expired
/// wait leaves this owner alive and a late callback remains observable.
nonisolated final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let lock = NSLock()
    private let completion = TaskCompletion()
    private var status: RecordingArtifactSnapshot.Status = .requested
    private var durationSeconds: Double?
    private var fileSize: Int64?
    private var failure: String?
    private var observer: (@Sendable (RecordingArtifactSnapshot) -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock {
            guard status == .requested else { return }
            status = .recording
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let duration = CMTimeGetSeconds(recordingOutput.recordedDuration)
        let size = recordingOutput.recordedFileSize
        let changed = lock.withLock {
            guard status != .finished && status != .failed else { return false }
            status = .finished
            durationSeconds = duration.isFinite && duration >= 0 ? duration : nil
            fileSize = size >= 0 ? Int64(size) : nil
            return true
        }
        if changed { publishCompletion() }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        recordingSetupFailed(error)
    }

    /// Construction/add-output/start errors can happen before the SDK sends
    /// its own recording callback. Preserve that explicit failure as well.
    func recordingSetupFailed(_ error: Error) {
        let changed = lock.withLock {
            guard status != .finished && status != .failed else { return false }
            status = .failed
            failure = error.localizedDescription
            return true
        }
        if changed { publishCompletion() }
    }

    func snapshot() -> RecordingArtifactSnapshot {
        lock.withLock {
            RecordingArtifactSnapshot(id: id, url: url, status: status,
                                      durationSeconds: durationSeconds, fileSize: fileSize, error: failure)
        }
    }

    /// One artifact owner receives the terminal event even if it subscribes
    /// after the SDK callback. Delivery is outside the state lock.
    func observeCompletion(_ callback: @escaping @Sendable (RecordingArtifactSnapshot) -> Void) {
        let immediate = lock.withLock {
            if status == .finished || status == .failed { return true }
            precondition(observer == nil)
            observer = callback
            return false
        }
        if immediate { callback(snapshot()) }
    }

    private func publishCompletion() {
        let callback = lock.withLock { let value = observer; observer = nil; return value }
        completion.markCompleted()
        callback?(snapshot())
    }

    @concurrent func waitForCompletion(timeoutSeconds: Double) async -> RecordingArtifactWaitResult {
        switch await completion.wait(timeoutSeconds: timeoutSeconds) {
        case .completed:
            let value = snapshot()
            return value.status == .finished ? .finished(value) : .failed(value)
        case .timedOut: return .timedOut(snapshot())
        case .cancelled: return .cancelled(snapshot())
        }
    }
}
