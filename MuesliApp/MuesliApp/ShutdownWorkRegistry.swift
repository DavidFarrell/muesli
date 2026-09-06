import Foundation

/// Records actual accepted owner lifetimes, independently of UI waits. The
/// final empty check and exit seal share the same lock as every admission.
nonisolated final class ShutdownWorkRegistry: @unchecked Sendable {
    static let shared = ShutdownWorkRegistry()
    enum Failure: Error, LocalizedError {
        case sealed
        var errorDescription: String? { "The application has finished preparing to quit; new work was not accepted." }
    }
    struct Snapshot: Sendable {
        let pending: [String]
        let failures: [String]
        let quiescing: Bool
    }
    private enum Phase { case open, quiescing, sealed }
    private struct Entry { let label: String; let onQuit: (@Sendable () -> Void)? }
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let registry: ShutdownWorkRegistry
        private let id: UUID
        fileprivate init(registry: ShutdownWorkRegistry, id: UUID) { self.registry = registry; self.id = id }
        func finish(failure: String? = nil) {
            guard lock.withLock({ if finished { return false }; finished = true; return true }) else { return }
            registry.finish(id, failure: failure)
        }
        deinit { finish() }
    }
    private let lock = NSLock()
    private var phase = Phase.open
    private var entries: [UUID: Entry] = [:]
    private var failures: [String] = []
    private var onChange: (@Sendable () -> Void)?
    private var deliveryPending = false
    var acceptsUserWork: Bool { lock.withLock { phase == .open } }

    /// New intent is admitted only while open, under the same lock as Quit.
    func beginUserWork(_ label: String, onQuit: (@Sendable () -> Void)? = nil) throws -> Token {
        try admit(label, requiresOpen: true, onQuit: onQuit)
    }
    /// Accepted successors may enter while quiescing. Their parent must keep
    /// its token until this successor has been admitted.
    func begin(_ label: String, onQuit: (@Sendable () -> Void)? = nil) throws -> Token {
        try admit(label, requiresOpen: false, onQuit: onQuit)
    }
    private func admit(_ label: String, requiresOpen: Bool, onQuit: (@Sendable () -> Void)?) throws -> Token {
        let id = UUID()
        let quitting = try lock.withLock {
            guard phase != .sealed && (!requiresOpen || phase == .open) else { throw Failure.sealed }
            entries[id] = Entry(label: label, onQuit: onQuit)
            return phase == .quiescing
        }
        let token = Token(registry: self, id: id)
        notify()
        if quitting { onQuit?() }
        return token
    }
    private func finish(_ id: UUID, failure: String?) {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: id) else { return }
            if let failure {
                let value = entry.label + ": " + String(failure.prefix(1000))
                if !failures.contains(value), failures.count < 32 { failures.append(value) }
            }
        }
        notify()
    }
    /// A terminal admission failure can occur before a native/store token was
    /// installed. It still needs a truthful Quit decision if accepted work lost
    /// its save path. This does not release or replace any original owner.
    func recordFailure(_ message: String) {
        lock.withLock {
            let value = String(message.prefix(1000))
            if !failures.contains(value), failures.count < 32 { failures.append(value) }
        }
        notify()
    }
    func observe(_ callback: @escaping @Sendable () -> Void) { lock.withLock { onChange = callback }; notify() }
    func snapshot() -> Snapshot {
        lock.withLock {
            deliveryPending = false
            return Snapshot(pending: entries.values.map(\.label).sorted(), failures: failures, quiescing: phase != .open)
        }
    }
    func beginQuit() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            guard phase == .open else { return [] }
            phase = .quiescing
            return entries.values.compactMap(\.onQuit)
        }
        notify()
        callbacks.forEach { $0() }
    }
    /// Never call after a timer alone. The coordinator also retains a token
    /// across Stop and finalizer dispatch, so an empty state cannot bridge them.
    func sealIfFinished() -> Bool {
        lock.withLock {
            guard phase == .quiescing, entries.isEmpty, failures.isEmpty else { return false }
            phase = .sealed
            return true
        }
    }
    func cancelQuit() { lock.withLock { if phase == .quiescing { phase = .open } }; notify() }
    func sealForExplicitQuit() { lock.withLock { phase = .sealed }; notify() }
    private func notify() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard !deliveryPending, let onChange else { return nil }
            deliveryPending = true
            return onChange
        }
        callback?()
    }
}
