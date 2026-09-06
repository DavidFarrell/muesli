import Foundation
import IOKit
import IOKit.pwr_mgt

/// A single process-lifetime native observer, delivered off MainActor. This
/// observer never prevents or deliberately delays sleep. Its original native
/// registration remains owned even if the registration call itself stalls.
nonisolated final class SystemPowerObserver: @unchecked Sendable {
    static let shared = SystemPowerObserver()
    let lifecycle = CapturePowerLifecycle(monitorAvailable: false)
    private let queue = DispatchQueue(label: "muesli.system-power", qos: .userInitiated)
    private let lock = NSLock()
    private var startRequested = false
    // Native fields are initialized before installing delivery on queue, and
    // retained for process lifetime. No deinit races a native callback.
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private init() {}

    func start() {
        guard lock.withLock({ if startRequested { return false }; startRequested = true; return true }) else { return }
        queue.async { [self] in
            rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort,
                { context, _, message, argument in
                    guard let context else { return }
                    let observer = Unmanaged<SystemPowerObserver>.fromOpaque(context).takeUnretainedValue()
                    observer.receive(message, argument: argument)
                }, &notifier)
            guard rootPort != 0, let notificationPort else {
                lifecycle.setMonitorAvailable(false)
                AudioLog.error("power.observer-unavailable")
                return
            }
            IONotificationPortSetDispatchQueue(notificationPort, queue)
            lifecycle.setMonitorAvailable(true)
        }
    }

    private func receive(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        SystemPowerNotificationDelivery.receive(message, argument: Int(bitPattern: argument), lifecycle: lifecycle) { [self] identifier in
            _ = IOAllowPowerChange(rootPort, identifier)
        }
    }
}

nonisolated enum SystemPowerNotificationDelivery {
    static func receive(_ message: UInt32, argument: Int, lifecycle: CapturePowerLifecycle,
                        acknowledge: (Int) -> Void) {
        // Acknowledge exactly these two messages immediately, before admission
        // locks, clocks, callbacks, or disk work. Wake must not be acknowledged.
        if message == MuesliPowerCanSystemSleep() || message == MuesliPowerSystemWillSleep() {
            acknowledge(argument)
        }
        if message == MuesliPowerSystemWillSleep() { lifecycle.willSleep() }
        else if message == MuesliPowerSystemHasPoweredOn() { lifecycle.didWake() }
    }
}
