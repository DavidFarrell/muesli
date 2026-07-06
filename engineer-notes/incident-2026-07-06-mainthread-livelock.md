# Incident: main-thread livelock kills mic capture mid-meeting (2026-07-06)

**Status: diagnosed and fixed** on the `livelock-fix` branch - see Resolution below. Originally written up from post-mortem evidence (no live repro at the time).

## What the user saw

A 68-minute real meeting (08:14-09:23 BST, Bose QC35 II as follow-default input,
current build - compiled 08:14 that morning, includes everything through 88fd920).
At ~14.5 minutes in, the app effectively froze; the user force-quit at 09:23 (no
crash report - SIGKILL, not an exception). The meeting was never finalized:
meeting.json stuck at `status: recording, duration_seconds: 0`.

## Post-mortem evidence

| Artifact | Fact |
|---|---|
| `audio/mic.wav` | stops at 873s (08:29:31) - mic feed dead from there |
| `audio/system.wav` | full 4102s, kept growing until 09:23 |
| `backend.log` | last line ~08:29:31, then silence; NO error/stall/recovery event |
| `transcript_events.jsonl` | mtime 08:29 - live transcript relay also died |
| `recording.mp4` + `screenshots/` | kept writing until 09:23 |
| `/Library/Logs/DiagnosticReports/MuesliApp_2026-07-06-083121...cpu_resource.diag` | **100% CPU for 90s+ starting 08:29:50**, main thread |
| `...python3.12_2026-07-06-090628...diag` | backend healthy the whole time (disk-writes report: 2.1GB over 3097s, i.e. the system audio) |
| `...MuesliApp_2026-07-05-174446...cpu_resource.diag` | SAME event fired the previous evening (53% avg over 169s) right after the 2-min acceptance test, on the PREVIOUS build - so this predates the 5 Jul rename/polish UI changes |

## Diagnosis

The main thread entered a **sustained SwiftUI render/layout storm** at 08:29:50. The
heaviest sampled stack is entirely inside the runloop-observer commit path:

```
__CFRunLoopDoObservers → NSHostingView.beginTransaction → GraphHost.flushTransactions
→ AG::Subgraph::update → StackLayout/_FlexFrameLayout/_PaddingLayout sizeThatFits (recursive)
```

i.e. every runloop turn flushes a fresh view-graph transaction - the graph never goes
quiet. No app symbols appear in the hot samples (typical for AttributeGraph storms).

**Blast radius follows directly from MainActor starvation:**

- Mic buffers reach the backend ONLY via `Task { @MainActor handleMicAudio }` →
  `writer?.send(...)` (AppModel.swift ~692-727). MainActor starved ⇒ mic.wav freezes.
  The frames watchdog, recovery ladder, and heartbeat are all MainActor too ⇒ the
  recovery machinery that should notice a dead mic is starved by the same storm it
  would need to detect. **The watchdog cannot see a wedged main thread.**
- `backend.log` writing and backend-stdout relaying are MainActor ⇒ both freeze; the
  backend keeps transcribing into a dead pipe (review finding B6 - emit errors are
  swallowed backend-side).
- ScreenCaptureKit video/screenshot/system-audio callbacks run on their own queues ⇒
  those all continue, which is why the folder looks half-alive.
- Quit-without-stop leaves meeting.json at `recording` forever ⇒ Resume and in-app
  rediarize are disabled for a folder that actually holds complete, healthy audio.
  (Phase 3b's rollback covers failed STARTS, not mid-meeting death.)

## Contributing factor found (real bug, probably not sufficient alone)

`AppModel.backendLogTail` (`@Published`, AppModel.swift:156) is appended on EVERY
AudioLog event via the sink (heartbeats every ~2s, engine events, live status lines,
plus `removeFirst` array-shifting at the cap) - an AppModel-wide invalidation drumbeat.
**Correction from an earlier draft of this note:** it is not a pure zombie -
`debugSummary` (the "Copy debug" button's source) reads it - but it is never
LIVE-RENDERED anywhere, so every one of those `@Published` invalidations exists
purely to keep a value fresh for a manual, rare button press. Cheap fix: stop
publishing it (keep the file write for copy-debug to read on demand), or gate the
tail behind an explicit debug flag.

The actual loop-closer (what turns the drumbeat into a saturated graph that re-flushes
every runloop turn) is NOT yet identified - candidates examined and not convicted:
transcript pane (LazyVStack, stable IDs, scrollTo only on count change), LevelMeter
(cheap, GeometryReader read-only), AudioMetersModel (properly throttled). Both
episodes shared: meters visible, AppModel-observing screens, growing meeting state.
Yesterday's episode was POST-meeting on the previous build; today's was mid-meeting -
so it is not specific to one screen or to the 5 Jul UI changes.

## Recommended fix directions (for the next work slice)

1. **Get mic forwarding off the MainActor** (robustness, independent of the storm's
   cause): the path from engine callback → backend stdin should not require a live UI
   thread. Same for the frames watchdog, or add an off-main watchdog that detects
   MainActor starvation itself (e.g. a background queue pinging a MainActor task and
   alarming/logging when the echo stops).
2. **Delete/gate the zombie backendLogTail publishing**; move backend.log file writes
   off the MainActor entirely.
3. **Crash/hang recovery for meeting.json**: on launch, a meeting left at
   `status: recording` with no live session should be finalized (flip to completed,
   compute duration from the wavs) so its audio remains usable in-app.
4. **Find the loop-closer with instrumentation**: add a signpost/log when
   NSHostingView transactions exceed N per second, or reproduce under Instruments
   (SwiftUI template) during a long meeting. Do this BEFORE attempting a blind fix of
   the storm itself.

## Recovery note for THIS meeting

The audio is fine (mic 873s + system 4102s). The CLI reprocess
(`python -m diarise_transcribe.reprocess <dir> --stream both --diar-backend senko`)
worked on the folder as-is; the transcript was recovered via the CLI reprocess.
Only the user's mic contributions after 08:29 are unrecoverable (never captured).

## Resolution

Shipped on the `livelock-fix` branch (Swift-only slice; the Python backend was not
touched):

1. **Mic forwarding off MainActor.** `MicAudioForwarder` (actor) now owns the
   `FramedWriter` reference, pending-audio buffer, frame count, last-frame
   timestamp, and first-frame flag. Both mic engines' callbacks deliver directly
   to it; only a throttled subset of deliveries (gated the same way as the meter
   fix below, with the very first frame of a generation always exempt so the
   recovery ladder resets promptly) hops to MainActor afterwards for metering/
   bookkeeping.
2. **Off-main starvation watchdog.** A background timer pings MainActor via a
   race-with-timeout and logs `mainactor.starved` / `mainactor.recovered`,
   rate-limited, including the mic forwarder's ground-truth liveness at the
   moment of the stall - this is the tripwire that would have made this incident
   diagnosable in one look.
3. **`TitlebarInsetReader` removed.** Replaced with a constant top padding of 28;
   the layout-feedback-loop shape (window geometry read in `updateNSView`, then
   written back into SwiftUI `@State`) no longer exists.
4. **Meter publishing fixed.** `AudioMetersModel` collapsed into one `@Published`
   snapshot struct per stream, gated by a shared, unit-tested
   `MeterPublishGate` (quantize + dedupe + stop republishing once at rest at
   zero). `CaptureEngine`'s system-audio callback and the mic forwarder both
   pre-gate before ever dispatching to MainActor. The home-level preview no
   longer starts while `isFinalizing`, and restarts automatically once
   finalizing completes if the user is still on the start screen.
5. **`backendLogTail` stopped publishing.** A new `BackendLogWriter` owns the
   ring buffer (plain, non-`@Published`) and all backend.log file I/O on its own
   queue; `AudioLog.sink` calls it directly with no MainActor hop at all.
6. **Launch recovery for orphaned meetings.** Any `meeting.json` left at
   `status: recording` is finalized on next launch - duration recovered from the
   wavs (`AVAudioFile`), falling back to newest-artifact-mtime if unreadable.
7. **Storm tripwire instrumentation.** A `CFRunLoopObserver`-based counter (no
   state writes in the hot path) logs `ui.storm` with turns/sec, active screen,
   transcript row count, meter-publish rate, and history count whenever the
   main run loop is turning over faster than a threshold.
