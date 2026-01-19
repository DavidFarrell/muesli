# Todo Item 6 - Meeting folder naming collision-proof

## Goal
Avoid failures when the default meeting title already exists by auto-suffixing new folders.

## What I changed
- `createMeetingFolder(title:)` now checks for existing folders and appends `-01`, `-02`, etc.
- `meta.json` includes `folder_name` so the exact folder is recorded even if the title is reused.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - Folder creation loop now resolves collisions before creating the directory.
  - Meta includes `folder_name`.

## Notes for reviewer
- Meeting title in UI remains the user input; the folder name may differ if a collision occurs.
