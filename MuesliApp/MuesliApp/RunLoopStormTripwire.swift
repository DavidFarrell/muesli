import Foundation
import CoreFoundation

/// Cheap, no-state-write tripwire for a SwiftUI transaction storm - the
/// symptom shared by both the 2026-07-05 and 2026-07-06 incidents. Counts
/// main-run-loop `beforeWaiting` passes and, once per window, logs turns/sec
/// plus context (active screen, transcript row count, meter publish rate,
/// meeting-history count) ONLY when the rate crosses a threshold. Steady
/// state costs one integer increment per run-loop turn and nothing else -
/// this must be near-zero cost when quiet, unlike the fix itself which
/// needed instrumentation to even find the loop-closer next time.
///
/// All counter access stays on the main thread by construction: the run-loop
/// observer callback IS the main run loop, and the aggregator reads/resets
/// the counter from a `Task { @MainActor in ... }` (also the main thread) -
/// so there is no locking, at the cost of the counter itself living outside
/// Swift's actor-isolation checking (a plain, not-`@MainActor`-annotated
/// class only ever touched from the main thread in practice).
final class RunLoopStormTripwire {
    struct Context {
        let activeScreen: String
        let transcriptRows: Int
        let historyCount: Int
        /// Cumulative meter-publish count as of this read; the tripwire
        /// tracks its own last-seen value to compute the per-window delta.
        let meterPublishCount: Int
    }

    private var observer: CFRunLoopObserver?
    private var aggregatorTimer: DispatchSourceTimer?
    private let aggregatorQueue = DispatchQueue(label: "muesli.storm-tripwire", qos: .utility)
    private let windowSeconds: Double
    private let turnsPerSecThreshold: Double
    private let logWriter: BackendLogWriter
    // Settable rather than an init parameter: the provider inevitably
    // captures `self` from whoever owns this tripwire (typically AppModel),
    // and an escaping closure can't capture `self` until ALL of the owner's
    // own stored properties are initialized - which this tripwire itself
    // usually is one of. `AppModel` constructs this with no provider, then
    // calls `setContextProvider` once its own `init()` body has assigned
    // everything else.
    private var contextProvider: (@MainActor () -> Context)?

    /// Main-thread-only (see type doc comment).
    private var turnsInWindow: Int = 0
    /// Touched only from the `@MainActor` aggregator task below.
    private var lastMeterPublishCount: Int = 0

    init(
        logWriter: BackendLogWriter,
        windowSeconds: Double = 5.0,
        turnsPerSecThreshold: Double = 30.0
    ) {
        self.logWriter = logWriter
        self.windowSeconds = windowSeconds
        self.turnsPerSecThreshold = turnsPerSecThreshold
    }

    func setContextProvider(_ provider: @escaping @MainActor () -> Context) {
        contextProvider = provider
    }

    func start() {
        stop()

        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            self?.turnsInWindow += 1
        }
        if let obs {
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
            observer = obs
        }

        let t = DispatchSource.makeTimerSource(queue: aggregatorQueue)
        t.schedule(deadline: .now() + windowSeconds, repeating: windowSeconds)
        t.setEventHandler { [weak self] in self?.evaluateWindow() }
        aggregatorTimer = t
        t.resume()
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
        aggregatorTimer?.cancel()
        aggregatorTimer = nil
    }

    private func evaluateWindow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let turns = self.turnsInWindow
            self.turnsInWindow = 0
            let turnsPerSec = Double(turns) / self.windowSeconds

            guard let ctx = self.contextProvider?() else { return }
            let meterDelta = max(0, ctx.meterPublishCount - self.lastMeterPublishCount)
            self.lastMeterPublishCount = ctx.meterPublishCount

            guard turnsPerSec >= self.turnsPerSecThreshold else { return }

            self.logWriter.append(
                "ui.storm turns_per_sec=\(String(format: "%.1f", turnsPerSec)) " +
                "screen=\(ctx.activeScreen) transcript_rows=\(ctx.transcriptRows) " +
                "meter_publishes_per_sec=\(String(format: "%.1f", Double(meterDelta) / self.windowSeconds)) " +
                "history=\(ctx.historyCount)",
                toTail: true
            )
        }
    }
}
