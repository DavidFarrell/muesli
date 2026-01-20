# Phase 2 - High Priority Overview

## Goal
Harden the capture pipeline against security and performance regressions without changing external behavior. This phase focuses on protecting filesystem writes, keeping transcript ingestion responsive during long meetings, and surfacing backend failures instead of silently dropping data.

## Work Completed
- Meeting title sanitization before folder creation.
- Transcript ingest optimization to avoid unnecessary sorts.
- FramedWriter error reporting wired to UI state.
- Bounded buffering for backend stdout AsyncStream.

## Approach
1) Address the security issue first (path traversal via meeting titles), because it affects where data is written.
2) Improve hot-path performance in transcript ingestion to avoid UI stutter in long sessions.
3) Wire backend write failures into app state so capture stops cleanly and the user gets a clear error.
4) Cap memory growth for backend stdout consumption by bounding the AsyncStream buffer.

## Verification
- Manual code review for all affected functions.
- Ensured sanitization is applied only at folder creation so meeting metadata remains user friendly.
- Confirmed ingest logic still handles out-of-order segments by falling back to sorting when needed.
- Verified FramedWriter error callback is only fired once and triggers `stopMeeting()`.

## Files Touched
- `MuesliApp/MuesliApp/AppModel.swift`
- `MuesliApp/MuesliApp/TranscriptModel.swift`
- `MuesliApp/MuesliApp/BackendProcess.swift`
