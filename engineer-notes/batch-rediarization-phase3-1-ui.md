# Batch Re-Diarization Phase 3.1 - Meeting Viewer UI

## Summary
- Added a "Rerun speaker segmentation" button above "Identify speakers" in the Meeting Viewer.
- Added a stream selector and progress UI to make batch re-diarization visible and controllable.

## Approach
- Placed the new controls inside the existing "Speaker ID" group to keep related actions together.
- Disabled the action while rediarization or speaker ID is running, and when the meeting is still recording.
- Surfaced progress and errors inline so the user doesn't need to open logs.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
