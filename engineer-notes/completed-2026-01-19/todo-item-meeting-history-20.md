# Meeting History Todo Item 20 - Resume Finalization

## Summary
- Finalization now respects prior session state, ensuring resume sessions update totals without clobbering older data.

## Changes
- `finalizeMeetingMetadata` now takes the max of existing totals and current in-memory segments, ensuring `last_timestamp`, `segment_count`, and `duration_seconds` reflect cumulative history.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
