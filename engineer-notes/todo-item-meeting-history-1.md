# Meeting History Todo Item 1 - Extract AppModel

## Summary
- Extracted the app model and related data types out of `ContentView.swift` into a dedicated file to reduce file size and align with the PRD refactor requirement.

## Changes
- Moved `CaptureMode`, `SourceKind`, `MeetingSession`, `BackendPythonError`, and `AppModel` into a new file.
- Left `ContentView.swift` focused on views and toolbar wiring.

## Files
- Created: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
