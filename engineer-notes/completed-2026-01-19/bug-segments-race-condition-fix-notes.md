# Bug Fix Notes - Segment race condition (AsyncStream + stable IDs)

## Summary
Implemented the recommended AsyncStream approach to serialize backend stdout processing and added stable segment identity to reduce SwiftUI flicker.

## Changes
- `BackendProcess` now exposes `stdoutLines: AsyncStream<String>` and yields parsed lines into it.
- `AppModel` consumes stdout via a single `for await` loop on `MainActor`, removing per-line Tasks.
- `TranscriptSegment.id` is now stable (`"<stream>_<t0_ms>"`) instead of a random UUID.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `BackendProcess` adds `stdoutLines` and yields lines.
  - `AppModel.startMeeting()` starts `stdoutTask` with `for await` loop.
  - `AppModel.stopMeeting()` cancels `stdoutTask` and `cleanup()` finishes the stream.
  - `TranscriptSegment.id` changed to stable identity.

## Why this fixes it
- AsyncStream guarantees serial, in-order processing for stdout lines.
- Stable IDs prevent SwiftUI from re-creating rows when segments update.

## How to verify
1) Play system audio while speaking into mic; segments should not disappear.
2) Export transcript and confirm no missing lines.
