import AppKit
import SwiftUI
import Combine

/// The AppKit adapter never replies YES from a deadline or a stale callback.
/// Tests inject preparation and replies; no test terminates a real application.
@MainActor
final class ApplicationQuitCoordinator: ObservableObject {
    static let shared = ApplicationQuitCoordinator()
    @Published private(set) var isRequested = false
    @Published private(set) var pendingLabels: [String] = []
    @Published private(set) var failures: [String] = []
    @Published private(set) var showsPending = false
    private let registry: ShutdownWorkRegistry
    private let pendingAfter: Duration
    // Captured by Start before its first suspension. Accepting Quit retires
    // it synchronously, even if Cancel prevents async shutdown preparation.
    private(set) var startIntent = UUID()
    private var requestID: UUID?
    private var reply: (@MainActor (Bool) -> Void)?
    private var accepted: @MainActor () -> Void = {}
    private var prepare: @MainActor () async -> Void = {}
    private var cancelled: @MainActor () -> Void = {}
    private var timer: Task<Void, Never>?
    var presentationChanged: (@MainActor (Bool) -> Void)?

    init(registry: ShutdownWorkRegistry = .shared, pendingAfter: Duration = .seconds(5)) {
        self.registry = registry; self.pendingAfter = pendingAfter
        registry.observe { [weak self] in Task { @MainActor [weak self] in self?.refresh() } }
    }
    func configure(accepted: @escaping @MainActor () -> Void = {}, prepare: @escaping @MainActor () async -> Void, cancelled: @escaping @MainActor () -> Void) {
        self.accepted = accepted; self.prepare = prepare; self.cancelled = cancelled
    }
    func canContinueStart(_ capturedIntent: UUID) -> Bool {
        registry.acceptsUserWork && startIntent == capturedIntent
    }
    /// Initial setup keeps the token captured before its first suspension.
    /// Cancel Quit reopens admission for new work, never that retired setup.
    func requireCurrentStart(_ capturedIntent: UUID) throws {
        try Task.checkCancellation()
        guard canContinueStart(capturedIntent) else { throw CancellationError() }
    }
    func requestQuit(reply: @escaping @MainActor (Bool) -> Void) {
        guard requestID == nil else { return }
        let id = UUID()
        // This bridge precedes quiescence, and remains until Stop has admitted
        // its finalizer. Every successor obtains its own token before release.
        guard let preparation = try? registry.begin("Stopping and finalizing capture") else { return }
        startIntent = UUID()
        requestID = id; self.reply = reply; isRequested = true
        // Finite synchronous retirement cannot be skipped by immediate Cancel.
        accepted()
        guard requestID == id else { preparation.finish(); return }
        registry.beginQuit()
        let prepare = self.prepare
        Task { @MainActor [weak self] in
            guard self?.requestID == id else { preparation.finish(); return }
            await prepare()
            preparation.finish()
            guard self?.requestID == id else { return }
            self?.refresh()
        }
        timer = Task { @MainActor [weak self, pendingAfter] in
            do { try await Task.sleep(for: pendingAfter) } catch { return }
            guard self?.requestID == id else { return }
            // Presentation only. This cannot seal admission or approve exit.
            self?.showPending()
        }
        refresh()
    }
    private func refresh() {
        let state = registry.snapshot()
        pendingLabels = Array(Set(state.pending)).sorted()
        failures = state.failures
        guard requestID != nil else { return }
        if registry.sealIfFinished() { complete(allow: true) }
        else if !failures.isEmpty { showPending() }
    }
    private func showPending() {
        guard requestID != nil, !showsPending else { return }
        showsPending = true; presentationChanged?(true)
    }
    func cancelQuit() {
        guard requestID != nil else { return }
        registry.cancelQuit()
        complete(allow: false)
        cancelled()
    }
    func quitAnyway() {
        guard requestID != nil else { return }
        // This is exposed only as a deliberate, warned user action.
        registry.sealForExplicitQuit()
        complete(allow: true)
    }
    private func complete(allow: Bool) {
        guard requestID != nil else { return }
        requestID = nil
        timer?.cancel(); timer = nil
        let callback = reply; reply = nil
        isRequested = false; showsPending = false
        presentationChanged?(false)
        callback?(allow)
    }
}

@MainActor
final class QuitApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationQuitCoordinator.shared.presentationChanged = { [weak self] visible in
            self?.presentPending(visible)
        }
        if ApplicationQuitCoordinator.shared.showsPending { presentPending(true) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationQuitCoordinator.shared.requestQuit { [weak sender] allow in
            sender?.reply(toApplicationShouldTerminate: allow)
        }
        return .terminateLater
    }
    private func presentPending(_ visible: Bool) {
        if !visible { panel?.orderOut(nil); panel = nil; return }
        guard panel == nil else { return }
        let value = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        value.title = "Finishing before quitting"
        value.contentView = NSHostingView(rootView: QuitPendingView(coordinator: .shared))
        value.isReleasedWhenClosed = false
        value.delegate = self
        value.center(); value.makeKeyAndOrderFront(nil)
        panel = value
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        ApplicationQuitCoordinator.shared.cancelQuit()
        return true
    }
}

private struct QuitPendingView: View {
    @ObservedObject var coordinator: ApplicationQuitCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Work is still unfinished").font(.headline)
            Text("The app is waiting for the original operations to finish. No time limit will make it quit automatically while work remains.")
            if !coordinator.failures.isEmpty {
                Text("A save operation reported a failure. Review it before quitting; finishing other work does not resolve that report.").font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(coordinator.pendingLabels, id: \.self) { Text($0) }
                    ForEach(coordinator.failures, id: \.self) { Text($0).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Quit Anyway may lose unfinished recording or unsaved changes. It does not confirm that they were saved.")
                .font(.callout)
            HStack {
                Button("Cancel Quit") { coordinator.cancelQuit() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Quit Anyway", role: .destructive) { coordinator.quitAnyway() }
            }
        }.padding(22).frame(width: 460, height: 330)
    }
}
