# Meeting History Todo Item 7 - Finalize meeting.json on Stop

## Summary
- Added meeting metadata finalization on stop: duration, last timestamp, segment count, status, and session end time.

## Changes
- Added metadata read helper and finalization routine.
- On stop, compute last timestamp from finalized segments and update `meeting.json` with completion data.
- Session end time is set on the latest session if missing.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
