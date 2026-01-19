# Speaker Identification Phase 3.3 - Mapping Review Sheet

## Summary
- Added a mapping review sheet that lets users edit proposed speaker names before applying them.

## Approach
- Created `SpeakerMappingSheet` with editable rows for speaker ID, name, and confidence.
- Initialized the sheet with the suggested mappings sorted by speaker ID for predictable review.
- Exposed explicit Cancel/Apply actions to avoid accidental persistence.

## Files
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
