import Foundation

/// Runs entirely off MainActor so it can detect - and log - a wedged main
/// thread even WHILE it is wedged. This is the exact blind spot in the
/// 2026-07-06 incident: the mic-frames watchdog and recovery ladder were
/// both MainActor, so the storm that killed the mic feed also starved the
/// machinery that should have noticed. This watchdog never triggers
/// recovery itself (it can't - if MainActor is truly wedged there is no
/// recovery action it could run there anyway); it only makes the failure
/// mode diagnosable from backend.log/Console after the fact, without
/// needing a live repro.
///
/// Mechanism: a background timer pings MainActor with a trivial task and
/// races it against a timeout. If the echo doesn't land within the
/// threshold, MainActor is starved - log it (rate-limited while the
/// condition persists) along with the mic forwarder's ground-truth liveness
/// so the log answers "was the mic actually still flowing during this
/// stall?" without needing to cross-reference anything else.
final class MainActorStarvationWatchdog {
    private let queue = DispatchQueue(label: "muesli.mainactor.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let logWriter: BackendLogWriter
    private let forwarder: MicAudioForwarder
    private let pingIntervalSeconds: Double
    private let starvedThresholdSeconds: Double
    private let starvedRelogIntervalSeconds: Double

    private var pingInFlight = false
    private var isStarved = false
    private var lastStarvedLogAt: Date = .distantPast

    init(
        logWriter: BackendLogWriter,
        forwarder: MicAudioForwarder,
        pingIntervalSeconds: Double = 2.0,
        starvedThresholdSeconds: Double = 5.0,
        starvedRelogIntervalSeconds: Double = 10.0
    ) {
        self.logWriter = logWriter
        self.forwarder = forwarder
        self.pingIntervalSeconds = pingIntervalSeconds
        self.starvedThresholdSeconds = starvedThresholdSeconds
        self.starvedRelogIntervalSeconds = starvedRelogIntervalSeconds
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pingIntervalSeconds, repeating: pingIntervalSeconds)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pingInFlight = false
    }

    private func tick() {
        guard !pingInFlight else { return }
        pingInFlight = true
        let sentAt = Date()
        let threshold = starvedThresholdSeconds
        let forwarder = self.forwarder

        Task {
            let echoed = await Self.echoMainActor(timeoutSeconds: threshold)
            let elapsedMs = Int(Date().timeIntervalSince(sentAt) * 1000)
            let snap = echoed ? nil : await forwarder.snapshot()
            self.queue.async {
                self.pingInFlight = false
                self.handleEchoResult(echoed: echoed, elapsedMs: elapsedMs, snap: snap)
            }
        }
    }

    /// Races a trivial MainActor hop against a timeout. If MainActor is free,
    /// the hop wins almost instantly; if it's wedged in a continuous storm,
    /// the timeout wins and this returns `false`. The (still-pending) echo
    /// task is left to complete whenever MainActor eventually frees up -
    /// harmless, since at most one ping is ever in flight at a time
    /// (`pingInFlight` above).
    private static func echoMainActor(timeoutSeconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func handleEchoResult(echoed: Bool, elapsedMs: Int, snap: MicAudioForwarder.Snapshot?) {
        if echoed {
            if isStarved {
                isStarved = false
                logWriter.append("mainactor.recovered echo_ms=\(elapsedMs)", toTail: true)
            }
            return
        }

        isStarved = true
        let now = Date()
        guard now.timeIntervalSince(lastStarvedLogAt) >= starvedRelogIntervalSeconds else { return }
        lastStarvedLogAt = now

        let sinceLastFrameMs: Int
        if let last = snap?.lastFrameAt {
            sinceLastFrameMs = Int(now.timeIntervalSince(last) * 1000)
        } else {
            sinceLastFrameMs = -1
        }
        logWriter.append(
            "mainactor.starved echo_ms=\(elapsedMs) micFramesSinceLastMs=\(sinceLastFrameMs) micTotalFrames=\(snap?.frameCount ?? -1)",
            toTail: true
        )
    }
}
