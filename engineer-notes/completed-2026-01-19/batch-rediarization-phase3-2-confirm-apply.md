# Batch Re-Diarization Phase 3.2 - Confirm + Apply Transcript Replacement

## Summary
- Added a confirmation dialog that reports the number of speakers found and asks before replacing the transcript.
- Implemented transcript replacement that rewrites `transcript.txt` and `transcript.jsonl`, and clears speaker names.

## Approach
- Stored the batch result until the user confirms, then applied it in one step to avoid partial updates.
- Regenerated transcript files from the new turns and reset speaker name mappings to empty.
- Updated meeting metadata and refreshed the meeting history entry so counts and timestamps stay accurate.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
