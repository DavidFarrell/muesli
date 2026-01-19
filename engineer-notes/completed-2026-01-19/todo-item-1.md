# Todo Item 1 - PRD-grade graceful stop

## Goal
Make meeting stop deterministic so the meetingStop frame is reliably delivered, stdin drains, and the backend has a chance to finalize before we terminate.

## What I changed
- Added a synchronous write path to `FramedWriter` and a drain/close helper so stop can flush the queue before closing stdin.
- Updated `stopMeeting()` to use `sendSync`, drain + close stdin, then wait for backend exit with timeout and terminate fallback.

## Why
The prior async-only write could race with closing stdin, dropping `meetingStop` or truncating the last audio frames. The PRD called for a sync/dain/close sequence to avoid silent data loss.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `stopMeeting()` now calls `writer?.sendSync(...)` and `writer?.closeStdinAfterDraining()`.
  - `FramedWriter` now has `sendSync`, `closeStdinAfterDraining`, and a shared `writeFrame` helper.

## Notes for reviewer
- Verify that `meetingStop` is delivered even under heavy audio load.
- Confirm the backend exits naturally after stdin closes, and that the timeout fallback still terminates as expected.
