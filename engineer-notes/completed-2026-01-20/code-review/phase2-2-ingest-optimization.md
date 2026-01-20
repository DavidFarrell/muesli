# Phase 2.2 - Transcript Ingest Optimization

## Problem
`TranscriptModel.ingest` sorted the entire segment list on every new segment. During long meetings this results in O(N log N) work per incoming segment, causing noticeable UI stutter and unnecessary CPU usage.

## Fix
- Introduced a monotonic timestamp check using the last known `t0`.
- Only sort when a new segment arrives out of order.
- Applied the same logic to both full `segment` updates and `partial` updates.

## Implementation Details
- For full segments:
  - Build `existing` from non-partials, merge the new segment via `mergeSegment`.
  - Compare `segment.t0` against `existing.last?.t0` and only call `sortedSegments` when out of order.
- For partial segments:
  - Update or append the partial segment.
  - Compare `segment.t0` against `segments.last?.t0` and sort only if needed.

## Why This Works
Live transcript data arrives in chronological order the vast majority of the time. Skipping the sort in the common case eliminates unnecessary churn while preserving correctness when a late correction or re-ordered segment arrives.

## Files
- `MuesliApp/MuesliApp/TranscriptModel.swift`
