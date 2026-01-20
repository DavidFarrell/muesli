# Speaker Identification Phase 2.0 - Screenshot Sampling Overview

## Summary
- Implemented screenshot selection logic inside `SpeakerIdentifier` to choose a small, representative set of frames before sending to Ollama.
- Added stable ordering, near-duplicate removal, and an empty-input fallback so the pipeline behaves predictably across meetings.
- Updated the Phase 2 checklist to reflect completion.

## Approach
- Centralized all Phase 2 selection concerns in `SpeakerIdentifier` so the UI/workflow can keep passing a full screenshot list without worrying about sampling.
- Chose a target count (16) and lightweight dedupe (8x8 average hash + short time window) to reduce payload size while keeping coverage across the timeline.
- Ensured deterministic ordering and selection so reruns on the same meeting yield identical inputs.

## Files
- Updated: `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
- Updated: `todo-speaker-identification.md`
