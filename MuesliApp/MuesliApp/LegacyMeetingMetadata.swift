import Foundation

nonisolated enum LegacyMeetingMetadata {
    static func buildLegacyMeetingMetadata(for folderURL: URL) throws -> MeetingMetadata {
        let title = legacyMeetingTitle(for: folderURL)
        let createdAt = creationDate(for: folderURL) ?? Date()
        let updatedAt = latestModificationDate(for: folderURL) ?? createdAt
        let discoveredAudioFolders = try audioFolderNames(in: folderURL)
        let audioFolders = discoveredAudioFolders.isEmpty ? ["audio"] : discoveredAudioFolders
        for name in discoveredAudioFolders {
            let audio = folderURL.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            let root = folderURL.standardizedFileURL.resolvingSymlinksInPath()
            guard audio.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
            try LocalAudioRecorder.withInactiveSource(directory: audio) { }
        }

        let transcriptURL = folderURL.appendingPathComponent("transcript.jsonl")
        let eventsURL = folderURL.appendingPathComponent("transcript_events.jsonl")

        var segmentCount = 0
        var lastTimestamp = 0.0
        var speakerNames: [String: String] = [:]

        if FileManager.default.fileExists(atPath: transcriptURL.path) {
            let stats = try parseSegmentStats(from: transcriptURL, expectsTypeField: false)
            segmentCount = stats.count
            lastTimestamp = stats.lastTimestamp
        } else if FileManager.default.fileExists(atPath: eventsURL.path) {
            let stats = try parseSegmentStats(from: eventsURL, expectsTypeField: true)
            segmentCount = stats.count
            lastTimestamp = stats.lastTimestamp
            speakerNames = stats.speakerNames
        }

        let streams: [String: MeetingStreamInfo] = [
            "system": MeetingStreamInfo(sampleRate: nil, channels: nil),
            "mic": MeetingStreamInfo(sampleRate: nil, channels: nil)
        ]

        let sessions = audioFolders.enumerated().map { index, folder in
            MeetingSessionMetadata(sessionID: index + 1, startedAt: createdAt, endedAt: nil,
                                   audioFolder: folder, streams: streams)
        }
        let metadata = MeetingMetadata(
            version: 1,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            durationSeconds: lastTimestamp,
            lastTimestamp: lastTimestamp,
            status: .interrupted,
            sessions: sessions,
            segmentCount: segmentCount,
            speakerNames: speakerNames
        )
        // Preserve every discovered source folder. Committed PCM manifests
        // supply their original offsets; legacy WAVs remain explicitly interrupted.
        let evidence = OrphanedMeetingRecovery.inspectAndRecover(folderURL: folderURL, metadata: metadata)
        return OrphanedMeetingRecovery.finalize(metadata, evidence: evidence, now: updatedAt)
    }

    private static func legacyMeetingTitle(for folderURL: URL) -> String {
        let metaURL = folderURL.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = obj["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return folderURL.lastPathComponent
    }

    private static func creationDate(for url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.creationDate] as? Date
    }

    private static func latestModificationDate(for folderURL: URL) -> Date? {
        let candidates = [
            folderURL.appendingPathComponent("transcript.jsonl"),
            folderURL.appendingPathComponent("transcript.txt"),
            folderURL.appendingPathComponent("transcript_events.jsonl"),
            folderURL.appendingPathComponent("backend.log"),
            folderURL.appendingPathComponent("recording.mp4")
        ]
        var latest: Date?
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let date = attrs?[.modificationDate] as? Date {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }
        return latest
    }

    private static func audioFolderNames(in folder: URL) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try entries.filter {
            guard $0.lastPathComponent.lowercased().hasPrefix("audio") else { return false }
            return try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func parseSegmentStats(from url: URL, expectsTypeField: Bool) throws -> (count: Int, lastTimestamp: Double, speakerNames: [String: String]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var count = 0
        var lastTimestamp = 0.0
        var speakerNames: [String: String] = [:]

        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }

            if expectsTypeField {
                guard let type = obj["type"] as? String else { return }
                if type == "speakers", let known = obj["known"] as? [[String: Any]] {
                    for entry in known {
                        if let speakerID = entry["speaker_id"] as? String {
                            let name = (entry["name"] as? String) ?? speakerID
                            let source = entry["source_session_id"] as? String ?? obj["source_session_id"] as? String
                            let stream = entry["stream"] as? String ?? obj["stream"] as? String ?? "unknown"
                            let identity = TranscriptSpeakerIdentity(sourceSessionID: source, stream: stream, speakerID: speakerID)
                            speakerNames[source == nil && stream == "unknown" ? speakerID : identity.storageKey] = name
                        }
                    }
                }
                guard type == "segment" else { return }
            }

            guard let t0 = obj["t0"] as? Double else { return }
            let t1 = obj["t1"] as? Double
            count += 1
            let end = t1 ?? t0
            if end > lastTimestamp {
                lastTimestamp = end
            }
        }

        while let chunk = try handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                guard line.count <= 256 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                try consume(line)
                pending.removeSubrange(...newline)
            }
            guard pending.count <= 256 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        }
        // A killed JSONL writer can leave a partial final record. Preserve
        // the original journal, and count only its complete JSON records.
        if !pending.isEmpty { try? consume(pending) }

        return (count, lastTimestamp, speakerNames)
    }
}
