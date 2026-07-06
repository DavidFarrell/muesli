import Foundation

/// Owns backend.log file writes and the ring buffer of recent lines shown by
/// "Copy debug" (`AppModel.debugSummary`). Everything is serialized through
/// one private queue so `AudioLog.sink` - fed from arbitrary queues
/// (CoreAudio device listeners, mic-engine actors, a MainActor heartbeat
/// every ~2s) - never needs to hop to MainActor just to keep the log tail
/// current.
///
/// Audit (2026-07-06 livelock post-mortem): the old design kept the tail as
/// an `@Published [String]` on `AppModel`, appended via
/// `Task { @MainActor in ... }` for EVERY `AudioLog` line - an AppModel-wide
/// invalidation drumbeat with zero live UI readers (only "Copy debug" ever
/// reads it). Moving both the ring buffer and the file I/O off MainActor
/// removes that drumbeat entirely and means backend.log can keep being
/// written even if the main thread is wedged.
final class BackendLogWriter {
    private let queue = DispatchQueue(label: "muesli.backend-log", qos: .utility)
    private var handle: FileHandle?
    private var ringBuffer: [String] = []
    private let ringBufferLimit: Int

    init(ringBufferLimit: Int) {
        self.ringBufferLimit = ringBufferLimit
    }

    /// Adopt a freshly-opened log file and clear the tail (new meeting).
    func reset(handle: FileHandle?) {
        queue.async { [self] in
            self.handle = handle
            ringBuffer.removeAll()
        }
    }

    /// Fire-and-forget: never blocks the caller. `overrideHandle` lets a
    /// caller write into a specific (possibly already-superseded) handle
    /// rather than whichever one is "current" - mirrors the escape hatch the
    /// pre-existing `appendBackendLog(handle:)` API already relied on for
    /// in-flight callbacks from a session that has started tearing down.
    func append(_ line: String, toTail: Bool, handle overrideHandle: FileHandle? = nil) {
        queue.async { [self] in
            appendOnQueue(line, toTail: toTail, handle: overrideHandle ?? handle)
        }
    }

    private func appendOnQueue(_ line: String, toTail: Bool, handle target: FileHandle?) {
        if let data = (line + "\n").data(using: .utf8), let target {
            do {
                try target.write(contentsOf: data)
            } catch {
                if toTail {
                    appendTailOnQueue("[backend.log write failed] \(error.localizedDescription)")
                }
            }
        }
        guard toTail else { return }
        appendTailOnQueue(line)
    }

    private func appendTailOnQueue(_ line: String) {
        ringBuffer.append(line)
        if ringBuffer.count > ringBufferLimit {
            ringBuffer.removeFirst(ringBuffer.count - ringBufferLimit)
        }
    }

    /// Best-effort fsync, ordered after any writes already queued.
    func synchronize(label: String) {
        queue.async { [self] in
            guard let handle else { return }
            do {
                try handle.synchronize()
            } catch {
                appendTailOnQueue("Failed to flush \(label): \(error.localizedDescription)")
            }
        }
    }

    /// Closes the current handle, ordered after any writes already queued on
    /// this same serial queue - so a close from meeting-stop teardown can
    /// never race an in-flight write to the same file (this is why close
    /// must go through the writer's queue rather than a bare
    /// `handle.close()` from MainActor).
    func close() {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }

    /// Synchronous snapshot for the "Copy debug" button - a manual, rare,
    /// MainActor-initiated read, not a hot path, so blocking briefly on this
    /// queue is fine (mirrors `CaptureEngine.AudioStateStore.withState`'s
    /// use of `queue.sync` for the same kind of cross-queue read).
    func tailSnapshot(limit: Int) -> [String] {
        queue.sync { Array(ringBuffer.suffix(limit)) }
    }
}
