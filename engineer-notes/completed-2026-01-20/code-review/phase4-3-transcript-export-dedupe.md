# Phase 4.3 - Deduplicate Transcript Export Logic

## Problem
Transcript JSONL encoding and file-writing logic was duplicated across `saveTranscriptFiles`, `exportTranscriptFiles`, and `writeTranscriptFiles`. This increased the risk of drift between persistence paths and required parallel updates for any change.

## Fix
- Centralized JSONL construction in `buildTranscriptJSONL`.
- Added `writeTranscriptData` helper to standardize encoding and write error handling.
- Updated all call sites to use the shared helpers.

## Implementation Details
- `saveTranscriptFiles` uses the shared JSONL builder and writer, and reuses the same data for the temporary export folder.
- Both export flows use `buildTranscriptJSONL` and `writeTranscriptData` for JSONL and text outputs.
- `writeTranscriptFiles` now uses the same helpers instead of silently ignoring write failures.

## Why This Works
A single JSONL builder eliminates drift between save and export paths. The shared writer ensures consistent error logging for disk failures.

## Files
- `MuesliApp/MuesliApp/AppModel.swift`
