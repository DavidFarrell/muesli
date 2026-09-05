import Foundation

/// The application callback boundary. It captures only this independently
/// synchronized owner, never AppModel. One worker preserves admission order
/// while awaiting the sink; the in-flight item remains included in the cap.
/// Overflow rejects newest input, preserving the accepted prefix and its PTS.
nonisolated final class MicAudioIngress: @unchecked Sendable {
    nonisolated struct Snapshot: Sendable {
        let queuedBytes: Int
        let acceptedFrames: Int
        let droppedFrames: Int
        let droppedSamples: Int
        let droppedBytes: Int
        let firstDroppedPTS: Int64?
        let lastDroppedEndPTS: Int64?
        let closed: Bool
        let sourceProblemCount: Int
        let latestSourceProblem: CapturedSourceProblem?
    }

    private let lock = NSLock()
    enum RejectionReason: String, Sendable { case capacity, retired, empty }
    private let onRejected: (@Sendable (CapturedMicAudio, RejectionReason) -> Void)?
    private let onProblem: (@Sendable (CapturedSourceProblem) -> Void)?
    private var sourceProblemCount = 0
    private var latestSourceProblem: CapturedSourceProblem?
    private let capacityBytes: Int
    private let sink: @Sendable (CapturedMicAudio) async -> Void
    private var queue: [CapturedMicAudio?] = []
    private var head = 0
    private var queuedBytes = 0
    private var running = false
    private var closed = false
    private var acceptedFrames = 0
    private var droppedFrames = 0
    private var droppedSamples = 0
    private var droppedBytes = 0
    private var firstDroppedPTS: Int64?
    private var lastDroppedEndPTS: Int64?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(capacityBytes: Int = 2 * 1024 * 1024, onRejected: (@Sendable (CapturedMicAudio, RejectionReason) -> Void)? = nil, onProblem: (@Sendable (CapturedSourceProblem) -> Void)? = nil, sink: @escaping @Sendable (CapturedMicAudio) async -> Void) {
        precondition(capacityBytes > 0)
        self.onRejected = onRejected
        self.onProblem = onProblem
        self.capacityBytes = capacityBytes
        self.sink = sink
    }

    static func forwarding(to forwarder: MicAudioForwarder, display: MicDeliveryDisplayMailbox,
                           onRejected: (@Sendable (CapturedMicAudio, RejectionReason) -> Void)? = nil,
                           onProblem: (@Sendable (CapturedSourceProblem) -> Void)? = nil) -> MicAudioIngress {
        MicAudioIngress(onRejected: onRejected, onProblem: onProblem) { packet in
            if let result = await forwarder.deliver(packet) { display.publish(result) }
        }
    }

    /// Use this exact factory in AppModel and integration tests. Creating it
    /// in nonisolated code prevents default MainActor closure inheritance.
    func callback() -> @Sendable (CapturedMicAudio) -> Void {
        { [self] packet in enqueue(packet) }
    }

    func problemCallback() -> @Sendable (CapturedSourceProblem) -> Void {
        { [self] problem in
            lock.withLock {
                sourceProblemCount += 1
                latestSourceProblem = problem
            }
            onProblem?(problem)
        }
    }

    @discardableResult
    func enqueue(_ packet: CapturedMicAudio) -> Bool {
        var admitted = false
        var rejection: RejectionReason?
        let startWorker = lock.withLock {
            guard !closed, !packet.data.isEmpty, packet.data.count <= capacityBytes - queuedBytes else {
                rejection = closed ? .retired : (packet.data.isEmpty ? .empty : .capacity)
                droppedFrames += 1
                droppedSamples += packet.outputFrameCount
                droppedBytes += packet.data.count
                firstDroppedPTS = firstDroppedPTS ?? packet.captureTimeUs
                lastDroppedEndPTS = packet.captureTimeUs + Int64(packet.outputFrameCount) * 1_000_000 / Int64(packet.outputSampleRate)
                return false
            }
            acceptedFrames += 1
            admitted = true
            queue.append(packet)
            queuedBytes += packet.data.count
            guard !running else { return false }
            running = true
            return true
        }
        if let rejection { onRejected?(packet, rejection) }
        if startWorker {
            Task.detached(priority: .userInitiated) { [self] in await drain() }
        }
        return admitted
    }

    private func drain() async {
        while let packet = takeNext() {
            await sink(packet)
            lock.withLock { queuedBytes -= packet.data.count }
        }
    }

    private func takeNext() -> CapturedMicAudio? {
        lock.withLock {
            if head < queue.count {
                let packet = queue[head]
                queue[head] = nil
                head += 1
                // Release already-delivered Data while keeping removal amortized.
                if head >= 64 || head == queue.count {
                    queue.removeFirst(head)
                    head = 0
                }
                return packet
            }
            running = false
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            return nil
        }
    }

    /// Close admission synchronously, then wait only for already accepted
    /// buffers. Engines must detach native callbacks and flush SRC first.
    func finish() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                closed = true
                if running { drainWaiters.append(continuation) }
                else { continuation.resume() }
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(queuedBytes: queuedBytes, acceptedFrames: acceptedFrames,
                     droppedFrames: droppedFrames, droppedSamples: droppedSamples,
                     droppedBytes: droppedBytes, firstDroppedPTS: firstDroppedPTS,
                     lastDroppedEndPTS: lastDroppedEndPTS, closed: closed,
                     sourceProblemCount: sourceProblemCount, latestSourceProblem: latestSourceProblem)
        }
    }
}

/// UI stalls retain only the latest meter result and at most one scheduled
/// MainActor task. Publishing never suspends capture/forwarding.
nonisolated final class MicDeliveryDisplayMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: MicAudioForwarder.DeliveryResult?
    private var scheduled = false
    private let consume: @MainActor @Sendable (MicAudioForwarder.DeliveryResult) -> Void

    init(consume: @escaping @MainActor @Sendable (MicAudioForwarder.DeliveryResult) -> Void) {
        self.consume = consume
    }

    func publish(_ result: MicAudioForwarder.DeliveryResult) {
        let schedule = lock.withLock {
            // Preserve recovery meaning if the first/resumption result is
            // coalesced while MainActor is blocked.
            latest = result.mergingRecoveryFlags(from: latest)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in
            let value = lock.withLock {
                let value = latest
                latest = nil
                scheduled = false
                return value
            }
            if let value { consume(value) }
        }
    }
}
