# Meeting History Todo Item 3 - Extract CaptureEngine

## Summary
- Moved capture pipeline types out of `ContentView.swift` into a dedicated `CaptureEngine.swift` file.

## Changes
- Extracted audio extraction helpers (`AudioExtractError`, `PCMChunk`, `PendingAudio`, `AudioSampleExtractor`).
- Extracted `CaptureEngine` and `RecordingDelegate` to the new file.
- Left `ContentView.swift` with only the remaining helpers and views.

## Files
- Created: `MuesliApp/MuesliApp/CaptureEngine.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
