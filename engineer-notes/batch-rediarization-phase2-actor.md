# Batch Re-Diarization Phase 2.0 - BatchRediarizer Actor

## Summary
- Added `BatchRediarizer` to run the reprocess CLI, parse JSON status/result lines, and surface progress to the UI.
- Implemented cancellation/timeout handling to avoid runaway processes.

## Approach
- Launched the CLI via `BackendProcess` with the backend's `PYTHONPATH` so the app can run the command inside the selected backend folder.
- Parsed `status` and `result` JSON envelopes to drive progress and capture the final transcript turns.
- Used a cancellation handler to terminate the process if the user cancels or the view disappears.

## Files
- Added: `MuesliApp/MuesliApp/BatchRediarizer.swift`
