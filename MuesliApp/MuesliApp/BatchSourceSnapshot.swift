import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// App-owned evidence, never decoded from subprocess output. Capture and compare
/// under the canonical folder transaction; titles are deliberately not inputs.
nonisolated struct BatchSourceSnapshot: Sendable, Equatable {
    struct Source: Sendable, Equatable {
        let inventory: BatchRediarizer.SourceInventory
        let streamDurations: [String: Double]
        let fingerprints: [String: String]
    }
    struct SessionKey: Sendable, Equatable {
        let number: Int
        let folder: String
        let sourceID: String?
    }
    let folderIdentity: MeetingFileAccess.Identity
    let selectedStream: BatchRediarizer.Stream
    let sessions: [SessionKey]
    let sources: [Source]
    let reviewedNames: [String: String]

    static func failure(_ message: String) -> TranscriptPersistenceStore.Failure {
        .operationFailed(message)
    }

    /// Only called on the original admission worker, which already owns the
    /// backend slot and outer access lease. One nested folder operation performs
    /// all I/O. A deadline abandons the admission, never this actual worker.
    static func prepare(in folder: URL, stream: BatchRediarizer.Stream,
                        store: TranscriptPersistenceStore = .shared,
                        purpose: TranscriptPersistenceStore.Purpose = .saveOrRecovery,
                        beforeRead: @escaping @Sendable () throws -> Void = {},
                        validateSource: @escaping @Sendable (TranscriptPersistenceStore.Context) throws -> Void = { _ in }) throws -> Self {
        let finished = DispatchSemaphore(value: 0)
        let operation = try store.start(in: folder, purpose: purpose, onCompletion: { _ in finished.signal() }) { context in
            try beforeRead()
            try validateSource(context)
            let snapshot = try capture(context: context, stream: stream)
            try validateSource(context)
            return snapshot
        }
        finished.wait()
        return try operation.completedValue()
    }

    static func capture(context: TranscriptPersistenceStore.Context,
                        stream: BatchRediarizer.Stream) throws -> Self {
        try context.access.validate()
        let rootFD = open(context.folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw failure("The source meeting folder is unreadable.") }
        let rootHandle = FileHandle(fileDescriptor: rootFD, closeOnDealloc: true)
        defer { try? rootHandle.close() }
        var rootState = stat()
        guard fstat(rootFD, &rootState) == 0,
              UInt64(rootState.st_dev) == context.access.identity.directoryDevice,
              rootState.st_ino == context.access.identity.directoryInode else {
            throw failure("The source meeting folder changed during admission.")
        }
        let metadataBytes = try readFile(directory: rootFD, name: "meeting.json", maximum: 8 * 1_024 * 1_024, retainBytes: true)!.data
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(MeetingMetadata.self, from: metadataBytes)
        guard metadata.status != .recording else {
            throw failure("Stop this meeting and wait for its source files to close before reprocessing.")
        }
        guard metadata.sessions.count <= 1_024 else { throw failure("Too many source sessions to verify.") }
        let ordered = metadata.sessions.sorted { $0.sessionID < $1.sessionID }
        let keys = ordered.map { SessionKey(number: $0.sessionID, folder: $0.audioFolder, sourceID: $0.sourceSessionID) }
        guard Set(keys.map(\.number)).count == keys.count,
              Set(keys.map(\.folder)).count == keys.count else { throw failure("The source session index is ambiguous.") }
        let audioFolders = try discoveredAudioFolders(descriptor: rootFD)
        for folder in audioFolders where !keys.isEmpty && !keys.contains(where: { $0.folder == folder }) {
            let fd = openat(rootFD, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("An unindexed audio folder is unreadable.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            for name in [LocalAudioRecorder.manifestName, "mic.pcm", "system.pcm", "mic.wav", "system.wav"] {
                var state = stat()
                if fstatat(fd, name, &state, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw failure("Unindexed source audio exists in this meeting. Its original files were preserved; recover the complete session index before reprocessing.")
                }
                guard errno == ENOENT else { throw failure("An unindexed audio folder could not be verified.") }
            }
        }
        // Deliberate pre-index compatibility: one legacy audio folder only.
        // Never silently choose a subset of multiple unindexed sources.
        let folders: [String]
        if keys.isEmpty {
            guard audioFolders == ["audio"] else { throw failure("Legacy reprocessing requires one unambiguous audio folder or a complete session index.") }
            folders = audioFolders
        } else { folders = keys.map(\.folder) }
        var sources: [Source] = [], offset = 0.0
        for (index, folder) in folders.enumerated() {
            guard !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"), !folder.contains("\0") else {
                throw failure("The session index contains an unsafe audio folder.")
            }
            let directory = context.folder.appendingPathComponent(folder, isDirectory: true)
            let fd = openat(rootFD, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("An indexed source audio folder is missing or unreadable.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let source = try LocalAudioRecorder.withInactiveSource(directory: directory) {
                let manifestFile = try readFile(directory: fd, name: LocalAudioRecorder.manifestName,
                                                maximum: 1_024 * 1_024, retainBytes: true, optional: true)
                var durations: [String: Double] = [:], fingerprints: [String: String] = [:]
                let identity: String, kind: String, sourceOffset: Double
                if let manifestFile {
                    guard !keys.isEmpty else { throw failure("A committed PCM source requires a complete session index.") }
                    let manifest = try LocalAudioRecorder.decodeManifest(manifestFile.data)
                    identity = manifest.session_id; kind = "committed_pcm"
                    if let expected = keys[index].sourceID, expected != identity {
                        throw failure("The indexed source identity does not match its recording manifest.")
                    }
                    sourceOffset = Double(manifest.timeline_offset_us) / 1_000_000
                    fingerprints[LocalAudioRecorder.manifestName] = manifestFile.fingerprint
                    for name in ["mic", "system"] {
                        let size = manifest.streams[name]!.committed_bytes
                        let file = try readFile(directory: fd, name: "\(name).pcm", maximum: 24 * 60 * 60 * 32_000,
                                                prefix: size)!
                        fingerprints[name] = file.fingerprint
                        durations[name] = Double(size) / 32_000
                    }
                } else {
                    guard keys.isEmpty || keys[index].sourceID == nil else {
                        throw failure("An indexed committed source has lost its manifest.")
                    }
                    for name in ["mic", "system"] {
                        guard try readFile(directory: fd, name: "\(name).pcm", maximum: 0, prefix: 0, optional: true) == nil else {
                            throw failure("PCM source evidence exists without its commit manifest; legacy WAV fallback is unsafe.")
                        }
                    }
                    identity = folder; kind = "legacy_wav"; sourceOffset = offset
                    for name in ["mic", "system"] {
                        guard let file = try readFile(directory: fd, name: "\(name).wav", maximum: 32 * 1_024 * 1_024 * 1_024,
                                                       optional: true) else { continue }
                        let audio = try AVAudioFile(forReading: directory.appendingPathComponent("\(name).wav"))
                        let duration = Double(audio.length) / audio.processingFormat.sampleRate
                        guard duration.isFinite, duration >= 0, duration <= 24 * 60 * 60 else {
                            throw failure("A legacy audio source has an invalid duration.")
                        }
                        // AVAudioFile opens by pathname; verify it still denotes
                        // the file whose bytes were hashed before accepting it.
                        try verifyPath(directory: fd, name: "\(name).wav", stamp: file.stamp)
                        durations[name] = duration; fingerprints[name] = file.fingerprint
                    }
                    guard !durations.isEmpty else { throw failure("No readable legacy source audio was found.") }
                }
                let required = stream == .both ? ["mic", "system"] : [stream.rawValue]
                guard required.allSatisfy({ durations[$0] != nil }) else {
                    throw failure("A selected stream is missing from a source session.")
                }
                let duration = durations.values.max() ?? 0
                return Source(inventory: .init(sourceSessionID: identity, audioFolder: folder,
                    timelineOffsetSeconds: sourceOffset, durationSeconds: duration, storageKind: kind),
                    streamDurations: durations, fingerprints: fingerprints)
            }
            var original = stat(), current = stat()
            guard fstat(fd, &original) == 0, lstat(directory.path, &current) == 0,
                  original.st_dev == current.st_dev, original.st_ino == current.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR else { throw failure("A source folder changed while being read.") }
            sources.append(source)
            offset = max(offset, source.inventory.timelineOffsetSeconds + source.inventory.durationSeconds)
        }
        guard Set(sources.map { $0.inventory.sourceSessionID }).count == sources.count else {
            throw failure("Source session identities are not unique.")
        }
        try context.access.validate()
        return Self(folderIdentity: context.access.identity, selectedStream: stream, sessions: keys,
                    sources: sources, reviewedNames: metadata.speakerNames)
    }

    func validateCurrent(context: TranscriptPersistenceStore.Context) throws {
        let current = try Self.capture(context: context, stream: selectedStream)
        guard current.reviewedNames == reviewedNames else {
            throw Self.failure("Speaker names changed during reprocessing. The saved transcript and reviewed names were preserved; rerun reprocessing before replacing them.")
        }
        guard current == self else {
            throw Self.failure("The meeting's source audio or sessions changed during reprocessing. Its saved transcript was preserved; rerun reprocessing for the current sources.")
        }
    }

    func validatedResult(_ value: BatchRediarizer.Result) throws -> BatchRediarizer.Result {
        try value.validateProtocol()
        var value = value
        let expected = sources.map(\.inventory)
        if let actual = value.sources {
            guard actual.count == expected.count, zip(actual, expected).allSatisfy({ $0.matches($1) }) else {
                throw Self.failure("Batch output does not cover every captured source session.")
            }
        } else {
            guard sources.count == 1, expected[0].storageKind == "legacy_wav" else {
                throw Self.failure("Unscoped legacy batch output cannot replace a transcript with committed or multiple sources.")
            }
            value.sources = expected
            for index in value.turns.indices {
                guard value.turns[index].sourceSessionID == nil || value.turns[index].sourceSessionID == expected[0].sourceSessionID else {
                    throw Self.failure("Legacy batch output refers to another source.")
                }
                value.turns[index].sourceSessionID = expected[0].sourceSessionID
            }
        }
        let end = expected.map { $0.timelineOffsetSeconds + $0.durationSeconds }.max() ?? 0
        guard Self.near(value.duration, end) else { throw Self.failure("Batch duration does not match the complete source timeline.") }
        for turn in value.turns {
            guard let source = sources.first(where: { $0.inventory.sourceSessionID == turn.sourceSessionID }),
                  selectedStream == .both || turn.stream == selectedStream.rawValue,
                  let duration = source.streamDurations[turn.stream],
                  turn.t0 + Self.tolerance >= source.inventory.timelineOffsetSeconds,
                  turn.t1 <= source.inventory.timelineOffsetSeconds + duration + Self.tolerance else {
                throw Self.failure("A batch turn is outside its selected source audio interval.")
            }
        }
        value.sourceSnapshot = self
        return value
    }

    static let tolerance = 1.0 / 16_000 // One sample, not a speech-tail estimate.
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }

    private static func discoveredAudioFolders(descriptor: Int32) throws -> [String] {
        let fd = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("The source folder could not be enumerated.") }
        guard let directory = fdopendir(fd) else {
            Darwin.close(fd)
            throw failure("The source folder could not be enumerated.")
        }
        defer { closedir(directory) }
        var folders: [String] = [], count = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw failure("The source folder could not be completely enumerated.") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 10_000 else { throw failure("Too many entries to verify the source folder.") }
            guard name.lowercased().hasPrefix("audio") else { continue }
            var state = stat()
            guard fstatat(descriptor, name, &state, AT_SYMLINK_NOFOLLOW) == 0,
                  state.st_mode & S_IFMT != S_IFLNK else { throw failure("A source folder is unreadable or unsafe.") }
            if state.st_mode & S_IFMT == S_IFDIR { folders.append(name) }
        }
        return folders
    }

    private struct FileRead {
        let data: Data
        let fingerprint: String
        let stamp: stat
    }
    private static func verifyPath(directory: Int32, name: String, stamp: stat) throws {
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, unchanged(stamp, current) else {
            throw failure("Source audio changed while being verified.")
        }
    }
    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func readFile(directory: Int32, name: String, maximum: Int64,
                                 prefix: Int64? = nil, retainBytes: Bool = false,
                                 optional: Bool = false) throws -> FileRead? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if optional && errno == ENOENT { return nil }
            throw failure("A source file is missing, unsafe or unreadable: \(name).")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, (prefix ?? before.st_size) <= maximum,
              before.st_size >= (prefix ?? 0) else { throw failure("A source file is truncated or outside the supported bounds.") }
        var remaining = prefix ?? before.st_size, hash = SHA256(), bytes = Data()
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(remaining, 128 * 1_024))) ?? Data()
            guard !chunk.isEmpty else { throw failure("A source file was truncated while being read.") }
            hash.update(data: chunk)
            if retainBytes { bytes.append(chunk) }
            remaining -= Int64(chunk.count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, unchanged(before, after) else { throw failure("Source audio changed while being verified.") }
        try verifyPath(directory: directory, name: name, stamp: before)
        // Identity prevents accepting a replaced path; the hash covers only
        // committed bytes for PCM, leaving any uncommitted tail untouched.
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return FileRead(data: bytes, fingerprint: "\(before.st_dev):\(before.st_ino):\(prefix ?? before.st_size):\(digest)", stamp: before)
    }
}

nonisolated extension BatchRediarizer.SourceInventory {
    func matches(_ other: Self) -> Bool {
        sourceSessionID == other.sourceSessionID && audioFolder == other.audioFolder && storageKind == other.storageKind
            && BatchSourceSnapshot.near(timelineOffsetSeconds, other.timelineOffsetSeconds)
            && BatchSourceSnapshot.near(durationSeconds, other.durationSeconds)
    }
}

nonisolated extension BatchRediarizer.Result {
    func validateProtocol() throws {
        func reject() -> TranscriptPersistenceStore.Failure { BatchSourceSnapshot.failure("Batch output contains invalid source identities or audio timing.") }
        guard duration.isFinite, duration >= 0 else { throw reject() }
        for turn in turns {
            guard !turn.speakerId.isEmpty, ["system", "mic"].contains(turn.stream),
                  turn.sourceSessionID == nil || turn.sourceSessionID?.isEmpty == false,
                  turn.t0.isFinite, turn.t1.isFinite, turn.t0 >= 0, turn.t1 >= turn.t0,
                  turn.t1 <= duration + BatchSourceSnapshot.tolerance else { throw reject() }
        }
        if let sources {
            guard !sources.isEmpty, sources.count <= 1_024,
                  Set(sources.map(\.sourceSessionID)).count == sources.count,
                  Set(sources.map(\.audioFolder)).count == sources.count else { throw reject() }
            for source in sources {
                guard !source.sourceSessionID.isEmpty, !source.audioFolder.isEmpty,
                      ["committed_pcm", "legacy_wav"].contains(source.storageKind),
                      source.timelineOffsetSeconds.isFinite, source.timelineOffsetSeconds >= 0,
                      source.durationSeconds.isFinite, source.durationSeconds >= 0,
                      source.durationSeconds <= 24 * 60 * 60 else { throw reject() }
            }
            guard BatchSourceSnapshot.near(duration, sources.map { $0.timelineOffsetSeconds + $0.durationSeconds }.max() ?? 0) else { throw reject() }
            for turn in turns {
                guard let source = sources.first(where: { $0.sourceSessionID == turn.sourceSessionID }),
                      turn.t0 + BatchSourceSnapshot.tolerance >= source.timelineOffsetSeconds,
                      turn.t1 <= source.timelineOffsetSeconds + source.durationSeconds + BatchSourceSnapshot.tolerance else { throw reject() }
            }
        }
    }
}
