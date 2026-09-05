import Foundation

/// One callback-style native request, including its invocation, owns this
/// slot until BOTH invocation return and the first callback. Wait deadlines
/// never free a native slot. Duplicate callbacks cannot resume a continuation.
nonisolated final class NativeCallbackOwner<Value: Sendable>: @unchecked Sendable {
    enum Failure: Error, LocalizedError, Sendable {
        case busy, timedOut, cancelled
        var errorDescription: String? {
            switch self {
            case .busy: return "The previous screen request is still waiting for macOS."
            case .timedOut: return "macOS did not finish the screen request before its deadline."
            case .cancelled: return "The screen request was cancelled."
            }
        }
    }
    typealias Reply = @Sendable (Result<Value, Error>) -> Void
    typealias Request = @Sendable (@escaping Reply) -> Void
    private final class Operation: @unchecked Sendable {
        let completion = TaskCompletion()
        var invocationReturned = false
        var result: Result<Value, Error>?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "muesli.native-callback", qos: .utility)
    private var active: Operation?
    var isBusy: Bool { lock.withLock { active != nil } }

    @concurrent func perform(timeoutSeconds: Double, request: @escaping Request) async throws -> Value {
        precondition(timeoutSeconds.isFinite && timeoutSeconds >= 0)
        if Task.isCancelled { throw Failure.cancelled }
        let operation = Operation()
        guard lock.withLock({ if active != nil { return false }; active = operation; return true }) else {
            throw Failure.busy
        }
        queue.async { [self] in
            request { [self] result in
                let complete = lock.withLock {
                    guard active === operation, operation.result == nil else { return false }
                    operation.result = result
                    guard operation.invocationReturned else { return false }
                    active = nil
                    return true
                }
                if complete { operation.completion.markCompleted() }
            }
            let complete = lock.withLock {
                operation.invocationReturned = true
                guard active === operation, operation.result != nil else { return false }
                active = nil
                return true
            }
            if complete { operation.completion.markCompleted() }
        }
        let outcome = await operation.completion.wait(timeoutSeconds: timeoutSeconds)
        if let result = lock.withLock({ operation.invocationReturned ? operation.result : nil }) {
            return try result.get()
        }
        throw outcome == .cancelled ? Failure.cancelled : Failure.timedOut
    }
}
