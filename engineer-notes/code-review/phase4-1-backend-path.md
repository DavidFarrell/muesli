# Phase 4.1 - Remove Hardcoded Backend Path

## Problem
`AppModel` included a fixed `/Users/david/...` backend path for the folder picker. This fails on any machine that doesn't match that filesystem layout and makes the app non-portable.

## Fix
- Removed the hardcoded path.
- Added a small discovery routine:
  - Optional `MUESLI_BACKEND_ROOT` environment variable override.
  - Debug-only fallback that checks for the backend folder relative to the current working directory.
- If no candidate path is found, the folder picker uses its default location.

## Implementation Details
- Replaced the stored `defaultBackendProjectRoot` with a computed property that resolves to an optional URL.
- `chooseBackendFolder()` now sets `panel.directoryURL` only when a valid default exists.

## Why This Works
The app no longer assumes a developer-specific directory while still preserving convenience for local development. Users on other machines are not blocked by an invalid path.

## Files
- `MuesliApp/MuesliApp/AppModel.swift`
