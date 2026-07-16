import Foundation

/// Serialized buffer-until-ready gate for the system-audio path (2026-07-16
/// readiness-handshake slice, gate blocker fix). Owns the two decisions the
/// capture callback and the readiness flush must agree on atomically:
/// whether a frame passes through live or gets buffered, and the
/// flush-then-enable transition itself.
///
/// **Why atomicity matters (gate BLOCKER 1):** the previous implementation
/// set `audioOutputEnabled = true` and *then* sent the buffered prefix
/// outside the critical section. A capture callback landing in that window
/// saw enabled == true and sent a NEWER frame ahead of the still-unsent
/// buffered prefix; the backend's `write_aligned_audio` aligns by PTS and
/// silently drops frames behind the write cursor - so on a perfectly
/// healthy meeting the whole buffered startup prefix (up to ~13s of system
/// audio under the readiness handshake) could be discarded. Here
/// `enableAndFlush` performs the flush AND the enabled flip inside one
/// critical section: a concurrent `admitOrBuffer` either lands before it
/// (buffered, flushed in order) or after it (sees enabled with an empty
/// buffer) - it can never overtake the prefix. The live-path send happens
/// outside the lock (as before - SCK delivers callbacks serially on one
/// queue, so live sends cannot race each other), but a callback only
/// receives `true` after `enableAndFlush`'s sends are already enqueued on
/// the writer's serial queue.
///
/// **Why a byte cap (gate BLOCKER 2):** the old ring capped by callback
/// COUNT, but callback cadence is device/OS dependent - at a fast cadence a
/// count cap covers far less wall time than intended. The cap here is PCM
/// bytes, sized directly against the window it must cover.
///
/// (The mic side needs neither fix: `MicAudioForwarder` is an actor and its
/// `setOutputEnabled(true)` flush + flag flip is one synchronous
/// actor-isolated function with no suspension points, so `deliver` can
/// never interleave mid-flush. Its ring is byte-capped separately.)
final class PendingAudioGate: @unchecked Sendable {
    struct Item {
        let ptsUs: Int64
        let payload: Data
    }

    struct Snapshot {
        let isEnabled: Bool
        let bufferedFrames: Int
        let bufferedBytes: Int
        let droppedOldestFrames: Int
        let droppedOldestBytes: Int
    }

    /// Default cap ≈ 32s of headroom even if the OS ignored the requested
    /// 16kHz mono and delivered 48kHz mono int16 (96KB/s); at the requested
    /// format (32KB/s) it is over two minutes. The window it must cover is
    /// capture start -> readiness acknowledgment: ~2-3s of setup plus the
    /// 10s handshake timeout. Worst case is a few MB held transiently
    /// during startup, released on flush or teardown.
    static let defaultMaxPendingBytes = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "muesli.pending-audio-gate", qos: .userInitiated)
    private let maxPendingBytes: Int
    private var enabled = false
    private var pending: [Item] = []
    private var pendingBytes = 0
    private var droppedOldestFrames = 0
    private var droppedOldestBytes = 0

    init(maxPendingBytes: Int = PendingAudioGate.defaultMaxPendingBytes) {
        self.maxPendingBytes = maxPendingBytes
    }

    /// Called per capture callback. Returns `true` when the caller should
    /// forward the frame live (gate open); otherwise the frame has been
    /// buffered (oldest evicted first beyond the byte cap - audio arriving
    /// late is acceptable, losing the newest audio is not).
    func admitOrBuffer(_ item: Item) -> Bool {
        queue.sync {
            if enabled { return true }
            pending.append(item)
            pendingBytes += item.payload.count
            while pendingBytes > maxPendingBytes, !pending.isEmpty {
                let evicted = pending.removeFirst()
                pendingBytes -= evicted.payload.count
                droppedOldestFrames += 1
                droppedOldestBytes += evicted.payload.count
            }
            return false
        }
    }

    /// Atomically drain the buffered prefix through `send` (in capture
    /// order) and open the gate. `send` runs inside the critical section on
    /// purpose - it is `FramedWriter.send`, a cheap non-blocking enqueue -
    /// so no concurrent `admitOrBuffer` can slip a newer frame ahead of the
    /// prefix (see the type doc comment).
    func enableAndFlush(_ send: (Item) -> Void) {
        queue.sync {
            for item in pending {
                send(item)
            }
            pending.removeAll()
            pendingBytes = 0
            enabled = true
        }
    }

    /// Close the gate and drop anything buffered - capture (re)start and
    /// teardown both want a clean slate.
    func reset() {
        queue.sync {
            enabled = false
            pending.removeAll()
            pendingBytes = 0
            droppedOldestFrames = 0
            droppedOldestBytes = 0
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                isEnabled: enabled,
                bufferedFrames: pending.count,
                bufferedBytes: pendingBytes,
                droppedOldestFrames: droppedOldestFrames,
                droppedOldestBytes: droppedOldestBytes
            )
        }
    }
}
