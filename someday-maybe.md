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

## General

### UI toast for errors
Engineer suggested adding a published error state for visible UI notifications (toast/banner) when things like transcript saves fail. Currently errors only go to the debug panel.
