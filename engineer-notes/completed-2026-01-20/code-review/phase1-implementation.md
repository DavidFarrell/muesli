# Code Review Phase 1 - Implementation Notes

## Summary
Phase 1 addressed all Critical severity findings from `engineer-notes/code-review/review.md`.

## Changes

### 1) BatchRediarizer Cancellation Race
- **Problem:** `BatchRediarizer.run` could leave a backend process running if cancellation happened before the local `process` variable was assigned.
- **Fix:** Added a `ProcessStore` actor to store the process reference as soon as it is created, and a cancellation handler that always terminates/cleans up the stored process.
- **Files:** `MuesliApp/MuesliApp/BatchRediarizer.swift`

### 2) TranscriptSegment ID Collisions
- **Problem:** `TranscriptSegment.id` used a millisecond-derived string, which could collide and break SwiftUI diffing.
- **Fix:** Replaced the ID with a UUID-based identity, and added a `logicKey` for any logic that needs the old key semantics.
- **Files:** `MuesliApp/MuesliApp/TranscriptModel.swift`

### 3) stopMeeting Data Loss Risk
- **Problem:** `stdoutTask` was canceled immediately, potentially dropping the backend’s final stdout lines.
- **Fix:** Added a drain helper that waits for stdout to finish (with timeout), avoids forced cancellation, and only cancels if it hangs.
- **Files:** `MuesliApp/MuesliApp/AppModel.swift`

### 4) Python Stdout Deadlock Risk
- **Problem:** The backend guarded stdout writes with a lock; if the pipe filled, the lock stayed held and other threads deadlocked.
- **Fix:** Introduced `StdoutWriter`, a dedicated writer thread with a queue, and routed all JSONL emits through it.
- **Files:** `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`

## Notes
- No tests were run as part of these changes.
- Phase 2–4 items are tracked in `todo.md` and the per-phase todo files under `engineer-notes/code-review/`.
