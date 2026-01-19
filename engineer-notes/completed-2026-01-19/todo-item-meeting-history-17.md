# Meeting History Todo Item 17 - Delete Flow

## Summary
- Deleting a meeting now closes the viewer if the deleted meeting is currently open.

## Changes
- `deleteMeeting` already trashes and removes from history; now also returns to start screen when deleting a viewed meeting.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
