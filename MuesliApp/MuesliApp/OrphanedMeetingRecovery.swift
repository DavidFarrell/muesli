import Foundation
import AVFoundation

/// Recovery preserves interruption as a historical fact. Media lengths and
/// explicit source offsets establish duration; file modification times and the
/// time spent waiting for the next app launch never enter that calculation.
nonisolated enum OrphanedMeetingRecovery {
    struct SessionEvidence: Sendable {
        let sessionID: Int
        let timelineOffsetSeconds: Double?
        let durationSeconds: Double?
    }

    struct Evidence: Sendable {
        let sessions: [SessionEvidence]
        let durationSeconds: Double?
        let problems: [String]
    }

    static func needsRecovery(_ metadata: MeetingMetadata) -> Bool { metadata.status == .recording }

    /// Resume positions are source boundaries, never the last spoken word.
    /// This read-only inspection must run off UI. Unknown extents are explicit
    /// failures instead of silently compressing missing legacy sessions.
    static func verifiedResumeOffset(folderURL: URL, metadata: MeetingMetadata) throws -> Double {
        let root = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        var end = 0.0
        guard !metadata.sessions.isEmpty else { throw resumeError("No source sessions are listed") }
        for session in metadata.sessions.sorted(by: { $0.sessionID < $1.sessionID }) {
            let audio = root.appendingPathComponent(session.audioFolder).standardizedFileURL.resolvingSymlinksInPath()
            guard audio.path.hasPrefix(root.path + "/") else { throw resumeError("Source folder is outside the meeting") }
            let offset: Double
            let duration: Double
            if FileManager.default.fileExists(atPath: audio.appendingPathComponent(LocalAudioRecorder.manifestName).path) {
                let manifest = try validatedManifest(directory: audio)
                offset = Double(manifest.timeline_offset_us) / 1_000_000
                duration = Double(manifest.streams.values.map(\.committed_bytes).max() ?? 0) / 32_000
            } else {
                guard let measured = legacyDuration(audioDirectory: audio) else {
                    throw resumeError("The media extent of session \(session.sessionID) is unknown")
                }
                offset = valid(session.timelineOffsetSeconds) ?? end
                duration = measured
            }
            var sessionEnd = offset + duration
            if let artifactsFolder = session.artifactsFolder {
                let artifacts = try artifactExtent(root: root, relativeDirectory: artifactsFolder)
                guard let captureEnd = artifacts.captureEnd, captureEnd >= offset else {
                    throw resumeError("Session \(session.sessionID) has no verified capture stop extent")
                }
                sessionEnd = max(sessionEnd, captureEnd, artifacts.mediaEnd ?? 0)
            }
            end = max(end, sessionEnd)
        }
        return end
    }

    private static func resumeError(_ message: String) -> NSError {
        NSError(domain: "MeetingResume", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func validatedManifest(directory: URL) throws -> LocalAudioRecorder.Manifest {
        let manifest = try LocalAudioRecorder.readManifest(directory: directory)
        for (name, stream) in manifest.streams {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name + ".pcm").path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value >= stream.committed_bytes else {
                throw resumeError("Committed source is truncated")
            }
        }
        return manifest
    }

    private struct ArtifactExtent { var mediaEnd: Double?; var captureEnd: Double? }
    /// Stream a bounded record at a time. A torn final ledger tail is not a
    /// committed event; earlier complete capture-stop evidence remains usable.
    private static func artifactExtent(root: URL, relativeDirectory: String) throws -> ArtifactExtent {
        let directory = root.appendingPathComponent(relativeDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path.hasPrefix(root.path + "/") else { throw resumeError("Artifact folder is outside the meeting") }
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent("assets.jsonl"))
        defer { try? handle.close() }
        var buffer = Data()
        var extent = ArtifactExtent()
        while let chunk = try handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            for byte in chunk {
                if byte != 0x0a {
                    guard buffer.count < 64 * 1024 else { throw resumeError("Artifact ledger record exceeds its limit") }
                    buffer.append(byte)
                    continue
                }
                guard let event = try JSONSerialization.jsonObject(with: buffer) as? [String: Any],
                      event["source_session_id"] as? String == directory.lastPathComponent else {
                    throw resumeError("Artifact ledger source identity is invalid")
                }
                buffer.removeAll(keepingCapacity: true)
                guard let time = valid(event["t"] as? Double) else { continue }
                if event["type"] as? String == "screenshot" { extent.mediaEnd = max(extent.mediaEnd ?? 0, time) }
                if event["type"] as? String == "capture_stopped" { extent.captureEnd = max(extent.captureEnd ?? 0, time) }
            }
        }
        return extent
    }

    static func recoveredDuration(mediaDurationSeconds: Double?, lastTranscriptTimestamp: Double) -> Double {
        if let mediaDurationSeconds, mediaDurationSeconds.isFinite, mediaDurationSeconds >= 0 {
            return mediaDurationSeconds
        }
        return lastTranscriptTimestamp.isFinite ? max(0, lastTranscriptTimestamp) : 0
    }

    static func finalize(_ metadata: MeetingMetadata, evidence: Evidence, now: Date) -> MeetingMetadata {
        var updated = metadata
        updated.status = .interrupted
        updated.updatedAt = now
        updated.durationSeconds = recoveredDuration(mediaDurationSeconds: evidence.durationSeconds,
                                                     lastTranscriptTimestamp: metadata.lastTimestamp)
        for observation in evidence.sessions {
            guard let index = updated.sessions.firstIndex(where: { $0.sessionID == observation.sessionID }) else { continue }
            updated.sessions[index].timelineOffsetSeconds = observation.timelineOffsetSeconds
            updated.sessions[index].durationSeconds = observation.durationSeconds
            // A recovered file gives a duration, not an observed wall-clock
            // stop callback. An unknown endedAt stays unknown, even days later.
        }
        return updated
    }

    /// Blocking file work: the caller must run this outside MainActor. Source
    /// PCM and its manifest are never changed; only compatibility WAVs are
    /// rebuilt from the frozen committed prefixes when a source manifest exists.
    static func inspectAndRecover(folderURL: URL, metadata: MeetingMetadata,
                                  exportWAVs: @Sendable (URL) throws -> Void = { _ = try LocalAudioRecorder.recoverWAVs(directory: $0) }) -> Evidence {
        var observations: [SessionEvidence] = []
        var problems: [String] = []
        var runningOffset: Double? = 0
        var knownEnd: Double?
        let root = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        for session in metadata.sessions.sorted(by: { $0.sessionID < $1.sessionID }) {
            let audio = root.appendingPathComponent(session.audioFolder, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard audio.path.hasPrefix(root.path + "/") else {
                problems.append("Session \(session.sessionID) audio folder is outside the meeting.")
                runningOffset = nil
                continue
            }
            var duration: Double?
            var offset = valid(session.timelineOffsetSeconds) ?? runningOffset
            if FileManager.default.fileExists(atPath: audio.appendingPathComponent(LocalAudioRecorder.manifestName).path) {
                do {
                    let manifest = try validatedManifest(directory: audio)
                    offset = Double(manifest.timeline_offset_us) / 1_000_000
                    duration = Double(manifest.streams.values.map { $0.committed_bytes }.max() ?? 0) / 32_000
                    do { try exportWAVs(audio) }
                    catch { problems.append("Session \(session.sessionID) WAV export failed; committed source remains available: \(error.localizedDescription)") }
                } catch {
                    // Do not fall back to a possibly stale WAV when the
                    // authoritative manifest/PCM failed validation or export.
                    problems.append("Session \(session.sessionID) committed source recovery failed: \(error.localizedDescription)")
                }
            } else {
                duration = legacyDuration(audioDirectory: audio)
                if duration == nil { problems.append("Session \(session.sessionID) has no readable source media duration.") }
            }
            if let artifactsFolder = session.artifactsFolder {
                do {
                    let artifacts = try artifactExtent(root: root, relativeDirectory: artifactsFolder)
                    if let offset, let end = [artifacts.captureEnd, artifacts.mediaEnd].compactMap({ $0 }).max(), end >= offset {
                        duration = max(duration ?? 0, end - offset)
                    }
                    if artifacts.captureEnd == nil {
                        problems.append("Session \(session.sessionID) artifact capture extent is not closed; media duration is a lower bound.")
                    }
                } catch { problems.append("Session \(session.sessionID) artifact recovery failed: \(error.localizedDescription)") }
            }
            observations.append(SessionEvidence(sessionID: session.sessionID,
                                                timelineOffsetSeconds: offset, durationSeconds: duration))
            if let offset, let duration {
                let end = offset + duration
                knownEnd = max(knownEnd ?? 0, end)
                runningOffset = max(runningOffset ?? 0, end)
            } else {
                // Never compress an unknown earlier legacy session out of the
                // timeline. A later explicit manifest offset can restore it.
                runningOffset = nil
            }
        }
        return Evidence(sessions: observations, durationSeconds: knownEnd, problems: problems)
    }

    /// Legacy fallback measures both independent tracks, even if the next
    /// reprocessing run selects only one. Returns nil when duration is unknown.
    static func legacyDuration(audioDirectory: URL) -> Double? {
        var longest: Double?
        for name in ["mic.wav", "system.wav"] {
            guard let file = try? AVAudioFile(forReading: audioDirectory.appendingPathComponent(name)),
                  file.fileFormat.sampleRate > 0 else { continue }
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            if seconds.isFinite && seconds >= 0 { longest = max(longest ?? 0, seconds) }
        }
        return longest
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
