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

    /// Whether the child is still running. Used by the startup readiness
    /// gate to fail fast when the backend crashes during launch instead of
    /// waiting out the full handshake timeout (2026-07-16 RCA rec #3).
    var isRunning: Bool { process.isRunning }

    /// SIGKILL escalation for a child that ignores SIGTERM - the 2026-07-16
    /// incident's backend was wedged pre-read-loop and could plausibly have
    /// ignored SIGTERM too (RCA rec #6). Killing the child also closes the
    /// pipe's read end, which is what actually unblocks a `FramedWriter`
    /// write stuck on a full pipe. No-op if the process already exited.
    func forceKill() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
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

final class FramedWriter: FrameSending {
    /// Frame header size: type (1) + stream (1) + PTS (8) + length (4).
    private static let headerByteCount = 14

    private let handle: FileHandle
    private let writeQueue = DispatchQueue(label: "muesli.framed-writer", qos: .userInitiated)
    private var didFail = false
    var onWriteError: ((Error) -> Void)?

    /// Guards `backlog` and `isForceClosed` - `send` is called from the
    /// capture queue, the mic forwarder actor and MainActor, and completions
    /// land on `writeQueue`. Everything under the lock is cheap counter
    /// arithmetic; no per-frame timers or dispatch sources (2026-07-16 RCA
    /// rec #2 requires the detection itself to be near-free).
    private let stateLock = NSLock()
    private var backlog: WriteBacklogTracker
    private var isForceClosed = false
    /// Diagnostics beyond the tracker's backlog accounting: queued writes
    /// that threw (EPIPE after the child died, or writes landing after the
    /// handle closed) and sends rejected because `forceCloseStdin` already
    /// ran. Both count toward "audio that never reached the backend".
    private var failedWrites = 0
    private var rejectedAfterCloseFrames = 0

    init(
        stdinHandle: FileHandle,
        maxOutstandingBytes: Int = WriteBacklogTracker.defaultMaxOutstandingBytes,
        stallThresholdSeconds: TimeInterval = WriteBacklogTracker.defaultStallThresholdSeconds
    ) {
        self.handle = stdinHandle
        self.backlog = WriteBacklogTracker(
            maxOutstandingBytes: maxOutstandingBytes,
            stallThresholdSeconds: stallThresholdSeconds
        )
    }

    /// Fire-and-forget for callers, exactly as before - the audio hot paths
    /// must never block on the pipe. New since the 2026-07-16 incident:
    /// enqueue/completion accounting feeds the backpressure detector, and
    /// audio frames beyond the backlog cap are dropped-with-accounting
    /// instead of retained (a wedged child used to grow ~100MB of queued
    /// payloads invisibly). Control frames are never dropped.
    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        let frameBytes = Self.headerByteCount + payload.count
        let admitted: Bool = stateLock.withLock {
            guard !isForceClosed else {
                rejectedAfterCloseFrames += 1
                return false
            }
            return backlog.recordEnqueue(bytes: frameBytes, droppable: type == .audio, now: Date())
        }
        guard admitted else { return }
        writeQueue.async {
            let wroteOK = self.writeFrame(type: type, stream: stream, ptsUs: ptsUs, payload: payload)
            self.stateLock.withLock {
                self.backlog.recordCompletion(bytes: frameBytes, now: Date())
                if !wroteOK {
                    self.failedWrites += 1
                }
            }
        }
    }

    /// Read-only view of the backpressure state for AppModel's watchdog.
    struct BacklogSnapshot {
        let outstandingFrames: Int
        let outstandingBytes: Int
        let droppedFrames: Int
        let droppedBytes: Int
        let totalEnqueuedFrames: Int
        let totalCompletedFrames: Int
        let failedWrites: Int
        let rejectedAfterCloseFrames: Int
        let secondsSinceLastProgress: TimeInterval?
        let isStalled: Bool
    }

    func backlogSnapshot(now: Date = Date()) -> BacklogSnapshot {
        stateLock.withLock {
            BacklogSnapshot(
                outstandingFrames: backlog.outstandingFrames,
                outstandingBytes: backlog.outstandingBytes,
                droppedFrames: backlog.droppedFrames,
                droppedBytes: backlog.droppedBytes,
                totalEnqueuedFrames: backlog.totalEnqueuedFrames,
                totalCompletedFrames: backlog.totalCompletedFrames,
                failedWrites: failedWrites,
                rejectedAfterCloseFrames: rejectedAfterCloseFrames,
                secondsSinceLastProgress: backlog.secondsSinceLastProgress(now: now),
                isStalled: backlog.isStalled(now: now)
            )
        }
    }

    func isBacklogStalled(now: Date = Date()) -> Bool {
        stateLock.withLock { backlog.isStalled(now: now) }
    }

    /// FRESH no-progress check for the post-stop exit wait (gate BLOCKER 4
    /// fix): true only when work is outstanding RIGHT NOW and nothing has
    /// completed for at least `seconds`. Any completion resets the clock, so
    /// a backend that recovered - or recovers while the caller is waiting -
    /// stops satisfying this immediately; there is no historical latch here.
    func hasMadeNoProgress(forAtLeast seconds: TimeInterval, now: Date = Date()) -> Bool {
        stateLock.withLock { backlog.hasMadeNoProgress(forAtLeast: seconds, now: now) }
    }

    func closeStdinAfterDraining() {
        writeQueue.async {
            try? self.handle.close()
        }
    }

    /// Stop-path hardening for a wedged reader (2026-07-16 RCA rec #6).
    /// Two effects: new `send` calls are rejected immediately (with
    /// accounting - see `rejectedAfterCloseFrames`), and a close of the
    /// write end is enqueued on the writeQueue.
    ///
    /// The close deliberately goes THROUGH the queue, not around it
    /// (gate BLOCKER 3 fix): NSFileHandle must not be used from multiple
    /// threads simultaneously, so closing from the caller's thread while a
    /// write sits blocked on the queue would be an unsupported race
    /// (crash / half-written frame risk). Single-queue handle ownership is
    /// preserved instead, which means this method alone cannot unblock a
    /// write stuck on a full pipe - the queued close waits behind it. The
    /// designed unblocking agent is killing the READER (see
    /// AppModel.finalizeStoppedMeeting's SIGTERM->SIGKILL escalation):
    /// the child's death closes the pipe's read end, the blocked write
    /// fails over with EPIPE, any remaining queued writes fail fast, and
    /// then the queued close runs. Against a healthy-but-slow child the
    /// queue drains normally and the close delivers EOF, exactly like
    /// `closeStdinAfterDraining`.
    func forceCloseStdin() {
        stateLock.withLock { isForceClosed = true }
        writeQueue.async {
            try? self.handle.close()
        }
    }

    /// Returns whether both writes succeeded (runs on `writeQueue` only).
    private func writeFrame(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) -> Bool {
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
            return true
        } catch {
            if !didFail {
                didFail = true
                onWriteError?(error)
            }
            return false
        }
    }
}
