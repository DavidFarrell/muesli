# Speaker Identification Phase 3.0 - UI/Workflow Overview

## Summary
- Wired the meeting viewer UI to trigger speaker identification, show progress, and review results before applying them.
- Added a review sheet for proposed mappings and persisted accepted names back to meeting metadata.
- Kept the workflow local to the viewer so it operates on the selected meeting without background logging.

## Approach
- Added a dedicated "Speaker ID" section in the Meeting Viewer to host the action, progress, and errors.
- Encapsulated result review in a new sheet with editable mappings and an explicit apply step.
- Added a model-level helper to persist approved mappings to the correct meeting folder.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
