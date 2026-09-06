import Foundation
import Darwin

/// The source recording is owned by the app, independently of the inference
/// process. Only committed PCM prefixes in source-recording.json are readable
/// by inference. A commit synchronizes both PCM files before replacing the
/// manifest. Queued/accepted bytes and committed bytes are deliberately distinct.
///
/// Synchronization: admission/status use `lock`; files and manifest use `queue`.
/// No file operation runs under the admission lock or on MainActor. At most
/// maxPendingBytes of audio and one drain work item can be pending at a time.
nonisolated final class LocalAudioRecorder: FrameSending, @unchecked Sendable {
    enum Source: String, Codable, CaseIterable, Sendable { case system, mic }

    struct StreamState: Codable, Sendable {
        var sample_rate = 16_000
        var channels = 1
        var committed_bytes: Int64 = 0
        var captured_frames: Int64 = 0
        var gap_frames: Int64 = 0
        var overlap_frames: Int64 = 0
        var dropped_frames: Int64 = 0
    }

    struct Manifest: Codable, Sendable {
        var schema_version = 1
        let session_id: String
        let timeline_offset_us: Int64
        var committed_at: Date?
        var revision: Int64 = 0
        var completed = false
        var streams: [String: StreamState]
        var problem_count: Int64 = 0
        var last_problem: String?
        var losses: [Loss] = []
        var loss_details_omitted: Int64 = 0
        // Optional additive fields keep manifests from older app versions readable.
        var power_events: [PowerEvent]?
        var power_events_omitted: Int64?
        var clock_corrections: [String: ClockCorrectionSummary]?
    }

    /// Fixed-size per-stream observations, including the latest generation in
    /// the totals. These count conversion work, never persisted PCM or losses.
    /// Historical generations are folded into totals before replacing latest.
    struct ClockCorrectionSummary: Codable, Sendable, Equatable {
        var generation_count: Int64 = 1
        var native_frames: Int64
        var nominal_output_frames: Int64
        var host_output_frames: Int64
        var observed_intervals: Int64
        var uncertain_intervals: Int64
        var min_rate_ratio: Double?
        var max_rate_ratio: Double?
        var counters_saturated = false
        var latest: CapturedClockCorrection

        init(_ correction: CapturedClockCorrection) {
            latest = correction
            native_frames = correction.native_frames
            nominal_output_frames = correction.nominal_output_frames
            host_output_frames = correction.host_output_frames
            observed_intervals = correction.observed_intervals
            uncertain_intervals = correction.uncertain_intervals
            min_rate_ratio = correction.min_rate_ratio
            max_rate_ratio = correction.max_rate_ratio
        }

        mutating func observe(_ correction: CapturedClockCorrection) {
            guard correction.isValid, correction.generation >= latest.generation else { return }
            let sameGeneration = correction.generation == latest.generation
            if sameGeneration {
                guard correction.native_frames >= latest.native_frames,
                      correction.nominal_output_frames >= latest.nominal_output_frames,
                      correction.host_output_frames >= latest.host_output_frames,
                      correction.observed_intervals >= latest.observed_intervals,
                      correction.uncertain_intervals >= latest.uncertain_intervals else { return }
            }
            var saturated = counters_saturated
            func add(_ total: Int64, _ current: Int64, _ previous: Int64) -> Int64 {
                let sum = total.addingReportingOverflow(current - (sameGeneration ? previous : 0))
                if sum.overflow { saturated = true; return Int64.max }
                return sum.partialValue
            }
            native_frames = add(native_frames, correction.native_frames, latest.native_frames)
            nominal_output_frames = add(nominal_output_frames, correction.nominal_output_frames, latest.nominal_output_frames)
            host_output_frames = add(host_output_frames, correction.host_output_frames, latest.host_output_frames)
            observed_intervals = add(observed_intervals, correction.observed_intervals, latest.observed_intervals)
            uncertain_intervals = add(uncertain_intervals, correction.uncertain_intervals, latest.uncertain_intervals)
            if !sameGeneration {
                let count = generation_count.addingReportingOverflow(1)
                generation_count = count.overflow ? Int64.max : count.partialValue
                saturated = saturated || count.overflow
            }
            counters_saturated = saturated
            min_rate_ratio = [min_rate_ratio, correction.min_rate_ratio].compactMap { $0 }.min()
            max_rate_ratio = [max_rate_ratio, correction.max_rate_ratio].compactMap { $0 }.max()
            latest = correction
        }

        var isValid: Bool {
            generation_count > 0 && latest.isValid
                && native_frames >= latest.native_frames && nominal_output_frames >= latest.nominal_output_frames
                && host_output_frames >= latest.host_output_frames && observed_intervals >= latest.observed_intervals
                && uncertain_intervals >= latest.uncertain_intervals
                && CapturedClockCorrection(native_frames: native_frames, nominal_output_frames: nominal_output_frames,
                    host_output_frames: host_output_frames, observed_intervals: observed_intervals,
                    uncertain_intervals: uncertain_intervals, min_rate_ratio: min_rate_ratio,
                    max_rate_ratio: max_rate_ratio, generation: latest.generation).isValid
        }
    }

    struct PowerEvent: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case willSleep = "will_sleep", didWake = "did_wake", monitorUnavailable = "monitor_unavailable"
            case bindingDuringSleep = "binding_during_sleep"
        }
        let kind: Kind
        let cycle_id: UUID?
        let source_time_us: Int64?
        let process_continuous_us: Int64
        // Duration between observed notifications, not claimed captured media
        // or an exact kernel sleep duration. Never changes PCM sample positions.
        let observed_pause_us: Int64?
    }

    struct Loss: Codable, Sendable {
        let source: String
        let reason: String
        let start_frame: Int64?
        var end_frame: Int64?
        var frames: Int64
    }

    enum Checkpoint: Sendable { case write(Source), sync(Source), manifest, export(Source) }

    struct Status: Sendable {
        let accepting: Bool
        let queuedBytes: Int
        let committedBytes: Int64
        let rejectedFrames: Int64
        let error: String?
        let secondsSinceCommit: TimeInterval
        let uncommittedPackets: Int64
        let secondsWithoutCommitProgress: TimeInterval
    }

    enum RecorderError: Error, LocalizedError {
        case invalidManifest
        case existingSource
        case invalidAudio
        case timestampOutOfRange
        case truncatedSource(String)
        case wavTooLarge(String)
        case sourceFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceFailed(let message): return message
            case .invalidManifest: return "The source recording manifest is invalid."
            case .existingSource: return "Refusing to overwrite an existing source recording."
            case .invalidAudio: return "Audio is not aligned 16 kHz mono PCM."
            case .timestampOutOfRange: return "An audio timestamp is outside the supported recording interval."
            case .truncatedSource(let source): return "The committed \(source) source is truncated."
            case .wavTooLarge(let source): return "The \(source) source exceeds the WAV size limit; PCM remains preserved."
            }
        }
    }

    private struct Packet: Sendable {
        let source: Source
        let ptsUs: Int64
        let payload: Data
    }

    static let manifestName = "source-recording.json"
    private let directory: URL
    private let queue = DispatchQueue(label: "muesli.source-recorder", qos: .userInitiated)
    private let lock = NSLock()
    private let maxPendingBytes: Int
    private let maximumDurationUs: Int64
    private let commitInterval: TimeInterval
    private let beforeIO: (@Sendable (Checkpoint) throws -> Void)?

    // Lock-owned fields. `pending` has bounded bytes AND packet count: even an
    // adversarial producer of 2-byte buffers cannot queue millions of objects.
    private var pending: [Packet] = []
    private var pendingBytes = 0
    private var acceptedPackets: Int64 = 0
    private var committedPackets: Int64 = 0
    private var workStartedAt = ProcessInfo.processInfo.systemUptime
    private var drainScheduled = false
    private var accepting = true
    // Stream-local append failure rejects only that stream at admission.
    // Shared commit/manifest failures still close the global gate.
    private var failedAdmissionSources: Set<Source> = []
    private var closeRequested = false
    private var closeWaitExpired = false
    private var rejectedFrames: [Source: Int64] = [:]
    private var latestError: String?
    private var committedBytes: Int64 = 0
    private var lastCommitUptime = ProcessInfo.processInfo.systemUptime
    private var rejectedLosses: [Loss] = []
    private var omittedLosses: Int64 = 0
    private var pendingPowerEvents: [PowerEvent] = []
    private var omittedPowerEvents: Int64 = 0
    private var clockCorrections: [Source: ClockCorrectionSummary] = [:]
    private var closedManifest: Manifest?
    private let closeCompletion = TaskCompletion()
    private let quitWork: ShutdownWorkRegistry.Token

    // Queue-owned fields.
    private var handles: [Source: FileHandle] = [:]
    private var sourceLease: FileHandle?
    private var meetingAccess: MeetingFileAccess? // owned by queue
    private var positions: [Source: Int64] = [:]
    private var manifest: Manifest
    private var dirty = false
    private var processedPackets: Int64 = 0
    private var failedSources: [Source: String] = [:]
    private var timer: DispatchSourceTimer?

    init(directory: URL, sessionID: String = UUID().uuidString, timelineOffsetUs: Int64 = 0,
         maxPendingBytes: Int = 2 * 1024 * 1024,
         maximumDurationSeconds: Int64 = 24 * 60 * 60,
         commitInterval: TimeInterval = 0.5,
         shutdown: ShutdownWorkRegistry = .shared,
         beforeIO: (@Sendable (Checkpoint) throws -> Void)? = nil) throws {
        quitWork = try shutdown.begin("Finishing audio recording")
        self.directory = directory
        self.maxPendingBytes = max(2, maxPendingBytes)
        maximumDurationUs = max(1, min(maximumDurationSeconds, 24 * 60 * 60)) * 1_000_000
        self.commitInterval = max(0.05, commitInterval)
        self.beforeIO = beforeIO
        guard timelineOffsetUs >= 0 else { throw RecorderError.invalidManifest }
        manifest = Manifest(session_id: sessionID, timeline_offset_us: timelineOffsetUs, streams: Dictionary(
            uniqueKeysWithValues: Source.allCases.map { ($0.rawValue, StreamState()) }))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceLease = try Self.acquireSourceLease(directory: directory, create: true)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.manifestName).path),
              Source.allCases.allSatisfy({ !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.rawValue + ".pcm").path) }) else {
            throw RecorderError.existingSource
        }
        // These URLs belong to this newly created session only. Existing
        // source files are never truncated as a fallback or initialization fix.
        for source in Source.allCases {
            let url = directory.appendingPathComponent(source.rawValue + ".pcm")
            try Data().write(to: url, options: .withoutOverwriting)
            handles[source] = try FileHandle(forWritingTo: url)
            positions[source] = 0
        }
        try Self.writeManifest(manifest, directory: directory)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + self.commitInterval, repeating: self.commitInterval)
        timer.setEventHandler { [weak self] in self?.commitIfNeeded() }
        self.timer = timer
        timer.resume()
    }

    func retainMeetingAccess(_ access: MeetingFileAccess) {
        queue.async { [self] in meetingAccess = access }
    }

    deinit {
        timer?.cancel()
        // A missing explicit finish leaves completed=false on disk. Do not
        // manufacture clean completion from deinit or trust uncommitted tails.
        for handle in handles.values { try? handle.close() }
        try? sourceLease?.close()
    }

    /// Returns admission, not a durability acknowledgment. Invalid/rejected
    /// data is counted even if the disk cannot accept the diagnostic itself.
    @discardableResult
    func record(source: Source, ptsUs: Int64, payload: Data) -> Bool {
        guard !payload.isEmpty else { return true }
        lock.lock()
        let valid = payload.count % 2 == 0 && ptsUs >= 0 && ptsUs <= maximumDurationUs
        let sourceFailed = failedAdmissionSources.contains(source)
        guard accepting, !sourceFailed, valid, pending.count < 4096,
              payload.count <= maxPendingBytes - pendingBytes else {
            rejectedFrames[source, default: 0] += Int64((payload.count + 1) / 2)
            let frame = valid ? (ptsUs * 16_000 + 500_000) / 1_000_000 : nil
            Self.addLoss(Loss(source: source.rawValue,
                              reason: !valid ? "invalid_audio" : (sourceFailed ? "source_failed" : (accepting ? "ingress_overflow" : "after_close_or_failure")),
                              start_frame: frame, end_frame: frame.map { $0 + Int64(payload.count / 2) },
                              frames: Int64((payload.count + 1) / 2)),
                         to: &rejectedLosses, omitted: &omittedLosses)
            if !valid { latestError = RecorderError.invalidAudio.localizedDescription }
            else if accepting && !sourceFailed { latestError = "Source recording queue is full; audio was lost." }
            lock.unlock()
            return false
        }
        if acceptedPackets == committedPackets { workStartedAt = ProcessInfo.processInfo.systemUptime }
        acceptedPackets += 1
        pending.append(Packet(source: source, ptsUs: ptsUs, payload: payload))
        pendingBytes += payload.count
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
        return true
    }

    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        guard type == .audio else { return }
        record(source: stream == .mic ? .mic : .system, ptsUs: ptsUs, payload: payload)
    }

    func reportLoss(stream: StreamID, ptsUs: Int64, frames: Int64, reason: String) {
        noteLoss(source: stream == .mic ? .mic : .system, ptsUs: ptsUs, frames: frames, reason: reason)
    }

    func reportFailure(stream: StreamID, message: String) {
        let source: Source = stream == .mic ? .mic : .system
        lock.withLock {
            latestError = source.rawValue + " capture failed: " + String(message.prefix(256))
            Self.addLoss(Loss(source: source.rawValue, reason: "source_failure_unknown_range",
                              start_frame: nil, end_frame: nil, frames: 0),
                         to: &rejectedLosses, omitted: &omittedLosses)
        }
    }

    /// Coalesced in memory under the same admission lock as close. The source
    /// timer/final barrier persists at most two summaries without per-packet I/O.
    func reportClockCorrection(stream: StreamID, correction: CapturedClockCorrection) {
        guard correction.isValid else { return }
        let source: Source = stream == .mic ? .mic : .system
        lock.withLock {
            guard !closeRequested else { return }
            if var summary = clockCorrections[source] {
                summary.observe(correction)
                clockCorrections[source] = summary
            } else {
                clockCorrections[source] = ClockCorrectionSummary(correction)
            }
        }
    }

    /// Admission only; the original source queue commits both evidence and the
    /// incomplete marker even if post-wake native audio resumes immediately.
    func reportPowerEvent(_ event: PowerEvent) {
        lock.withLock {
            guard !closeRequested else { return }
            if pendingPowerEvents.count < 128 { pendingPowerEvents.append(event) }
            else { omittedPowerEvents = min(Int64.max - 1, omittedPowerEvents) + 1 }
            switch event.kind {
            case .monitorUnavailable:
                latestError = "System sleep observation is unavailable; capture continuity cannot be verified."
            case .bindingDuringSleep:
                latestError = "Recording began during a pending sleep transition; capture continuity cannot be verified."
            case .willSleep, .didWake:
                latestError = "Recording was interrupted by system sleep. The unrecorded interval is preserved in source power events."
            }
        }
    }

    /// Upstream bounded ingress reports rejected converted samples here.
    /// No payload is retained and the same queue commits this loss ledger.
    func noteLoss(source: Source, ptsUs: Int64, frames: Int64, reason: String) {
        guard frames > 0, frames <= maximumDurationUs * 16_000 / 1_000_000 else { return }
        lock.lock()
        rejectedFrames[source, default: 0] += frames
        let start: Int64? = ptsUs >= 0 && ptsUs <= maximumDurationUs
            ? (ptsUs * 16_000 + 500_000) / 1_000_000 : nil
        Self.addLoss(Loss(source: source.rawValue, reason: String(reason.prefix(128)),
                          start_frame: start, end_frame: start.map { $0 + frames }, frames: frames),
                     to: &rejectedLosses, omitted: &omittedLosses)
        latestError = "Audio was lost before reaching the source recorder (" + String(reason.prefix(128)) + ")."
        lock.unlock()
    }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let uncommitted = acceptedPackets - committedPackets
        let stalledFor = uncommitted > 0 ? max(0, now - max(lastCommitUptime, workStartedAt)) : 0
        return Status(accepting: accepting, queuedBytes: pendingBytes,
                      committedBytes: committedBytes,
                      rejectedFrames: rejectedFrames.values.reduce(0, +),
                      error: latestError ?? (closeWaitExpired && closedManifest == nil ? "Source close is still pending; its committed prefix remains recoverable." : nil) ?? (stalledFor > 5 ? "Source audio has not made commit progress for over five seconds." : nil),
                      secondsSinceCommit: max(0, now - lastCommitUptime),
                      uncommittedPackets: uncommitted, secondsWithoutCommitProgress: stalledFor)
    }

    /// Idempotent stop. Admission closes synchronously; all already accepted
    /// packets finish before final commit and compatibility WAV generation.
    /// Expiry leaves the file owner and queued close intact; it never grants
    /// permission to close its handles from another queue or claim completion.
    func finish(timeoutSeconds: Double = 10) async -> Manifest? {
        requestFinish()
        let outcome = await closeCompletion.wait(timeoutSeconds: timeoutSeconds)
        guard outcome == .completed else {
            lock.withLock { closeWaitExpired = true }
            return nil
        }
        return lock.withLock { closedManifest }
    }

    /// Nonblocking close admission, shared with abandoned-start cleanup.
    func requestFinish() {
        let schedule = lock.withLock {
            accepting = false
            let schedule = !closeRequested
            closeRequested = true
            return schedule
        }
        if schedule { queue.async { [self] in closeOnQueue() } }
    }

    /// One immutable owner can retain an abandoned preparation until the
    /// actual close and source-lease release, independently of wait deadlines.
    func observeClosed(_ observer: @escaping @Sendable () -> Void) {
        closeCompletion.observeCompletion(observer)
    }

    private func drain() {
        // One batch per work item keeps the commit timer/close barrier from
        // being starved by a continuously replenished producer.
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        for packet in batch {
            do { try append(packet) }
            catch {
                lock.lock()
                rejectedFrames[packet.source, default: 0] += Int64(packet.payload.count / 2)
                latestError = packet.source.rawValue + " source write failed: " + error.localizedDescription
                failedAdmissionSources.insert(packet.source)
                if let recorderError = error as? RecorderError, case .invalidManifest = recorderError {
                    accepting = false // Invalid shared stream/handle inventory is store-wide.
                }
                let start = (packet.ptsUs * 16_000 + 500_000) / 1_000_000
                Self.addLoss(Loss(source: packet.source.rawValue, reason: "source_write_failed",
                                  start_frame: start, end_frame: start + Int64(packet.payload.count / 2),
                                  frames: Int64(packet.payload.count / 2)),
                             to: &rejectedLosses, omitted: &omittedLosses)
                lock.unlock()
                failedSources[packet.source] = failedSources[packet.source] ?? error.localizedDescription
                manifest.problem_count += 1
                manifest.last_problem = error.localizedDescription
                dirty = true
            }
            lock.lock()
            processedPackets += 1
            pendingBytes -= packet.payload.count
            lock.unlock()
        }
        lock.lock()
        let again = !pending.isEmpty
        if !again { drainScheduled = false }
        lock.unlock()
        if again { queue.async { [self] in drain() } }
    }

    private func append(_ packet: Packet) throws {
        if let failure = failedSources[packet.source] { throw RecorderError.sourceFailed(failure) }
        guard let handle = handles[packet.source], var state = manifest.streams[packet.source.rawValue] else {
            throw RecorderError.invalidManifest
        }
        let start = (packet.ptsUs * 16_000 + 500_000) / 1_000_000
        let position = positions[packet.source, default: 0]
        let count = Int64(packet.payload.count / 2)
        guard start + count <= maximumDurationUs * 16_000 / 1_000_000 else {
            throw RecorderError.timestampOutOfRange
        }
        var data = packet.payload
        var writeAt = position
        var loss: Loss?
        if start > position {
            // Sparse zeros represent a real source-timestamp gap. Never
            // allocate silence proportional to an arbitrary timestamp jump.
            try handle.seek(toOffset: UInt64(start * 2))
            state.gap_frames += start - position
            loss = Loss(source: packet.source.rawValue, reason: position == 0 ? "initial_source_alignment" : "source_timestamp_gap",
                        start_frame: position, end_frame: start, frames: start - position)
            writeAt = start
        } else if start < position {
            let overlap = min(position - start, count)
            state.overlap_frames += overlap
            loss = Loss(source: packet.source.rawValue, reason: "overlapping_source_timestamp",
                        start_frame: start, end_frame: start + overlap, frames: overlap)
            data = data.dropFirst(Int(overlap * 2))
        }
        if !data.isEmpty {
            try beforeIO?(.write(packet.source))
            try handle.write(contentsOf: data)
            positions[packet.source] = writeAt + Int64(data.count / 2)
            state.captured_frames += Int64(data.count / 2)
        }
        if let loss {
            appendManifestLoss(loss)
            if loss.reason != "initial_source_alignment" {
                let message = "Source audio has a timestamp discontinuity (" + loss.reason + ")."
                manifest.problem_count += 1
                manifest.last_problem = message
                lock.withLock { latestError = message }
            }
        }
        manifest.streams[packet.source.rawValue] = state
        dirty = true
    }

    private func commitIfNeeded() {
        lock.lock()
        let drops = rejectedFrames
        let error = latestError
        let losses = rejectedLosses
        let omitted = omittedLosses
        let power = pendingPowerEvents
        let powerOmitted = omittedPowerEvents
        let clocks = clockCorrections
        rejectedLosses.removeAll()
        omittedLosses = 0
        pendingPowerEvents.removeAll(keepingCapacity: true)
        omittedPowerEvents = 0
        lock.unlock()
        if !clocks.isEmpty {
            let summaries = Dictionary(uniqueKeysWithValues: clocks.map { ($0.key.rawValue, $0.value) })
            if manifest.clock_corrections != summaries {
                manifest.clock_corrections = summaries
                dirty = true
            }
        }
        if !power.isEmpty || powerOmitted > 0 {
            var recorded = manifest.power_events ?? []
            let admitted = power.prefix(max(0, 128 - recorded.count))
            recorded.append(contentsOf: admitted)
            manifest.power_events = recorded
            let lost = powerOmitted.addingReportingOverflow(Int64(power.count - admitted.count))
            let total = (manifest.power_events_omitted ?? 0).addingReportingOverflow(lost.partialValue)
            manifest.power_events_omitted = lost.overflow || total.overflow ? Int64.max : total.partialValue
            manifest.completed = false
            dirty = true
        }
        for loss in losses {
            appendManifestLoss(loss)
            dirty = true
        }
        manifest.loss_details_omitted += omitted
        if omitted > 0 { dirty = true }
        for source in Source.allCases {
            if manifest.streams[source.rawValue]?.dropped_frames != drops[source, default: 0] {
                manifest.streams[source.rawValue]?.dropped_frames = drops[source, default: 0]
                dirty = true
            }
        }
        if let error, manifest.last_problem != error {
            manifest.completed = false
            manifest.last_problem = error
            manifest.problem_count += 1
            dirty = true
        }
        guard dirty else { return }
        do {
            for (source, handle) in handles {
                try beforeIO?(.sync(source))
                try handle.synchronize()
            }
            var committed = manifest
            for source in Source.allCases {
                committed.streams[source.rawValue]?.committed_bytes = positions[source, default: 0] * 2
            }
            committed.revision += 1
            committed.committed_at = Date()
            try beforeIO?(.manifest)
            try Self.writeManifest(committed, directory: directory)
            manifest = committed
            dirty = false
            lock.lock()
            committedPackets = processedPackets
            committedBytes = committed.streams.values.reduce(0) { $0 + $1.committed_bytes }
            lastCommitUptime = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        } catch {
            lock.lock()
            let message = "Source recording could not be committed: \(error.localizedDescription)"
            latestError = message
            manifest.problem_count += 1
            manifest.last_problem = message
            manifest.completed = false
            accepting = false
            lock.unlock()
            // Retain dirty state. A later commit/finish retries the marker;
            // an unavailable disk cannot be assumed to preserve its own error.
        }
    }

    private func closeOnQueue() {
        timer?.cancel()
        timer = nil
        // Another scheduled drain can be behind the close work item; closing
        // admission before enqueuing this barrier makes the remaining set finite.
        drain()
        commitIfNeeded()
        let writeFailed = dirty
        if !writeFailed {
            do {
                try Self.exportWAVs(manifest: manifest, directory: directory, beforeIO: beforeIO)
                manifest.completed = failedSources.isEmpty && manifest.problem_count == 0
                    && manifest.streams.values.allSatisfy { $0.dropped_frames == 0 }
                    && (manifest.power_events?.isEmpty ?? true) && (manifest.power_events_omitted ?? 0) == 0
                dirty = true
                commitIfNeeded()
            } catch {
                manifest.problem_count += 1
                manifest.last_problem = error.localizedDescription
                lock.lock()
                latestError = error.localizedDescription
                lock.unlock()
                dirty = true
                commitIfNeeded()
            }
        }
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
        lock.lock()
        // Failure to write the final manifest must not be reported as a
        // durable clean close merely because the in-memory bool was set.
        if dirty { manifest.completed = false }
        closedManifest = manifest
        lock.unlock()
        try? sourceLease?.close()
        sourceLease = nil
        meetingAccess = nil
        quitWork.finish(failure: dirty ? "The final source recording could not be saved." : nil)
        closeCompletion.markCompleted()
    }

    /// An expired caller deadline does not make the committed prefix final.
    /// Hold the same OS lease while reading a resume boundary; a crashed
    /// process releases it automatically, while a live closing queue retains it.
    static func withInactiveSource<T>(directory: URL, _ body: () throws -> T) throws -> T {
        let lease = try acquireSourceLease(directory: directory, create: false)
        defer { try? lease?.close() }
        return try body()
    }

    private static func acquireSourceLease(directory: URL, create: Bool) throws -> FileHandle? {
        let path = directory.appendingPathComponent(".capture-owner.lock").path
        let flags = create ? O_RDWR | O_CREAT | O_CLOEXEC : O_RDONLY | O_CLOEXEC
        let descriptor = open(path, flags, S_IRUSR | S_IWUSR)
        if descriptor < 0 {
            if !create && errno == ENOENT { return nil } // Older sources predate leases.
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw RecorderError.sourceFailed("Source audio is still being saved. Resume is available after its original writer closes.")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func readManifest(directory: URL) throws -> Manifest {
        let url = directory.appendingPathComponent(manifestName)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1024 * 1024 else { throw RecorderError.invalidManifest }
        return try decodeManifest(Data(contentsOf: url))
    }

    static func decodeManifest(_ data: Data) throws -> Manifest {
        guard data.count <= 1024 * 1024 else { throw RecorderError.invalidManifest }
        let result = try JSONDecoder().decode(Manifest.self, from: data)
        guard result.schema_version == 1, !result.session_id.isEmpty,
              result.timeline_offset_us >= 0,
              result.streams.count == Source.allCases.count else { throw RecorderError.invalidManifest }
        if let clocks = result.clock_corrections {
            guard clocks.count <= Source.allCases.count,
                  clocks.allSatisfy({ Source(rawValue: $0.key) != nil && $0.value.isValid }) else {
                throw RecorderError.invalidManifest
            }
        }
        guard (result.power_events?.count ?? 0) <= 128, (result.power_events_omitted ?? 0) >= 0,
              result.power_events?.allSatisfy({ $0.process_continuous_us >= 0 && ($0.source_time_us ?? 0) >= 0 && ($0.observed_pause_us ?? 0) >= 0 }) ?? true else {
            throw RecorderError.invalidManifest
        }
        for source in Source.allCases {
            guard let state = result.streams[source.rawValue], state.sample_rate == 16_000,
                  state.channels == 1, state.committed_bytes >= 0, state.committed_bytes % 2 == 0,
                  state.committed_bytes <= 24 * 60 * 60 * 32_000 else { throw RecorderError.invalidManifest }
        }
        return result
    }

    /// Recover only the manifest's committed prefix; the uncommitted tail is
    /// retained as evidence but is not presented as verified recorded audio.
    static func recoverWAVs(directory: URL) throws -> Manifest {
        let manifest = try readManifest(directory: directory)
        try exportWAVs(manifest: manifest, directory: directory)
        return manifest
    }

    private static func writeManifest(_ manifest: Manifest, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = directory.appendingPathComponent(manifestName)
        let temporary = directory.appendingPathComponent(".source-manifest-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encoder.encode(manifest).write(to: temporary, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        try file.synchronize()
        try file.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func exportWAVs(manifest: Manifest, directory: URL,
                                   beforeIO: (@Sendable (Checkpoint) throws -> Void)? = nil) throws {
        for source in Source.allCases {
            try beforeIO?(.export(source))
            guard let state = manifest.streams[source.rawValue] else { throw RecorderError.invalidManifest }
            let bytes = state.committed_bytes
            guard bytes <= Int64(UInt32.max) - 36 else { throw RecorderError.wavTooLarge(source.rawValue) }
            let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(source.rawValue + ".pcm"))
            defer { try? input.close() }
            let size = try input.seekToEnd()
            guard size >= UInt64(bytes) else { throw RecorderError.truncatedSource(source.rawValue) }
            try input.seek(toOffset: 0)
            let temporary = directory.appendingPathComponent(".\(source.rawValue)-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try wavHeader(byteCount: UInt32(bytes)).write(to: temporary, options: .withoutOverwriting)
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try output.seekToEnd()
            var remaining = bytes
            while remaining > 0 {
                let data = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                guard !data.isEmpty else { throw RecorderError.truncatedSource(source.rawValue) }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
            try output.synchronize()
            try output.close()
            let target = directory.appendingPathComponent(source.rawValue + ".wav")
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        }
    }

    private static func wavHeader(byteCount: UInt32) -> Data {
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(16_000)); word(UInt32(32_000))
        word(UInt16(2)); word(UInt16(16)); data.append(contentsOf: "data".utf8); word(byteCount)
        return data
    }

    private static func addLoss(_ loss: Loss, to losses: inout [Loss], omitted: inout Int64) {
        if let last = losses.last, last.source == loss.source, last.reason == loss.reason,
           last.end_frame != nil, last.end_frame == loss.start_frame {
            losses[losses.count - 1].end_frame = loss.end_frame
            losses[losses.count - 1].frames += loss.frames
        } else if losses.count < 512 {
            losses.append(loss)
        } else {
            omitted += 1
        }
    }

    private func appendManifestLoss(_ loss: Loss) {
        // Copy individual values rather than opening two overlapping inout
        // modifications on the class's stored Manifest value.
        var losses = manifest.losses
        var omitted = manifest.loss_details_omitted
        Self.addLoss(loss, to: &losses, omitted: &omitted)
        manifest.losses = losses
        manifest.loss_details_omitted = omitted
    }
}
