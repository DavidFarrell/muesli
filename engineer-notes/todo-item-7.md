# Todo Item 7 - Copy/Export transcript controls

## Goal
Provide quick transcript export actions from the Session UI.

## What I changed
- Added "Copy transcript" and "Export transcript" buttons to the Controls group.
- Implemented `TranscriptModel.asPlainText()` for human-readable export.
- Implemented `exportTranscriptFiles()` in `AppModel` to write `transcript.txt` and `transcript.jsonl` to the meeting folder and log failures.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - Session Controls buttons added.
  - `TranscriptModel.asPlainText()` added.
  - `AppModel.exportTranscriptFiles()` added.

## Notes for reviewer
- Export uses finalized segments only (partials omitted).
- Errors are logged to backend log for visibility.
