# Exploration: the capture lifecycle failure of 2026-08-06

**Status:** exploration, pre-build. Round 2 of the GPT-5 convergence loop. Written by
re-reading the preserved evidence in `engineer-notes/incident-2026-08-06-evidence/` rather
than by trusting the incident note's narrative.

**Headline: the incident note's mechanism is not supported by its own evidence.** The backend
was not in the alleged persistent stderr-pipe deadlock at diagnosis time. Two of the note's
five recommended fixes are not justified by this incident, and building them first would spend
the budget on a failure this evidence does not show. The corrected picture is below, with the
evidence that decides each point and an explicit confidence label on each.

`engineer-notes/incident-2026-08-06-backend-stderr-deadlock.md` has been headed as superseded
by this file.

**A note on what a `sample` can and cannot prove.** `sample` aggregates identical stacks across
its whole window, so a single narrow spine in the output does **not** distinguish one long
invocation from many repeated identical ones. Several claims below turn on that distinction and
are labelled accordingly. Where a stronger conclusion is reached, it is reached from a second
source, not from the shape of the tree.

---

## 1. What the evidence actually shows

### F1. The backend was not deadlocked at diagnosis time (retires the note's central claim)

The note claims the backend's capture threads were deadlocked on a full 16 KB stderr pipe,
blocked in `write()` while holding Python's buffered-writer lock, for the nine and a half
minutes after 14:23:52. The backend sample contradicts that state. From
`backend-sample-53049.txt` (1 ms sampling, 3,419 samples ≈ 3.4 s, taken 14:25:25):

1. **No thread is resident in `write()`.** A thread blocked on a full pipe for the sample
   window would appear in `write` in ~3,419 of 3,419 samples. The actual counts are **3
   samples** on `Thread_187537766` (`_io_TextIOWrapper_flush` ->
   `_bufferedwriter_flush_unlocked` -> `write`) and **2** on the main thread. Short residence
   in `write` is incompatible with a continuously blocked writer. It does not by itself prove
   the writes succeeded, and the stacks do not identify which file descriptor was being written.
2. **The threads the note read as buffered-writer contention are not that.**
   `Thread_187537766` spends 3,414/3,419 samples in `_queue_SimpleQueue_get_impl` ->
   `PyThread_acquire_lock_timed`, which is consistent with a worker awaiting queue work.
   `Thread_187537768` spends 3,417/3,419 in `lock_PyThread_acquire_lock` reached from
   `_PyEval_EvalFrameDefault`, i.e. Python-level code calling `_thread.lock.acquire` - **an
   unidentified Python-level lock waiter, not CPython's internal buffered-I/O lock.** (The
   internal lock is entered from whichever `_io` operation is running - `write`, `flush`, or a
   seek - and an optimised build may inline the helper, so its absence from the symbolised
   stack is weaker evidence than a specific frame name would be. What is solid is that Thread
   B's path is a Python-visible lock object, which the buffer lock is not.)
3. **`ps` agrees the child was not working:** `STAT=S`, 0.3% CPU, against the parent's
   `STAT=R`, 100.4%.

**Correction to my own first argument, which ran backwards.** I initially argued that because
MainActor never recovered between 14:23:52 and the sample, a pipe block could not have resolved
in between. That is exactly wrong. The stderr drain is a
`FileHandle.readabilityHandler` (`BackendProcess.swift:65-82`) which Foundation services on
its own queue - visible in the parent's sample as
`DispatchQueue: com.apple.NSFileHandle.fd_monitoring` - and the handler body only appends to a
`Data` buffer and splits on newlines. So the drain **could** have kept running and relieved
transient pipe pressure while MainActor stayed wedged. That is a reason the pipe was unlikely
to stay full, not a reason an earlier block could not have cleared.

**What is therefore established, and what is not.** Established: no persistent stderr deadlock
at 14:25:25, and the drain has never been MainActor-dependent. Not established: that no
transient backpressure ever occurred. But a transient block by definition clears, and mic
capture never resumed for the remaining nine and a half minutes, so a transient cannot be the
mechanism of the outage either way.

Consequence: **the note's recommended fixes #1 (non-blocking backend diagnostics) and #2 (drain
stdout/stderr off the MainActor) come out of the plan.** #2 describes something
`BackendProcess` already does. #1 is a reasonable robustness idea in the abstract but is **not
justified by this incident's evidence**, which is a different statement from "protects against
a failure proven never to have occurred".

Also unverifiable: the note's evidence table says the stderr pipe was "paired with `MuesliApp`
fd 13 and fd 20". The preserved `lsof-backend-pipes.txt` contains only the backend's own three
fds and no peer information. That claim cannot be checked.

### F2. The real fault: sustained deep SwiftUI layout computation on the main thread

From `app-sample-39594.txt` (1 ms sampling, 3,727 samples ≈ 3.7 s, taken 14:25:25), the
main-thread call tree is a single narrow spine with counts decrementing by one or two per level:

```
3727  main -> NSApplication.run -> ... -> __CFRunLoopDoObservers
3715  NSRunLoop.flushObservers -> NSHostingView.beginTransaction -> Update.ensure
3713  GraphHost.flushTransactions
3606  GraphHost.runTransaction
3545  AG::Subgraph::update
3440  AG::Graph::UpdateStack::update
2562  RootGeometry.value.getter -> LayoutEngineBox.sizeThatFits
2561  _FlexFrameLayout.sizeThatFits -> LayoutProxy.size -> LayoutEngineBox.sizeThatFits
2558  _PaddingLayout.sizeThatFits -> ...
2557  StackLayout.UnmanagedImplementation.sizeChildren... -> ...
2553  (the frame / padding / stack chain repeats, ~200 levels deep)
```

**Established (observed):** for essentially the whole window - 3,715 of 3,727 samples - the
main thread was inside the run-loop observer's view-graph flush, descending a repeating
`_FlexFrameLayout` / `_PaddingLayout` / `StackLayout` chain roughly 200 levels deep. `ps`
shows 100% CPU and `STAT=R`. The main thread was doing nothing but layout.

**NOT established:** that this was one single non-terminating invocation. My earlier claim to
that effect over-read the sample: aggregation means repeated identical passes produce the same
tree, and the 100% CPU reading minutes later cannot establish continuation of the *same*
invocation.

**What does narrow it, from a second source.** If the main thread were completing many fast
passes and turning the run loop between them, MainActor tasks would have been scheduled in the
gaps - and two log producers that hop to MainActor (`ui.storm`, and the `[stderr]` relay) would
have kept writing. Both stopped dead at 14:23:52 and never resumed. So whatever the invocation
count, **the main thread was not yielding usefully to queued MainActor work at any point in
those nine and a half minutes.** For every purpose that matters here, that is equivalent to a
wedge.

**Open mechanisms, none preferred:**
- a true cycle in the layout graph (unbounded recursion);
- a bounded-but-exponential re-evaluation of a genuinely deep tree;
- repeated-pass churn driven by an invalidation source that never settles;
- a long inner loop inside one framework layout call;
- a framework control contributing the depth: the hot path contains
  `??? (in DesignLibrary)` frames, so part of the ~200 levels may not be David's nesting at all.

**Dead already:** the "custom alignment guides" theory. There are zero `alignmentGuide` uses in
the codebase. `explicitAlignment` dominating the aggregate symbol totals is expected for
implicit stack alignment, and recursive frame counting inflates whatever repeats.

**Not a lead:** `RootGeometry` is a framework root-layout symbol and is **not** evidence
pointing at the source-level `GeometryReader` in `SessionView.swift:329`. Treat that
`GeometryReader` as one candidate among several, not the obvious first suspect.

### F3. The starvation watchdog cannot report while MainActor stays wedged

`MainActorStarvationWatchdog` was started (`AppModel.swift:390`), yet backend.log contains
**zero** `mainactor.starved` lines across the whole meeting. The structural reason is in
`MainActorStarvationWatchdog.swift:86-97`:

```swift
private static func echoMainActor(timeoutSeconds: Double) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor in true }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
```

`withTaskGroup` cannot return until **every** child has completed. `cancelAll()` marks the
`{ @MainActor in true }` child cancelled but does not discard it, Swift cancellation is
cooperative, and that body has no suspension point at which to observe it. So while MainActor
is wedged, `group.next()` yields `false` from the sleeper and the group then waits for a child
that cannot run. `echoMainActor` does not return, `tick()`'s completion does not run, and
`pingInFlight` stays `true`, suppressing every subsequent tick.

**Two precise consequences**, replacing the stronger claim I made first ("can never fire"):
- the watchdog **cannot report during** a wedge, which is the entire condition it exists to
  report;
- if MainActor later recovers, the child runs, the group finishes, and the already-selected
  `false` propagates - so it can emit a **stale** `starved` line after the fact.

The type's own doc comment asserts the opposite ("the still-pending echo task is left to
complete whenever MainActor eventually frees up - harmless"). The group is the thing waiting,
so it is not harmless.

**Confidence:** the mechanism is read from source and is high-confidence. The zero log lines
are *consistent* with it but do not independently prove `tick()` ever ran.

`MicAudioForwarder` is a plain `actor` (`MicAudioForwarder.swift:74`), not MainActor-isolated,
so the `await forwarder.snapshot()` on the same path is not a second block. The fix is contained.

### F4. The storm tripwire cannot detect a stuck main thread

`RunLoopStormTripwire` counts `beforeWaiting` run-loop passes and reports them from inside
`Task { @MainActor in ... }` (`RunLoopStormTripwire.swift:93-111`). Two consequences:

- **Its reporting path requires MainActor.** Each `ui.storm` line therefore establishes that
  the app was able to execute MainActor work at that instant. It is not a statement about UI
  health, and it is certainly not a report of a wedge.
- **A wedge drives the metric toward zero**, because the run loop stops turning, so the 30/sec
  threshold is never crossed. The instrument cannot detect the condition it is named for.

What is **not** established: that the 60 to 100 turns/sec it reported were false positives. No
healthy baseline for this app exists, so the threshold's calibration is simply unknown. The one
concretely useful thing it produced was `transcript_rows=9`, which killed the transcript-list
theory. That was worth having.

What is needed instead is a measure of **how long the main thread has been unable to service
queued work**, reported from a queue that does not need MainActor - which is what F3's watchdog
is for, once repaired. See the plan: this does not need a second instrument.

### F5. The stream that failed first is the one with no telemetry

backend.log carries, for the mic: an `[audio] heartbeat` every ~2 s with `micLevel`, `frames`,
`sinceLastFrameMs` and the bound device; plus `AUDIO DROP stream=mic` lines with cumulative byte
and frame accounting. For system audio it carries **nothing** - no level, no heartbeat, no drop
accounting. The only system-stream lines are `[status] live_process_start/done stream=system`,
which report ASR progress, not capture health.

System audio is the stream that failed first and hardest. The app had no way to notice and no
way to tell David. This is the single clearest actionable gap in the whole incident.

### F6. Mic loss is recurring cumulative loss, magnitude known, cadence not

The note reads the drops as one gap every 5.12 s. That conflates the loss with the logging:
`cumulative_frames_dropped` steps 46 -> 51 -> 55 -> 59 -> 64 -> 68 -> 72 between consecutively
logged lines, so roughly four or five drops occur per line logged, and the 5.12 s interval is
the **logging** cadence. Periodic counter snapshots cannot tell us whether the underlying drops
were evenly spaced or bursty.

**Established:** recurring loss throughout the meeting, totalling 72 frames / 35,904 bytes
(≈1.1 s of 16 kHz mono) by t≈73 s. **Not established:** any mechanism. The drift and
ring-wrap hypotheses I first offered were both derived from the 5.12 s figure and are void now
that the figure is known to be the log interval. This is a data-quality question, not the
outage, and is deliberately left open.

### F7. The harm model: everything behind a MainActor hop stopped

| Artefact | Froze at | Why |
|---|---|---|
| `backend.log` | 14:23:52 (t≈75.4 s) | Its three chattiest producers all hop to MainActor: `[stderr]` lines via `onStderrLine` -> `Task { @MainActor }` (`AppModel.swift:2411`), `ui.storm` via F4's MainActor task, `[audio] heartbeat` from a MainActor timer |
| `transcript_events.jsonl` | t=75.379979 s | Written in `handleBackendJSONLine`, called from the `Task { @MainActor }` consuming `backend.stdoutLines` (`AppModel.swift:2425`) |
| `audio/mic.pcm` | t=75.6 s | Open - see below |
| The Stop button, the whole UI | ~t=75 s | MainActor |
| `meeting.json` | never finalised | Left at `status: recording`, `duration_seconds: 0` |

What kept working, and why: `system.pcm` (the backend writes it directly from frames the
`CaptureEngine` queue sends), `recording.mp4`, `screenshots/`. All off-main.

**Ownership, resolved from source, because both documents had it wrong.** The mp4 is written by
**`SCRecordingOutput` inside the app** (`CaptureEngine.swift:205, 282-287`), not by the backend.
The WAVs are the **backend's** (`muesli_backend.py:140` `writer.wav.close()`), produced from the
PCM on its own exit. So the SIGTERM at ~14:30 finalised the mp4 because the *app* exited
cleanly, and produced the WAVs because the *backend* exited cleanly. This matters for the fix
and is dealt with in the plan: the app cannot finalise the WAVs at all, and the backend cannot
finalise the mp4.

Note what this table does **not** prove. `backend.log` and `transcript_events.jsonl` freezing
says nothing about whether the backend was still emitting - only that the app stopped writing
what it received. The incident note's timeline treated those file mtimes as backend liveness
data. They are app liveness data.

**Mic stopping at 75.6 s is still open.** 6 Jul's fix #1 moved mic forwarding off MainActor and
`MicAudioForwarder` is a plain actor, so on the face of it the mic path should have survived as
the system path did. Either some part of it retains a MainActor dependency, or the mic engine
died at the same moment for an unrelated reason. Worth an hour, not on the critical path.

### F8. The primary open fault: system audio becoming digital zero at ~54 s

`system.wav` is 641.8 s long and 91.9% digital zero, with real content confined to roughly the
first 54 s plus brief passages at 148.8, 298.6, 319.4, 353.3, 523.7 and 578.5 s.
`recording.mp4`'s audio track is **perfectly correlated** with it (`corr = 1.0000` after
resampling; this is a correlation result, not a byte-equality test), which indicates both derive
from the same ScreenCaptureKit buffers and that the mp4 contains no mic content.

The important refinement: **the file kept growing.** `system.pcm` was still growing at 14:27:03,
minutes after everything else stopped, and the finished file is full length. So this is not a
stalled capture - zero-valued bytes were being written throughout.

**The open boundary, stated precisely:** somewhere between the ScreenCaptureKit audio callback
and the two persisted tracks, the samples became zero. The evidence does not locate it at the
callback specifically - conversion, timestamp padding, or shared downstream processing are all
still in scope.

This is the earliest failure in the timeline (54 s, versus 75 s for everything else), it
happened while the app was fully healthy, and **F1 has removed the mechanism the note offered
to explain it.** Nothing in the corrected diagnosis accounts for it.

Standing hypothesis, unproven: input and output were both `Bose QC35 II` (in every heartbeat:
`in[id=200 ... 'Bose QC35 II'] out[id=194 ... 'Bose QC35 II']`), which is **consistent with an
HFP route** in both directions - the known-fragile path
(`engineer-notes/audio-device-audit-2026-06-25.md`). Device IDs do not prove the active
transport profile, so this needs the experiment in slice 0, not more reasoning.

---

## 2. Revised timeline

| t | Event | Status |
|---|---|---|
| 0 s | Meeting starts. Bose QC35 II as both in and out. Mic healthy, `micLevel` 0.03-0.15 | Observed |
| 0 s onward | Recurring small mic gaps accumulate (72 frames by t=73 s) | Observed |
| ~54 s | System audio becomes digital zero. Buffers keep arriving, file keeps growing | Observed |
| 54-580 s | Six brief passages of real audio | Observed |
| ~75 s | Main thread enters sustained deep layout computation | **Inferred** - start time from when MainActor-dependent output ceased |
| 75.4 s | Everything behind a MainActor hop stops: log, event file, UI, Stop button | Observed |
| 75.6 s | `mic.pcm` stops | Observed, cause open |
| 75.4 s onward | No `mainactor.starved` line, per F3 | Observed absence; mechanism read from source |
| to 641.9 s | System audio buffers, the mp4 and the screenshots all continue | Observed |
| 14:25:25 | Both processes sampled: app 100% CPU in layout, backend idle | Observed |
| ~14:30 | SIGTERM. App exits cleanly and finalises the mp4; backend exits cleanly and writes the WAVs | Observed |

Net usable audio: of a 10m42s meeting, ~75 s of David's voice, plus roughly the first 54 s of
the other party and the six later passages. `reprocess` **cannot restore the missing intervals**
- there is no audio in them - though it can still be run over the fragments that survive.

---

## 3. What this means for the fix

Three facts shape the plan.

**The primary open fault has no explanation.** F1 removed the note's mechanism, so the system
stream going to zero at 54 s is unexplained by anything in the corrected diagnosis. It is also
the earliest failure and the one with no telemetry. That combination puts a device-routing
experiment and system-stream telemetry at the front.

**One instrument is broken and the other is redundant.** The starvation watchdog cannot report
during a wedge (F3); the storm tripwire cannot detect one at all (F4). Repairing the first
covers both needs, so this costs one slice, not two.

**The layout fault needs a reproduction, not a theory.** The preserved aggregate sample is not
sufficient to select a view. What is needed is a captured session state that reproduces the
screen, time-ordered profiling, and subtree bisection.

And one thing not to do: do not build the note's fixes #1 and #2.

The sliced plan is in `2026-08-06 - implementation-plan.md`.
