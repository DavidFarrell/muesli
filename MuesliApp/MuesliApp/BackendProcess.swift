import Foundation

// MARK: - Backend Process

nonisolated final class BackendProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let workingDirectory: URL?
    private let environment: [String: String]?

    private var buffer = Data()
    private var stderrBuffer = Data()
    private var stdoutContinuation: AsyncStream<String>.Continuation?
    let stdoutLines: AsyncStream<String>

    var onJSONLine: ((String) -> Void)?
    var onStderrLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    var stdin: FileHandle { stdinPipe.fileHandleForWriting }

    init(command: [String], workingDirectory: URL? = nil, environment: [String: String]? = nil) throws {
        guard !command.isEmpty else {
            throw NSError(domain: "Muesli", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }

        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        self.workingDirectory = workingDirectory
        self.environment = environment

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var continuation: AsyncStream<String>.Continuation?
        self.stdoutLines = AsyncStream<String>(bufferingPolicy: .bufferingNewest(500)) { cont in
            continuation = cont
        }
        self.stdoutContinuation = continuation
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.buffer.append(chunk)

            while true {
                if let range = self.buffer.firstRange(of: Data([0x0A])) {
                    let lineData = self.buffer.subdata(in: 0..<range.lowerBound)
                    self.buffer.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.onJSONLine?(line)
                        self.stdoutContinuation?.yield(line)
                    }
                } else {
                    break
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.stderrBuffer.append(chunk)

            while true {
                if let range = self.stderrBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = self.stderrBuffer.subdata(in: 0..<range.lowerBound)
                    self.stderrBuffer.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.onStderrLine?(line)
                    }
                } else {
                    break
                }
            }
        }

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        process.terminationHandler = { [weak self] proc in
            self?.onExit?(proc.terminationStatus)
        }

        try process.run()
    }

    func stop() {
        cleanup()
        terminate()
    }

    func requestStop() {
        stdinPipe.fileHandleForWriting.closeFile()
    }

    func waitForExit(timeoutSeconds: Double) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func cleanup() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()
        stdoutContinuation?.finish()
    }
}

// MARK: - Framed Writer

enum StreamID: UInt8 {
    case system = 0
    case mic = 1
}

enum MsgType: UInt8 {
    case audio = 1
    case screenshotEvent = 2
    case meetingStart = 3
    case meetingStop = 4
}

final class FramedWriter {
    private let handle: FileHandle
    private let writeQueue = DispatchQueue(label: "muesli.framed-writer")
    private var didFail = false
    var onWriteError: ((Error) -> Void)?

    init(stdinHandle: FileHandle) {
        self.handle = stdinHandle
    }

    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        writeQueue.async {
            self.writeFrame(type: type, stream: stream, ptsUs: ptsUs, payload: payload)
        }
    }

    func sendSync(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        writeQueue.sync {
            self.writeFrame(type: type, stream: stream, ptsUs: ptsUs, payload: payload)
        }
    }

    func closeStdinAfterDraining() {
        writeQueue.sync {
            try? self.handle.close()
        }
    }

    private func writeFrame(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        var header = Data()
        header.append(type.rawValue)
        header.append(stream.rawValue)

        var pts = ptsUs.littleEndian
        header.append(Data(bytes: &pts, count: 8))

        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: payload)
        } catch {
            if !didFail {
                didFail = true
                onWriteError?(error)
            }
            return
        }
    }
}
