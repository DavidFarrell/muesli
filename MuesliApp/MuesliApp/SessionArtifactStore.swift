import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

nonisolated struct SessionArtifactStatus: Sendable {
    let sourceSessionID: String
    let pendingVideos: Int
    let finishedVideos: Int
    let committedScreenshots: Int
    let error: String?
    let mediaEndSeconds: Double?
    var captureEndSeconds: Double? = nil
    let closed: Bool
    var isComplete: Bool { closed && pendingVideos == 0 && error == nil }
}

nonisolated enum SessionArtifactFinishResult: Sendable {
    case completed(SessionArtifactStatus)
    case timedOut(SessionArtifactStatus)
    case cancelled(SessionArtifactStatus)
    var status: SessionArtifactStatus {
        switch self {
        case .completed(let value), .timedOut(let value), .cancelled(let value): return value
        }
    }
}

nonisolated struct ScreenshotArtifact: Encodable, Sendable {
    let type = "screenshot"
    let sourceSessionID: String
    let t: Double
    let path: String
    enum CodingKeys: String, CodingKey { case type, t, path; case sourceSessionID = "source_session_id" }
}

/// Immutable session ownership. The queue alone writes artifacts and its
/// append-only ledger. Admission/status use a short lock, never a disk-I/O lock.
/// The ledger contains only committed screenshots and real SDK video outcomes.
nonisolated final class SessionArtifactStore: @unchecked Sendable {
    typealias PNGWriter = @Sendable (CGImage, URL) throws -> Void
    let sourceSessionID: String
    let relativeDirectory: String
    let directory: URL
    let timeline: CaptureTimeline
    let timelineOffsetUs: Int64
    private let queue = DispatchQueue(label: "muesli.session-artifacts", qos: .utility)
    private let lock = NSLock()
    private let completion = TaskCompletion()
    private let quitWork: ShutdownWorkRegistry.Token
    private let pngWriter: PNGWriter
    private var ledger: FileHandle?
    private var ownerLease: FileHandle?
    private var meetingAccess: MeetingFileAccess?
    private var ledgerFailed = false
    private var closing = false
    private var closed = false
    private var screenshotsAllowed = true
    private var screenshotPending = false
    private var storageUnavailable = false
    private var pendingCaptureFailures = 0
    private var pendingUnavailableFailures = 0
    private var failureDrainPending = false
    private var firstError: String?
    private var finishedVideos = 0
    private var committedScreenshots = 0
    private var mediaEndSeconds: Double?
    private var captureEndSeconds: Double?
    private struct Video {
        let requestedAt: Double
        var delegate: RecordingDelegate?
    }
    private var videos: [URL: Video] = [:]

    /// Creates a fresh directory; call away from the UI executor.
    init(meetingDirectory: URL, sourceSessionID: String, timeline: CaptureTimeline,
         timelineOffsetUs: Int64, meetingAccess: MeetingFileAccess? = nil, shutdown: ShutdownWorkRegistry = .shared,
         pngWriter: @escaping PNGWriter = SessionArtifactStore.writePNG) throws {
        quitWork = try shutdown.begin("Finishing video and screenshots")
        guard UUID(uuidString: sourceSessionID) != nil, timelineOffsetUs >= 0 else {
            throw Self.error("Invalid artifact session identity or offset")
        }
        self.meetingAccess = meetingAccess
        self.sourceSessionID = sourceSessionID
        self.timeline = timeline
        self.timelineOffsetUs = timelineOffsetUs
        self.pngWriter = pngWriter
        relativeDirectory = "artifacts/\(sourceSessionID)"
        directory = meetingDirectory.appendingPathComponent(relativeDirectory, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw Self.error("Artifact session already exists") }
        try fm.createDirectory(at: directory.appendingPathComponent("screenshots"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("video"), withIntermediateDirectories: false)
        ownerLease = try Self.acquireLease(directory: directory, create: true)
        let ledgerURL = directory.appendingPathComponent("assets.jsonl")
        let fd = open(ledgerURL.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.posixError() }
        ledger = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try append(["type": "session", "source_session_id": sourceSessionID,
                        "timeline_offset_us": timelineOffsetUs])
            try Self.syncDirectory(directory)
            try Self.syncDirectory(directory.deletingLastPathComponent())
            try Self.syncDirectory(meetingDirectory)
        } catch { try? ledger?.close(); ledger = nil; throw error }
    }

    /// A finite number of unsettled native outputs can own one store. This is
    /// synchronous in-memory admission for CaptureEngine's retry URL provider.
    func nextVideoURL() -> URL? {
        let url = directory.appendingPathComponent("video/\(UUID().uuidString).mp4")
        let admitted = lock.withLock {
            guard !closing, !storageUnavailable, videos.count < 16 else { return false }
            let localUs = max(0, timeline.relativeMicroseconds(CaptureTimeline.hostNowMicroseconds()))
            videos[url] = Video(requestedAt: Double(timelineOffsetUs) / 1_000_000 + Double(localUs) / 1_000_000)
            return true
        }
        guard admitted else { return nil }
        return url
    }

    func retainRecording(_ delegate: RecordingDelegate) {
        let accepted = lock.withLock {
            guard var video = videos[delegate.url], video.delegate == nil else {
                if firstError == nil { firstError = "Recording output has no session reservation" }
                return false
            }
            video.delegate = delegate
            videos[delegate.url] = video
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            let time = lock.withLock { videos[delegate.url]?.requestedAt }
            do { try append(["type": "video", "status": "requested", "path": relativePath(delegate.url),
                             "requested_t": time ?? 0, "source_session_id": sourceSessionID]) }
            catch { recordError(error) }
        }
        // Retain this original owner until the real callback. Expiring a wait
        // does not close the ledger or redirect a late event into a new session.
        delegate.observeCompletion { [self] state in
            queue.async { [self] in completeVideo(state) }
        }
    }

    /// At most one image can be queued/in I/O, even if a caller bypasses the
    /// scheduler. Completion is delivered only after PNG + ledger persistence.
    @discardableResult
    func submitScreenshot(_ image: CGImage, captureTimeUs: Int64,
                          onCommitted: @escaping @Sendable (ScreenshotArtifact) -> Void) -> Bool {
        let accepted = lock.withLock {
            guard screenshotsAllowed, !closing, !screenshotPending, !storageUnavailable else { return false }
            screenshotPending = true
            return true
        }
        guard accepted else { return false }
        queue.async { [self] in
            defer { lock.withLock { screenshotPending = false }; finishIfReady() }
            guard lock.withLock({ screenshotsAllowed && !closing }) else { return }
            let localUs = timeline.relativeMicroseconds(captureTimeUs)
            guard localUs >= 0 else {
                persistFailure("Screenshot predates the capture timeline", kind: "screenshot_timestamp")
                return
            }
            let name = UUID().uuidString + ".png"
            let url = directory.appendingPathComponent("screenshots/" + name)
            do {
                try pngWriter(image, url)
                // A result arriving while a session stops is never published
                // as a screenshot event, including after slow image encoding.
                guard lock.withLock({ screenshotsAllowed && !closing }) else { return }
                let event = ScreenshotArtifact(sourceSessionID: sourceSessionID,
                    t: Double(timelineOffsetUs) / 1_000_000 + Double(localUs) / 1_000_000,
                    path: relativePath(url))
                let data = try JSONEncoder().encode(event)
                try append(data)
                let deliver = lock.withLock {
                    committedScreenshots += 1
                    mediaEndSeconds = max(mediaEndSeconds ?? 0, event.t)
                    return screenshotsAllowed && !closing
                }
                if deliver { onCommitted(event) }
            } catch { persistFailure(error.localizedDescription, kind: "screenshot_write") }
        }
        return true
    }

    func stopScreenshots() { lock.withLock { screenshotsAllowed = false } }

    /// Caller must have positively observed native source stop. This is the
    /// capture scope boundary, not a claim about the MP4's first-frame time.
    func markCaptureStopped(atHostUs: Int64) {
        let accepted = lock.withLock { !closing }
        guard accepted else { return }
        queue.async { [self] in
            let localUs = timeline.relativeMicroseconds(atHostUs)
            guard localUs >= 0 else { persistFailure("Capture stop predates its epoch", kind: "capture_stop"); return }
            let end = Double(timelineOffsetUs) / 1_000_000 + Double(localUs) / 1_000_000
            do {
                try append(["type": "capture_stopped", "source_session_id": sourceSessionID, "t": end])
                lock.withLock { captureEndSeconds = max(captureEndSeconds ?? 0, end) }
            } catch { recordError(error) }
        }
    }

    func recordScreenshotFailure(ownershipUnavailable: Bool = false) {
        let schedule = lock.withLock {
            guard screenshotsAllowed, !closing else { return false }
            if firstError == nil { firstError = ownershipUnavailable ? "Screenshot request did not complete" : "Screenshot capture failed" }
            if ownershipUnavailable { pendingUnavailableFailures = min(Int.max - 1, pendingUnavailableFailures) + 1 }
            else { pendingCaptureFailures = min(Int.max - 1, pendingCaptureFailures) + 1 }
            guard !failureDrainPending else { return false }
            failureDrainPending = true
            return true
        }
        if schedule { queue.async { [self] in drainCaptureFailures() } }
    }

    func status() -> SessionArtifactStatus {
        lock.withLock { SessionArtifactStatus(sourceSessionID: sourceSessionID, pendingVideos: videos.count,
            finishedVideos: finishedVideos, committedScreenshots: committedScreenshots, error: firstError,
            mediaEndSeconds: mediaEndSeconds, captureEndSeconds: captureEndSeconds, closed: closed) }
    }

    @concurrent func finish(timeoutSeconds: Double) async -> SessionArtifactFinishResult {
        requestFinish()
        switch await completion.wait(timeoutSeconds: timeoutSeconds) {
        case .completed: return .completed(status())
        case .timedOut: return .timedOut(status())
        case .cancelled: return .cancelled(status())
        }
    }

    func requestFinish() {
        let schedule = lock.withLock {
            let schedule = !closing
            closing = true
            screenshotsAllowed = false
            return schedule
        }
        guard schedule else { return }
        queue.async { [self] in
            let unregistered = lock.withLock {
                let unregistered = videos.filter { $0.value.delegate == nil }.map(\.key)
                for url in unregistered { videos.removeValue(forKey: url) }
                return unregistered.count
            }
            if unregistered > 0 { persistFailure("A reserved video output was never created", kind: "video_not_created", count: unregistered) }
            finishIfReady()
        }
    }

    func observeClosed(_ observer: @escaping @Sendable () -> Void) {
        completion.observeCompletion(observer)
    }

    private func completeVideo(_ state: RecordingArtifactSnapshot) {
        let video = lock.withLock { videos[state.url] }
        guard let video else { return }
        var event: [String: Any] = ["type": "video", "status": state.status.rawValue,
            "path": relativePath(state.url), "source_session_id": sourceSessionID, "requested_t": video.requestedAt]
        // SCRecordingOutput exposes duration but not a first-frame host PTS.
        // Reservation time is diagnostic, not evidence of media alignment.
        if let duration = state.durationSeconds { event["duration_seconds"] = duration }
        if let size = state.fileSize { event["file_size"] = size }
        if let error = state.error { event["error"] = error }
        do {
            if state.status == .finished {
                // SDK completion finalizes the container; sync the resulting
                // file before its successful event becomes durable.
                let handle = try FileHandle(forWritingTo: state.url)
                defer { try? handle.close() }
                try handle.synchronize()
                try Self.syncDirectory(state.url.deletingLastPathComponent())
            }
            try append(event)
        } catch { persistFailure(error.localizedDescription, kind: "video_persistence") }
        lock.withLock {
            videos.removeValue(forKey: state.url)
            if state.status == .finished {
                finishedVideos += 1
            } else if firstError == nil { firstError = state.error ?? "Recording output failed" }
        }
        finishIfReady()
    }

    private func finishIfReady() {
        let ready = lock.withLock { closing && videos.isEmpty && !screenshotPending && !failureDrainPending }
        guard ready else { return }
        do {
            try ledger?.synchronize()
            try ledger?.close()
            lock.withLock { closed = true }
        } catch { recordError(error) }
        ledger = nil
        // The queue has retired every screenshot and actual native output.
        // A deadline never reaches here while those owners remain outstanding.
        do { try ownerLease?.close(); ownerLease = nil }
        catch { recordError(error) } // Retain a failed close's handle through deinit.
        meetingAccess = nil
        quitWork.finish(failure: ledgerFailed || !closed ? "The final artifact ledger could not be saved or closed." : nil)
        completion.markCompleted()
    }

    /// Caller retains this lease across a destructive folder operation. Missing
    /// leases identify old sessions; current stores create theirs before their
    /// first ledger write. Process death also releases the kernel-held lease.
    static func acquireInactiveLease(directory: URL) throws -> FileHandle? {
        try acquireLease(directory: directory, create: false)
    }
    private static func acquireLease(directory: URL, create: Bool) throws -> FileHandle? {
        let path = directory.appendingPathComponent(".artifact-owner.lock").path
        let flags = (create ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW
        let descriptor = open(path, flags, S_IRUSR | S_IWUSR)
        if descriptor < 0 {
            if !create && errno == ENOENT { return nil }
            throw posixError()
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw error("Screenshot or video files are still owned by their original save operation.")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func relativePath(_ url: URL) -> String {
        relativeDirectory + "/" + url.path.dropFirst(directory.path.count + 1)
    }
    private func recordError(_ error: Error) { lock.withLock { if firstError == nil { firstError = error.localizedDescription } } }
    private func persistFailure(_ message: String, kind: String, count: Int = 1) {
        // Native messages cannot make a single ledger event arbitrarily large.
        let bounded = String(message.prefix(2_048))
        recordError(Self.error(bounded))
        do {
            try append(["type": "artifact_error", "source_session_id": sourceSessionID,
                        "kind": kind, "error": bounded, "count": count])
        } catch { recordError(error) }
    }
    private func drainCaptureFailures() {
        let (count, unavailable) = lock.withLock {
            let counts = (pendingCaptureFailures, pendingUnavailableFailures)
            pendingCaptureFailures = 0; pendingUnavailableFailures = 0
            return counts
        }
        if count > 0 { persistFailure("Screenshot capture failed", kind: "screenshot_capture", count: count) }
        if unavailable > 0 { persistFailure("Screenshot request did not complete; its native owner remains outstanding",
                                            kind: "screenshot_unavailable", count: unavailable) }
        let repeatDrain = lock.withLock {
            if pendingCaptureFailures > 0 || pendingUnavailableFailures > 0 { return true }
            failureDrainPending = false
            return false
        }
        if repeatDrain { queue.async { [self] in drainCaptureFailures() } }
        else { finishIfReady() }
    }
    private func append(_ object: [String: Any]) throws { try append(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
    private func append(_ data: Data) throws {
        guard let ledger, !ledgerFailed else { throw Self.error("Artifact ledger is closed or failed") }
        do {
            try ledger.write(contentsOf: data + Data([0x0a]))
            try ledger.synchronize()
        } catch {
            // A failed write can leave a partial tail. Never append another
            // record behind it or claim that a later fsync committed this one.
            ledgerFailed = true
            lock.withLock { storageUnavailable = true }
            throw error
        }
    }
    private static func error(_ message: String) -> NSError {
        NSError(domain: "SessionArtifactStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }
    private static func writePNG(_ image: CGImage, _ url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw error("Could not create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw error("PNG encoding failed") }
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.synchronize()
        // link is an atomic no-replace publication; UUID collisions cannot
        // overwrite any earlier session asset.
        guard link(temp.path, url.path) == 0 else { throw posixError() }
        try syncDirectory(url.deletingLastPathComponent())
    }
}
