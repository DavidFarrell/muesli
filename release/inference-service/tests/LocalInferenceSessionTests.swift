import Foundation
import CryptoKit
import Darwin

nonisolated private final class Checks: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var cases: [String] = []
    func check(_ passed: Bool, _ message: String) { if !passed { lock.withLock { failures.append(message) } } }
    func finished(_ name: String) { lock.withLock { cases.append(name) } }
    var report: ([String], [String]) { lock.withLock { (cases, failures) } }
}

nonisolated private final class Gate: @unchecked Sendable {
    let entered = TaskCompletion()
    private let release = DispatchSemaphore(value: 0)
    func block(_ checks: Checks) {
        entered.markCompleted()
        checks.check(release.wait(timeout: .now() + 10) == .success, "Synthetic stall exceeded its failsafe.")
    }
    func open() { release.signal() }
}

/// The actual SourceCapabilityOwner owns its normal control queue/state machine;
/// only this transport replaces native callbacks. It never invokes NSXPC or UI.
nonisolated private final class Transport: SourceCapabilityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let automatic: Bool
    private let bookmarkRoot: URL?
    private var reply: (@Sendable (Bool, String?) -> Void)?
    private var failure: (@Sendable (String) -> Void)?
    private var calls = 0
    private var grants = 0
    private var retirements = 0
    private var closed = false
    let authorized = TaskCompletion()
    let didClose = TaskCompletion()
    init(automatic: Bool = false, bookmarkRoot: URL? = nil) { self.automatic = automatic; self.bookmarkRoot = bookmarkRoot }
    func setFailureHandler(_ callback: @escaping @Sendable (String) -> Void) { lock.withLock { failure = callback } }
    func authorize(root: SourceCapabilityOwner.RootIdentity, reply: @escaping @Sendable (Bool, String?) -> Void) {
        lock.withLock { calls += 1; self.reply = reply }
        authorized.markCompleted()
        if automatic { reply(true, nil) }
    }
    func allowLate() { lock.withLock { reply }?(true, nil) }
    func fail() { lock.withLock { failure }?("Synthetic broker loss") }
    func bookmark(child: String, jobID: UUID, leaseRecord: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        lock.withLock { grants += 1 }
        guard let bookmarkRoot else { reply(nil, "The session fixture never requests source capabilities."); return }
        do { reply(try bookmarkRoot.appendingPathComponent(child).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), nil) }
        catch { reply(nil, error.localizedDescription) }
    }
    func retire(jobID: UUID) { lock.withLock { retirements += 1 } }
    func close() { lock.withLock { closed = true }; didClose.markCompleted() }
    var authorizationCalls: Int { lock.withLock { calls } }
    var isClosed: Bool { lock.withLock { closed } }
    var bookmarkCalls: Int { lock.withLock { grants } }
    var retirementCalls: Int { lock.withLock { retirements } }
}

nonisolated private final class Availability: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications = 0
    private var staleUIWouldClear = false
    func notify(session: LocalInferenceSession, checks: Checks) {
        // Reentrant status access proves callbacks are not under manager locks.
        checks.check(!session.isReady, "Unavailable callback preceded truthful cache retirement.")
        lock.withLock { notifications += 1 }
    }
    func deliverOldUIMessage(session: LocalInferenceSession) {
        if !session.isReady { lock.withLock { staleUIWouldClear = true } }
    }
    var count: Int { lock.withLock { notifications } }
    var cleared: Bool { lock.withLock { staleUIWouldClear } }
}

nonisolated private final class Sources: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private var values: [SourceCapabilityOwner] = []
    private let transports: [Transport]
    init(_ transports: [Transport]) { self.transports = transports }
    func make(_ root: URL) throws -> SourceCapabilityOwner {
        let position = lock.withLock { let old = index; index += 1; return old }
        guard position < transports.count else { throw POSIXError(.EOVERFLOW) }
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transports[position])
        lock.withLock { values.append(owner) }
        return owner
    }
    var count: Int { lock.withLock { index } }
    var owners: [SourceCapabilityOwner] { lock.withLock { values } }
}

@main nonisolated enum LocalInferenceSessionTests {
    private static let runtime = PackagedInferenceRuntime(runtimeManifestSHA256: Data(repeating: 1, count: 32),
                                                        modelManifestSHA256: Data(repeating: 2, count: 32))

    private static func failed(_ task: Task<LocalInferenceSelection, Error>) async -> Bool {
        do { _ = try await task.value; return false } catch { return true }
    }
    private static func busy(_ session: LocalInferenceSession) async -> Bool {
        do { _ = try await session.prepare(); return false }
        catch { return error.localizedDescription.contains("previous transcription setup is still closing") }
    }

    private static func createAndReleaseIdleSession(root: URL, transport: Transport) async throws {
        let session = LocalInferenceSession(testingShutdown: ShutdownWorkRegistry(), loadRuntime: { runtime }, prepareRoot: { root },
            makeSourceOwner: { try SourceCapabilityOwner(expectedRoot: $0, testingTransport: transport) })
        _ = try await session.prepare()
    }

    private static func runSessions(root: URL, checks: Checks) async throws {
        // Caller cancellation while the original package read is genuinely
        // blocked: no source factory may run, and no timer discards the slot.
        do {
            let registry = ShutdownWorkRegistry(), load = Gate(), returning = Gate()
            let transport = Transport(), sources = Sources([transport])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: {
                load.block(checks); return runtime
            }, prepareRoot: { root }, makeSourceOwner: { try sources.make($0) }, checkpoint: {
                if $0 == .beforeWorkerReturn { returning.block(checks) }
            })
            let task = Task { try await session.prepare() }
            checks.check(await load.entered.wait(timeoutSeconds: 2) == .completed, "Package worker did not enter.")
            task.cancel()
            checks.check(await busy(session) && !registry.snapshot().pending.isEmpty, "Cancellation released a blocked package worker.")
            load.open()
            checks.check(await returning.entered.wait(timeoutSeconds: 2) == .completed, "Cancelled worker did not reach its return fence.")
            checks.check(!registry.snapshot().pending.isEmpty && sources.count == 0, "Package cancellation admitted a source owner or released work early.")
            returning.open()
            checks.check(await failed(task) && registry.snapshot().pending.isEmpty, "Cancelled package read returned success or retained finished work.")
            checks.finished("cancelled_package_worker_retains_slot_and_token")
        }
        // A real source owner exists inside a blocked factory, but has not
        // been installed. Immediate Cancel Quit must not revive that attempt.
        do {
            let registry = ShutdownWorkRegistry(), install = Gate(), returning = Gate()
            let transport = Transport(), sources = Sources([transport])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root },
                makeSourceOwner: { root in let owner = try sources.make(root); install.block(checks); return owner },
                checkpoint: { if $0 == .beforeWorkerReturn { returning.block(checks) } })
            let task = Task { try await session.prepare() }
            checks.check(await install.entered.wait(timeoutSeconds: 2) == .completed, "Source factory did not stall before install.")
            session.beginShutdown(); registry.beginQuit(); registry.cancelQuit()
            checks.check(await busy(session) && !registry.snapshot().pending.isEmpty, "Quit/Cancel reopened the pending setup slot.")
            install.open()
            checks.check(await returning.entered.wait(timeoutSeconds: 2) == .completed, "Late source installation did not retire.")
            checks.check(transport.authorizationCalls == 0 && !sources.owners[0].isAuthorizedSession,
                         "Late owner installation authorized a retired source session.")
            checks.check(!registry.snapshot().pending.isEmpty, "Late factory return lost its original shutdown token.")
            returning.open()
            checks.check(await failed(task), "Quit before installation returned a usable selection.")
            checks.check(await transport.didClose.wait(timeoutSeconds: 2) == .completed, "Uninstalled source transport did not close.")
            checks.finished("quit_cancel_before_owner_install")
        }
        // Cancellation while the real SourceCapabilityOwner is waiting for its
        // authorization reply, followed by a stale success from that same owner.
        do {
            let registry = ShutdownWorkRegistry(), returning = Gate()
            let transport = Transport(), sources = Sources([transport])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root },
                makeSourceOwner: { try sources.make($0) }, checkpoint: { if $0 == .beforeWorkerReturn { returning.block(checks) } })
            let task = Task { try await session.prepare() }
            checks.check(await transport.authorized.wait(timeoutSeconds: 2) == .completed, "Authorization callback was not requested.")
            task.cancel()
            checks.check(await returning.entered.wait(timeoutSeconds: 2) == .completed, "Authorization cancellation did not return from its real wait.")
            transport.allowLate()
            checks.check(await busy(session) && !sources.owners[0].isAuthorizedSession, "Late authorization success republished a cancelled setup.")
            checks.check(!registry.snapshot().pending.isEmpty, "Cancelled authorization released its token before worker return.")
            returning.open()
            checks.check(await failed(task), "Cancelled authorization returned a selection.")
            checks.check(await transport.didClose.wait(timeoutSeconds: 2) == .completed, "Cancelled source transport remained open.")
            checks.finished("cancel_during_authorization_late_success_ignored")
        }
        // Successful authorization has returned, but its result has not yet
        // entered the session cache. Retire this generation, then start a new one.
        do {
            let registry = ShutdownWorkRegistry(), publish = Gate()
            let first = Transport(automatic: true), second = Transport(automatic: true)
            let sources = Sources([first, second])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root },
                makeSourceOwner: { try sources.make($0) }, checkpoint: {
                    if $0 == .afterAuthorization && sources.count == 1 { publish.block(checks) }
                })
            let task = Task { try await session.prepare() }
            checks.check(await publish.entered.wait(timeoutSeconds: 2) == .completed, "Authorized result did not reach its publication fence.")
            session.beginShutdown(); registry.beginQuit(); registry.cancelQuit()
            checks.check(await busy(session) && sources.count == 1, "Retired pending publication admitted a competing setup.")
            publish.open()
            checks.check(await failed(task), "Old successful authorization republished after Quit/Cancel.")
            let fresh = try await session.prepare()
            checks.check(sources.count == 2 && fresh.sources === sources.owners[1] && fresh.sources.isAuthorizedSession,
                         "Fresh preparation reused the retired owner.")
            session.beginShutdown()
            let firstClosed = await first.didClose.wait(timeoutSeconds: 2)
            let secondClosed = await second.didClose.wait(timeoutSeconds: 2)
            checks.check(firstClosed == .completed && secondClosed == .completed,
                         "Retired/fresh source transports did not close.")
            checks.finished("late_publication_fenced_and_fresh_session_allowed")
        }
        // An unchanged authorized session requires no package or native setup.
        do {
            let registry = ShutdownWorkRegistry(), transport = Transport(automatic: true), sources = Sources([transport])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root }, makeSourceOwner: { try sources.make($0) })
            let first = try await session.prepare(), reused = try await session.prepare()
            checks.check(first.sources === reused.sources && sources.count == 1 && transport.authorizationCalls == 1,
                         "Authorized session reuse created another broker authorization.")
            checks.check(registry.snapshot().pending.isEmpty, "Completed cached setup retained a preparation token.")
            checks.finished("authorized_session_reused")
            // This call is already cancelled before it enters prepare(). A
            // cached fast path must not bypass the caller's retirement intent.
            let proceed = Gate()
            let cancelled = Task.detached {
                proceed.block(checks)
                return try await session.prepare()
            }
            _ = await proceed.entered.wait(timeoutSeconds: 2)
            cancelled.cancel(); proceed.open()
            checks.check(await failed(cancelled), "Already-cancelled prepare returned its cached authorized selection.")
            checks.check(first.sources.isAuthorizedSession && sources.count == 1,
                         "Cancelled reuse retired an independently held valid session.")
            session.beginShutdown()
            checks.check(await transport.didClose.wait(timeoutSeconds: 2) == .completed, "Cached source transport did not close.")
            checks.finished("already_cancelled_cached_call_is_rejected")
        }
        // Sealed admission fails before any disk/native factory and can be
        // attempted again only on a different, genuinely open registry/session.
        do {
            let registry = ShutdownWorkRegistry(), sources = Sources([Transport()])
            registry.beginQuit(); checks.check(registry.sealIfFinished(), "Empty test registry did not seal.")
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root }, makeSourceOwner: { try sources.make($0) })
            checks.check(await failed(Task { try await session.prepare() }) && sources.count == 0,
                         "Sealed Quit admission reached a source factory.")
            checks.finished("sealed_registry_rejects_new_preparation")
        }
        do {
            let registry = ShutdownWorkRegistry(), publish = Gate(), availability = Availability()
            let transport = Transport(automatic: true), sources = Sources([transport])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root },
                makeSourceOwner: { try sources.make($0) }, checkpoint: { if $0 == .afterAuthorization { publish.block(checks) } })
            session.observeUnavailability { [weak session] in if let session { availability.notify(session: session, checks: checks) } }
            let task = Task { try await session.prepare() }
            checks.check(await publish.entered.wait(timeoutSeconds: 2) == .completed, "Broker-loss publication fence was not reached.")
            transport.fail()
            checks.check(!session.isReady && availability.count == 1, "Broker loss before publication was not observed.")
            publish.open()
            checks.check(await failed(task) && !session.isReady, "Broker loss before publication produced ready state.")
            checks.check(await transport.didClose.wait(timeoutSeconds: 2) == .completed, "Failed broker did not close.")
            checks.finished("broker_loss_before_publication_is_latched")
        }
        do {
            let registry = ShutdownWorkRegistry(), availability = Availability()
            let old = Transport(automatic: true), fresh = Transport(automatic: true), sources = Sources([old, fresh])
            let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root }, makeSourceOwner: { try sources.make($0) })
            session.observeUnavailability { [weak session] in if let session { availability.notify(session: session, checks: checks) } }
            _ = try await session.prepare()
            checks.check(session.isReady, "Authorized session did not publish ready state.")
            old.fail()
            checks.check(!session.isReady && availability.count == 1, "Broker loss left its old cached selection ready.")
            let replacement = try await session.prepare()
            old.fail()
            availability.deliverOldUIMessage(session: session)
            checks.check(session.isReady && replacement.sources === sources.owners[1] && availability.count == 1 && !availability.cleared,
                         "Old broker failure or delayed UI notice cleared a fresh authorized session.")
            session.beginShutdown()
            checks.check(!session.isReady, "Explicit retirement left ready state set.")
            let oldClosed = await old.didClose.wait(timeoutSeconds: 2), freshClosed = await fresh.didClose.wait(timeoutSeconds: 2)
            checks.check(oldClosed == .completed && freshClosed == .completed, "Old/fresh broker transport did not close.")
            checks.finished("old_session_loss_and_delayed_notice_cannot_clear_replacement")
        }
        do {
            let transport = Transport(automatic: true)
            try await createAndReleaseIdleSession(root: root, transport: transport)
            checks.check(await transport.didClose.wait(timeoutSeconds: 2) == .completed,
                         "The availability callback retained its completed Preparation/source owner after the manager was released.")
            checks.finished("idle_manager_release_has_no_availability_capture_cycle")
        }
    }

    private struct PackageFixture {
        let bundle: Bundle
        let recordURL: URL
        let runtimeURL: URL
        let modelsURL: URL
        let build: BuildIdentity
        var record: [String: Any]
        init(root: URL) throws {
            let url = root.appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            let serviceResources = contents.appendingPathComponent("XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc/Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: serviceResources, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "paidiaconsulting.MuesliApp", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            guard let value = Bundle(url: url) else { throw POSIXError(.EINVAL) }
            bundle = value
            recordURL = resources.appendingPathComponent("local-runtime-package.json")
            runtimeURL = serviceResources.appendingPathComponent("runtime-manifest.json")
            modelsURL = serviceResources.appendingPathComponent("model-manifest.json")
            let runtimeBytes = Data("{\"fixture\":\"runtime-only-no-code\"}".utf8)
            let modelBytes = Data("{\"fixture\":\"no-models\"}".utf8)
            try runtimeBytes.write(to: runtimeURL); try modelBytes.write(to: modelsURL)
            build = BuildIdentity(schemaVersion: 1, buildID: String(repeating: "a", count: 64), sourceCommit: String(repeating: "b", count: 40),
                sourceDirty: false, sourceTreeSHA256: String(repeating: "c", count: 64), expectedInputSHA256: [:], schemas: [:], buildSettings: [:])
            record = ["schema_version": 1, "app_build_id": build.buildID, "source_commit": build.sourceCommit!, "source_tree_sha256": build.sourceTreeSHA256!,
                "runtime_manifest_sha256": Self.hash(runtimeBytes), "model_manifest_sha256": Self.hash(modelBytes),
                "inference_client_identifier": "paidiaconsulting.MuesliApp", "signing_team": "JA9EPB8K4N"]
            try save()
        }
        func save() throws { try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: recordURL) }
        static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func load(build: BuildIdentity? = nil) throws -> PackagedInferenceRuntime { try .load(bundle: bundle, build: build ?? self.build) }
    }

    private static func runPackages(root: URL, checks: Checks) throws {
        let mutations: [(String, (inout PackageFixture) throws -> Void)] = [
            ("schema", { $0.record["schema_version"] = 2; try $0.save() }),
            ("build_id", { $0.record["app_build_id"] = "different"; try $0.save() }),
            ("source_commit", { $0.record["source_commit"] = String(repeating: "d", count: 40); try $0.save() }),
            ("source_tree", { $0.record["source_tree_sha256"] = String(repeating: "d", count: 64); try $0.save() }),
            ("client", { $0.record["inference_client_identifier"] = "different"; try $0.save() }),
            ("team", { $0.record["signing_team"] = "different"; try $0.save() }),
            ("record_runtime_digest", { $0.record["runtime_manifest_sha256"] = String(repeating: "0", count: 64); try $0.save() }),
            ("runtime_bytes", { try Data("changed".utf8).write(to: $0.runtimeURL) }),
            ("model_bytes", { try Data("changed".utf8).write(to: $0.modelsURL) }),
            ("missing_manifest", { try FileManager.default.removeItem(at: $0.runtimeURL) }),
            ("empty_manifest", { try Data().write(to: $0.runtimeURL) }),
            ("oversize_manifest", { try Data(repeating: 0, count: 8 * 1024 * 1024 + 1).write(to: $0.runtimeURL) }),
            ("oversize_record", { try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: $0.recordURL) }),
            ("malformed_record", { try Data("[]".utf8).write(to: $0.recordURL) }),
            ("manifest_hardlink", { try FileManager.default.linkItem(at: $0.runtimeURL, to: $0.runtimeURL.appendingPathExtension("alias")) }),
            ("manifest_symlink", { let target = $0.runtimeURL.appendingPathExtension("original"); try FileManager.default.moveItem(at: $0.runtimeURL, to: target); try FileManager.default.createSymbolicLink(at: $0.runtimeURL, withDestinationURL: target) }),
            ("dangling_record", { try FileManager.default.removeItem(at: $0.recordURL); try FileManager.default.createSymbolicLink(atPath: $0.recordURL.path, withDestinationPath: "absent") })
        ]
        let valid = try PackageFixture(root: root)
        let loaded = try valid.load()
        checks.check(PackageFixture.hash(try Data(contentsOf: valid.runtimeURL)) == loaded.runtimeManifestSHA256.map { String(format: "%02x", $0) }.joined(), "Valid generated manifest expectation did not match actual bytes.")
        checks.finished("package_valid_generated_hashes")
        for (name, mutate) in mutations {
            var fixture = try PackageFixture(root: root)
            try mutate(&fixture)
            var rejected = false
            do { _ = try fixture.load() } catch { rejected = true }
            checks.check(rejected, "Package mismatch accepted: " + name)
            checks.finished("package_rejects_" + name)
        }
        for dirty: Bool? in [true, nil] {
            let fixture = try PackageFixture(root: root), original = fixture.build
            let build = BuildIdentity(schemaVersion: original.schemaVersion, buildID: original.buildID, sourceCommit: original.sourceCommit,
                sourceDirty: dirty, sourceTreeSHA256: original.sourceTreeSHA256, expectedInputSHA256: [:], schemas: [:], buildSettings: [:])
            var rejected = false
            do { _ = try fixture.load(build: build) } catch { rejected = true }
            checks.check(rejected, "Dirty or unidentified build accepted a local package.")
            checks.finished(dirty == true ? "package_rejects_dirty_build" : "package_rejects_unknown_build")
        }
    }

    private static func runActiveNativeJob(root: URL, checks: Checks) async throws {
        let meeting = root.appendingPathComponent("generated-meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: false)
        let sentinel = meeting.appendingPathComponent("synthetic-source.txt")
        let originalBytes = Data("Generated model-free session source\n".utf8)
        try originalBytes.write(to: sentinel)
        guard chmod(sentinel.path, 0o400) == 0 else { throw POSIXError(.EIO) }
        var originalInfo = stat()
        guard lstat(sentinel.path, &originalInfo) == 0 else { throw POSIXError(.EIO) }
        let registry = ShutdownWorkRegistry(), transport = Transport(automatic: true, bookmarkRoot: root)
        let sources = Sources([transport])
        let session = LocalInferenceSession(testingShutdown: registry, loadRuntime: { runtime }, prepareRoot: { root }, makeSourceOwner: { try sources.make($0) })
        let selection = try await session.prepare()
        let configuration = try selection.configuration(folder: meeting, operation: .preflight, streams: .both)
        let owner = BackendAdmissionOwner(shutdown: registry)
        let attempt = try owner.start(protecting: meeting, timeoutSeconds: 53) {
            .init(backend: try BackendProcess(inference: configuration, eventJournalURL: meeting.appendingPathComponent("events.jsonl")))
        }
        guard case .ready = await attempt.waitUntilReady() else { throw POSIXError(.EIO) }
        let resources = try attempt.claim(), backend = resources.backend
        checks.check(transport.bookmarkCalls == 1 && transport.retirementCalls == 0 && backend.isRunning,
                     "Actual native job was not admitted with one live source token.")
        session.beginShutdown(); registry.beginQuit(); registry.cancelQuit()
        checks.check(!session.isReady && !selection.sources.isAuthorizedSession, "Retired session admitted a new inference selection.")
        var configurationRejected = false
        do { _ = try selection.configuration(folder: meeting, operation: .preflight, streams: .both) } catch { configurationRejected = true }
        checks.check(configurationRejected, "Retired selection still produced a new native configuration.")
        // A well-formed native lease makes this a state rejection, not merely
        // invalid test input. This attempt must not register a token or call RPC.
        var info = stat(), words: [UInt64] = [1]
        guard lstat(meeting.path, &info) == 0 else { throw POSIXError(.EIO) }
        words += [UInt64(info.st_dev), info.st_ino]
        for name in [".meeting-access.lock", ".backend-owner.lock"] {
            guard lstat(meeting.appendingPathComponent(name).path, &info) == 0 else { throw POSIXError(.EIO) }
            words += [UInt64(info.st_dev), info.st_ino]
        }
        let lease = words.reduce(into: Data()) { data, word in var big = word.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
        var acquisitionRejected = false
        do {
            _ = try selection.sources.acquire(meetingFolder: meeting, leaseRecord: lease, jobID: UUID(),
                process: .init(pid: 2, startSeconds: 1, startMicroseconds: 0), onRegistered: { _ in
                    checks.check(false, "Retired session registered another source token.")
                }, onCapabilityLost: { _ in })
        } catch { acquisitionRejected = error.localizedDescription.contains("no longer accepts capabilities") }
        checks.check(acquisitionRejected && transport.bookmarkCalls == 1, "Retirement sent a new source-grant RPC.")
        checks.check(backend.isRunning && owner.isBusy && !transport.isClosed && transport.retirementCalls == 0 && !registry.snapshot().pending.isEmpty,
                     "Accepted Quit/Cancel cancelled or released the existing native job before its normal stop frame.")
        resources.writer.send(type: .meetingStart, stream: .system, ptsUs: 0, payload: Data("{\"type\":\"fixture_control\"}".utf8))
        let status = await backend.waitForExit(timeoutSeconds: 10)
        checks.check(status == 0 && backend.completionEvidence()?.osTermination == .exited(125),
                     "Session retirement cancelled a claimed job instead of allowing its actual successful native completion.")
        checks.check(await attempt.waitUntilClosed(timeoutSeconds: 8) == .completed, "Original backend owner did not finish.")
        let drain = await backend.finishStdout(timeoutSeconds: 1)
        checks.check(drain.status.isComplete && drain.status.durableLines == 1, "Claimed job did not durably complete after session retirement.")
        checks.check(await transport.didClose.wait(timeoutSeconds: 2) == .completed && transport.retirementCalls == 1,
                     "The broker token did not retire exactly once after actual native termination.")
        checks.check(!owner.isBusy && registry.snapshot().pending.isEmpty, "Actual job close did not release the original shutdown work.")
        for name in [".meeting-access.lock", ".backend-owner.lock"] {
            let fd = open(meeting.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            checks.check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "Original native source pin survived close publication.")
            if fd >= 0 { close(fd) }
        }
        var finalInfo = stat()
        checks.check(lstat(sentinel.path, &finalInfo) == 0 && finalInfo.st_dev == originalInfo.st_dev
            && finalInfo.st_ino == originalInfo.st_ino && finalInfo.st_size == originalInfo.st_size
            && finalInfo.st_mtimespec.tv_sec == originalInfo.st_mtimespec.tv_sec
            && finalInfo.st_mtimespec.tv_nsec == originalInfo.st_mtimespec.tv_nsec
            && finalInfo.st_ctimespec.tv_sec == originalInfo.st_ctimespec.tv_sec
            && finalInfo.st_ctimespec.tv_nsec == originalInfo.st_ctimespec.tv_nsec,
            "Generated original source identity changed during session retirement.")
        checks.check(try Data(contentsOf: sentinel) == originalBytes, "Generated original source bytes changed.")
        checks.finished("session_quit_cancel_preserves_claimed_native_job_until_kernel_exit")
    }

    static func main() async throws {
        alarm(60)
        signal(SIGPIPE, SIG_IGN)
        guard [2, 3].contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/private/tmp/") else { throw POSIXError(.EINVAL) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let checks = Checks()
        let native = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "active-native-job"
        if native { try await runActiveNativeJob(root: root, checks: checks) }
        else { try await runSessions(root: root, checks: checks); try runPackages(root: root, checks: checks) }
        let (cases, failures) = checks.report
        let json: [String: Any] = ["passed": failures.isEmpty, "cases": cases, "failures": failures,
            "scope": native ? "Actual session to source token to BackendProcess/admission/native observer, signed model-free helper and generated temporary grant; no real broker/private grant/models/application activation" : "Actual session/source-owner/package logic, generated files and injected transport only; no native broker, picker, helper, models, or application activation"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]))
        FileHandle.standardOutput.write(Data([10]))
        if !failures.isEmpty { exit(1) }
    }
}
