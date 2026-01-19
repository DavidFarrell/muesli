# Batch Re-Diarization Phase 0.0 - Overview

## Summary
- Implemented the batch re-diarization workflow end-to-end: backend CLI, Swift actor, Meeting Viewer UI, and transcript replacement.
- Added a confirmation gate that clears existing speaker names and rewrites transcript files when approved.

## Approach
- Kept the batch workflow separate from the live streaming backend with a dedicated CLI entrypoint.
- Centralized process orchestration in a Swift actor with structured progress updates.
- Updated transcript and metadata in one place so UI and meeting history stay consistent.

## Files
- Added: `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/reprocess.py`
- Updated: `backend/fast_mac_transcribe_diarise_local_models_only/pyproject.toml`
- Added: `MuesliApp/MuesliApp/BatchRediarizer.swift`
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
