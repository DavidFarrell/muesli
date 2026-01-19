# TODO: Meeting History & Resume (Comprehensive)

## Phase 0 - Refactor (Prerequisite)
- [x] Extract `AppModel` to `MuesliApp/MuesliApp/AppModel.swift`.
- [x] Extract `TranscriptModel` to `MuesliApp/MuesliApp/TranscriptModel.swift`.
- [x] Extract `CaptureEngine` + `AudioSampleExtractor` to `MuesliApp/MuesliApp/CaptureEngine.swift`.
- [x] Extract `BackendProcess` + `FramedWriter` to `MuesliApp/MuesliApp/BackendProcess.swift`.
- [x] Add `MuesliApp/MuesliApp/MeetingData.swift` for metadata types.

## Phase 1 - Metadata Foundation
- [x] Create `meeting.json` on meeting start with initial metadata (status=recording, session 1).
- [x] Update `meeting.json` on stop: duration, last_timestamp, segment_count, status=completed, session end.
- [x] Persist speaker name edits to `meeting.json` immediately.
- [x] Record per-stream formats in session `streams` entry (system/mic sample rate/channels).

## Phase 1b - Migration for Existing Meetings
- [x] Scan meetings folder and detect missing `meeting.json`.
- [x] Generate metadata from transcript files + filesystem timestamps.
- [x] Write generated `meeting.json` for each legacy meeting.

## Phase 2 - History List (Start Screen)
- [x] Add `MeetingHistoryItem` model and scan `~/Library/Application Support/Muesli/Meetings` at launch.
- [x] Load metadata; fallback to folder name if missing.
- [x] Sort by `created_at` desc; show first 5-10 with “Show More”.
- [x] Add delete (trash) action with confirmation.

## Phase 2b - Meeting Viewer
- [x] Add `AppScreen.viewing(URL)` state + navigation back.
- [x] Load `transcript.jsonl` into `TranscriptModel` for read-only viewer.
- [x] Show transcript + speaker editor; persist edits to `meeting.json`.
- [x] Add Copy + Export actions in viewer.

## Phase 3 - Delete
- [x] Use `FileManager.trashItem` to move meeting folder to Trash.
- [x] Remove deleted item from history list immediately.
- [x] If currently viewing, navigate back to start screen.

## Phase 4 - Resume
- [x] Compute next session ID and create `audio-session-N` folder.
- [x] Load `meeting.json`, compute timestamp offset from `last_timestamp`.
- [x] Add `TranscriptModel.timestampOffset` and apply to new segments on ingest.
- [x] Append new session info to `meeting.json` (status=recording).
- [x] On stop, finalize session, update `duration_seconds`, `last_timestamp`, `segment_count`, status=completed.

## QA / Acceptance Checks
- [ ] History list shows recent meetings with duration + segment count.
- [ ] Viewer loads transcript in correct order; speaker edits persist.
- [ ] Delete moves folder to Trash (recoverable).
- [ ] Resume appends new audio folder and continues timestamps without resetting to 0.
