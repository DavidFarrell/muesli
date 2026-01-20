# Speaker Identification Phase 3.1 - Identify Speakers Button

## Summary
- Added an "Identify speakers" button to the Meeting Viewer sidebar.
- Disabled the action when Ollama is not ready or a run is already in progress.

## Approach
- Placed the button in a new "Speaker ID" group within the viewer to keep related controls together.
- Gated the action using `AppModel.speakerIdStatus` so the UI reflects the preflight checks.
- Left errors in the viewer UI instead of logging to disk.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
