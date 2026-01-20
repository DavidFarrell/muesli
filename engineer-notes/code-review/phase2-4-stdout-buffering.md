# Phase 2.4 - Bound Backend Stdout Buffering

## Problem
`BackendProcess.stdoutLines` used an unbounded `AsyncStream`. If a caller didn't consume all lines (or consumed them slowly), the buffer could grow without limit during long meetings, increasing memory usage and eventually pressuring the app.

## Fix
- Configured `AsyncStream` with `.bufferingNewest(500)`.
- This caps memory growth while still preserving a useful recent history for UI and diagnostics.

## Implementation Details
- The `AsyncStream` initialization in `BackendProcess` now explicitly sets a buffering policy.
- The existing line parsing and `onJSONLine` callback behavior are unchanged.

## Why This Works
The app only needs recent stdout lines for live status and debugging. Dropping older lines is an acceptable tradeoff and prevents unbounded memory growth during multi-hour meetings.

## Files
- `MuesliApp/MuesliApp/BackendProcess.swift`
