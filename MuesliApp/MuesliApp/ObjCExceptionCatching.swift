import Foundation

/// An ObjC NSException caught at the bridge, surfaced as a Swift error.
struct ObjCExceptionError: Error, CustomStringConvertible {
    let name: String
    let reason: String

    nonisolated var description: String { "NSException \(name): \(reason)" }
}

/// Runs `body`, converting an ObjC NSException raised inside it into a thrown
/// `ObjCExceptionError`. Swift errors thrown by `body` pass through unchanged.
///
/// `nonisolated` because SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor would
/// otherwise make this MainActor-isolated and uncallable from MicEngine's
/// actor-isolated `startEngine`.
nonisolated func catchingObjCExceptions<T>(_ body: () throws -> T) throws -> T {
    var outcome: Result<T, Error>!
    do {
        try ObjCExceptionCatcher.catchException {
            outcome = Result { try body() }
        }
    } catch let nsError as NSError {
        throw ObjCExceptionError(
            name: nsError.userInfo[MuesliObjCExceptionNameKey] as? String ?? "unknown",
            reason: nsError.userInfo[MuesliObjCExceptionReasonKey] as? String ?? "unknown"
        )
    }
    return try outcome.get()
}
