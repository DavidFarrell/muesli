import Foundation
import Darwin

nonisolated final class Report: @unchecked Sendable {
    let lock = NSLock()
    var bookmarkCalls = 0
    var completion: BackendXPCJobOwner.Completion?
    let finished = DispatchSemaphore(value: 0)
}

@main nonisolated enum ClientFixtureHost {
    static func main() throws {
        alarm(15)
        let mode = Int(CommandLine.arguments.dropFirst().first ?? "0") ?? 0
        let report = Report()
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("muesli-xpc-client-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var words: [UInt64] = [1]
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw POSIXError(.EIO) }
        words += [UInt64(info.st_dev), info.st_ino]
        for name in [".meeting-access.lock", ".backend-owner.lock"] {
            let path = root.appendingPathComponent(name).path
            let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o400)
            guard fd >= 0, fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
            words += [UInt64(info.st_dev), info.st_ino]
            close(fd)
        }
        let record = words.reduce(into: Data()) { data, word in
            var big = word.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        let owner = try BackendXPCJobOwner(configuration: .init(operation: .preflight, streams: .both,
            liveSource: nil, expectedRuntimeSHA256: Data(repeating: 1, count: 32),
            expectedModelsSHA256: Data(repeating: 2, count: 32), sourceBookmark: {
                report.lock.withLock { report.bookmarkCalls += 1 }
                if mode == 9 { Thread.sleep(forTimeInterval: 8.1) }
                return try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }), completed: { value in
                report.lock.withLock { report.completion = value }
                report.finished.signal()
            })
        try owner.installLease(record)
        let input = Pipe(), output = Pipe(), diagnostics = Pipe()
        let began = DispatchTime.now().uptimeNanoseconds
        if mode == 8 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { owner.cancel() }
        }
        var startFailure: String?
        do {
            try owner.start(input: input.fileHandleForReading, output: output.fileHandleForWriting,
                diagnostics: diagnostics.fileHandleForWriting, checkAdmission: {}, withNativeLaunch: {
                    if mode == 10 { Thread.sleep(forTimeInterval: 8.1) }
                    try $0()
                })
        } catch { startFailure = error.localizedDescription }
        func exclusiveAvailable() -> Bool {
            for name in [".meeting-access.lock", ".backend-owner.lock"] {
                let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { return false }
                let available = flock(fd, LOCK_EX | LOCK_NB) == 0
                close(fd)
                if !available { return false }
            }
            return true
        }
        let exclusiveAfterStart = exclusiveAvailable()
        let didComplete = owner.hasStarted ? report.finished.wait(timeout: .now() + 5) == .success : false
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        let snapshot = report.lock.withLock { (report.bookmarkCalls, report.completion) }
        var json: [String: Any] = ["mode": mode, "source": root.path, "bookmark_calls": snapshot.0,
            "start_succeeded": startFailure == nil, "actual_observation_started": owner.hasStarted,
            "completed": didComplete, "elapsed_seconds": elapsed,
            "exclusive_available_after_start": exclusiveAfterStart,
            "exclusive_available_after_actual_exit": didComplete ? exclusiveAvailable() : false,
            "scope": "Signed model-free protocol/observer fixture; not current-backend inference or private-source capability qualification"]
        if let startFailure { json["start_failure"] = startFailure }
        if let value = snapshot.1 {
            json["kernel_raw_status"] = value.termination.rawWaitStatus
            json["kernel_exit_code"] = value.termination.exitCode
            json["kernel_signal"] = value.termination.signal
            json["kernel_pid"] = value.termination.processIdentifier
            json["reservation_pid"] = value.reservation.processID
            json["operation_status"] = value.operationResult?.operationStatus ?? -1
            json["completion_failure"] = value.failure ?? NSNull()
            json["registered_identity_matches_kernel"] = value.registeredProcess == .init(
                pid: value.termination.processIdentifier, startSeconds: value.termination.startSeconds,
                startMicroseconds: value.termination.startMicroseconds)
        }
        try? input.fileHandleForWriting.close()
        // Completion is actual service exit, so only now can EOF be expected.
        if didComplete {
            let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
            json["stdout_bytes"] = bytes.count
            json["stdout"] = String(decoding: bytes, as: UTF8.self)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        withExtendedLifetime(owner) {}
    }
}
