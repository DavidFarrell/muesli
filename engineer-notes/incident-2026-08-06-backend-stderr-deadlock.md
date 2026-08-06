# Incident: UI storm now deadlocks the BACKEND via its unread stderr pipe (2026-08-06)

> # 🔴 SUPERSEDED - THE TITLE AND CENTRAL DIAGNOSIS OF THIS NOTE ARE WRONG
>
> **Read `design/2026-08-06 - capture-lifecycle-exploration.md` instead.** Written
> 2026-08-06 from the same evidence folder.
>
> **There was no stderr pipe deadlock.** The backend sample shows the child idle and
> healthy: **3 samples out of 3,419 in `write()`** (a flush caught in flight, not a block),
> the "contended" threads are workers waiting on an **empty** `SimpleQueue`, and the
> buffered-writer-lock frame (`_enter_buffered_busy`) appears nowhere. The stderr drain was
> never MainActor-dependent either - it is a `FileHandle.readabilityHandler` serviced on
> `com.apple.NSFileHandle.fd_monitoring`.
>
> Specifically wrong below, and NOT to be built:
> - the title, and the whole of "### 2. NEW: the unread stderr pipe deadlocks the backend's
>   capture threads";
> - recommended fixes **#1** and **#2** - #2 describes something `BackendProcess` already does;
> - "#7 storm tripwire earned its keep" - the tripwire reports through MainActor, so its
>   lines prove MainActor was ALIVE, and a wedge drives its metric to zero. It measures the
>   opposite of the failure it is named for;
> - the evidence table's "paired with `MuesliApp` fd 13 and fd 20" - not present in the
>   preserved `lsof-backend-pipes.txt`, unverifiable.
>
> Still correct and still useful: the raw measurements, the data-loss section (both
> corrections in it), and the observation that system audio died first at ~54 s. That last
> point is now the **primary open fault**, because this note's mechanism was the thing that
> was supposed to explain it.
>
> Kept rather than deleted because the measurements are the record and the wrong turning is
> worth being able to retrace.

**Status: diagnosed live, from a wedged process, with the app still running.** This is
the first time this failure has been caught in vivo rather than reconstructed from a
post-mortem folder. Samples of both processes are in
`incident-2026-08-06-evidence/`.

**Relationship to prior work: this is a RECURRENCE of
[`incident-2026-07-06-mainthread-livelock.md`](incident-2026-07-06-mainthread-livelock.md)
with the same user-visible symptom and a DIFFERENT proximate mechanism.** The 6 Jul
resolution moved the Swift half of mic forwarding off the MainActor. That fix holds -
and the failure has relocated into the Python backend. See "Why the 6 Jul fix did not
prevent this" below.

## What the user saw

Meeting `2026_08_06 - Meeting 2 -` (started ~14:22 BST, Bose QC35 II as both input
and output, i.e. Bluetooth HFP). The app beachballed; by the time the user asked for
diagnosis it would not even come to the front when clicked, so the meeting could not
be stopped from the UI and had to be killed. The meeting itself had already finished.

## Evidence (collected live, 14:23-14:30)

| Artifact | Fact |
|---|---|
| `MuesliApp` (pid 39594) | Pinned at ~100% CPU, `STAT=R`. Main thread 100% inside SwiftUI layout |
| App main-thread stack | `__CFRunLoopDoObservers` → `NSHostingView.beginTransaction` → `GraphHost.flushTransactions` → `AG::Subgraph::update` → recursive `StackLayout`/`_FlexFrameLayout`/`_PaddingLayout` `sizeThatFits`. **3,329 `sizeThatFits` frames, ~200 levels deep** |
| `backend.log` | Frozen at **14:23:52**. Last lines are `ui.storm turns_per_sec=63.8 … 97.4`, `transcript_rows=9`, `meter_publishes_per_sec=2.8-5.8` |
| `audio/mic.pcm` | Frozen at **14:23:53**, 2,420,188 bytes = **75.6s** at 16 kHz mono |
| `transcript_events.jsonl` | Frozen at **t=75.379979s**; 4,117 lines |
| `audio/system.pcm` | **Still growing** at 14:27:03, long after the freeze |
| `recording.mp4` + `screenshots/` | Still growing; mp4 had **no `moov` atom** (in-progress) |
| Backend (pid 53049, PPID 39594) | `STAT=S`, 0.3% CPU. **Threads blocked in `write` → `_Py_write_impl` → `_io_FileIO_write` → `_bufferedwriter_flush_unlocked`**; three further threads parked in `PyThread_acquire_lock_timed` for 3,219/3,419 and 3,417/3,419 samples |
| `lsof` | Backend **fd 2** = `PIPE 0xdcca69cdea17b901`, **buffer size 16,384 bytes**, paired with `MuesliApp` fd 13 and fd 20 |

## Diagnosis

Two coupled failures, and the second one is new.

### 1. The main-thread storm (same as 6 Jul, cause still unidentified)

The runloop-observer commit path never goes quiet: every runloop turn flushes a fresh
view-graph transaction, at 60-100 turns/sec by the app's own `ui.storm` counter. This
is the identical signature to 6 Jul and the loop-closer is **still not identified**.

🔴 **Ruled OUT this time - the transcript list is not the driver.** `ui.storm` reported
`transcript_rows=9`, and `transcript_events.jsonl` contains only **10 `segment` events
in the whole meeting**. A nine-row list cannot need a 200-deep layout recursion at 97
flushes/sec. Any theory that scales the storm with transcript length is wrong. (An
earlier reading of this incident blamed the growing list on the strength of
`TranscriptSegment` appearing in the stack - it appears in **3 samples out of 3,727**,
which is noise, not the hot path.)

**Worth recording as a narrowing fact:** the event stream is **4,063 `meter` events out
of 4,117 (98.7%)**, arriving at 50 Hz (`t` steps of 0.02). The backend is launched with
`--emit-meters`. Meter *publishing* into SwiftUI is gated post-6-Jul
(`meter_publishes_per_sec` was only 2.8-5.8), so the gate is working - but the 50 Hz
event flow still has to be parsed and relayed per event.

### 2. NEW: the unread stderr pipe deadlocks the backend's capture threads

This is the part that is genuinely different from 6 Jul, and it is why mic capture
still dies despite fix #1 of that incident.

1. The main thread saturates, so **the app stops draining the backend's stderr pipe**.
2. The pipe holds **16 KB**. `backend.log` is chatty on that pipe - an `[audio]
   heartbeat` line every few hundred ms plus an `AUDIO DROP` line per mic drop - so 16
   KB fills in seconds.
3. The backend's next `write()` to fd 2 **blocks in the kernel**, and it blocks *while
   holding Python's buffered-writer lock*.
4. **Every other backend thread that logs then blocks behind that lock** - which is
   exactly what the sample shows: three threads parked in
   `PyThread_acquire_lock_timed` for >94% of samples.
5. The mic path is the **chattiest logger in the backend** - every `AUDIO DROP` line is
   `stream=mic` - so the mic thread is the one that wedges first and hardest. Mic
   capture is therefore **coupled to diagnostic logging**, which is the actual defect.
6. System audio, video and screenshots survive because they log rarely (`stream=system`
   only every 15s) and write to different file objects, so they never contend for the
   blocked lock. **This is why the folder looks half-alive - same outward shape as 6
   Jul, different plumbing underneath.**

**Confidence:** steps 1-4 are directly observed (blocked `write`, held lock, 16 KB pipe,
matching fds, sub-second correlation between `backend.log` and `mic.pcm` freezing).
Step 5's *ordering* claim - that mic wedges first *because* it logs most - is inference
from the log-volume asymmetry, not proof. Confirming it needs a look at which backend
thread owns the mic writer and whether it shares the stderr handle.

## Why the 6 Jul fix did not prevent this

The 6 Jul resolution was explicitly **Swift-only** ("the Python backend was not
touched"). It fixed:

- #1 mic forwarding off MainActor → **held.** The Swift side is no longer the choke.
- #5 `backendLogTail` no longer published; `BackendLogWriter` owns file I/O off-main →
  **partially held.** The *writing* moved off-main, but nothing moved the **reading of
  the backend's stdout/stderr pipe** off the starved thread. That drain is the surviving
  MainActor dependency, and it is now sufficient on its own to kill capture.
- #7 storm tripwire → ✅ **earned its keep.** `ui.storm` is the line that turned this
  from "the app froze" into a measured storm with a rate, a screen, and a row count. It
  is the reason `transcript_rows=9` could rule out the list theory. Keep it.

The lesson: fix #1 moved the *Swift* mic path off the starved thread, but the mic data
still has to reach the backend and the backend still has to be able to log. Starvation
propagated across the process boundary through the one channel nobody hardened.

## Recommended fixes

0. **FIRST, before any code: re-test with the built-in mic and speakers.** System audio
   died at ~54s with retry-shaped blips, which no main-thread or pipe theory explains.
   If Bluetooth HFP is the originating fault, fixing the pipe deadlock would leave the
   real bug in place and the next meeting would still be lost. Cheap test, changes what
   is worth building.
1. **Make backend diagnostics non-blocking, and decouple capture from logging.** The
   backend must never lose audio because a log line cannot be written. Options: write
   diagnostics to a file directly rather than stderr; use a bounded queue with
   drop-on-full and a dropped-line counter; or set the pipe non-blocking and tolerate
   `EAGAIN`. **This is the highest-value fix - it makes capture survive any UI
   pathology, present or future, without needing to find the storm.**
2. **Drain the backend's stdout/stderr off the MainActor**, on a dedicated queue, so a
   wedged UI cannot fill the pipe. This is the direct completion of 6 Jul's fix #5.
3. **Make the starvation watchdog act, not just log.** 6 Jul added
   `mainactor.starved` logging. It fired into a pipe nobody was reading - so the
   tripwire was silenced by the very condition it exists to report. The watchdog needs
   a path to disk that does not traverse the blocked channel, and ideally should
   auto-stop-and-finalise the meeting rather than let it bleed.
4. **Reduce the 50 Hz meter flow on the event channel.** Even correctly gated for
   publishing, 4,063 of 4,117 events being meters means the relay does ~50 parses/sec
   of work whose only consumer is a throttled meter view. Consider a separate channel
   or a lower emit rate.
5. **Still to do from 6 Jul: find the loop-closer.** Now better constrained - it is
   NOT transcript row count, and meter publishing is already gated. Next candidates
   worth instrumenting are anything reading geometry during layout.

## Possible contributing factor: Bluetooth HFP mic

Input **and** output were both `Bose QC35 II`, which forces HFP mono. The mic path was
already degrading before the freeze: `cumulative_frames_dropped=72`,
`cumulative_bytes_dropped=35904` by t≈73s, with `AUDIO DROP stream=mic` roughly every
5s throughout. Those drops are what makes the mic thread the chattiest logger, so the
flaky transport plausibly *accelerates* the deadlock. Worth testing whether the
built-in mic delays or avoids it. Machine was also loaded (`PerfPowerServices` 150%,
WindowServer 50%, a Steam game at 33%, plus a Parallels VM).

## Data loss and recovery for this meeting

🔴 **This is a near-total audio loss, and worse than the 6 Jul incident. Two earlier
readings in this investigation were wrong and are corrected here.**

**Correction 1 - "both streams carried real audio, system fully captured" was WRONG.**
That was computed from the `meter` events in `transcript_events.jsonl`, which only span
**t=0-75.4s** because the event stream itself froze. Measuring the meter events told us
about the first 75 seconds and was silently mistaken for the whole meeting - a
comparison answering a different question than the one asked.

**Correction 2 - the graceful SIGTERM exit finalising the mp4 was a smaller win than it
looked.** The mp4 is valid and full-length, but its audio is worthless (below).

Measured directly from the finalised WAVs and the mp4:

| Artifact | Length | Actual audio content |
|---|---|---|
| `audio/mic.wav` | **75.6s** | Healthy throughout (per-5s rms 0.03-0.10). Ends at 75.63s |
| `audio/system.wav` | 641.8s | **91.9% digital zero.** Nine zero-runs ≥0.25s totalling **575.8s (89.7%)** |
| `recording.mp4` | **641.9s**, h264 + AAC 48k stereo | Audio is **bit-identical to `system.wav`** - `corr = 1.0000` after resampling. **No mic content whatsoever** |
| `screenshots/` | 128 files | ✅ Intact - the only full-length record alongside the video |

**`system.wav`'s real audio is confined to roughly the first 54 seconds**, plus a handful
of ~1s blips and one ~7s patch. Zero-runs:

```
  54.1s ->  148.8s   ( 94.67s)      354.5s ->  523.7s   (169.25s)
 149.9s ->  298.6s   (148.73s)      530.5s ->  578.5s   ( 47.97s)
 299.8s ->  319.4s   ( 19.64s)      580.4s ->  641.8s   ( 61.48s)
 320.5s ->  353.3s   ( 32.79s)
```

**Net: of a 10m42s meeting, there is ~75s of the user's voice and ~54s of the other
party. Everything after ~75s exists only as silent video.** The
`reprocess`/`muesli-merge` recovery path that rescued the 6 Jul meeting **will not
rescue this one** - there is no audio for it to work on.

### 🔴 This reorders the diagnosis: system audio died FIRST, at ~54s

Timeline of deaths: **system audio ~54s → mic 75.6s → event stream 75.4s → `backend.log`
75.4s (14:23:52)**. System capture failed **before** the pipe deadlock, and the blips at
148.8s, 298.6s, 319.4s, 353.3s, 523.7s and 578.5s look like a capture engine
**repeatedly retrying and briefly succeeding**.

**That means the stderr-pipe deadlock cannot be the whole story, and possibly is not
even the root cause.** A plausible second fault, stated as a hypothesis and not
established: input **and** output were both `Bose QC35 II`, so the headset was in
Bluetooth HFP with output also on SCO. That is the known-fragile path (see
`audio-device-audit-2026-06-25.md`), it explains the steady `AUDIO DROP stream=mic`
from early on, and it would explain intermittent system-audio dropouts that no
main-thread theory accounts for. **Next step before any fix: re-test on the built-in
mic/speakers to see whether either failure survives removing Bluetooth.**

The pipe deadlock is still real and still worth fixing - it is what froze the log and
the mic file and blinded the watchdog - but it should no longer be assumed to be the
originating fault.
- `meeting.json` will be left at `status: recording`. **6 Jul's fix #6 (launch recovery
  for orphaned meetings) should finalise it on next launch** - worth confirming it does,
  since this is its first real test.
- Recovery path unchanged: `python -m diarise_transcribe.reprocess <dir> --stream both
  --diar-backend senko` on the folder as-is.

## Note on evidence handling

`transcript_events.jsonl` is **deliberately not copied into this repo** - 16 of its
events carry speech content, and this repo is on GitHub. `backend.log` was checked and
contains no speech text (the single `text=` grep hit is `context=meeting`), so it is
safe to include.
