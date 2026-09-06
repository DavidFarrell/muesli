import Foundation
import Darwin

nonisolated final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func change(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

nonisolated final class FixtureTransport: SourceCapabilityTransport, @unchecked Sendable {
    struct Request: Sendable {
        let child: String
        let jobID: UUID
        let lease: Data
        let reply: @Sendable (Data?, String?) -> Void
    }
    private let lock = NSLock()
    private var failureHandler: (@Sendable (String) -> Void)?
    private var roots: [SourceCapabilityOwner.RootIdentity] = []
    private var authorizations: [@Sendable (Bool, String?) -> Void] = []
    private var jobs: [Request] = []
    private var retired: [UUID] = []
    private var closed = false
    let automaticallyAuthorize: Bool
    let automaticBookmark: Data?
    init(automaticallyAuthorize: Bool = true, automaticBookmark: Data? = Data([0xA1,0xB2,0xC3])) {
        self.automaticallyAuthorize = automaticallyAuthorize
        self.automaticBookmark = automaticBookmark
    }
    func setFailureHandler(_ callback: @escaping @Sendable (String) -> Void) { lock.withLock { failureHandler = callback } }
    func authorize(root: SourceCapabilityOwner.RootIdentity, reply: @escaping @Sendable (Bool, String?) -> Void) {
        lock.withLock { roots.append(root); authorizations.append(reply) }
        if automaticallyAuthorize { reply(true, nil) }
    }
    func bookmark(child: String, jobID: UUID, leaseRecord: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        lock.withLock { jobs.append(Request(child: child, jobID: jobID, lease: leaseRecord, reply: reply)) }
        if let automaticBookmark { reply(automaticBookmark, nil) }
    }
    func retire(jobID: UUID) { lock.withLock { retired.append(jobID) } }
    func close() { lock.withLock { closed = true } }
    func authorizeReply(_ allowed: Bool) { lock.withLock { authorizations.first }?(allowed, nil) }
    func sourceReply(_ data: Data?) { lock.withLock { jobs.last }?.reply(data, nil) }
    func fail() { lock.withLock { failureHandler }?("The authenticated broker exited.") }
    var rootCalls: [SourceCapabilityOwner.RootIdentity] { lock.withLock { roots } }
    var requests: [Request] { lock.withLock { jobs } }
    var retirements: [UUID] { lock.withLock { retired } }
    var isClosed: Bool { lock.withLock { closed } }
}

nonisolated struct Check: Codable { let name: String; let passed: Bool }
nonisolated struct Report: Codable { let passed: Bool; let checks: [Check]; let scope: String }
nonisolated func spin(_ predicate: () -> Bool, seconds: Double = 2) -> Bool {
    let deadline = DispatchTime.now() + seconds
    while !predicate() && DispatchTime.now() < deadline { usleep(1_000) }
    return predicate()
}
nonisolated func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
nonisolated func identity(_ evidence: MuesliProcessTermination) -> SourceCapabilityOwner.ProcessIdentity {
    .init(pid: evidence.processIdentifier, startSeconds: evidence.startSeconds, startMicroseconds: evidence.startMicroseconds)
}

nonisolated func runOwnerTests(executable: String) throws -> Report {
    var checks: [Check] = []
    func check(_ name: String, _ value: Bool) { checks.append(Check(name: name, passed: value)) }
    var nativeError: NSError?
    guard let first = MuesliSourceOwnerTestTermination(executable, &nativeError),
          let second = MuesliSourceOwnerTestTermination(executable, &nativeError) else {
        throw nativeError ?? SourceCapabilityOwner.Failure(message: "Missing actual native test evidence.")
    }
    let base = URL(fileURLWithPath: "/private/tmp/muesli-source-owner-tests-" + UUID().uuidString, isDirectory: true)
    let root = base.appendingPathComponent("Meetings", isDirectory: true)
    let meeting = root.appendingPathComponent("meeting", isDirectory: true)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    let wire = MuesliSourceLease(directoryDevice: 1, directoryInode: 2, accessDevice: 1, accessInode: 3, backendDevice: 1, backendInode: 4).record
    let process = identity(first)
    check("Actual native exit evidence has original PID/birth and exit125", first.exitCode == 125 && second.exitCode == 125 && first.processIdentifier != second.processIdentifier)

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        var metadata = stat(); _ = lstat(root.path, &metadata)
        let sent = transport.rootCalls.first
        check("Authorization transmits only the original root path and dev/ino", sent?.path == root.path && sent?.device == UInt64(metadata.st_dev) && sent?.inode == metadata.st_ino)
        let tokenBox = Box<SourceCapabilityOwner.JobToken?>(nil)
        let cancellations = Box(0)
        let job = UUID()
        let token = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: job, process: process,
            onRegistered: { tokenBox.set($0) }, onCapabilityLost: { _ in cancellations.change { $0 += 1 } })
        check("Pending token is registered before handoff", tokenBox.get() === token)
        check("Opaque bookmark and immutable 56-byte lease are unchanged", try token.bookmark == transport.automaticBookmark && token.leaseRecord == wire && transport.requests.first?.lease == wire)
        check("A different actual native process cannot retire this token", rejected { try token.observedTermination(second) })
        owner.beginShutdown()
        check("Shutdown cancels once and retains the original session while a token is active", cancellations.get() == 1 && !transport.isClosed)
        check("Matching original exit retires exactly once", try token.observedTermination(first) && !token.observedTermination(first))
        check("Retired bookmark cannot be reused", rejected { _ = try token.bookmark })
        check("One remote retirement and session closure follow real death", spin { transport.retirements == [job] && transport.isClosed })
    }

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        let notices = Box(0), losses = Box(0)
        owner.observeUnavailability {
            // Reentrant owner access proves callback delivery is outside locks.
            _ = owner.isAuthorizedSession
            notices.change { $0 += 1 }
        }
        check("An idle session is not reported as unavailable", notices.get() == 0)
        try owner.authorizeSession(timeoutSeconds: 1)
        let token = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: process,
            onRegistered: { _ in }, onCapabilityLost: { _ in losses.change { $0 += 1 } })
        owner.retireAdmission(); owner.retireAdmission()
        check("Graceful retirement preserves active capability without cancellation", try token.bookmark == transport.automaticBookmark && losses.get() == 0 && !transport.isClosed)
        check("Graceful retirement signals availability exactly once outside locks", notices.get() == 1 && !owner.isAuthorizedSession)
        check("Retired admission rejects further source grants", rejected {
            _ = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: process,
                onRegistered: { _ in fatalError("Retired admission registered work") }, onCapabilityLost: { _ in })
        })
        check("Retired admission rejects further authorization", rejected { try owner.authorizeSession(timeoutSeconds: 1) })
        _ = try token.observedTermination(first)
        check("Gracefully retained capability closes only at matching kernel exit", spin { transport.isClosed && transport.retirements.count == 1 } && losses.get() == 0)
    }

    do {
        let transport = FixtureTransport(automaticallyAuthorize: false)
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        let notices = Box(0), done = DispatchSemaphore(value: 0)
        owner.observeUnavailability { notices.change { $0 += 1 } }
        DispatchQueue.global().async { _ = rejected { try owner.authorizeSession(timeoutSeconds: 1) }; done.signal() }
        _ = spin { transport.rootCalls.count == 1 }
        check("An authorizing session is not reported as unavailable", notices.get() == 0)
        owner.retireAdmission()
        check("Retiring preparation notifies once and wakes its original waiter", done.wait(timeout: .now()+1) == .success && notices.get() == 1)
    }

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        transport.fail()
        let notices = Box(0)
        owner.observeUnavailability { notices.change { $0 += 1 }; owner.retireAdmission() }
        owner.observeUnavailability { notices.change { $0 += 100 } }
        owner.beginShutdown()
        check("Late unavailability registration fires once and duplicate observers cannot replace it", notices.get() == 1)
    }

    do {
        let transport = FixtureTransport(automaticallyAuthorize: false)
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        let outcomes = Box<[Bool]>([]), group = DispatchGroup()
        for _ in 0..<2 {
            group.enter(); DispatchQueue.global().async {
                let success = !rejected { try owner.authorizeSession(timeoutSeconds: 1) }
                outcomes.change { $0.append(success) }; group.leave()
            }
        }
        check("Concurrent authorization opens one original request", spin { transport.rootCalls.count == 1 })
        transport.authorizeReply(true)
        check("Both authorization waiters observe one successful session", group.wait(timeout: .now()+2) == .success && outcomes.get() == [true,true] && transport.rootCalls.count == 1)
        owner.beginShutdown(); _ = spin { transport.isClosed }
    }

    do {
        let transport = FixtureTransport(automaticallyAuthorize: false)
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        check("Authorization timeout closes the initial session", rejected { try owner.authorizeSession(timeoutSeconds: 0.05) })
        transport.authorizeReply(true)
        check("A late successful authorization cannot reopen the session", !owner.isAuthorizedSession && spin { transport.isClosed })
    }

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let job = UUID(), registered = Box(false)
        let failed = rejected {
            _ = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: job, process: process,
                onRegistered: { token in registered.set(true); _ = try? token.observedTermination(first) }, onCapabilityLost: { _ in })
        }
        check("Termination replay during registration prevents all source RPCs", failed && registered.get() && transport.requests.isEmpty)
        owner.beginShutdown()
        check("Terminal-before-request still closes its remote job ID once", spin { transport.retirements == [job] && transport.isClosed })
    }

    do {
        let transport = FixtureTransport(automaticBookmark: nil)
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let pending = Box<SourceCapabilityOwner.JobToken?>(nil), losses = Box(0), finished = DispatchSemaphore(value: 0), failed = Box(false)
        let job = UUID()
        DispatchQueue.global().async {
            failed.set(rejected {
                _ = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: job, process: process,
                    onRegistered: { pending.set($0) }, onCapabilityLost: { _ in losses.change { $0 += 1 } })
            }); finished.signal()
        }
        check("In-flight acquire is owned before its reply", spin { pending.get() != nil && transport.requests.count == 1 })
        let token = pending.get()!
        _ = try token.observedTermination(first)
        transport.sourceReply(Data([0xCC]))
        check("Actual exit before reply prevents late bookmark delivery", finished.wait(timeout: .now()+1) == .success && failed.get() && rejected { _ = try token.bookmark })
        check("Actual termination is not reported as capability loss", losses.get() == 0)
        owner.beginShutdown(); check("Late reply cannot recreate a retired job", spin { transport.retirements == [job] && transport.isClosed })
    }

    do {
        let transport = FixtureTransport(automaticBookmark: nil)
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let pending = Box<SourceCapabilityOwner.JobToken?>(nil), losses = Box(0)
        let start = DispatchTime.now().uptimeNanoseconds
        let failed = rejected {
            _ = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: process,
                onRegistered: { pending.set($0) }, onCapabilityLost: { _ in losses.change { $0 += 1 } })
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
        let token = pending.get()!
        check("Source acquire fails within its two-second caller bound", failed && elapsed >= 1.9 && elapsed < 2.5 && losses.get() == 1)
        owner.beginShutdown(); transport.sourceReply(Data([0xDD]))
        check("Timeout and late reply retain ownership until actual exit", !transport.isClosed && rejected { _ = try token.bookmark })
        _ = try token.observedTermination(first)
        check("Timed-out pending token drains after original native exit", spin { transport.isClosed && transport.retirements.count == 1 })
    }

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let losses = Box(0)
        let token1 = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: process,
            onRegistered: { _ in }, onCapabilityLost: { _ in losses.change { $0 += 1 } })
        let token2 = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: identity(second),
            onRegistered: { _ in }, onCapabilityLost: { _ in losses.change { $0 += 1 } })
        transport.fail(); transport.fail()
        check("Broker loss cancels each active job exactly once without retiring it", losses.get() == 2 && !owner.isAuthorizedSession && !transport.isClosed)
        _ = try token1.observedTermination(first)
        check("One original exit cannot drain another active process", !transport.isClosed)
        _ = try token2.observedTermination(second)
        check("Broker-loss session closes only after both original processes exit", spin { transport.isClosed })
    }

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let token = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: process,
            onRegistered: { _ in }, onCapabilityLost: { _ in })
        let wins = Box(0), errors = Box(0), group = DispatchGroup()
        for _ in 0..<32 {
            group.enter(); DispatchQueue.global().async {
                do { if try token.observedTermination(first) { wins.change { $0 += 1 } } } catch { errors.change { $0 += 1 } }
                group.leave()
            }
        }
        check("Concurrent duplicate kernel events retire once", group.wait(timeout: .now()+2) == .success && wins.get() == 1 && errors.get() == 0)
        check("Concurrent retirement emits one remote retirement while session remains active", spin { transport.retirements.count == 1 })
        owner.beginShutdown(); _ = spin { transport.isClosed }
    }

    for data in [Data(), Data(repeating: 0x11, count: 1024*1024+1)] {
        let transport = FixtureTransport(automaticBookmark: data)
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let pending = Box<SourceCapabilityOwner.JobToken?>(nil), losses = Box(0)
        let failed = rejected {
            _ = try owner.acquire(meetingFolder: meeting, leaseRecord: wire, jobID: UUID(), process: process,
                onRegistered: { pending.set($0) }, onCapabilityLost: { _ in losses.change { $0 += 1 } })
        }
        check("Invalid bookmark size \(data.count) cancels without releasing the token", failed && losses.get() == 1 && pending.get() != nil && !transport.isClosed)
        _ = try pending.get()!.observedTermination(first); owner.beginShutdown(); _ = spin { transport.isClosed }
    }

    do {
        let transport = FixtureTransport()
        let owner = try SourceCapabilityOwner(expectedRoot: root, testingTransport: transport)
        try owner.authorizeSession(timeoutSeconds: 1)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        check("A path outside the original Meetings root is rejected before registration", rejected {
            _ = try owner.acquire(meetingFolder: outside, leaseRecord: wire, jobID: UUID(), process: process,
                onRegistered: { _ in fatalError("Unexpected external registration") }, onCapabilityLost: { _ in })
        } && transport.requests.isEmpty)
        check("Invalid immutable wire version is rejected before registration", rejected {
            _ = try owner.acquire(meetingFolder: meeting, leaseRecord: Data(repeating: 0,count: 56), jobID: UUID(), process: process,
                onRegistered: { _ in fatalError("Unexpected invalid lease registration") }, onCapabilityLost: { _ in })
        } && transport.requests.isEmpty)
        owner.beginShutdown(); _ = spin { transport.isClosed }
    }

    return Report(passed: checks.allSatisfy(\.passed), checks: checks,
        scope: "Actual owner with test-only transport callbacks and real native process-exit evidence; no UI or sandbox grant claim")
}

@main struct Main {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let executable = CommandLine.arguments[1]
        do {
            let report = try await Task.detached { try runOwnerTests(executable: executable) }.value
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            exit(report.passed ? 0 : 1)
        } catch {
            fputs("Source owner tests failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
