# Phase 2.1 - Meeting Title Sanitization

## Problem
Meeting folder names were derived directly from user-provided text. A title like `../../Library` or `Reports/2024` could influence the final filesystem path, creating a path traversal risk and potentially writing meeting assets outside the intended `Application Support/Muesli/Meetings` directory.

## Fix
- Added a dedicated normalizer for meeting titles that is applied before folder creation.
- Allowed only ASCII letters, digits, spaces, hyphen, and underscore.
- Trimmed leading/trailing whitespace, collapsed internal multiple spaces into single spaces.
- If the sanitized title becomes empty, fall back to the default `yyyy-MM-dd-meeting` title.

## Implementation Details
- `normaliseMeetingTitle(_:)` performs the filtering and normalization.
- `startMeeting()` now calls `normaliseMeetingTitle` before passing the title into `createMeetingFolder`.
- The rename flow remains untouched because it only updates metadata; it does not rename folders on disk.

## Why This Works
By removing all path separators and `..` tokens, the resulting folder name cannot escape the base directory. The fallback ensures we never create empty or invalid folder names, preventing filesystem errors on meeting start.

## Files
- `MuesliApp/MuesliApp/AppModel.swift`
