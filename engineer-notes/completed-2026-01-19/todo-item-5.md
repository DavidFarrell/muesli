# Todo Item 5 - Reset transcript state on meeting start

## Goal
Clear transcript segments when a new meeting starts, while optionally keeping speaker name mappings.

## What I changed
- Added `resetForNewMeeting(keepSpeakerNames:)` to `TranscriptModel`.
- Call this at the start of `startMeeting()` after creating the session.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `TranscriptModel.resetForNewMeeting(keepSpeakerNames: Bool)` clears segments and debug state.
- `AppModel.startMeeting()` calls reset with `keepSpeakerNames: false` to avoid misleading carryover names.

## Notes for reviewer
- We now reset speaker names each meeting to avoid mislabeling different calls.
