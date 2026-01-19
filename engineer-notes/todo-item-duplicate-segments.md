# Todo Item - Dedupe duplicate transcript segments

## Goal
Prevent duplicate/superseded transcript segments from appearing in the UI and export by deduping overlapping segments on ingest.

## What I changed
- Added `insertSegment(_:)` to `TranscriptModel` to replace or drop overlapping segments per stream.
- `ingest(jsonLine:)` now calls `insertSegment` instead of blindly appending.
- Segments are sorted by `t0` after each insert to enforce ordering.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `TranscriptModel.insertSegment(_:)` implements overlap rules and sorting.
  - `ingest(jsonLine:)` uses `insertSegment` for `segment` events.

## Notes for reviewer
- Overlapping segments with the same stream are treated as superseded if they have close start times or high overlap; longer/expanded segments replace earlier fragments.
- If an existing segment fully covers a new one and is longer, the new segment is ignored to avoid regressions.
- This should satisfy the acceptance criteria in `engineer-notes/bug-duplicate-segments.md` for clean exports.
