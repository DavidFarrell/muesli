import Foundation

nonisolated private func requireSendable<Value: Sendable>(_ value: Value) {}

// Compile-only check. It performs no XPC connection or process operation.
nonisolated func checkNativeObserverImport(_ connection: NSXPCConnection) throws {
    let observer = try MuesliNativeProcessObserver.armConnection(
        connection,
        codeSigningRequirement: "identifier test",
        timeout: 1,
        terminationHandler: { termination in
            let _: Int32 = termination.rawWaitStatus
            let _: MuesliProcessTerminationKind = termination.kind
            requireSendable(termination)
        },
        failureHandler: { _ in }
    )
    let _: pid_t = observer.processIdentifier
    requireSendable(observer)
}
