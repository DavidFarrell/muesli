# Todo Item 7 - Revisions Required

## Background

The current implementation has three issues identified during code review.

## Issue 1: Inconsistent TXT format between auto-save and export

**Current behavior:**

`saveTranscriptFiles` (called on meeting stop) produces:
```
system:SPEAKER_00 [system] 0.00-5.23 Hello world
```

`asPlainText` (used by copy/export) produces:
```
[system] t=0.00s David: Hello world
```

**Problem:** These should be consistent. The human-readable format (with display names) is preferred for both.

**Fix:** Update `saveTranscriptFiles` to use `transcriptModel.asPlainText()` for the TXT output instead of building its own format string. The JSONL can stay as-is (raw IDs are fine for machine-readable format).

---

## Issue 2: No visual feedback for "Copy transcript"

**Current behavior:** User clicks button, text goes to clipboard, nothing visible happens.

**Problem:** User doesn't know if it worked.

**Fix:** Add brief visual feedback. Options:
- Change button text to "Copied!" for 1-2 seconds, then revert
- Show a small toast/banner
- Disable button briefly with checkmark

Simplest approach is probably the button text change.

---

## Issue 3: "Export transcript" doesn't do what users expect

**Current behavior:** Writes files to the meeting folder (`~/Library/Application Support/Muesli/Meetings/<title>/`).

**Problem:** This is redundant - `saveTranscriptFiles` already writes to the same location automatically on meeting stop. Users expect "Export" to let them save to a custom location (Desktop, Downloads, share with someone).

**Fix:** Change "Export transcript" to:
1. Open an `NSSavePanel`
2. Let user choose destination and filename
3. Default filename could be `<meeting-title>-transcript.txt` (or offer both .txt and .jsonl)

This matches standard macOS "Export" behavior.

---

## Summary of Changes

| Component | Current | Change To |
|-----------|---------|-----------|
| `saveTranscriptFiles` TXT output | Raw speakerID, custom format | Use `asPlainText()` for human-readable format |
| "Copy transcript" button | No feedback | Show "Copied!" briefly or similar |
| "Export transcript" button | Writes to meeting folder (redundant) | Open Save panel for user-chosen destination |

---

## Notes

- The JSONL format can stay as-is (raw IDs are fine for machine-readable data)
- Auto-save on meeting stop still happens - that's the primary persistence mechanism
- "Export" is for when user wants to save somewhere specific (share, backup, etc.)
- `transcript_events.jsonl` (crash-safe streaming) is unaffected by these changes
