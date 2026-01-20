# Phase 2.3 - Surface FramedWriter Write Failures

## Problem
If the backend process exits or its stdin closes, `FramedWriter` writes can fail silently. The app would keep recording without realizing the backend was no longer receiving audio/screenshot frames, leading to data loss with no visible error.

## Fix
- Added an `onWriteError` callback to `FramedWriter`.
- Guarded with a `didFail` flag to avoid spamming repeated error callbacks.
- Wired the callback in `AppModel` to surface an error and stop the meeting cleanly.

## Implementation Details
- `FramedWriter.writeFrame` now catches write errors and triggers `onWriteError` once.
- `AppModel` registers `onWriteError` when the backend writer is created.
- The handler (`handleBackendWriteError`) updates `shareableContentError`, writes to the backend log tail, and invokes `stopMeeting()` to end capture reliably.

## Why This Works
This makes backend write failures visible and stops the meeting to prevent corrupt or empty outputs. The one-shot guard prevents a flood of UI alerts or log spam if multiple writes fail after the backend is gone.

## Files
- `MuesliApp/MuesliApp/BackendProcess.swift`
- `MuesliApp/MuesliApp/AppModel.swift`
