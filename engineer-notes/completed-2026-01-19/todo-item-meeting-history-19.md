# Meeting History Todo Item 19 - Resume Timestamp Offset

## Summary
- Resume flow now computes timestamp offsets and applies them when ingesting new segments.

## Changes
- Added `timestampOffset` to `TranscriptModel` and applied it when ingesting segments/partials.
- Added resume entry point that reads `meeting.json`, sets the offset, and starts a resumed meeting.
- Added resume-aware start path that appends a new session to `meeting.json`.

## Files
- Updated: `MuesliApp/MuesliApp/TranscriptModel.swift`
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
