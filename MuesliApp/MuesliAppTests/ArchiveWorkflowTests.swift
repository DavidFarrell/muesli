import XCTest
import Foundation
import Darwin

@MainActor
final class ArchiveWorkflowTests: XCTestCase {
    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func add(_ amount: Int = 1) { lock.withLock { count += amount } }
        var value: Int { lock.withLock { count } }
    }
    nonisolated private final class Token: Sendable {
        let counter: Counter
        init(_ counter: Counter) { self.counter = counter; counter.add() }
        deinit { counter.add(-1) }
    }
    private typealias Owner = ArchiveWorkflowOwner<Int>
    private func waitUntil(_ condition: () -> Bool, seconds: Double = 3) {
        let end = ArchiveWorkflowSocket.now() + seconds
        // Intentionally blocks MainActor: actual workers must still progress.
        while !condition() && ArchiveWorkflowSocket.now() < end { usleep(1_000) }
        XCTAssertTrue(condition())
    }
    private func owner(finalize: @escaping Owner.Finalize = { _, _, _ in .retained }) -> Owner {
        Owner(acquireWorkToken: { 1 }, prepare: { _, _ in .init(context: 7, outputManifestPath: "/tmp/native-manifest.json") }, finalize: finalize)
    }
    func testProtocolRejectsDuplicateAliasesUnknownFieldsAndUnsupportedShapes() throws {
        let valid = try ArchiveWorkflowProtocol.Request.begin(sourcePath: "/source", vaultPath: "/vault").encode()
        XCTAssertEqual(try ArchiveWorkflowProtocol.Request.decode(valid).sourcePath, "/source")
        let values = [
            #"{"protocol_version":1,"command":"begin","source_path":"/a","vault_path":"/v","command":"status"}"#,
            #"{"protocol_version":1,"command":"begin","source_path":"/a","vault_path":"/v","comm\u0061nd":"status"}"#,
            #"{"protocol_version":1,"command":"begin","source_path":"/a","vault_path":"/v","completion":true}"#,
            #"{"protocol_version":"1","command":"begin","source_path":"/a","vault_path":"/v"}"#,
            #"{"protocol_version":01,"command":"begin","source_path":"/a","vault_path":"/v"}"#,
            #"{"protocol_version":1,"command":"begin","source_path":{},"vault_path":"/v"}"#,
            #"{"protocol_version":1,"command":"begin","source_path":"/a/../v","vault_path":"/v"}"#]
        for value in values { XCTAssertThrowsError(try ArchiveWorkflowProtocol.Request.decode(Data(value.utf8))) }
        XCTAssertThrowsError(try ArchiveWorkflowProtocol.Request.decode(Data(repeating: 32, count: 16_385)))
    }
    func testBlockedPrepareRetainsAdmissionAndTokenThroughQuitCancellation() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let tokens = Counter(), calls = Counter()
        let owner = Owner(acquireWorkToken: { Token(tokens) }, prepare: { _, _ in
            calls.add(); entered.signal(); release.wait()
            return .init(context: 7, outputManifestPath: "/tmp/native.json")
        }, finalize: { _, _, _ in .retained })
        let first = owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault"))
        let id = try XCTUnwrap(first.operationID)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(tokens.value, 1)
        XCTAssertEqual(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).operationID, id)
        XCTAssertEqual(owner.handle(.begin(sourcePath: "/other", vaultPath: "/vault")).failure, .busy)
        XCTAssertEqual(owner.handle(.operation(.abandon, id: id)).failure, .busy)
        XCTAssertEqual(owner.handle(.operation(.finalize, id: id, receiptPath: "/receipt")).failure, .notReady)
        XCTAssertFalse(owner.closeAdmissionForQuit())
        owner.reopenAdmissionAfterCancelledQuit()
        XCTAssertEqual(owner.handle(.operation(.finalize, id: id, receiptPath: "/receipt")).failure, .stopping)
        XCTAssertEqual(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).failure, .busy)
        release.signal(); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(tokens.value, 0); XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(owner.handle(.operation(.status, id: id)).failure, .unknownOperation)
    }
    func testIdleQuitDropsProofAndOldOperationCannotReviveOnReopen() throws {
        let owner = owner(); let request = ArchiveWorkflowProtocol.Request.begin(sourcePath: "/source", vaultPath: "/vault")
        let id = try XCTUnwrap(owner.handle(request).operationID)
        waitUntil { !owner.hasActualWork }
        XCTAssertTrue(owner.closeAdmissionForQuit()); owner.reopenAdmissionAfterCancelledQuit()
        XCTAssertEqual(owner.handle(.operation(.finalize, id: id, receiptPath: "/receipt")).failure, .unknownOperation)
        let second = try XCTUnwrap(owner.handle(request).operationID)
        XCTAssertNotEqual(id, second); waitUntil { !owner.hasActualWork }
    }
    func testDuplicateFinalizeCannotCompeteAndTokenClosesBeforeTerminalPublication() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let tokens = Counter(), calls = Counter()
        let owner = Owner(acquireWorkToken: { Token(tokens) }, prepare: { _, _ in .init(context: 7, outputManifestPath: "/manifest") },
                          finalize: { context, _, _ in
            XCTAssertEqual(context, 7); calls.add(); entered.signal(); release.wait(); return .trashed
        })
        let id = try XCTUnwrap(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).operationID)
        waitUntil { !owner.hasActualWork }
        let request = ArchiveWorkflowProtocol.Request.operation(.finalize, id: id, receiptPath: "/receipt")
        XCTAssertEqual(owner.handle(request).state, .finalizing)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<50 { XCTAssertEqual(owner.handle(request).state, .finalizing) }
        XCTAssertEqual(owner.handle(.operation(.finalize, id: id, receiptPath: "/changed")).failure, .busy)
        XCTAssertEqual(owner.handle(.operation(.abandon, id: id)).failure, .busy)
        release.signal(); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(tokens.value, 0); XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(owner.handle(request).state, .trashed)
        XCTAssertEqual(owner.handle(request).state, .trashed); XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(owner.handle(.operation(.finalize, id: id, receiptPath: "/different")).failure, .notReady)
    }
    func testOnlyExplicitPrecommitCorrectionIsRetryableThrownErrorIsUncertain() throws {
        let calls = Counter()
        let owner = owner { _, _, _ in
            calls.add()
            if calls.value == 1 { return .needsCorrection }
            throw NSError(domain: "failure after durable pending", code: 1)
        }
        let id = try XCTUnwrap(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).operationID)
        waitUntil { !owner.hasActualWork }
        let request = ArchiveWorkflowProtocol.Request.operation(.finalize, id: id, receiptPath: "/receipt")
        _ = owner.handle(request); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(owner.handle(.operation(.status, id: id)).failure, .validationFailed)
        _ = owner.handle(request); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(owner.handle(request).state, .uncertain)
        XCTAssertEqual(calls.value, 2)
    }
    func testAdmissionFailureNeverStartsNativeWork() {
        let calls = Counter()
        let owner = Owner(acquireWorkToken: { throw ArchiveWorkflowProtocol.Failure.stopping }, prepare: { _, _ in
            calls.add(); return .init(context: 0, outputManifestPath: "/manifest")
        }, finalize: { _, _, _ in .retained })
        XCTAssertEqual(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).failure, .admissionRejected)
        XCTAssertFalse(owner.hasActualWork); XCTAssertEqual(calls.value, 0)
    }
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/aw-" + UUID().uuidString.prefix(8))
        XCTAssertEqual(mkdir(url.path, 0o700), 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func startServer(_ directory: URL, timeout: Double = 5,
                             handler: @escaping @Sendable (ArchiveWorkflowProtocol.Request) -> ArchiveWorkflowProtocol.Response) throws -> ArchiveWorkflowServer {
        let server = try ArchiveWorkflowServer(directory: directory, requestTimeoutSeconds: timeout, handler: handler)
        server.start()
        addTeardownBlock {
            server.stop()
            let deadline = ArchiveWorkflowSocket.now() + 3
            while !server.isClosed && ArchiveWorkflowSocket.now() < deadline { usleep(1_000) }
            XCTAssertTrue(server.isClosed)
        }
        return server
    }
    private func connect(_ directory: URL) throws -> Int32 {
        let fd = try ArchiveWorkflowSocket.descriptor()
        var address = try ArchiveWorkflowSocket.address(directory.appendingPathComponent("archive.sock").path)
        guard ArchiveWorkflowSocket.withAddress(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
            Darwin.close(fd); throw ArchiveWorkflowProtocol.Failure.transportUnavailable
        }
        return fd
    }
    func testActualSocketRoutesRequestsAndSecondListenerCannotReplaceFirst() throws {
        let directory = try directory(), owner = owner()
        _ = try startServer(directory) { owner.handle($0) }
        let before = try ArchiveWorkflowSocket.Endpoint(directory: directory, create: false).socketIdentity()
        XCTAssertThrowsError(try ArchiveWorkflowServer(directory: directory, handler: { owner.handle($0) }))
        XCTAssertEqual(before, try ArchiveWorkflowSocket.Endpoint(directory: directory, create: false).socketIdentity())
        let request = ArchiveWorkflowProtocol.Request.begin(sourcePath: "/source", vaultPath: "/vault")
        let response = try ArchiveWorkflowSocket.request(request, directory: directory)
        let id = try XCTUnwrap(response.operationID); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(try ArchiveWorkflowSocket.request(.operation(.status, id: id), directory: directory).state, .awaitingOutputs)
    }
    func testDisconnectDoesNotCancelAdmittedPrepare() throws {
        let directory = try directory(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let owner = Owner(acquireWorkToken: { 1 }, prepare: { _, _ in
            entered.signal(); release.wait(); return .init(context: 1, outputManifestPath: "/manifest")
        }, finalize: { _, _, _ in .retained })
        _ = try startServer(directory) { owner.handle($0) }
        let fd = try connect(directory)
        try ArchiveWorkflowSocket.send(fd, data: ArchiveWorkflowProtocol.Request.begin(sourcePath: "/source", vaultPath: "/vault").encode(), deadline: ArchiveWorkflowSocket.now() + 1)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        Darwin.close(fd)
        XCTAssertTrue(owner.hasActualWork)
        XCTAssertEqual(owner.handle(.begin(sourcePath: "/other", vaultPath: "/vault")).failure, .busy)
        release.signal(); waitUntil { !owner.hasActualWork }
    }
    func testSocketSlotsAndAbsoluteDeadlineBoundSlowClients() throws {
        let directory = try directory(), calls = Counter()
        let server = try startServer(directory, timeout: 0.25) { _ in calls.add(); return .init() }
        var descriptors: [Int32] = []
        for _ in 0..<4 { descriptors.append(try connect(directory)) }
        defer { descriptors.forEach { Darwin.close($0) } }
        waitUntil { server.activeClientCount == 4 }
        let fifth = try connect(directory); Darwin.close(fifth)
        for fd in descriptors { var byte: UInt8 = 0; _ = Darwin.write(fd, &byte, 1) }
        usleep(120_000)
        for fd in descriptors { var byte: UInt8 = 0; _ = Darwin.write(fd, &byte, 1) }
        waitUntil({ server.activeClientCount == 0 }, seconds: 0.3)
        XCTAssertEqual(calls.value, 0)
    }
    func testOversizedFrameAndMalformedCommandNeverReachHandler() throws {
        let directory = try directory(), calls = Counter()
        let server = try startServer(directory) { _ in calls.add(); return .init() }
        let fd = try connect(directory)
        var header = UInt32(16_385).bigEndian
        _ = withUnsafeBytes(of: &header) { Darwin.write(fd, $0.baseAddress, $0.count) }
        usleep(50_000); waitUntil { server.activeClientCount == 0 }; Darwin.close(fd)
        let malformed = try connect(directory)
        try ArchiveWorkflowSocket.send(malformed, data: Data(#"{"protocol_version":1,"command":"shell"}"#.utf8), deadline: ArchiveWorkflowSocket.now() + 1)
        usleep(50_000); Darwin.close(malformed)
        XCTAssertEqual(calls.value, 0)
    }
    func testUnsafeDirectoriesSymlinksAndForeignEndpointFilesArePreserved() throws {
        let directory = try directory()
        let path = directory.appendingPathComponent("archive.sock")
        try Data("foreign evidence".utf8).write(to: path)
        XCTAssertThrowsError(try ArchiveWorkflowServer(directory: directory, handler: { _ in .init() }))
        XCTAssertEqual(try Data(contentsOf: path), Data("foreign evidence".utf8))
        let alias = directory.appendingPathComponent("alias")
        XCTAssertEqual(symlink(directory.path, alias.path), 0)
        XCTAssertThrowsError(try ArchiveWorkflowServer(directory: alias.appendingPathComponent("child"), handler: { _ in .init() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("child").path))
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        XCTAssertThrowsError(try ArchiveWorkflowSocket.Endpoint(directory: directory, create: false))
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
    }
    nonisolated private final class BlockingToken: Sendable {
        let entered: DispatchSemaphore, release: DispatchSemaphore
        init(entered: DispatchSemaphore, release: DispatchSemaphore) { self.entered = entered; self.release = release }
        deinit { entered.signal(); release.wait() }
    }
    func testTokenActualCloseCannotBeSkippedByCompletionOrCancelledQuit() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let owner = Owner(acquireWorkToken: { BlockingToken(entered: entered, release: release) },
                          prepare: { _, _ in .init(context: 7, outputManifestPath: "/manifest") },
                          finalize: { _, _, _ in .retained })
        let id = try XCTUnwrap(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).operationID)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(owner.hasActualWork)
        XCTAssertEqual(owner.handle(.operation(.status, id: id)).state, .preparing)
        XCTAssertFalse(owner.closeAdmissionForQuit()); owner.reopenAdmissionAfterCancelledQuit()
        XCTAssertEqual(owner.handle(.begin(sourcePath: "/other", vaultPath: "/vault")).failure, .busy)
        release.signal(); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(owner.handle(.operation(.status, id: id)).failure, .unknownOperation)
    }
    func testQuitDuringFinalizationCannotReleaseOrResurrectOperation() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = Counter()
        let owner = owner { _, _, _ in calls.add(); entered.signal(); release.wait(); return .retained }
        let id = try XCTUnwrap(owner.handle(.begin(sourcePath: "/source", vaultPath: "/vault")).operationID)
        waitUntil { !owner.hasActualWork }
        _ = owner.handle(.operation(.finalize, id: id, receiptPath: "/receipt"))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(owner.closeAdmissionForQuit()); owner.reopenAdmissionAfterCancelledQuit()
        XCTAssertEqual(owner.handle(.operation(.abandon, id: id)).failure, .busy)
        release.signal(); waitUntil { !owner.hasActualWork }
        XCTAssertEqual(owner.handle(.operation(.finalize, id: id, receiptPath: "/receipt")).failure, .unknownOperation)
        XCTAssertEqual(calls.value, 1)
    }
    func testStopBeforeStartClosesOriginalLeaseAndAllowsFreshListener() throws {
        let directory = try directory()
        let first = try ArchiveWorkflowServer(directory: directory, handler: { _ in .init() })
        first.stop(); waitUntil { first.isClosed }
        let second = try startServer(directory) { _ in .init() }
        XCTAssertFalse(second.isClosed)
    }
    func testStaleSocketRecoveryDoesNotRestoreAnyOperationProof() throws {
        let directory = try directory()
        let old = try ArchiveWorkflowSocket.descriptor()
        var address = try ArchiveWorkflowSocket.address(directory.appendingPathComponent("archive.sock").path)
        XCTAssertEqual(ArchiveWorkflowSocket.withAddress(&address, { Darwin.bind(old, $0, $1) }), 0)
        XCTAssertEqual(chmod(directory.appendingPathComponent("archive.sock").path, 0o600), 0)
        Darwin.close(old)
        let owner = owner()
        _ = try startServer(directory) { owner.handle($0) }
        let response = try ArchiveWorkflowSocket.request(.operation(.finalize, id: UUID(), receiptPath: "/receipt"), directory: directory)
        XCTAssertEqual(response.failure, .unknownOperation)
    }
    func testActualFDReuseDoesNotEraseNewClientOwnership() throws {
        let directory = try directory()
        let closed = DispatchSemaphore(value: 0), releaseOld = DispatchSemaphore(value: 0)
        let handlerEntered = DispatchSemaphore(value: 0), releaseHandler = DispatchSemaphore(value: 0)
        let count = Counter()
        let server = try ArchiveWorkflowServer(directory: directory, afterClientClose: { _ in
            count.add()
            if count.value == 1 { closed.signal(); _ = releaseOld.wait(timeout: .now() + 5) }
        }, handler: { _ in
            handlerEntered.signal(); _ = releaseHandler.wait(timeout: .now() + 5)
            return .init()
        })
        server.start()
        defer {
            releaseOld.signal(); releaseHandler.signal(); server.stop()
            waitUntil { server.isClosed }
        }
        let first = try connect(directory)
        defer { Darwin.close(first) }
        waitUntil { server.activeClientCount == 1 }
        // Keep the first client FD allocated, and allocate the second client
        // before the server closes its first accepted FD. accept then reuses
        // exactly that released server descriptor.
        let second = try ArchiveWorkflowSocket.descriptor()
        defer { Darwin.close(second) }
        XCTAssertEqual(shutdown(first, SHUT_WR), 0)
        XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        var address = try ArchiveWorkflowSocket.address(directory.appendingPathComponent("archive.sock").path)
        XCTAssertEqual(ArchiveWorkflowSocket.withAddress(&address, { Darwin.connect(second, $0, $1) }), 0)
        try ArchiveWorkflowSocket.send(second, data: ArchiveWorkflowProtocol.Request.operation(.status, id: UUID()).encode(), deadline: ArchiveWorkflowSocket.now() + 1)
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 2), .success)
        releaseOld.signal()
        usleep(50_000)
        XCTAssertEqual(server.activeClientCount, 1, "old closed descriptor cleanup must not erase the live reused descriptor's owner")
    }

}
