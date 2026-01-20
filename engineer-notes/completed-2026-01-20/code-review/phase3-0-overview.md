# Phase 3 - Medium Priority Overview

## Goal
Improve debuggability, maintainability, and correctness in several medium-risk areas: clearer timeout feedback for speaker identification, more manageable SwiftUI file structure, and cleanup of backend file handling and audio format metadata.

## Work Completed
- Explicit 30s timeout for Ollama speaker ID requests with user-facing error messaging.
- Split `ContentView.swift` into smaller, focused SwiftUI files.
- Fixed file descriptor leak when PCM file creation fails in the backend.
- Propagated per-stream audio format from Swift into the Python pipeline.

## Approach
1) Make user-facing errors actionable (timeout messaging) instead of generic failures.
2) Reduce risk of UI regressions by dividing large view files into smaller, isolated components.
3) Eliminate low-level resource leaks in the backend that can accumulate over time.
4) Ensure backend audio processing reflects the actual stream format negotiated by the capture pipeline.

## Verification
- Manual code review for each item.
- Confirmed timeout handling and messaging behavior in the speaker identification call path.
- Checked that view extractions preserved existing state bindings and environment usage.
- Verified backend uses per-stream sample rates and channel counts from meeting metadata with safe fallbacks.

## Files Touched
- `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
- `MuesliApp/MuesliApp/MeetingViewer.swift`
- `MuesliApp/MuesliApp/ContentView.swift`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
