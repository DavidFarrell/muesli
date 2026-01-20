# Speaker Identification Phase 2.1 - Even Screenshot Sampling

## Summary
- Added a timeline-aware sampler that selects screenshots evenly across the recording using timestamps embedded in filenames.
- Added a deterministic fallback (index-based sampling) when timestamps are missing or insufficient.

## Approach
- Parsed timestamps from screenshot filenames using the existing naming format (`t+%010.3f.png`).
- Sorted candidates by timestamp (and by filename when timestamps are missing) to guarantee stable ordering.
- When timestamps are available, computed evenly spaced target times from start to end and selected the closest frames.
- When timestamps are not reliable, used evenly spaced indices across the list instead.
- Ensured the final selection is unique and filled to the target count if initial choices collided.

## Files
- Updated: `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
