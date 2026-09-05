import Foundation
import Darwin

/// The UI view is disposable and bounded by both line count and bytes. A lease
/// releases its byte reservation when consumed, evicted, or abandoned. The
/// authoritative journal is written before a line reaches this sequence.
nonisolated struct BackendEventLines: AsyncSequence, Sendable {
    typealias Element = String
    private let stream: AsyncStream<LeasedLine>

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var iterator: AsyncStream<LeasedLine>.Iterator
        mutating func next() async -> String? {
            guard let line = await iterator.next() else { return nil }
            line.release()
            return line.value
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(iterator: stream.makeAsyncIterator()) }

    fileprivate init(stream: AsyncStream<LeasedLine>) { self.stream = stream }

    fileprivate final class ByteBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func reserve(_ count: Int) -> Bool {
            lock.withLock {
                guard count <= limit - bytes else { return false }
                bytes += count
                return true
            }
        }
        func release(_ count: Int) { lock.withLock { bytes -= count } }
        var pendingBytes: Int { lock.withLock { bytes } }
    }

    fileprivate final class LeasedLine: @unchecked Sendable {
        let value: String
        private let bytes: Int
        private let budget: ByteBudget
        private let lock = NSLock()
        private var released = false
        init(value: String, bytes: Int, budget: ByteBudget) {
            self.value = value
            self.bytes = bytes
            self.budget = budget
        }
        func release() {
            let first = lock.withLock {
                guard !released else { return false }
                released = true
                return true
            }
            if first { budget.release(bytes) }
        }
        deinit { release() }
    }
}

nonisolated struct BackendStdoutStatus: Sendable {
    var reachedEOF = false
    var closed = false
    var cleanupRequested = false
    var journalConfigured = false
    var journalStartOffset: UInt64 = 0
    var journaledLines: UInt64 = 0
    var journaledBytes: UInt64 = 0
    var durableBytes: UInt64 = 0
    var durableLines: UInt64 = 0
    var deliveredLines: UInt64 = 0
    var droppedUILines: UInt64 = 0
    var rejectedLines: UInt64 = 0
    var maximumBufferedLineBytes = 0
    var bufferedUIBytes = 0
    var firstError: String?
    var isComplete: Bool { reachedEOF && closed && firstError == nil }
}

nonisolated enum BackendJournalCheckpoint: Sendable { case prepare, write, synchronize, finalSynchronize }

nonisolated enum BackendStdoutDrainResult: Sendable {
    /// Reader resources closed; inspect isComplete. Explicit cleanup without
    /// EOF or any framing/I/O failure is drained but NOT a clean completion.
    case drained(BackendStdoutStatus)
    case timedOut(BackendStdoutStatus)
    case cancelled(BackendStdoutStatus)

    var status: BackendStdoutStatus {
        switch self {
        case .drained(let status), .timedOut(let status), .cancelled(let status): return status
        }
    }
}

/// One coalescing dispatch source per pipe, on one serial queue. This queue
/// alone owns reads, framing buffers, journal writes/sync, and handle closure.
/// It never enqueues one job or MainActor task per event. Snapshot/callback
/// configuration is lock protected; deadlines use an independent completion
/// signal and cannot be held open by a blocked file operation on this queue.
nonisolated final class BackendOutputReader: @unchecked Sendable {
    let lines: BackendEventLines
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let journalURL: URL?
    private let maximumLineBytes: Int
    private let beforeJournalIO: (@Sendable (BackendJournalCheckpoint) throws -> Void)?
    private let queue = DispatchQueue(label: "muesli.backend-output", qos: .utility)
    private let completion = TaskCompletion()
    private let budget = BackendEventLines.ByteBudget(limit: 8 * 1024 * 1024)
    private let continuation: AsyncStream<BackendEventLines.LeasedLine>.Continuation

    private let lock = NSLock()
    private var snapshot = BackendStdoutStatus()
    private var jsonCallback: (@Sendable (String) -> Void)?
    private var stderrCallback: (@Sendable (String) -> Void)?

    // Queue-owned state, except initialization before the sources start.
    private var state = BackendStdoutStatus()
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var journal: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var discardingStdoutLine = false
    private var discardingStderrLine = false
    private var stdoutEnding = false
    private var stderrEnding = false
    private var journalFailed = false
    private var prepared = false

    init(stdoutHandle: FileHandle, stderrHandle: FileHandle, journalURL: URL?,
         maximumLineBytes: Int, beforeJournalIO: (@Sendable (BackendJournalCheckpoint) throws -> Void)? = nil) {
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.journalURL = journalURL
        self.maximumLineBytes = min(4 * 1024 * 1024, max(1, maximumLineBytes))
        self.beforeJournalIO = beforeJournalIO
        let pair = AsyncStream<BackendEventLines.LeasedLine>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = pair.continuation
        lines = BackendEventLines(stream: pair.stream)
        state.journalConfigured = journalURL != nil
        snapshot = state
    }

    deinit {
        // Cancel handlers retain the resources and close them on their owning
        // queue. No cross-thread FileHandle close races a read or journal write.
        stdoutSource?.cancel()
        stderrSource?.cancel()
        continuation.finish()
    }

    var onJSONLine: (@Sendable (String) -> Void)? {
        get { lock.withLock { jsonCallback } }
        set { lock.withLock { jsonCallback = newValue } }
    }
    var onStderrLine: (@Sendable (String) -> Void)? {
        get { lock.withLock { stderrCallback } }
        set { lock.withLock { stderrCallback = newValue } }
    }

    func status() -> BackendStdoutStatus {
        var value = lock.withLock { snapshot }
        value.bufferedUIBytes = budget.pendingBytes
        return value
    }

    func prepare() throws {
        try queue.sync {
            guard !prepared else { throw failure("Backend output reader cannot be restarted.") }
            prepared = true
            do {
                if let journalURL {
                    let fd = open(journalURL.path, O_CREAT | O_RDWR | O_APPEND, S_IRUSR | S_IWUSR)
                    guard fd >= 0 else { throw posixError() }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    journal = handle
                    // A deadline does not release ownership. The advisory
                    // lock follows this open file description until the real
                    // cancel handler closes it, including hard-link aliases.
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                        throw failure("Another reader still owns this event journal.")
                    }
                    try beforeJournalIO?(.prepare)
                    let offset = try handle.seekToEnd()
                    if offset > 0 {
                        try handle.seek(toOffset: offset - 1)
                        guard try handle.read(upToCount: 1) == Data([0x0A]) else {
                            throw failure("Existing event journal has an incomplete final line; refusing to append.")
                        }
                        try handle.seekToEnd()
                    }
                    state.journalStartOffset = offset
                    // The journal may have just been created. Persist its
                    // directory entry before the child can publish events.
                    try handle.synchronize()
                    let directoryFD = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
                    guard directoryFD >= 0 else { throw posixError() }
                    defer { _ = Darwin.close(directoryFD) }
                    guard fsync(directoryFD) == 0 else { throw posixError() }
                }
                try makeNonblocking(stdoutHandle)
                try makeNonblocking(stderrHandle)
                let stdout = DispatchSource.makeReadSource(fileDescriptor: stdoutHandle.fileDescriptor, queue: queue)
                let stderr = DispatchSource.makeReadSource(fileDescriptor: stderrHandle.fileDescriptor, queue: queue)
                stdout.setEventHandler { [weak self] in self?.readAvailable(isStdout: true) }
                stderr.setEventHandler { [weak self] in self?.readAvailable(isStdout: false) }
                let outputHandle = stdoutHandle
                let errorHandle = stderrHandle
                let journalHandle = journal
                let completion = self.completion
                stdout.setCancelHandler { [weak self] in
                    do { try outputHandle.close() }
                    catch { self?.noteError("Backend stdout close failed: \(error.localizedDescription)") }
                    do { try journalHandle?.close() }
                    catch { self?.noteError("Event journal close failed: \(error.localizedDescription)") }
                    if let self {
                        self.state.closed = true
                        self.publishSnapshot()
                        self.continuation.finish()
                    }
                    completion.markCompleted()
                }
                stderr.setCancelHandler { try? errorHandle.close() }
                stdoutSource = stdout
                stderrSource = stderr
                publishSnapshot()
                stdout.resume()
                stderr.resume()
            } catch {
                noteError("Backend output setup failed: \(error.localizedDescription)")
                stdoutEnding = true
                stderrEnding = true
                try? journal?.close()
                journal = nil
                try? stdoutHandle.close()
                try? stderrHandle.close()
                state.closed = true
                publishSnapshot()
                continuation.finish()
                completion.markCompleted()
                throw error
            }
        }
    }

    /// Explicit cleanup is an abort unless this bounded final read sees EOF.
    /// It preserves complete currently available lines, never promises that
    /// an exited process's pipe tail has already been read, and never closes
    /// stdin (FramedWriter exclusively owns that handle).
    func cleanup() {
        queue.async { [self] in
            state.cleanupRequested = true
            if !prepared {
                prepared = true
                stdoutEnding = true
                stderrEnding = true
                noteError("Backend output cleaned up before start.")
                try? stdoutHandle.close()
                try? stderrHandle.close()
                state.closed = true
                publishSnapshot()
                continuation.finish()
                completion.markCompleted()
                return
            }
            if !stdoutEnding {
                readAvailable(isStdout: true)
                if !stdoutEnding {
                    noteError("Backend stdout cleanup occurred before EOF; event completeness is unconfirmed.")
                    endStdout(reachedEOF: false)
                }
            }
            if !stderrEnding { endStderr() }
            publishSnapshot()
        }
    }

    @concurrent func finish(timeoutSeconds: Double) async -> BackendStdoutDrainResult {
        switch await completion.wait(timeoutSeconds: timeoutSeconds) {
        case .completed: return .drained(status())
        case .timedOut: return .timedOut(status())
        case .cancelled: return .cancelled(status())
        }
    }

    private func readAvailable(isStdout: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isStdout ? !stdoutEnding : !stderrEnding else { return }
        let fd = (isStdout ? stdoutHandle : stderrHandle).fileDescriptor
        // A continuously writing process cannot starve cleanup or stderr on
        // this queue. DispatchSource coalesces readiness into another handler.
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<8 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                consume(Data(bytes.prefix(count)), isStdout: isStdout)
            } else if count == 0 {
                if isStdout { endStdout(reachedEOF: true) } else { endStderr() }
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                if isStdout {
                    noteError("Backend stdout read failed: \(posixError().localizedDescription)")
                    endStdout(reachedEOF: false)
                } else { endStderr() }
                return
            }
        }
        publishSnapshot()
    }

    private func consume(_ chunk: Data, isStdout: Bool) {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 0x0A)
            let end = newline ?? chunk.endIndex
            if isStdout {
                if !discardingStdoutLine {
                    if end - start > maximumLineBytes - stdoutBuffer.count {
                        stdoutBuffer.removeAll()
                        discardingStdoutLine = true
                        state.rejectedLines += 1
                        noteError("Backend stdout line exceeded \(maximumLineBytes) bytes.")
                    } else {
                        stdoutBuffer.append(chunk[start..<end])
                        state.maximumBufferedLineBytes = max(state.maximumBufferedLineBytes, stdoutBuffer.count)
                    }
                }
                if newline != nil {
                    if !discardingStdoutLine { acceptLine(stdoutBuffer, requiresCompleteJSON: false) }
                    stdoutBuffer.removeAll()
                    discardingStdoutLine = false
                }
            } else {
                if !discardingStderrLine {
                    if end - start > 64 * 1024 - stderrBuffer.count {
                        stderrBuffer.removeAll()
                        discardingStderrLine = true
                    } else { stderrBuffer.append(chunk[start..<end]) }
                }
                if newline != nil {
                    if !discardingStderrLine, let line = String(data: stderrBuffer, encoding: .utf8) {
                        onStderrLine?(line)
                    }
                    stderrBuffer.removeAll()
                    discardingStderrLine = false
                }
            }
            start = newline.map { $0 + 1 } ?? chunk.endIndex
        }
    }

    private func acceptLine(_ data: Data, requiresCompleteJSON: Bool) {
        guard let line = String(data: data, encoding: .utf8) else {
            state.rejectedLines += 1
            noteError("Backend stdout contained an invalid UTF-8 event.")
            return
        }
        // EOF is a valid delimiter only for a complete final JSON object.
        // A process killed halfway through JSON must not manufacture a final.
        if journalURL != nil {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                state.rejectedLines += 1
                noteError(requiresCompleteJSON
                          ? "Backend stdout ended with an incomplete JSON event."
                          : "Backend stdout contained a malformed JSON event.")
                return
            }
        }
        if journalURL != nil {
            guard !journalFailed, let journal else { state.rejectedLines += 1; return }
            do {
                try beforeJournalIO?(.write)
                var framed = data
                framed.append(0x0A)
                try journal.write(contentsOf: framed)
                state.journaledBytes += UInt64(framed.count)
                state.journaledLines += 1
                // Persistence happens before either lossy UI delivery or a
                // callback. A sync failure suppresses unconfirmed UI delivery.
                try beforeJournalIO?(.synchronize)
                try journal.synchronize()
                state.durableBytes = state.journaledBytes
                state.durableLines = state.journaledLines
                // The next event may block indefinitely in file IO. Publish
                // this acknowledged prefix before that can happen.
                publishSnapshot()
            } catch {
                journalFailed = true
                state.rejectedLines += 1
                noteError("Event journal write/sync failed: \(error.localizedDescription)")
                return
            }
        }
        onJSONLine?(line)
        let bytes = data.count
        guard budget.reserve(bytes) else { state.droppedUILines += 1; return }
        let lease = BackendEventLines.LeasedLine(value: line, bytes: bytes, budget: budget)
        switch continuation.yield(lease) {
        case .enqueued: state.deliveredLines += 1
        case .dropped(let old):
            old.release()
            state.deliveredLines += 1
            state.droppedUILines += 1
        case .terminated:
            lease.release()
            state.droppedUILines += 1
        @unknown default:
            lease.release()
            state.droppedUILines += 1
        }
    }

    private func endStdout(reachedEOF: Bool) {
        guard !stdoutEnding else { return }
        stdoutEnding = true
        state.reachedEOF = reachedEOF
        if reachedEOF && !discardingStdoutLine && !stdoutBuffer.isEmpty {
            acceptLine(stdoutBuffer, requiresCompleteJSON: true)
        }
        stdoutBuffer.removeAll()
        if !journalFailed {
            do {
                if journal != nil { try beforeJournalIO?(.finalSynchronize) }
                try journal?.synchronize()
                state.durableBytes = state.journaledBytes
                state.durableLines = state.journaledLines
            }
            catch { noteError("Event journal final sync failed: \(error.localizedDescription)") }
        }
        publishSnapshot()
        stdoutSource?.cancel()
    }

    private func endStderr() {
        guard !stderrEnding else { return }
        stderrEnding = true
        if !discardingStderrLine, !stderrBuffer.isEmpty,
           let line = String(data: stderrBuffer, encoding: .utf8) { onStderrLine?(line) }
        stderrBuffer.removeAll()
        stderrSource?.cancel()
    }

    private func noteError(_ message: String) {
        if state.firstError == nil { state.firstError = message }
        publishSnapshot()
    }
    private func publishSnapshot() { lock.withLock { snapshot = state } }
    private func makeNonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw posixError() }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "MuesliBackendOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
