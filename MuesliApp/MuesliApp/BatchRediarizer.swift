import Foundation

actor BatchRediarizer {
    enum Progress: String {
        case preparing
        case transcribing
        case diarizing
        case merging
        case complete
    }

    enum Stream: String, CaseIterable, Identifiable {
        case system
        case mic
        case both

        var id: String { rawValue }
    }

    struct Turn: Codable {
        let speakerId: String
        let stream: String
        let t0: Double
        let t1: Double
        let text: String

        enum CodingKeys: String, CodingKey {
            case speakerId = "speaker_id"
            case stream
            case t0
            case t1
            case text
        }
    }

    struct Result: Codable {
        let turns: [Turn]
        let speakers: [String]
        let duration: Double
    }

    private struct StatusEnvelope: Codable {
        let type: String
        let stage: String?
    }

    private struct ErrorEnvelope: Codable {
        let type: String
        let message: String?
    }

    private struct ResultEnvelope: Codable {
        let type: String
        let turns: [Turn]
        let speakers: [String]
        let duration: Double
    }

    private let timeoutSeconds: Double = 60 * 60

    func run(
        meetingDirectory: URL,
        backendPython: String,
        backendRoot: URL,
        stream: Stream,
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> Result {
        var process: BackendProcess?

        return try await withTaskCancellationHandler(operation: {
            let command = [
                backendPython,
                "-m",
                "diarise_transcribe.reprocess",
                meetingDirectory.path,
                "--stream",
                stream.rawValue,
            ]
            let env = backendEnvironment(root: backendRoot)
            let backend = try BackendProcess(command: command, workingDirectory: backendRoot, environment: env)
            process = backend

            var capturedResult: Result?
            var capturedError: String?

            backend.onJSONLine = { line in
                guard let data = line.data(using: .utf8) else { return }
                if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data),
                   status.type == "status",
                   let stage = status.stage,
                   let progress = Progress(rawValue: stage) {
                    progressHandler?(progress)
                    return
                }
                if let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
                   error.type == "error" {
                    capturedError = error.message ?? "Batch reprocess failed."
                    return
                }
                if let result = try? JSONDecoder().decode(ResultEnvelope.self, from: data),
                   result.type == "result" {
                    capturedResult = Result(turns: result.turns, speakers: result.speakers, duration: result.duration)
                }
            }

            try backend.start()
            let exitStatus = await backend.waitForExit(timeoutSeconds: timeoutSeconds)
            backend.cleanup()

            if Task.isCancelled {
                throw CancellationError()
            }

            guard let exitStatus = exitStatus else {
                backend.terminate()
                throw NSError(
                    domain: "BatchRediarizer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Batch reprocess timed out."]
                )
            }

            if let message = capturedError {
                throw NSError(
                    domain: "BatchRediarizer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            guard exitStatus == 0 else {
                throw NSError(
                    domain: "BatchRediarizer",
                    code: Int(exitStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Batch reprocess failed."]
                )
            }

            guard let result = capturedResult else {
                throw NSError(
                    domain: "BatchRediarizer",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No batch reprocess output received."]
                )
            }

            progressHandler?(.complete)
            return result
        }, onCancel: {
            process?.terminate()
            process?.cleanup()
        })
    }

    private func backendEnvironment(root: URL) -> [String: String] {
        let baseEnv = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let mergedPath: String
        if let existingPath = baseEnv["PATH"], !existingPath.isEmpty {
            mergedPath = "\(defaultPath):\(existingPath)"
        } else {
            mergedPath = defaultPath
        }
        return [
            "PYTHONPATH": root.appendingPathComponent("src").path,
            "PATH": mergedPath,
        ]
    }
}
