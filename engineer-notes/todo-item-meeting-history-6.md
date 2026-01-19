# Meeting History Todo Item 6 - Create meeting.json on Start

## Summary
- Added initial metadata creation when a meeting starts, writing `meeting.json` with status=recording and session 1.

## Changes
- `startMeeting()` now writes `meeting.json` after creating the meeting folder and audio subfolder.
- Removed legacy `meta.json` creation from `createMeetingFolder`.
- Added helpers to write JSON metadata with ISO8601 dates.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
