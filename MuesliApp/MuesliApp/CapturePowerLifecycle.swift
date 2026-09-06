import Foundation

/// Power receipt admission is independent of the UI and of disk completion.
/// A sleep cycle belongs to the binding present when WillSleep was received;
/// retirement cannot transfer its wake or recovery to a later source.
nonisolated final class CapturePowerLifecycle: @unchecked Sendable {
    struct Observation: Sendable {
        let hostTimeUs: Int64
        let continuousTimeUs: Int64
        private static let origin = ContinuousClock.now
        static func now() -> Self {
            let elapsed = origin.duration(to: .now).components
            let seconds = max(0, min(elapsed.seconds, Int64.max / 1_000_000 - 1))
            return Self(hostTimeUs: CaptureTimeline.hostNowMicroseconds(),
                        continuousTimeUs: seconds * 1_000_000 + max(0, elapsed.attoseconds / 1_000_000_000_000))
        }
    }
    struct Wake: Sendable, Equatable { let bindingID: UUID; let cycleID: UUID; let sourceSessionID: String? }
    private struct Binding {
        let id: UUID
        let recorder: LocalAudioRecorder?
        let timeline: CaptureTimeline?
        let sourceSessionID: String?
    }
    private struct Sleep {
        let id: UUID
        let bindingID: UUID?
        let continuousTimeUs: Int64
    }
    private let lock = NSLock()
    private var binding: Binding?
    private var sleep: Sleep?
    private var pendingWake: Wake?
    private var deliveryScheduled = false
    private var wakeHandler: (@Sendable () -> Void)?
    private var monitorAvailable: Bool
    private let now: @Sendable () -> Observation

    init(monitorAvailable: Bool = true, now: @escaping @Sendable () -> Observation = Observation.now) {
        self.monitorAvailable = monitorAvailable; self.now = now
    }

    func setWakeHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { wakeHandler = handler } }

    @discardableResult
    func bind(recorder: LocalAudioRecorder? = nil, timeline: CaptureTimeline? = nil, sourceSessionID: String? = nil) -> UUID {
        let observed = now()
        return lock.withLock {
            let value = Binding(id: UUID(), recorder: recorder, timeline: timeline, sourceSessionID: sourceSessionID)
            binding = value; pendingWake = nil
            if !monitorAvailable {
                record(.monitorUnavailable, for: value, cycleID: nil, observed: observed, pauseUs: nil)
            }
            if sleep != nil {
                // A replacement/first source does not inherit the old cycle,
                // but absence of its own WillSleep cannot prove it started
                // after actual wake while HasPoweredOn is still pending.
                record(.bindingDuringSleep, for: value, cycleID: nil, observed: observed, pauseUs: nil)
            }
            return value.id
        }
    }

    func retire(_ id: UUID) {
        lock.withLock {
            guard binding?.id == id else { return }
            binding = nil; pendingWake = nil
        }
    }

    func setMonitorAvailable(_ available: Bool) {
        let observed = now()
        lock.withLock {
            monitorAvailable = available
            if !available, let binding {
                record(.monitorUnavailable, for: binding, cycleID: nil, observed: observed, pauseUs: nil)
            }
        }
    }

    func willSleep() {
        let observed = now()
        lock.withLock {
            guard sleep == nil else { return } // Duplicate native notification.
            let cycle = Sleep(id: UUID(), bindingID: binding?.id, continuousTimeUs: observed.continuousTimeUs)
            sleep = cycle
            if let binding { record(.willSleep, for: binding, cycleID: cycle.id, observed: observed, pauseUs: nil) }
        }
    }

    func didWake() {
        let observed = now()
        let notify: (@Sendable () -> Void)? = lock.withLock {
            guard let cycle = sleep else { return nil }
            sleep = nil
            guard let binding, binding.id == cycle.bindingID else { return nil }
            let pause = observed.continuousTimeUs >= cycle.continuousTimeUs
                ? observed.continuousTimeUs - cycle.continuousTimeUs : nil
            record(.didWake, for: binding, cycleID: cycle.id, observed: observed, pauseUs: pause)
            pendingWake = Wake(bindingID: binding.id, cycleID: cycle.id, sourceSessionID: binding.sourceSessionID)
            guard !deliveryScheduled else { return nil }
            deliveryScheduled = true
            return wakeHandler
        }
        notify?()
    }

    /// One queued UI delivery takes the latest wake. Receipt/durability never
    /// depends on this call executing. A retired binding produces no request.
    func takeWake() -> Wake? {
        lock.withLock {
            deliveryScheduled = false
            defer { pendingWake = nil }
            guard pendingWake?.bindingID == binding?.id else { return nil }
            return pendingWake
        }
    }

    private func record(_ kind: LocalAudioRecorder.PowerEvent.Kind, for binding: Binding,
                        cycleID: UUID?, observed: Observation, pauseUs: Int64?) {
        let relative = binding.timeline.map { $0.relativeMicroseconds(observed.hostTimeUs) }
        // reportPowerEvent only enters a bounded admission lock. Holding this
        // lock makes receipt vs Stop retirement atomic; neither lock does I/O.
        binding.recorder?.reportPowerEvent(.init(kind: kind, cycle_id: cycleID,
            source_time_us: relative.flatMap { $0 >= 0 ? $0 : nil },
            process_continuous_us: max(0, observed.continuousTimeUs), observed_pause_us: pauseUs))
    }
}
