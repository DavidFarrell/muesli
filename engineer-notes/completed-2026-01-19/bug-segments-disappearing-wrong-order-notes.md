# Bug Fix Notes - Segments disappearing / wrong order (revision 2)

## Summary
Adjusted partial handling to be stream-aware and simplified sorting to avoid partials jumping to the end.

## Changes
- Partial replacement now matches by stream: only replaces the last partial for the same stream.
- Sorting now uses `t0` only, so partials sit in natural time order.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `ingest(jsonLine:)` partial replacement includes `stream` filter.
  - `sortedSegments(_:)` now sorts by `t0` only.

## Why this helps
- Avoids mic partial overwriting system partials.
- Prevents partials from jumping between bottom/top when finalized.

## How to verify
1) Emit concurrent system+mic partials; they should update independently.
2) Partial -> segment should not jump far in the list.
