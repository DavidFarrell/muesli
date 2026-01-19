# Speaker Identification Phase 3.2 - Progress State

## Summary
- Added live progress feedback (extracting frames, analyzing, complete) for speaker identification runs.

## Approach
- Used `SpeakerIdentifier.Progress` to drive a `ProgressView` and status text.
- Propagated progress updates from the actor back to the UI on the main actor.
- Cleared progress state on completion or cancellation.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
