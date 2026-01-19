# Todo Item 8 - Window capture audio scope warning

## Goal
Warn users that window capture may limit audio to the selected app, and advise Display mode for full system audio.

## What I changed
- Added a footnote warning under the Source type picker when `sourceKind == .window`.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - New UI warning text in `NewMeetingView`.

## Notes for reviewer
- This is a UI-only mitigation; no capture behavior changed.
