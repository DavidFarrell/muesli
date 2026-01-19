# Todo Item 3 - Temp transcript artifacts on stop

## Goal
Write final transcript artifacts to a temp folder on stop (in addition to the meeting folder) and surface that path in logs/UI.

## What I changed
- Added `tempTranscriptFolderPath` to `AppModel` and reset it on meeting start.
- `saveTranscriptFiles(for:)` now writes `transcript.jsonl` and `transcript.txt` to a unique temp folder under the system temp directory.
- The temp path is logged to the backend log and shown in the debug panel.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - New `@Published var tempTranscriptFolderPath`.
  - `saveTranscriptFiles(for:)` now writes a temp copy and logs the path.
  - Debug summary/panel includes the temp path.
  - `startMeeting()` clears old temp path.
- `/Users/david/git/ai-sandbox/projects/muesli/todo.md` marked item 3 complete.

## Output location
- Temp transcripts: `FileManager.default.temporaryDirectory/Muesli-<title>-<uuid>/transcript.{txt,jsonl}`.

## Notes for reviewer
- The meeting folder copy is still written as before.
- Temp folder path is logged and visible in the debug panel.
