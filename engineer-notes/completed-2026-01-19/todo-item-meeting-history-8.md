# Meeting History Todo Item 8 - Persist Speaker Names

## Summary
- Speaker name edits now persist immediately to `meeting.json` during a live session.

## Changes
- Added `AppModel.renameSpeaker` to wrap `TranscriptModel.renameSpeaker` and write speaker names to metadata.
- Updated UI bindings to use the new `AppModel` method.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
