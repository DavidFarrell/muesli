# Speaker Identification Phase 3.4 - Persist Mappings

## Summary
- Persisted accepted speaker mappings to the meeting's `meeting.json` metadata.
- Ensured renames in the viewer also save to disk, not just live sessions.

## Approach
- Added `applySpeakerMappings` to update `TranscriptModel` in bulk and then write metadata once.
- Refactored speaker-name persistence to accept a folder URL so it works for both active sessions and historical meetings.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
