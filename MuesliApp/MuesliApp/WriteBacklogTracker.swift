import Foundation

/// Pure bookkeeping for `FramedWriter`'s backpressure detection - the
/// 2026-07-16 total-loss incident's earliest possible alarm (RCA rec #2,
/// `engineer-notes/bug-2026-07-16-stop-device-change/RCA-2026-07-16.md`).
///
/// The failure signature it detects: the Python backend is alive but not
/// reading its stdin, so the ~64KB OS pipe fills within seconds and
/// `FileHandle.write` BLOCKS on the writer's serial queue - it never throws,
/// so `onWriteError` never fires, and every later frame piles up as a
/// retained payload in a queued work item (~100MB over the incident's 26
/// minutes). Two responsibilities, both pure so they're unit-testable
/// without a real pipe:
///
/// 1. **Stall detection**: work has been enqueued but no write has COMPLETED
///    for `stallThresholdSeconds`. A healthy consumer completes writes
///    near-continuously, so "outstanding work + no completion progress" is
///    specific to the blocked-pipe state.
/// 2. **Backlog cap**: beyond `maxOutstandingBytes` of un-completed writes,
///    droppable (audio) frames are dropped WITH accounting instead of
///    enqueued, so a wedged child bounds memory at the cap instead of
///    growing without limit. Control frames (meeting start/stop, screenshot
///    events - tiny and semantically load-bearing) are never dropped.
///
/// Mutated only under `FramedWriter`'s state lock; takes explicit `now:`
/// dates rather than reading the clock so tests control time (same pattern
/// as `MeterPublishGate`).
struct WriteBacklogTracker {
    /// Default cap ≈ 32s of two-stream 16kHz mono int16 audio (64KB/s).
    /// Deliberately generous: a healthy backend keeps the backlog near zero,
    /// and a transient consumer pause (disk hiccup mid `write_aligned_audio`)
    /// should delay audio, never drop it - only a genuinely wedged child
    /// accumulates this much. Bounded enough that the incident's ~100MB of
    /// retained payloads can never recur.
    static let defaultMaxOutstandingBytes = 2 * 1024 * 1024
    /// Default stall threshold. The pipe fills ~2s after the consumer stops
    /// reading, so 5s of zero completions with work queued is unambiguous -
    /// while staying comfortably above any per-frame write latency a healthy
    /// consumer could show.
    static let defaultStallThresholdSeconds: TimeInterval = 5.0

    let maxOutstandingBytes: Int
    let stallThresholdSeconds: TimeInterval

    private(set) var outstandingFrames = 0
    private(set) var outstandingBytes = 0
    private(set) var droppedFrames = 0
    private(set) var droppedBytes = 0
    private(set) var totalEnqueuedFrames = 0
    private(set) var totalCompletedFrames = 0
    /// The stall clock's reference point: the last time the queue provably
    /// made progress (a write completed), or - when work is enqueued onto an
    /// idle queue - the moment that work arrived. Nil until the first
    /// enqueue.
    private(set) var lastProgressAt: Date?

    init(
        maxOutstandingBytes: Int = WriteBacklogTracker.defaultMaxOutstandingBytes,
        stallThresholdSeconds: TimeInterval = WriteBacklogTracker.defaultStallThresholdSeconds
    ) {
        self.maxOutstandingBytes = maxOutstandingBytes
        self.stallThresholdSeconds = stallThresholdSeconds
    }

    /// Decide whether a frame may be enqueued. Returns `false` (drop, with
    /// accounting) when the frame is droppable and admitting it would push
    /// the outstanding backlog past the cap. Never drops non-droppable
    /// (control) frames.
    mutating func recordEnqueue(bytes: Int, droppable: Bool, now: Date) -> Bool {
        if droppable, outstandingBytes + bytes > maxOutstandingBytes {
            droppedFrames += 1
            droppedBytes += bytes
            return false
        }
        if outstandingFrames == 0 {
            // Enqueue onto an idle queue starts the stall clock - without
            // this, a queue that NEVER completes a single write (wedged from
            // frame one, the incident's exact shape) would have no reference
            // point and never read as stalled.
            lastProgressAt = now
        }
        outstandingFrames += 1
        outstandingBytes += bytes
        totalEnqueuedFrames += 1
        return true
    }

    /// A queued write finished (successfully OR by throwing - either way the
    /// serial queue made progress and is not blocked).
    mutating func recordCompletion(bytes: Int, now: Date) {
        outstandingFrames = max(0, outstandingFrames - 1)
        outstandingBytes = max(0, outstandingBytes - bytes)
        totalCompletedFrames += 1
        lastProgressAt = now
    }

    /// True when work is queued but nothing has completed for longer than
    /// the threshold - the reader is alive-but-not-reading. An idle queue is
    /// never stalled, however long it idles.
    func isStalled(now: Date) -> Bool {
        guard outstandingFrames > 0, let last = lastProgressAt else { return false }
        return now.timeIntervalSince(last) > stallThresholdSeconds
    }

    /// Seconds since the queue last made progress; nil before any activity.
    /// Diagnostic companion to `isStalled` for the `writequeue.stalled` log.
    func secondsSinceLastProgress(now: Date) -> TimeInterval? {
        lastProgressAt.map { now.timeIntervalSince($0) }
    }

    /// Sustained-no-progress check for the post-stop escalation decision
    /// (gate BLOCKER 4 on the 2026-07-16 slice): true only when work is
    /// outstanding NOW and nothing has completed for at least `seconds`.
    /// Purely a live measurement - any completion resets the clock and a
    /// drained queue never satisfies it - so callers can never escalate off
    /// a stall that has since recovered.
    func hasMadeNoProgress(forAtLeast seconds: TimeInterval, now: Date) -> Bool {
        guard outstandingFrames > 0, let last = lastProgressAt else { return false }
        return now.timeIntervalSince(last) >= seconds
    }
}
