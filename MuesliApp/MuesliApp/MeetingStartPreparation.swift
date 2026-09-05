import Foundation
import Darwin

/// One start may own storage preparation, including late cleanup, at a time.
/// Deadlines abandon the handoff, not filesystem calls. A stalled initializer
/// keeps its original owner and folder reservation until it really returns.
nonisolated final class MeetingStartPreparationOwner: @unchecked Sendable {
    struct Request: Sendable {
        let title: String
        let automaticDatePrefix: String?
        let resumeFolder: URL?
        let meetingsDirectory: URL?
        let video: Bool
        init(title: String, automaticDatePrefix: String? = nil, resumeFolder: URL? = nil,
             meetingsDirectory: URL? = nil, video: Bool = false) {
            self.title = title
            self.automaticDatePrefix = automaticDatePrefix
            self.resumeFolder = resumeFolder
            self.meetingsDirectory = meetingsDirectory
            self.video = video
        }
    }

    struct Prepared: Sendable {
        let title: String
        let folderURL: URL
        let audioDirectory: URL
        let startedAt: Date
        let priorMetadata: MeetingMetadata?
        let timestampOffset: Double
        let sourceID: String
        let recorder: LocalAudioRecorder
        let artifacts: SessionArtifactStore?
        let timeline: CaptureTimeline
        let logURL: URL
        let logHandle: FileHandle
        let eventsURL: URL
        let transcriptData: Data?
        let attachmentsData: Data?
    }

    enum Outcome: Sendable {
        case ready(Prepared)
        case failed(String)
        case timedOut
        case cancelled
        case busy
    }
    enum Step: Sendable, Equatable {
        case beforeFolderCreation
        case beforeInitialFileCreation
        case afterRecorderCreation
        case beforeHandoff
        case beforeCleanup
    }
    private struct Abandoned: Error {}

    private final class Attempt: @unchecked Sendable {
        let ready = TaskCompletion()
        let decision = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var abandoned = false
        private var claimed = false
        private var prepared: Prepared?
        private var failure: String?

        func check() throws { if lock.withLock({ abandoned }) { throw Abandoned() } }
        func publish(_ value: Prepared) -> Bool {
            let offer = lock.withLock {
                guard !abandoned else { return false }
                prepared = value
                return true
            }
            guard offer else { return false }
            ready.markCompleted()
            // This is the single admitted worker, never a new timeout monitor.
            // The independent deadline/cancellation path always wakes it.
            decision.wait()
            return lock.withLock { claimed }
        }
        func claim() -> Outcome {
            let outcome: Outcome = lock.withLock {
                if Task.isCancelled || abandoned {
                    abandoned = true
                    prepared = nil
                    return .cancelled
                }
                if let prepared {
                    self.prepared = nil
                    claimed = true
                    return .ready(prepared)
                }
                return .failed(failure ?? "Meeting preparation ended without a source owner.")
            }
            decision.signal()
            return outcome
        }
        func abandon() {
            lock.withLock { abandoned = true; prepared = nil }
            decision.signal()
        }
        func fail(_ error: Error) {
            lock.withLock { failure = error.localizedDescription }
            ready.markCompleted()
        }
    }

    private let lock = NSLock()
    private var active: Attempt?
    private let queue = DispatchQueue(label: "muesli.start-preparation", qos: .utility)
    private let store: TranscriptPersistenceStore
    private let checkpoint: @Sendable (Step) throws -> Void
    private let createRecorder: @Sendable (URL, String, Int64) throws -> LocalAudioRecorder

    init(store: TranscriptPersistenceStore = .shared,
         createRecorder: @escaping @Sendable (URL, String, Int64) throws -> LocalAudioRecorder = {
             try LocalAudioRecorder(directory: $0, sessionID: $1, timelineOffsetUs: $2)
         },
         checkpoint: @escaping @Sendable (Step) throws -> Void = { _ in }) {
        self.store = store
        self.createRecorder = createRecorder
        self.checkpoint = checkpoint
    }
    var isBusy: Bool { lock.withLock { active != nil } }

    @concurrent func prepare(_ request: Request, timeoutSeconds: Double = 8) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let attempt = Attempt()
        let admitted = lock.withLock {
            guard active == nil else { return false }
            active = attempt
            return true
        }
        guard admitted else { return .busy }
        queue.async { [self] in
            do {
                try attempt.check()
                let folder = try request.resumeFolder ?? createMeetingFolder(request, attempt: attempt)
                try attempt.check()
                _ = try store.start(in: folder, onCompletion: { [self] result in
                    if case .failure(let error) = result { attempt.fail(error) }
                    release(attempt)
                }) { [self] context in
                    try prepareOnOwner(request, folder: folder, attempt: attempt, context: context)
                }
            } catch {
                attempt.fail(error)
                release(attempt)
            }
        }
        switch await attempt.ready.wait(timeoutSeconds: timeoutSeconds) {
        case .completed: return attempt.claim()
        case .timedOut: attempt.abandon(); return .timedOut
        case .cancelled: attempt.abandon(); return .cancelled
        }
    }

    private func release(_ attempt: Attempt) {
        lock.withLock { if active === attempt { active = nil } }
    }

    /// Everything in this closure, including cleanup, belongs to the same
    /// transcript folder reservation. No other metadata writer can interleave.
    private func prepareOnOwner(_ request: Request, folder: URL, attempt: Attempt,
                                context: TranscriptPersistenceStore.Context) throws {
        try attempt.check()
        let prior = request.resumeFolder == nil ? nil : try context.readMetadata()
        let offset = try prior.map { try OrphanedMeetingRecovery.verifiedResumeOffset(folderURL: folder, metadata: $0) } ?? 0
        guard offset.isFinite, offset >= 0, offset < 1_000_000_000 else {
            throw LocalAudioRecorder.RecorderError.invalidManifest
        }
        let transcript = try optionalData(folder.appendingPathComponent("transcript.jsonl"), limit: 64 * 1024 * 1024)
        let attachments = try optionalData(folder.appendingPathComponent("attachments.json"), limit: 4 * 1024 * 1024)
        try attempt.check()
        let (sessionID, audio) = try createAudioFolder(in: folder, prior: prior)
        let sourceID = UUID().uuidString
        let startedAt = Date()
        let title = prior?.title ?? folder.lastPathComponent
        var recorder: LocalAudioRecorder?
        var artifacts: SessionArtifactStore?
        var logHandle: FileHandle?
        var metadata: MeetingMetadata?
        var handedOff = false
        do {
            try checkpoint(.beforeInitialFileCreation)
            try attempt.check()
            let source = try createRecorder(audio, sourceID, Int64(offset * 1_000_000))
            recorder = source
            var updated = prior ?? MeetingMetadata(version: 1, title: title, createdAt: startedAt,
                updatedAt: startedAt, durationSeconds: 0, lastTimestamp: 0, status: .recording,
                sessions: [], segmentCount: 0, speakerNames: [:])
            if prior == nil { updated.buildIdentity = .current }
            updated.preservePreviousSessionOutcome()
            updated.status = .recording
            updated.updatedAt = startedAt
            updated.sessions.append(MeetingSessionMetadata(sessionID: sessionID, startedAt: startedAt,
                endedAt: nil, audioFolder: audio.lastPathComponent,
                streams: ["system": MeetingStreamInfo(sampleRate: 16_000, channels: 1),
                          "mic": MeetingStreamInfo(sampleRate: 16_000, channels: 1)],
                timelineOffsetSeconds: offset, buildIdentity: .current, sourceSessionID: sourceID))
            metadata = updated
            // Index the source before subsequent setup. Abandonment retains
            // this new, empty source as interrupted; prior sessions never move.
            try commit(updated, context: context)
            try checkpoint(.afterRecorderCreation)
            try attempt.check()
            let eventsURL = audio.appendingPathComponent("transcript_events.jsonl")
            try Data().write(to: eventsURL, options: .withoutOverwriting)
            let logURL = audio.appendingPathComponent("backend.log")
            try Data().write(to: logURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: logURL)
            logHandle = handle
            let timeline = CaptureTimeline()
            if request.video {
                artifacts = try SessionArtifactStore(meetingDirectory: folder, sourceSessionID: sourceID,
                    timeline: timeline, timelineOffsetUs: Int64(offset * 1_000_000))
                updated.sessions[updated.sessions.count - 1].artifactsFolder = artifacts?.relativeDirectory
                metadata = updated
                try commit(updated, context: context)
            }
            try checkpoint(.beforeHandoff)
            try attempt.check()
            let prepared = Prepared(title: title, folderURL: folder, audioDirectory: audio,
                startedAt: startedAt, priorMetadata: prior, timestampOffset: offset, sourceID: sourceID,
                recorder: source, artifacts: artifacts, timeline: timeline, logURL: logURL,
                logHandle: handle, eventsURL: eventsURL, transcriptData: transcript, attachmentsData: attachments)
            handedOff = attempt.publish(prepared)
            if !handedOff { throw Abandoned() }
        } catch {
            // Capture never received these owners. Close them only on their
            // owning queues, and retain this attempt through actual completion.
            try? checkpoint(.beforeCleanup)
            if let recorder {
                let closed = DispatchSemaphore(value: 0)
                recorder.observeClosed { closed.signal() }
                recorder.requestFinish()
                closed.wait()
            }
            if let artifacts {
                let closed = DispatchSemaphore(value: 0)
                artifacts.observeClosed { closed.signal() }
                artifacts.requestFinish()
                closed.wait()
            }
            try? logHandle?.close()
            if var metadata {
                metadata.status = .interrupted
                metadata.updatedAt = Date()
                let last = metadata.sessions.count - 1
                metadata.sessions[last].endedAt = startedAt
                metadata.sessions[last].durationSeconds = 0
                metadata.sessions[last].finalizationStatus = "interrupted"
                // No native output was admitted; this unused artifact folder
                // remains on disk, but cannot impose an unknown capture extent.
                metadata.sessions[last].artifactsFolder = nil
                try commit(metadata, context: context)
            }
            throw error
        }
        assert(handedOff)
    }

    private func commit(_ metadata: MeetingMetadata, context: TranscriptPersistenceStore.Context) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try context.commit(files: ["meeting.json": encoder.encode(metadata)])
    }

    private func optionalData(_ url: URL, limit: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else {
                throw NSError(domain: "MeetingPreparation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The saved \(url.lastPathComponent) exceeds the supported startup size."])
            }
        }
        return data
    }

    private func createAudioFolder(in folder: URL, prior: MeetingMetadata?) throws -> (Int, URL) {
        var id = (prior?.sessions.map(\.sessionID).max() ?? 0) + 1
        while true {
            let name = prior == nil && id == 1 ? "audio" : "audio-session-\(id)"
            let audio = folder.appendingPathComponent(name, isDirectory: true)
            if mkdir(audio.path, S_IRWXU) == 0 { return (id, audio) }
            guard errno == EEXIST else { throw posixError() }
            id += 1
        }
    }

    private func createMeetingFolder(_ request: Request, attempt: Attempt) throws -> URL {
        try checkpoint(.beforeFolderCreation)
        try attempt.check()
        let base = request.meetingsDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first!.appendingPathComponent("Muesli/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var title = request.title
        guard !title.isEmpty, title != ".", title != "..", !title.contains("/"), !title.contains("\0") else {
            throw NSError(domain: "MeetingPreparation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The meeting title cannot be used as a folder name."])
        }
        if let prefix = request.automaticDatePrefix {
            let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
            let start = prefix + " - Meeting "
            let largest = names.compactMap { name -> Int? in
                guard name.hasPrefix(start) else { return nil }
                return Int(name.dropFirst(start.count).prefix(while: \.isNumber))
            }.max() ?? 0
            title = start + "\(largest + 1) -"
        }
        var suffix = 0
        while true {
            try attempt.check()
            let name = suffix == 0 ? title : title + String(format: "-%02d", suffix)
            let folder = base.appendingPathComponent(name, isDirectory: true)
            if mkdir(folder.path, S_IRWXU) == 0 { return folder }
            guard errno == EEXIST else { throw posixError() }
            suffix += 1
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
