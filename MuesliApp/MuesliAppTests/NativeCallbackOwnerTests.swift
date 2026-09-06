import XCTest
import Foundation

final class NativeCallbackOwnerTests: XCTestCase {
    nonisolated private final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: NativeCallbackOwner<Int>.Reply?
        let admitted = TaskCompletion()
        func save(_ reply: @escaping NativeCallbackOwner<Int>.Reply) {
            lock.withLock { self.reply = reply }
            admitted.markCompleted()
        }
        func send(_ value: Int) { lock.withLock { reply }?(.success(value)) }
    }
    func testSynchronousAndDuplicateCallbacksHaveOneResult() async throws {
        let owner = NativeCallbackOwner<Int>()
        let result = try await owner.perform(timeoutSeconds: 1) { reply in
            reply(.success(3)); reply(.success(9))
        }
        XCTAssertEqual(result, 3)
        XCTAssertFalse(owner.isBusy)
    }
    func testMissingCallbackExpiresWaitButRefusesAnotherNativeInvocation() async throws {
        let owner = NativeCallbackOwner<Int>(), callback = Callback()
        do {
            _ = try await owner.perform(timeoutSeconds: 0.02, request: callback.save)
            XCTFail("An unresolved callback must not succeed")
        } catch { XCTAssertEqual(error as? NativeCallbackOwner<Int>.Failure, .timedOut) }
        XCTAssertTrue(owner.isBusy)
        do {
            _ = try await owner.perform(timeoutSeconds: 1) { _ in XCTFail("A second native invocation was admitted") }
            XCTFail("Busy owner must refuse")
        } catch { XCTAssertEqual(error as? NativeCallbackOwner<Int>.Failure, .busy) }
        callback.send(4)
        XCTAssertFalse(owner.isBusy)
        let result = try await owner.perform(timeoutSeconds: 1) { $0(.success(5)) }
        XCTAssertEqual(result, 5)
    }
    func testCallbackBeforeBlockedInvocationReturnDoesNotReleaseSlotOrBlockUI() async throws {
        let owner = NativeCallbackOwner<Int>(), returned = TaskCompletion()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        do {
            _ = try await owner.perform(timeoutSeconds: 0.02) { reply in
                reply(.success(7))
                release.wait()
                returned.markCompleted()
            }
            XCTFail("Callback alone must not finish")
        } catch { XCTAssertEqual(error as? NativeCallbackOwner<Int>.Failure, .timedOut) }
        let heartbeat = await MainActor.run { true }
        XCTAssertTrue(heartbeat)
        XCTAssertTrue(owner.isBusy)
        release.signal()
        _ = await returned.wait(timeoutSeconds: 1)
        // Poll only the in-memory actual-return state with a bounded test wait.
        let deadline = Date().addingTimeInterval(1)
        while owner.isBusy && Date() < deadline { await Task.yield() }
        XCTAssertFalse(owner.isBusy)
    }
    func testCancelledWaitRetainsOriginalCallbackOwnership() async throws {
        let owner = NativeCallbackOwner<Int>(), callback = Callback()
        let task = Task { try await owner.perform(timeoutSeconds: 30, request: callback.save) }
        let admitted = await callback.admitted.wait(timeoutSeconds: 1)
        XCTAssertEqual(admitted, .completed)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled wait succeeded") }
        catch { XCTAssertEqual(error as? NativeCallbackOwner<Int>.Failure, .cancelled) }
        XCTAssertTrue(owner.isBusy)
        callback.send(6)
        let deadline = Date().addingTimeInterval(1)
        while owner.isBusy && Date() < deadline { await Task.yield() }
        XCTAssertFalse(owner.isBusy)
    }
    func testOldDuplicateCannotCompleteNewRequest() async throws {
        let owner = NativeCallbackOwner<Int>(), first = Callback(), second = Callback()
        let one = Task { try await owner.perform(timeoutSeconds: 1, request: first.save) }
        _ = await first.admitted.wait(timeoutSeconds: 1)
        first.send(1)
        let firstValue = try await one.value
        XCTAssertEqual(firstValue, 1)
        let two = Task { try await owner.perform(timeoutSeconds: 1, request: second.save) }
        _ = await second.admitted.wait(timeoutSeconds: 1)
        first.send(99)
        XCTAssertTrue(owner.isBusy)
        second.send(2)
        let secondValue = try await two.value
        XCTAssertEqual(secondValue, 2)
    }
    func testNativeFailureReleasesOnlyAfterInvocationCompletes() async throws {
        let owner = NativeCallbackOwner<Int>()
        do {
            _ = try await owner.perform(timeoutSeconds: 1) { $0(.failure(CocoaError(.fileReadUnknown))) }
            XCTFail("Failure was ignored")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnknown) }
        XCTAssertFalse(owner.isBusy)
    }
}
