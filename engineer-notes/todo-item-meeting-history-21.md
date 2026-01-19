# Meeting History Fixes - Review Items 17-20

## Summary
- Blocked deletion of the active recording session.
- Fixed resume timestamp offset being reset during start.
- Ensured duration uses existing metadata max.

## Changes
- `deleteMeeting` now guards against deleting the currently recording meeting.
- Resume now passes `timestampOffset` into `startMeeting` and applies it after reset.
- Finalization now takes max of existing duration, last timestamp, and elapsed time.

## Files
- Updated: `MuesliApp/MuesliApp/AppModel.swift`
