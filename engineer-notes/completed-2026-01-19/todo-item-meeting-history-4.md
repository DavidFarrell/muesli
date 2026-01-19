# Meeting History Todo Item 4 - Extract BackendProcess

## Summary
- Moved backend process management and framing to a dedicated file to decouple it from the UI layer.

## Changes
- Extracted `BackendProcess`, `StreamID`, `MsgType`, and `FramedWriter` into `BackendProcess.swift`.
- Kept `ContentView.swift` focused on UI and non-backend helpers.

## Files
- Created: `MuesliApp/MuesliApp/BackendProcess.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
