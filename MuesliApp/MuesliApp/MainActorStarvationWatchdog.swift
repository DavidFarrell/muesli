import Foundation

/// A timer-owned liveness probe. There is at most one outstanding MainActor
/// echo, including across stop/start. A late echo clears that slot; a timeout
/// only reports it and never creates another task behind the blocked actor.
///
/// `nonisolated` is essential with the app's MainActor default isolation.
/// Mutable state belongs exclusively to `queue`; the unchecked conformance
/// expresses that confinement, not permission to access it from other queues.
nonisolated final class MainActorStarvationWatchdog: @unchecked Sendable {
    struct Context: Sendable, Equatable {
        let activeScreen: String
        let transcriptRows: Int
        let historyCount: Int
        let meterPublishCount: Int
    }

    struct Report: Sendable, Equatable {
        enum Kind: Sendable { case starved, recovered }
        let kind: Kind
        let elapsed: Duration
        /// Context comes from the last completed echo, never a read during a
        /// stall. It cannot establish current microphone or capture health.
        let lastResponsiveContext: Context?
        let contextAge: Duration?

        var logLine: String {
            var line = "mainactor.\(kind == .starved ? "starved" : "recovered") echo_ms=\(milliseconds(elapsed))"
            if let context = lastResponsiveContext, let contextAge {
                line += " last_responsive_context_age_ms=\(milliseconds(contextAge))"
                line += " screen=\(context.activeScreen) transcript_rows=\(context.transcriptRows)"
                line += " history=\(context.historyCount) meter_publishes_total=\(context.meterPublishCount)"
            } else {
                line += " last_responsive_context=unavailable"
            }
            return line
        }

        private func milliseconds(_ duration: Duration) -> Int64 {
            let value = duration.components
            return value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000
        }
    }

    /// Pure state machine: tests advance a monotonic clock without sleeping.
    struct ProbeState: Sendable {
        struct Pending: Sendable {
            let id: UInt64
            var sentAt: Duration
        }
        struct Tick: Sendable {
            var echoID: UInt64?
            var report: Report?
        }

        let threshold: Duration
        let relogInterval: Duration
        private(set) var running = false
        private(set) var pending: Pending?
        private var nextID: UInt64 = 0
        private var lastStarvedReportAt: Duration?
        private var lastContext: Context?
        private var lastContextAt: Duration?

        init(threshold: Duration, relogInterval: Duration) {
            self.threshold = threshold
            self.relogInterval = relogInterval
        }

        mutating func start(now: Duration) {
            guard !running else { return }
            running = true
            lastStarvedReportAt = nil
            // Keep the outstanding echo across restart. Its eventual reply
            // still proves MainActor ran, with a fresh observation window.
            pending?.sentAt = now
        }

        mutating func stop() {
            running = false
            lastStarvedReportAt = nil
        }

        mutating func tick(now: Duration) -> Tick {
            guard running else { return Tick() }
            guard let pending else {
                nextID &+= 1
                self.pending = Pending(id: nextID, sentAt: now)
                return Tick(echoID: nextID)
            }
            let elapsed = now - pending.sentAt
            guard elapsed >= threshold else { return Tick() }
            if let lastStarvedReportAt, now - lastStarvedReportAt < relogInterval {
                return Tick()
            }
            lastStarvedReportAt = now
            return Tick(report: report(kind: .starved, elapsed: elapsed, now: now))
        }

        mutating func acknowledge(id: UInt64, now: Duration, context: Context?) -> Report? {
            guard let pending, pending.id == id else { return nil }
            self.pending = nil
            let recovered = running && lastStarvedReportAt != nil
                ? report(kind: .recovered, elapsed: now - pending.sentAt, now: now) : nil
            lastStarvedReportAt = nil
            lastContext = context
            lastContextAt = context == nil ? nil : now
            return recovered
        }

        private func report(kind: Report.Kind, elapsed: Duration, now: Duration) -> Report {
            Report(kind: kind, elapsed: elapsed, lastResponsiveContext: lastContext,
                   contextAge: lastContextAt.map { now - $0 })
        }
    }

    private let queue = DispatchQueue(label: "muesli.mainactor.watchdog", qos: .utility)
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private let logWriter: BackendLogWriter
    private let pingIntervalSeconds: Double
    private var contextProvider: @MainActor @Sendable () -> Context?
    private let onReport: (@Sendable (Report) -> Void)?
    private var timer: DispatchSourceTimer?
    private var state: ProbeState

    init(
        logWriter: BackendLogWriter,
        pingIntervalSeconds: Double = 2.0,
        starvedThresholdSeconds: Double = 5.0,
        starvedRelogIntervalSeconds: Double = 10.0,
        contextProvider: @escaping @MainActor @Sendable () -> Context? = { nil },
        onReport: (@Sendable (Report) -> Void)? = nil
    ) {
        precondition(pingIntervalSeconds.isFinite && pingIntervalSeconds > 0)
        precondition(starvedThresholdSeconds.isFinite && starvedThresholdSeconds > 0)
        precondition(starvedRelogIntervalSeconds.isFinite && starvedRelogIntervalSeconds > 0)
        self.logWriter = logWriter
        self.pingIntervalSeconds = pingIntervalSeconds
        self.contextProvider = contextProvider
        self.onReport = onReport
        origin = clock.now
        state = ProbeState(threshold: .seconds(starvedThresholdSeconds),
                           relogInterval: .seconds(starvedRelogIntervalSeconds))
    }

    deinit { timer?.cancel() }

    func setContextProvider(_ provider: @escaping @MainActor @Sendable () -> Context?) {
        queue.async { [self] in contextProvider = provider }
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            state.start(now: now())
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: pingIntervalSeconds)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            state.stop()
        }
    }

    private func now() -> Duration { origin.duration(to: clock.now) }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        let action = state.tick(now: now())
        if let report = action.report { emit(report) }
        guard let id = action.echoID else { return }
        let contextProvider = self.contextProvider
        Task { @MainActor [weak self] in
            let context = contextProvider()
            self?.acknowledge(id: id, context: context)
        }
    }

    private func acknowledge(id: UInt64, context: Context?) {
        queue.async { [self] in
            if let report = state.acknowledge(id: id, now: now(), context: context) {
                emit(report)
            }
        }
    }

    private func emit(_ report: Report) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Reporting and file enqueue never await another executor. The log
        // queue can persist this while MainActor is still stuck.
        logWriter.append(report.logLine, toTail: true)
        onReport?(report)
    }
}
