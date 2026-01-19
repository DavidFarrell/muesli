# Meeting History Todo Item 2 - Extract TranscriptModel

## Summary
- Extracted transcript data types into a dedicated file for easier reuse in the meeting history viewer and to reduce file size of `ContentView.swift`.

## Changes
- Moved `TranscriptSegment` and `TranscriptModel` into `TranscriptModel.swift`.
- Left `ContentView.swift` to focus on views and remaining helpers.

## Files
- Created: `MuesliApp/MuesliApp/TranscriptModel.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
