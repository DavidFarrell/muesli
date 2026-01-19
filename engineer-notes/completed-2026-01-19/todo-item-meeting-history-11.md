# Meeting History Todo Item 11 - Load Meeting History

## Summary
- Added meeting history loading at launch by scanning the Meetings directory and decoding `meeting.json`.

## Changes
- Added `meetingHistory` state in `AppModel`.
- Added history loading helpers to build `MeetingHistoryItem` from metadata or legacy fallbacks.
- Runs on app init after legacy migration to ensure `meeting.json` exists.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
