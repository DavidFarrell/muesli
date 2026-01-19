# Meeting History Todo Item 13 - AppScreen + Viewer Navigation

## Summary
- Added an explicit `AppScreen` state with a viewing mode, and wired navigation back to the start screen.

## Changes
- Added `AppScreen` enum and `activeScreen` in `AppModel`.
- Set screen to `.session` on successful start, `.start` on stop.
- Added `openMeeting`/`closeMeetingViewer` helpers.
- Updated `RootView` to switch on `activeScreen` and added a placeholder `MeetingViewer` with a Back button.
- Recent meetings list now opens the viewer.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
