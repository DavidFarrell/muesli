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
    static func inspectAndRecover(folderURL: URL, metadata: MeetingMetadata) -> Evidence {
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
                    let manifest = try LocalAudioRecorder.recoverWAVs(directory: audio)
                    offset = Double(manifest.timeline_offset_us) / 1_000_000
                    duration = Double(manifest.streams.values.map { $0.committed_bytes }.max() ?? 0) / 32_000
                } catch {
                    // Do not fall back to a possibly stale WAV when the
                    // authoritative manifest/PCM failed validation or export.
                    problems.append("Session \(session.sessionID) committed source recovery failed: \(error.localizedDescription)")
                }
            } else {
                duration = legacyDuration(audioDirectory: audio)
                if duration == nil { problems.append("Session \(session.sessionID) has no readable source media duration.") }
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
