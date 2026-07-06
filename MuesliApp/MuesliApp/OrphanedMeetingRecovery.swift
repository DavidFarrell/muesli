import Foundation

/// Pure decision logic for recovering a meeting whose `meeting.json` was left
/// at `status: recording` - the app crashed or was force-quit mid-meeting
/// (see engineer-notes/incident-2026-07-06-mainthread-livelock.md, where a
/// SIGKILL after a main-thread livelock left exactly this state, with fully
/// healthy audio underneath that Resume/rediarize refused to touch). Free of
/// `FileManager`/`AVAudioFile`/`AppModel` state so the finalize decision and
/// the duration fallback can be unit tested without real audio files or a
/// running app. `AppModel` supplies the actual wav-duration reads and
/// fallback mtime; this just decides what the finalized metadata should be.
enum OrphanedMeetingRecovery {
    /// Anything besides `.recording` is untouched - this only matters for a
    /// meeting that never reached its normal stop/finalize path.
    static func needsRecovery(_ metadata: MeetingMetadata) -> Bool {
        metadata.status == .recording
    }

    /// The final duration to record: the larger of the wav-derived duration
    /// (nil if both wavs were unreadable) and the fallback (mtime-based)
    /// duration, never smaller than whatever was already on disk.
    static func recoveredDuration(
        existingDurationSeconds: Double,
        wavDurationSeconds: Double?,
        fallbackDurationSeconds: Double
    ) -> Double {
        let best = wavDurationSeconds.map { max($0, fallbackDurationSeconds) } ?? fallbackDurationSeconds
        return max(existingDurationSeconds, best)
    }

    /// Applies the recovery decision to a copy of the metadata: flips status
    /// to `.completed`, bumps `durationSeconds`/`updatedAt`, and closes out
    /// the last session's `endedAt` if it was still open - mirrors
    /// `AppModel.finalizeMeetingMetadata`'s normal-stop bookkeeping so a
    /// recovered meeting looks exactly like one that stopped cleanly.
    /// `segmentCount` is left untouched - it is only ever known from the
    /// transcript files, which recovery does not attempt to re-derive.
    static func finalize(
        _ metadata: MeetingMetadata,
        wavDurationSeconds: Double?,
        fallbackDurationSeconds: Double,
        now: Date
    ) -> MeetingMetadata {
        var updated = metadata
        updated.status = .completed
        updated.updatedAt = now
        updated.durationSeconds = recoveredDuration(
            existingDurationSeconds: metadata.durationSeconds,
            wavDurationSeconds: wavDurationSeconds,
            fallbackDurationSeconds: fallbackDurationSeconds
        )
        if let lastIndex = updated.sessions.indices.last {
            let lastSession = updated.sessions[lastIndex]
            if lastSession.endedAt == nil {
                updated.sessions[lastIndex] = MeetingSessionMetadata(
                    sessionID: lastSession.sessionID,
                    startedAt: lastSession.startedAt,
                    endedAt: now,
                    audioFolder: lastSession.audioFolder,
                    streams: lastSession.streams
                )
            }
        }
        return updated
    }
}
