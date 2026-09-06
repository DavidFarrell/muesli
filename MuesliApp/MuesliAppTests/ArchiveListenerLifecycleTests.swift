import XCTest
import Darwin

@MainActor
final class ArchiveListenerLifecycleTests: XCTestCase {
    nonisolated private final class Gate: @unchecked Sendable {
        let entered = TaskCompletion()
        private let release = DispatchSemaphore(value: 0)
        func block() { XCTAssertFalse(Thread.isMainThread); entered.markCompleted(); XCTAssertEqual(release.wait(timeout: .now() + 8), .success) }
        func open() { release.signal() }
    }
    nonisolated private final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        @discardableResult func add() -> Int { lock.withLock { value += 1; return value } }
        var current: Int { lock.withLock { value } }
    }
    nonisolated private final class Listener: ArchiveListenerHandle {
        let starts: Count, stops: Count
        let close: @Sendable () -> Void
        let beforeStop: @Sendable () -> Void
        init(starts: Count = Count(), stops: Count = Count(), close: @escaping @Sendable () -> Void,
             beforeStop: @escaping @Sendable () -> Void = {}) {
            self.starts = starts; self.stops = stops; self.close = close; self.beforeStop = beforeStop
        }
        func start() { XCTAssertFalse(Thread.isMainThread); starts.add() }
        func stop() { XCTAssertFalse(Thread.isMainThread); stops.add(); beforeStop(); close() }
    }
    private typealias Workflow = ArchiveWorkflowOwner<Int>
    private func workflow(_ registry: ShutdownWorkRegistry) -> Workflow {
        Workflow(acquireWorkToken: { try registry.beginUserWork("Archive semantic operation") }, acquireRetirementToken: { try registry.begin("Archive retirement") },
                 prepare: { _, _ in .init(context: 1, outputManifestPath: "/native-manifest") },
                 finalize: { _, _, _ in .retained })
    }
    private func until(_ condition: () -> Bool, timeout: Double = 3) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    private func entered(_ gate: Gate) async {
        let value = await gate.entered.wait(timeoutSeconds: 2); XCTAssertEqual(value, .completed)
    }
    private func stop(_ lifecycle: ArchiveListenerLifecycle, _ registry: ShutdownWorkRegistry) async throws {
        let bridge = try registry.begin("Shutdown handoff")
        lifecycle.closeAdmissionForQuit(); bridge.finish()
        try await until { !lifecycle.hasActualOwner }
    }
    func testUserAdmissionIsAtomicButAcceptedSuccessorCanEnterQuiescence() throws {
        let registry = ShutdownWorkRegistry()
        let parent = try registry.beginUserWork("accepted")
        registry.beginQuit()
        XCTAssertThrowsError(try registry.beginUserWork("too late"))
        let successor = try registry.begin("accepted successor")
        parent.finish(); XCTAssertFalse(registry.sealIfFinished())
        successor.finish(); XCTAssertTrue(registry.sealIfFinished())
        XCTAssertThrowsError(try registry.begin("sealed successor"))
    }
    func testStalledConstructorImmediateCancelRetiresOriginalAndStartsOnlyAfterReturn() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), constructors = Count(), oldStarts = Count(), newStarts = Count(), stops = Count()
        defer { gate.open() }
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { closed in
            let n = constructors.add()
            if n == 1 { gate.block() }
            return Listener(starts: n == 1 ? oldStarts : newStarts, stops: stops, close: closed)
        })
        XCTAssertTrue(lifecycle.enable()); await entered(gate)
        let expired = await lifecycle.waitForStartup(timeoutSeconds: 0.01); XCTAssertEqual(expired, .timedOut)
        for _ in 0..<100 { XCTAssertTrue(lifecycle.enable()) }
        XCTAssertEqual(constructors.current, 1)
        let coordinator = ApplicationQuitCoordinator(registry: registry)
        var preparations = 0, replies: [Bool] = []
        coordinator.configure(accepted: { lifecycle.closeAdmissionForQuit() }, prepare: { preparations += 1 },
                              cancelled: { lifecycle.reopenAfterCancelledQuit() })
        coordinator.requestQuit { replies.append($0) }
        coordinator.cancelQuit()
        XCTAssertEqual(lifecycle.snapshot.phase, .stopping)
        XCTAssertTrue(lifecycle.hasActualOwner)
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        XCTAssertEqual(constructors.current, 1)
        gate.open()
        try await until { lifecycle.snapshot.phase == .listening }
        try await until { registry.snapshot().pending.isEmpty }
        XCTAssertEqual(constructors.current, 2); XCTAssertEqual(oldStarts.current, 0); XCTAssertEqual(newStarts.current, 1)
        XCTAssertEqual(preparations, 0); XCTAssertEqual(replies, [false])
        try await stop(lifecycle, registry)
        XCTAssertEqual(stops.current, 2)
    }
    func testSecondQuitRetiresCoalescedRestartBeforeOriginalConstructorReturns() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), constructors = Count()
        defer { gate.open() }
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { closed in
            constructors.add(); gate.block(); return Listener(close: closed)
        })
        lifecycle.enable(); await entered(gate)
        let coordinator = ApplicationQuitCoordinator(registry: registry)
        var replies: [Bool] = []
        coordinator.configure(accepted: { lifecycle.closeAdmissionForQuit() }, prepare: {},
                              cancelled: { lifecycle.reopenAfterCancelledQuit() })
        coordinator.requestQuit { replies.append($0) }; coordinator.cancelQuit()
        coordinator.requestQuit { replies.append($0) }
        XCTAssertEqual(constructors.current, 1)
        gate.open()
        try await until { !lifecycle.hasActualOwner && replies == [false, true] }
        XCTAssertEqual(constructors.current, 1); XCTAssertFalse(lifecycle.snapshot.desiredEnabled)
        XCTAssertFalse(lifecycle.enable())
    }
    func testCloseStallRetainsTokenAndOnlyOneStopAcrossRepeatedIntentChanges() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), constructors = Count(), firstStops = Count()
        defer { gate.open() }
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { closed in
            let n = constructors.add()
            return Listener(stops: n == 1 ? firstStops : Count(), close: closed, beforeStop: { if n == 1 { gate.block() } })
        })
        lifecycle.enable(); let ready = await lifecycle.waitForStartup(timeoutSeconds: 2); XCTAssertEqual(ready, .listening)
        XCTAssertTrue(registry.snapshot().pending.isEmpty, "idle listener is not perpetual pending work")
        lifecycle.closeAdmissionForQuit(); await entered(gate)
        for _ in 0..<50 { lifecycle.reopenAfterCancelledQuit(); lifecycle.closeAdmissionForQuit() }
        lifecycle.reopenAfterCancelledQuit()
        XCTAssertEqual(constructors.current, 1); XCTAssertEqual(firstStops.current, 1)
        registry.beginQuit(); XCTAssertFalse(registry.sealIfFinished()); registry.cancelQuit()
        gate.open()
        try await until { lifecycle.snapshot.phase == .listening && constructors.current == 2 }
        XCTAssertEqual(firstStops.current, 1)
        try await stop(lifecycle, registry)
    }
    func testEarlyCloseCallbackCannotReleaseBlockedConstructorOrAdmitReplacement() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), constructors = Count()
        defer { gate.open() }
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { closed in
            let n = constructors.add()
            if n == 1 { closed(); closed(); gate.block() }
            return Listener(close: closed)
        })
        lifecycle.enable(); await entered(gate)
        lifecycle.closeAdmissionForQuit(); lifecycle.reopenAfterCancelledQuit()
        XCTAssertTrue(lifecycle.hasActualOwner); XCTAssertEqual(constructors.current, 1)
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        gate.open()
        try await until { lifecycle.snapshot.phase == .listening && constructors.current == 2 }
        try await stop(lifecycle, registry)
    }
    func testThrowingConstructorKeepsOriginalCleanupOwnedAndDoesNotRetryAutomatically() async throws {
        let registry = ShutdownWorkRegistry(), cleanup = Gate(), constructors = Count()
        defer { cleanup.open() }
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { _ in
            constructors.add(); cleanup.block(); throw ArchiveWorkflowProtocol.Failure.unsafeEndpoint
        })
        lifecycle.enable(); await entered(cleanup)
        let expired = await lifecycle.waitForStartup(timeoutSeconds: 0.01); XCTAssertEqual(expired, .timedOut)
        XCTAssertFalse(registry.snapshot().pending.isEmpty)
        cleanup.open()
        let actual = await lifecycle.waitForStartup(timeoutSeconds: 2); XCTAssertEqual(actual, .failed)
        XCTAssertEqual(lifecycle.snapshot.phase, .failed); XCTAssertEqual(constructors.current, 1)
        XCTAssertFalse(lifecycle.hasActualOwner); XCTAssertTrue(registry.snapshot().pending.isEmpty)
    }
    func testQueuedPublicationReadsLatestStateAfterMainActorWasBlocked() async throws {
        let registry = ShutdownWorkRegistry(), constructed = DispatchSemaphore(value: 0)
        var publications: [ArchiveListenerLifecycle.Snapshot] = []
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { closed in
            constructed.signal(); return Listener(close: closed)
        }, publish: { publications.append($0) })
        lifecycle.enable()
        XCTAssertEqual(constructed.wait(timeout: .now() + 2), .success)
        // MainActor has not yielded to its queued publisher.
        lifecycle.closeAdmissionForQuit()
        let end = Date().addingTimeInterval(2)
        while lifecycle.hasActualOwner && Date() < end { usleep(1_000) }
        XCTAssertFalse(lifecycle.hasActualOwner); XCTAssertEqual(publications.count, 0)
        try await until { !publications.isEmpty }
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.last, lifecycle.snapshot)
        XCTAssertEqual(publications.last?.phase, .stopped)
    }
    func testSameSemanticOwnerRemainsBusyAcrossListenerRestart() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), preparations = Count()
        defer { gate.open() }
        let semantic = Workflow(acquireWorkToken: { try registry.beginUserWork("Native operation") }, acquireRetirementToken: { try registry.begin("Archive retirement") }, prepare: { _, _ in
            if preparations.add() == 1 { gate.block() }
            return .init(context: 1, outputManifestPath: "/manifest")
        }, finalize: { _, _, _ in .retained })
        let lifecycle = ArchiveListenerLifecycle(workflow: semantic, shutdown: registry, factory: { Listener(close: $0) })
        lifecycle.enable(); _ = await lifecycle.waitForStartup(timeoutSeconds: 2)
        let request = ArchiveWorkflowProtocol.Request.begin(sourcePath: "/source", vaultPath: "/vault")
        let id = try XCTUnwrap(semantic.handle(request).operationID); await entered(gate)
        lifecycle.closeAdmissionForQuit(); lifecycle.reopenAfterCancelledQuit()
        try await until { lifecycle.snapshot.phase == .listening }
        XCTAssertEqual(semantic.handle(request).failure, .busy)
        gate.open(); try await until { !semantic.hasActualWork }
        XCTAssertEqual(semantic.handle(.operation(.status, id: id)).failure, .unknownOperation)
        let next = try XCTUnwrap(semantic.handle(request).operationID); XCTAssertNotEqual(id, next)
        try await until { !semantic.hasActualWork }
        try await stop(lifecycle, registry)
    }
    func testRealSocketCloseCallbackIsOnceAfterClientsAndLeaseAndCanReenter() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), callbacks = Count()
        defer { gate.open() }
        let directory = URL(fileURLWithPath: "/private/tmp/al-" + UUID().uuidString.prefix(8))
        XCTAssertEqual(mkdir(directory.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let semantic = workflow(registry)
        let lifecycle = ArchiveListenerLifecycle(workflow: semantic, shutdown: registry, factory: { closed in
            try ArchiveWorkflowServer(directory: directory, afterClientClose: { _ in gate.block() }, onClosed: {
                callbacks.add()
                // Acquiring another listener proves the old lease is closed;
                // its stopped-before-start path must call onClosed once too.
                do {
                    let check = try ArchiveWorkflowServer(directory: directory, onClosed: closed, handler: { _ in .init() })
                    check.stop()
                } catch { XCTFail("old listener lease was not released: \(error)"); closed() }
            }, handler: { semantic.handle($0) })
        })
        lifecycle.enable(); _ = await lifecycle.waitForStartup(timeoutSeconds: 2)
        let fd = try ArchiveWorkflowSocket.descriptor(); defer { Darwin.close(fd) }
        var address = try ArchiveWorkflowSocket.address(directory.appendingPathComponent("archive.sock").path)
        XCTAssertEqual(ArchiveWorkflowSocket.withAddress(&address, { Darwin.connect(fd, $0, $1) }), 0)
        XCTAssertEqual(shutdown(fd, SHUT_WR), 0)
        await entered(gate)
        lifecycle.closeAdmissionForQuit(); registry.beginQuit()
        XCTAssertFalse(registry.sealIfFinished()); XCTAssertEqual(callbacks.current, 0)
        gate.open(); try await until { !lifecycle.hasActualOwner }
        XCTAssertEqual(callbacks.current, 1); XCTAssertTrue(registry.sealIfFinished())
    }
    func testAcceptedHookMayCancelWithoutLeavingAdmissionQuiescent() async throws {
        let registry = ShutdownWorkRegistry()
        let actual = ApplicationQuitCoordinator(registry: registry)
        var calls = 0, replies: [Bool] = []
        let old = actual.startIntent
        actual.configure(accepted: { calls += 1; actual.cancelQuit() }, prepare: { XCTFail("retired asynchronous preparation") }, cancelled: {})
        actual.requestQuit { replies.append($0) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(replies, [false])
        XCTAssertTrue(registry.acceptsUserWork); XCTAssertFalse(actual.canContinueStart(old))
        XCTAssertTrue(registry.snapshot().pending.isEmpty)
    }
    func testLateRealBoundListenerIsClosedBeforeRestartAndNeverDispatchesOldRequest() async throws {
        let registry = ShutdownWorkRegistry(), gate = Gate(), constructors = Count(), preparations = Count()
        defer { gate.open() }
        let directory = URL(fileURLWithPath: "/private/tmp/al-" + UUID().uuidString.prefix(8))
        XCTAssertEqual(mkdir(directory.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let semantic = Workflow(acquireWorkToken: { try registry.beginUserWork("semantic") }, acquireRetirementToken: { try registry.begin("Archive retirement") }, prepare: { _, _ in
            preparations.add(); return .init(context: 1, outputManifestPath: "/manifest")
        }, finalize: { _, _, _ in .retained })
        let lifecycle = ArchiveListenerLifecycle(workflow: semantic, shutdown: registry, factory: { closed in
            let server = try ArchiveWorkflowServer(directory: directory, onClosed: closed, handler: { semantic.handle($0) })
            if constructors.add() == 1 { gate.block() }
            return server
        })
        lifecycle.enable(); await entered(gate)
        XCTAssertThrowsError(try ArchiveWorkflowServer(directory: directory, handler: { _ in .init() }))
        let fd = try ArchiveWorkflowSocket.descriptor(); defer { Darwin.close(fd) }
        var address = try ArchiveWorkflowSocket.address(directory.appendingPathComponent("archive.sock").path)
        XCTAssertEqual(ArchiveWorkflowSocket.withAddress(&address, { Darwin.connect(fd, $0, $1) }), 0)
        try ArchiveWorkflowSocket.send(fd, data: ArchiveWorkflowProtocol.Request.begin(sourcePath: "/old", vaultPath: "/vault").encode(), deadline: ArchiveWorkflowSocket.now() + 1)
        lifecycle.closeAdmissionForQuit(); lifecycle.reopenAfterCancelledQuit()
        XCTAssertEqual(preparations.current, 0)
        gate.open()
        try await until { lifecycle.snapshot.phase == .listening && constructors.current == 2 }
        XCTAssertEqual(preparations.current, 0, "retired listener cannot dispatch its queued connection")
        let result = try ArchiveWorkflowSocket.request(.begin(sourcePath: "/new", vaultPath: "/vault"), directory: directory)
        XCTAssertNotNil(result.operationID)
        try await until { !semantic.hasActualWork }
        XCTAssertEqual(preparations.current, 1)
        try await stop(lifecycle, registry)
    }

    func testSuccessfulExplicitRetryClearsPriorStartupFailure() async throws {
        let registry = ShutdownWorkRegistry(), attempts = Count()
        let lifecycle = ArchiveListenerLifecycle(workflow: workflow(registry), shutdown: registry, factory: { closed in
            if attempts.add() == 1 { throw ArchiveWorkflowProtocol.Failure.unsafeEndpoint }
            return Listener(close: closed)
        })
        XCTAssertTrue(lifecycle.enable())
        try await until { lifecycle.snapshot.phase == .failed }
        XCTAssertEqual(lifecycle.snapshot.failure, .startupFailed)
        XCTAssertTrue(lifecycle.enable())
        let ready = await lifecycle.waitForStartup(timeoutSeconds: 2)
        XCTAssertEqual(ready, .listening)
        XCTAssertNil(lifecycle.snapshot.failure, "successful new admission must not keep the previous attempt's failure")
        XCTAssertEqual(attempts.current, 2)
        try await stop(lifecycle, registry)
    }

}
