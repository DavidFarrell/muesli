# Meeting History Todo Item 18 - Resume Session Folder

## Summary
- Added helper to compute the next session ID and create a new `audio-session-N` folder for resume.

## Changes
- New `prepareResumeSession(for:)` reads `meeting.json`, computes next session ID, creates the audio folder, and returns metadata + folder URL.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
