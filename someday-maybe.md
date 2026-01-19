# Someday / Maybe

Low-priority polish items captured during code review. Not blocking, but worth revisiting when time allows.

---

## From Todo Item 1 (Graceful Stop)

### Redundant stdin close
`cleanup()` calls `stdinPipe.fileHandleForWriting.closeFile()` but `closeStdinAfterDraining()` already closed it. Harmless (closing twice is safe) but could be cleaned up for clarity.

### Polling vs termination handler
`waitForExit` polls every 200ms. Could use `process.terminationHandler` with a continuation for a cleaner async pattern. Current approach works fine and is simple to understand.

---

## From Todo Item 2 (Crash-safe Persistence)

### No explicit flush after write
`transcriptEventsHandle?.write(data)` relies on OS buffering. For maximum crash safety, could call `synchronizeFile()` periodically (e.g., every N writes or every few seconds). In practice the OS flushes frequently so likely fine.

### Silent write failures for event log
The write to `transcript_events.jsonl` silently fails if there's an issue. Could add error logging similar to the finalized transcript file writes.

### Meter events bloat
With `--emit-meters`, high-frequency meter events all end up in `transcript_events.jsonl`. Options:
- Filter to only persist `segment`, `partial`, `speakers` events
- Accept the bloat (useful for debugging)

Current behaviour is fine for debugging. If file size becomes an issue, add filtering.

---

## From Todo Item 3 (Temp Transcript Artifacts)

### Temp folder cleanup
Temp folders (`Muesli-<title>-<uuid>`) accumulate in the system temp directory. Could explicitly clean up old Muesli temp folders on app launch or next meeting start. Low priority since OS cleans temp on reboot anyway.

---

## From Todo Item 5 (Reset Transcript State)

### Cross-meeting speaker identification
Currently `keepSpeakerNames: false` because diarisation assigns arbitrary IDs (SPEAKER_00, SPEAKER_01) per meeting - they don't map to the same people across recordings. Keeping names would show wrong names when IDs coincidentally match.

Future options to revisit:
- **Voice fingerprinting** - Store voice embeddings and match speakers across meetings
- **User-assisted matching** - "Is this the same David from last meeting?" prompt
- **Meeting context** - Use calendar/title to suggest likely participants

For now, clean slate is safest. Revisit if users find re-naming tedious in recurring meetings.

---

## Segment Deduplication

### Magic numbers in overlap detection
`insertSegment()` uses several hardcoded thresholds:
- `epsilon = 0.05` - timing tolerance for "covers" checks
- `closeStart` threshold `0.12` - how close two segment starts must be to be considered duplicates
- `overlapRatio >= 0.8` - minimum overlap ratio to trigger replacement
- `existingDuration > newDuration + 0.1` - margin for "existing is longer" check

These seem reasonable but are somewhat arbitrary. If edge cases appear (valid segments being dropped, or duplicates slipping through), these may need tuning.

### Sorting on every insert
`segments.sort { $0.t0 < $1.t0 }` runs on every segment insert. For long meetings with many segments this could get slow. Could optimize with binary insert to maintain sorted order. Probably fine for typical meeting lengths (<2 hours).

---

## General

### UI toast for errors
Engineer suggested adding a published error state for visible UI notifications (toast/banner) when things like transcript saves fail. Currently errors only go to the debug panel.
