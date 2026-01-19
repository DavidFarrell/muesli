# Meeting History Todo Item 14 - Load Transcript for Viewer

## Summary
- Meeting viewer now loads the saved transcript and speaker names into `TranscriptModel`.

## Changes
- On `openMeeting`, load `transcript.jsonl` lines into `TranscriptModel` and apply `speakerNames` from metadata.
- Clear transcript state on viewer exit to avoid bleeding into new sessions.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
