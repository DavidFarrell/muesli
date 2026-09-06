import XCTest
import Darwin

@MainActor
final class ArchiveApplicationBridgeTests: XCTestCase {
    private func paths() throws -> ArchiveApplicationDirectories.Paths {
        // Unix sockets have a short fixed address buffer.
        let root = URL(fileURLWithPath: "/private/tmp/aab-" + UUID().uuidString.prefix(8))
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(base: root.appendingPathComponent("Muesli"))
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    func testActualNativeBridgeBootstrapsOnceRejectsUnconfiguredPrepareAndClosesThroughQuit() async throws {
        let paths = try paths(), registry = ShutdownWorkRegistry()
        let bridge = ArchiveApplicationBridge(backend: .init(), paths: paths, shutdown: registry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.base.path), "Construction alone must not do filesystem work.")
        XCTAssertTrue(bridge.enable())
        try await until { bridge.snapshot.phase == .listening }
        defer { bridge.closeAdmissionForQuit() }
        XCTAssertThrowsError(try ArchiveWorkflowServer(directory: paths.endpoint, handler: { _ in .init() }))
        let response = try ArchiveWorkflowSocket.request(.begin(sourcePath: "/unused-source", vaultPath: "/unused-vault"), directory: paths.endpoint)
        let id = try XCTUnwrap(response.operationID)
        var latest = response
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while latest.state != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            latest = try ArchiveWorkflowSocket.request(.operation(.status, id: id), directory: paths.endpoint)
        }
        XCTAssertEqual(latest.state, .failed)
        XCTAssertEqual(latest.failure, .preparationFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/unused-source"))
        var replies: [Bool] = []
        let quit = ApplicationQuitCoordinator(registry: registry)
        quit.configure(accepted: { bridge.closeAdmissionForQuit() }, prepare: {}, cancelled: { bridge.reopenAfterCancelledQuit() })
        quit.requestQuit { replies.append($0) }
        try await until { replies == [true] }
        XCTAssertFalse(bridge.hasActualListenerOwner)
        XCTAssertTrue(registry.snapshot().pending.isEmpty)
        XCTAssertFalse(bridge.enable())
    }
    func testImmediateCancelRestartsActualListenerAfterOriginalClose() async throws {
        let paths = try paths(), registry = ShutdownWorkRegistry()
        let bridge = ArchiveApplicationBridge(backend: .init(), paths: paths, shutdown: registry)
        XCTAssertTrue(bridge.enable())
        try await until { bridge.snapshot.phase == .listening }
        let old = bridge.snapshot.generation
        var replies: [Bool] = []
        let quit = ApplicationQuitCoordinator(registry: registry)
        quit.configure(accepted: { bridge.closeAdmissionForQuit() }, prepare: {}, cancelled: { bridge.reopenAfterCancelledQuit() })
        quit.requestQuit { replies.append($0) }; quit.cancelQuit()
        try await until { bridge.snapshot.phase == .listening && bridge.snapshot.generation != old }
        XCTAssertEqual(replies, [false])
        let unknown = try ArchiveWorkflowSocket.request(.operation(.status, id: UUID()), directory: paths.endpoint)
        XCTAssertEqual(unknown.failure, .unknownOperation)
        bridge.closeAdmissionForQuit()
        try await until { !bridge.hasActualListenerOwner }
    }
}
