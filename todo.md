# TODO: Code Review Remediation Plan

Source: `engineer-notes/code-review/review.md`

## Phase 1 - Critical (in progress)
- [x] Fix BatchRediarizer cancellation race (zombie backend risk).
- [x] Prevent TranscriptSegment ID collisions (SwiftUI corruption).
- [x] Avoid data loss in stopMeeting by draining stdout before cleanup.
- [x] Remove Python stdout deadlock risk with dedicated writer.

See: `engineer-notes/code-review/todo-phase1-critical.md`

## Phase 2 - High (completed)
- [x] Sanitize meeting titles to prevent path traversal.
- [x] Optimize TranscriptModel ingest to avoid O(N log N) sort on every segment.
- [x] Surface FramedWriter write failures to UI state.
- [x] Bound AsyncStream buffering for backend stdout.

See: `engineer-notes/code-review/todo-phase2-high.md`

## Phase 3 - Medium (completed)
- [x] Add explicit timeout feedback for Ollama requests.
- [x] Split monolithic `ContentView.swift` into smaller files.
- [x] Fix Python file descriptor leak in `muesli_backend.py`.
- [x] Pass detected audio format from Swift to Python pipeline.

See: `engineer-notes/code-review/todo-phase3-medium.md`

## Phase 4 - Low (completed)
- [x] Remove hardcoded `/Users/david` path in `AppModel`.
- [x] Make `SpeakerIdentifier.checkAvailability` fully async with short timeout.
- [x] Deduplicate transcript export logic.
- [x] Replace magic numbers with named constants.

See: `engineer-notes/code-review/todo-phase4-low.md`
