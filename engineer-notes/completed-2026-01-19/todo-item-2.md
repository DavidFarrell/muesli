# Todo Item 2 - PRD-grade transcript persistence

## Goal
Persist backend JSONL events to disk as they arrive (crash-safe), instead of only writing transcript files on stop.

## What I changed
- Added a streaming JSONL log `transcript_events.jsonl` in the meeting folder.
- Each backend stdout JSON line is appended to this file immediately in `handleBackendJSONLine`.
- Wired log lifecycle: create on meeting start, close on stop or early failure.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - New properties: `transcriptEventsHandle`, `transcriptEventsURL`.
  - New helpers: `resetTranscriptEventsLog(in:)`, `closeTranscriptEventsLog()`.
  - `handleBackendJSONLine(_:)` now appends raw JSON lines to `transcript_events.jsonl`.
  - Start/stop error paths now close the transcript events log.

## Output location
- `~/Library/Application Support/Muesli/Meetings/<meeting>/transcript_events.jsonl`

## Notes for reviewer
- This keeps the existing `transcript.jsonl` (finalized segments on stop) intact.
- If we want the PRD naming exactly, we can swap `transcript_events.jsonl` -> `transcript.jsonl` and rename the final output file.
