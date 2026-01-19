# Meeting History Todo Item 10 - Legacy Metadata Migration

## Summary
- Added a migration pass that scans meeting folders and generates `meeting.json` for legacy meetings.

## Behavior
- Runs at app model init.
- Skips folders that already contain `meeting.json`.
- Derives title from `meta.json` if present, otherwise folder name.
- Derives segment count + last timestamp from `transcript.jsonl` or `transcript_events.jsonl`.
- Uses filesystem timestamps for created/updated times when needed.
- Writes a single-session metadata file marked as completed.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
