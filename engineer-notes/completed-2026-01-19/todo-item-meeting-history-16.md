# Meeting History Todo Item 16 - Viewer Copy + Export

## Summary
- Added transcript copy and export actions to the meeting viewer header.

## Changes
- Viewer header now shows clipboard and export icons.
- Export uses a new `AppModel.exportTranscriptFiles(for:)` helper that writes JSONL alongside TXT.
- Copy uses the existing `TranscriptModel.asPlainText()` output.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `todo-meeting-history.md`
