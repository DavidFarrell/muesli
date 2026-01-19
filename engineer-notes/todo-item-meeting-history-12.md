# Meeting History Todo Item 12 - History List UI + Delete

## Summary
- Added a Recent Meetings list to the start screen with show-more behavior and delete confirmation.

## Changes
- `NewMeetingView` now renders the recent meeting list with duration + segment counts.
- Added show more/less toggle and empty state.
- Added delete confirmation alert and wired delete to `AppModel.deleteMeeting`.
- `AppModel.deleteMeeting` moves the meeting folder to Trash and updates in-memory history.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
