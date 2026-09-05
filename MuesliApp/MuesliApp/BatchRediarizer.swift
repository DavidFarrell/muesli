import Foundation

actor BatchRediarizer {
    nonisolated enum Progress: String, Sendable {
        case preparing
        case transcribing
        case diarizing
        case merging
        case complete
    }

    nonisolated enum Stream: String, CaseIterable, Identifiable, Sendable {
        case system
        case mic
        case both

        var id: String { rawValue }
    }

    nonisolated struct Turn: Codable, Sendable {
        let speakerId: String
        let stream: String
        let t0: Double
        let t1: Double
        let text: String
        var sourceSessionID: String? = nil

        enum CodingKeys: String, CodingKey {
            case speakerId = "speaker_id"
            case stream
            case t0
            case t1
            case text
            case sourceSessionID = "source_session_id"
        }
    }

    nonisolated struct Result: Codable, Sendable {
        let turns: [Turn]
        let speakers: [String]
        let duration: Double
        var sources: [SourceInventory]? = nil
        var runtimeIdentity: ObservedRuntimeIdentity? = nil
        enum CodingKeys: String, CodingKey {
            case turns, speakers, duration, sources
            case runtimeIdentity = "runtime_identity"
        }
    }

    nonisolated struct SourceInventory: Codable, Sendable {
        let sourceSessionID: String
        let audioFolder: String
        let timelineOffsetSeconds: Double
        let durationSeconds: Double
        let storageKind: String
        enum CodingKeys: String, CodingKey {
            case sourceSessionID = "source_session_id"
            case audioFolder = "audio_folder"
            case timelineOffsetSeconds = "timeline_offset_seconds"
            case durationSeconds = "duration_seconds"
            case storageKind = "storage_kind"
        }
    }

    nonisolated private struct StatusEnvelope: Codable {
        let type: String
        let stage: String?
    }

    nonisolated private struct ErrorEnvelope: Codable {
        let type: String
        let message: String?
    }

    nonisolated private struct ResultEnvelope: Codable {
        let type: String
        let turns: [Turn]
        let speakers: [String]
        let duration: Double
        let sources: [SourceInventory]?
        let runtimeIdentity: ObservedRuntimeIdentity?
        enum CodingKeys: String, CodingKey {
            case type, turns, speakers, duration, sources
            case runtimeIdentity = "runtime_identity"
        }
    }

    /// Reader callbacks and the caller share only this bounded lock-owned state.
    /// Results are accepted directly from the reader, before its lossy UI view.
    nonisolated private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result?
        private var error: String?
        private var stderr: [String] = []
        private var reported: Set<Progress> = []
        func receive(_ line: String) -> Progress? {
            guard let data = line.data(using: .utf8) else { return nil }
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                lock.withLock { if error == nil { error = "Batch stdout contained an incomplete or malformed JSON event." } }
                return nil
            }
            if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data),
               status.type == "status", let stage = status.stage, let progress = Progress(rawValue: stage) {
                return lock.withLock { reported.insert(progress).inserted ? progress : nil }
            }
            if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), failure.type == "error" {
                lock.withLock { if error == nil { error = failure.message ?? "Batch reprocess failed." } }
            } else if let value = try? JSONDecoder().decode(ResultEnvelope.self, from: data), value.type == "result" {
                lock.withLock { result = Result(turns: value.turns, speakers: value.speakers,
                                               duration: value.duration, sources: value.sources, runtimeIdentity: value.runtimeIdentity) }
            } else if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data), status.type == "status" {
                // A future progress stage is harmless; a malformed result is not.
                return nil
            } else {
                lock.withLock { if error == nil { error = "Batch stdout contained a malformed JSON protocol event." } }
            }
            return nil
        }
        func receiveStderr(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lock.withLock {
                stderr.append(trimmed)
                if stderr.count > 20 { stderr.removeFirst(stderr.count - 20) }
            }
        }
        func snapshot() -> (Result?, String?, String?) {
            lock.withLock { (result, error, stderr.reversed().first { $0 != "Traceback (most recent call last):" }) }
        }
    }

    private let timeoutSeconds: Double
    private let admission = BackendAdmissionOwner()
    init(timeoutSeconds: Double = 60 * 60) { self.timeoutSeconds = timeoutSeconds }

    func run(
        meetingDirectory: URL,
        backendPython: String? = nil,
        backendRoot: URL,
        stream: Stream,
        progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async throws -> Result {
        let environment = { @Sendable in Self.backendEnvironment(root: backendRoot) }
        return try await execute(protecting: meetingDirectory, progressHandler: progressHandler) { accumulator in
            let build: (String) throws -> BackendProcess = { python in
                let command = [python, "-m", "diarise_transcribe.reprocess", meetingDirectory.path, "--stream", stream.rawValue]
                let backend = try BackendProcess(command: command, workingDirectory: backendRoot, environment: environment())
                Self.attach(backend, accumulator: accumulator, progressHandler: progressHandler)
                return backend
            }
            if let backendPython { return BackendAdmissionOwner.Resources(backend: try build(backendPython)) }
            return try BackendLaunchConfiguration.scoped(root: backendRoot, build: build)
        }
    }

    /// Runs the same production admission path with model-free child/IO seams.
    func runCommand(_ command: [String], backendRoot: URL,
                    eventJournalURL: URL? = nil,
                    beforeEventJournalIO: (@Sendable (BackendJournalCheckpoint) throws -> Void)? = nil,
                    launchCheckpoint: (@Sendable (BackendLaunchCheckpoint) throws -> Void)? = nil,
                    progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil) async throws -> Result {
        try await execute(protecting: backendRoot, progressHandler: progressHandler) { accumulator in
            let backend = try BackendProcess(command: command, workingDirectory: backendRoot,
                environment: Self.backendEnvironment(root: backendRoot), eventJournalURL: eventJournalURL,
                beforeEventJournalIO: beforeEventJournalIO, launchCheckpoint: launchCheckpoint)
            Self.attach(backend, accumulator: accumulator, progressHandler: progressHandler)
            return BackendAdmissionOwner.Resources(backend: backend)
        }
    }

    private func execute(protecting folder: URL, progressHandler: (@MainActor @Sendable (Progress) -> Void)?,
                         factory: @escaping @Sendable (Accumulator) throws -> BackendAdmissionOwner.Resources) async throws -> Result {
        let accumulator = Accumulator()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        let attempt = try admission.start(protecting: folder, timeoutSeconds: min(8, timeoutSeconds)) { try factory(accumulator) }
        return try await withTaskCancellationHandler(operation: {
            do {
                switch await attempt.waitUntilReady() {
                case .ready: break
                case .failed(let message): throw Self.failure(1, message)
                case .timedOut: throw Self.failure(1, "Batch startup timed out; its original operation is still closing.")
                case .cancelled: throw CancellationError()
                }
                try Task.checkCancellation()
                let backend = try attempt.claim().backend
                let remaining = ContinuousClock.now.duration(to: deadline)
                let seconds = max(0, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
                let exitStatus = await backend.waitForExit(timeoutSeconds: seconds)
                try Task.checkCancellation()
                guard let exitStatus else { throw Self.failure(1, "Batch reprocess timed out.") }
                let drain = await backend.finishStdout(timeoutSeconds: 5)
                try Task.checkCancellation()
                guard case .drained(let status) = drain, status.isComplete else {
                    throw Self.failure(4, "Batch output did not completely drain: \(drain.status.firstError ?? "stdout deadline expired")")
                }
                let (result, error, stderr) = accumulator.snapshot()
                if let error { throw Self.failure(2, error) }
                guard exitStatus == 0 else {
                    throw Self.failure(Int(exitStatus), stderr.map { "Batch reprocess failed (\($0))" } ?? "Batch reprocess failed.")
                }
                guard let result else { throw Self.failure(3, "No batch reprocess output received.") }
                backend.cleanup()
                _ = await attempt.waitUntilClosed(timeoutSeconds: 2)
                try Task.checkCancellation()
                if let progressHandler { await progressHandler(.complete) }
                return result
            } catch {
                // Cancelling the wait neither closes the journal nor releases
                // the original child/scope. Admission stays busy until real cleanup.
                attempt.cancel()
                // Preserve the prompt native-exit barrier when it can finish,
                // but a blocked setup/close cannot hold a cancelled UI caller.
                _ = await Task.detached { await attempt.waitUntilClosed(timeoutSeconds: 2) }.value
                throw error
            }
        }, onCancel: { attempt.cancel() })
    }

    nonisolated private static func attach(_ backend: BackendProcess, accumulator: Accumulator,
                                          progressHandler: (@MainActor @Sendable (Progress) -> Void)?) {
        backend.onJSONLine = { line in
            if let progress = accumulator.receive(line), let progressHandler {
                Task { @MainActor in progressHandler(progress) }
            }
        }
        backend.onStderrLine = { accumulator.receiveStderr($0) }
    }

    nonisolated private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "BatchRediarizer", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated static func backendEnvironment(root: URL) -> [String: String] {
        let baseEnv = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let numbaCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-numba-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: numbaCacheDir, withIntermediateDirectories: true)
        let mergedPath: String
        if let existingPath = baseEnv["PATH"], !existingPath.isEmpty {
            mergedPath = "\(defaultPath):\(existingPath)"
        } else {
            mergedPath = defaultPath
        }
        return [
            "MUESLI_ALLOW_MODEL_DOWNLOADS": "0",
            "HF_HUB_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "PYTHONPATH": root.appendingPathComponent("src").path,
            "PATH": mergedPath,
            "NUMBA_CACHE_DIR": numbaCacheDir.path,
        ]
    }
}
