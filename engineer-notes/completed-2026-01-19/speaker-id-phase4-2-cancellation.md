# Speaker Identification Phase 4.2 - Cancellation Support

## Summary
- Added user-initiated cancellation and lifecycle cleanup for speaker identification tasks.

## Approach
- Stored the identification task in Meeting Viewer state and cancelled it on demand and on view disappearance.
- Added `Task.checkCancellation()` in the identification pipeline and image-loading loop to exit early.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
