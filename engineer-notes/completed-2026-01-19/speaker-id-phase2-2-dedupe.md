# Speaker Identification Phase 2.2 - Near-Duplicate Dedupe

## Summary
- Implemented lightweight near-duplicate detection so visually similar frames taken close together do not crowd out the sample set.

## Approach
- Computed an 8x8 grayscale average hash per image using CoreGraphics and measured Hamming distance between consecutive frames.
- Skipped frames when the hash distance is below a threshold and the timestamps are within a short time window; this preserves coverage while dropping redundant frames.
- Defaulted to keeping frames when hashing fails (e.g., unreadable image) to avoid accidental data loss.

## Files
- Updated: `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
