# Meeting History Todo Item 9 - Persist Stream Formats

## Summary
- Session stream formats are now stored in `meeting.json` once real sample rates/channels are detected.

## Changes
- After capture format detection, update the latest session `streams` entry with system/mic sample rate and channel count.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
- Updated: `todo-meeting-history.md`
