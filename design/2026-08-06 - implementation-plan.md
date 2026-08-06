# Implementation plan: capture lifecycle hardening (2026-08-06)

Companion to `2026-08-06 - capture-lifecycle-exploration.md`. Read that first - this plan only
makes sense against the corrected diagnosis, in particular F1 (the backend was not deadlocked)
and F2 (sustained deep layout computation on the main thread, mechanism open).

**Overlay:** `design/_build-overlay.md`. Small actors, direct Core Audio, no DI framework, no
strategy hierarchies. Mic-side changes must not touch the system-audio or recording path.

**Not in this plan, deliberately:**
- The incident note's fixes **#1** (non-blocking backend diagnostics) and **#2** (drain
  stdout/stderr off the MainActor). F1 retires #2 outright - `BackendProcess` already drains on
  Foundation's own queue - and leaves #1 unjustified by this incident's evidence.
- A second main-thread instrument. An earlier draft had a run-loop turn-duration monitor as its
  own slice. It is deleted: it duplicates what slice 2's repaired watchdog reports, and its
  proposed `entry`/`exit` observer pair was also wrong (`CFRunLoopActivity.entry` fires once per
  run-loop *invocation*, not per turn, and `beforeWaiting` is not guaranteed on every
  iteration). The context fields it would have carried are folded into slice 2 instead.

---

## Slice 0 - device-routing experiment (no code)

**Why first:** F1 removed the mechanism that was supposed to explain the system stream going to
zero at 54 s, which is now the earliest and least-explained failure. Any app code written before
this runs blind.

A single healthy built-in run would neither establish Bluetooth causation nor clear the app, so
run a small matrix with a **known continuous audio source** playing throughout (not a live
meeting, and not silence):

| # | Input | Output |
|---|---|---|
| 1 | Built-in mic | Built-in speakers |
| 2 | Built-in mic | Bose QC35 II |
| 3 | Bose QC35 II | Built-in speakers |
| 4 | Bose QC35 II | Bose QC35 II |

All four cells, not three. Without row 3, a failure in Bose/Bose cannot be separated from a
Bose-**input** effect, and that distinction changes which routing guard slice 1b would pick. The
fourth run costs two minutes and makes this a full-factor experiment.

Two minutes each. Then measure digital-zero runs and compare against the 6 Aug numbers.

**Measure the system track only, or supply the mic with its own known source.** Continuous
playback controls what `SCStream` should be capturing; it does **not** give the microphone a known
signal, and on headphones the mic hears essentially nothing controlled at all. So either restrict
this experiment's analysis to `system.wav`, or provide an independent continuous acoustic source
(a second device playing aloud) if mic numbers are wanted from the same runs.

**Done when** each configuration has a recorded result: the failure reproduced in a named
configuration, or a recorded non-reproduction. That is the whole of what the experiment can
establish - it **narrows the failure to a routing configuration** and cannot establish app
causation either way. The write-up must not claim one.

**Cost:** fifteen minutes including analysis. **Blocks:** slice 1's manual verification, and slice
1b. Blocks no implementation work.

---

## Slice 1 - system-stream telemetry

**The gap (F5):** the mic gets heartbeats with level, frame count, time since last frame and
bound device, plus cumulative drop accounting. System audio gets nothing. The stream that failed
first and hardest is the unmonitored one, and the failure mode was **zero-valued samples in
arriving buffers** (F8), which no existing counter would catch because buffers kept flowing and
the file kept growing.

**Change:** emit one `[audio] system.heartbeat` every ~2 s from the existing
`muesli.audio.system` queue, alongside the mic heartbeat. No MainActor hop.

🔴 **Schedule the heartbeat on a timer, NOT off callback arrival.** A callback-triggered heartbeat
emits nothing once the callbacks stop, so `sinceLastCallbackMs` could never report the very outage
it exists to measure - the same self-silencing shape as F3 and F4. A timer on the existing queue is
all this needs; no new actor, no state machine.

**Fields, defined so they are not conflated.** These are three different questions and an earlier
draft mushed them into one:
- `rms`, `peak` - level over the window;
- `callbacks` - buffers delivered in the window;
- `zeroSampleRatio` - fraction of individual **samples** that are exactly zero;
- `zeroBufferRatio` - fraction of **buffers** that were entirely zero;
- `zeroDurationMs` - the **current run of consecutive zero sample frames**, derived from frame counts
  or timestamps and never from wall clock. A frame counts as zero only when **every channel** in it
  is zero. The run **persists across heartbeat windows** - it is a property of the stream, not of the
  window;
- `sinceLastCallbackMs` - wall clock since the last buffer, which is a liveness measure and a
  different thing from all of the above.

**Measure the raw callback buffer, before the app's own PCM conversion.** Measured after conversion
the telemetry cannot separate a pre-fork stream fault from a conversion fault, which is the whole
question F8 needs it to answer.

**Do not block the capture queue.** Either the `BackendLogWriter` call is enqueue-only and
non-blocking, or snapshot the accumulator and do the formatting and file I/O on a separate existing
serial queue. Read the output-device description **outside** the realtime callback.

State the value honestly: this **time-localises arriving zero samples**. Without a known source it
does not make a failure "visible", because legitimate silence looks identical.

**Treat silence as telemetry, not a detected fault.** Legitimate system silence can last far
longer than a few seconds - nobody is playing anything - so a "silence alarm" would fire
constantly. One honest heartbeat carrying the numbers is strictly better than a new alert state
machine, and it is what makes the 6 Aug recording legible in the log after the fact: a 91.9%-zero
recording would have shown `zeroBufferRatio` pinned at 1.0 for minutes.

**This also answers the F8 fork question.** Because the mp4 and the WAV descend from parallel
`SCStream` outputs, telemetry at the app's own callback discriminates the two remaining
possibilities: callback sees non-zero while the mp4 is silent means two independent branch
failures; callback sees zeros means the fault is at or above `SCStream`.

**Files:** `MuesliApp/MuesliApp/CaptureEngine.swift`, plus
`MuesliAppTests/SystemAudioStatsTests.swift`. Keep the implementation in `CaptureEngine.swift`
unless an existing helper already owns audio statistics.

**Test:** the pure sample-statistics accumulator. Every field gets an assertion, or the field could
be deleted with the test still green:
- `rms` and `peak` over a known buffer;
- `zeroSampleRatio` **and** `zeroBufferRatio` on the same input, so the two cannot be conflated;
- `callbacks` and `sinceLastCallbackMs`;
- `zeroDurationMs` on a **mixed buffer with trailing zeros** - the run continues, it does not reset,
  which is why "resets on a non-zero buffer" (an earlier draft's wording) is wrong;
- `zeroDurationMs` across a **window rollover**, proving the run is not reset by the heartbeat;
- a multichannel frame with one non-zero channel, proving it does not count as zero.

Delete the accumulator and these fail in ways that explain why it mattered. This is the one new test
that would have turned the 6 Aug failure into something the log could localise.

**Manual verification:** play a known continuous signal through each slice 0 configuration and
confirm the heartbeat tracks it. **Not** by muting or unplugging the output - muting produces
expected silence and does not reproduce the alleged failure. **This part needs slice 0's
configurations**, so slice 1's *completion* depends on slice 0 even though its implementation and
unit tests do not.

**First code slice.** If one slice ships before the next meeting, this is the one: it turns a
silent total loss into one the log can localise afterwards.

---

## Slice 1b - fix the system-audio fault (gated on slice 0)

Slices 0 and 1 diagnose the primary fault. Neither repairs it, and an earlier draft left the repair
outside the plan as "eventual", which let the plan read as though capture hardening were complete
while its primary fault had no fix decision at all.

**If slice 0 reproduced the failure in a named configuration:** use slice 1's callback telemetry to
localise it per the F8 fork test, then implement the smallest thing that addresses it - a routing
guard, or a correction in whichever branch is at fault. Scope it after localisation, not before;
naming a fix now would be guessing.

**If slice 0 did not reproduce it:** record the deferral explicitly, with all four configurations
tried and their numbers, so the next occurrence starts from a narrowed field rather than from scratch.

**Completion gate, because "implement the smallest thing" plus "unsized" is a checkpoint and not a
done condition for the plan's primary fix.** Once localised, this slice is **rewritten** with the
selected correction named, and then it is done when the correction is verified against the **same
named routing configuration**, with the controlled source, checking all four of: raw callback
telemetry, `system.wav`, the mp4 track, and a focused unit test of any pure routing guard or
decision the fix introduces. Hardware behaviour stays manual.

**Blocks on slice 0 and slice 1.** Unsized until localisation.

---

## Slice 2 - make the starvation watchdog able to report

**The bug (F3):** `echoMainActor`'s `withTaskGroup` cannot return until the `{ @MainActor in
true }` child completes, and that child cannot run while MainActor is wedged. So the watchdog
cannot report during the condition it exists to report, `pingInFlight` latches, and every
subsequent tick is suppressed. It can also emit a stale `starved` line after recovery.

**Change:** replace the race with **one queue-owned probe state machine**. Per episode: enqueue
exactly one MainActor echo, schedule the deadline on the existing serial queue, and transition
to `starved` when the deadline passes without the echo landing - **without starting further
echoes**. The eventual echo, whenever it lands, transitions to `recovered`.

Two things this deliberately avoids. Resetting `pingInFlight` on each timeout would accumulate
one abandoned MainActor task per interval across a nine-minute wedge. And a continuation is the
wrong primitive: there is nothing safe to resume it with while MainActor is blocked. The queue
owns the state; the MainActor hop only signals into it.

**Fold in the context the deleted turn-duration slice would have carried:** have MainActor
**enqueue snapshot updates onto the watchdog's existing serial queue** (active screen, transcript
rows, history count) while it is healthy, and have the `starved` line read the queue-owned copy. Not
a second lock-guarded state owner - one queue owns everything, which is the point of the slice.
A wedge then cannot suppress the context, because nothing on the reporting path needs MainActor.

**Files:** `MuesliApp/MuesliApp/MainActorStarvationWatchdog.swift`,
`MuesliApp/MuesliApp/AppModel.swift` (snapshot push, replacing `RunLoopStormTripwire`'s
MainActor context provider), `MuesliAppTests/MainActorStarvationWatchdogTests.swift`. Retire
`RunLoopStormTripwire.swift`.

**Tests.** The state machine is where the bug lived, so test it deterministically by driving the
transitions directly, with no timing dependence:
- echo lands before the deadline: no `starved` at all;
- deadline passes with no echo: **exactly one** `starved`;
- further deadlines while already starved: **no additional probe, no repeat line**;
- the echo eventually lands: **exactly one** `recovered`;
- a stale deadline or a stale echo belonging to an earlier episode: ignored.

That last case is the round-1 defect generalised - the old code's failure was precisely that a
stale in-flight probe suppressed everything after it.

Plus **one** integration test: a MainActor task blocked on a semaphore released by a background
queue, sub-second threshold, off-main sink, assert `starved` before the release and `recovered`
after. Keep it off MainActor and give it a fail-safe release so a bug cannot hang the suite.
Deliberately **not** a ten-second busy loop - slow, timing-sensitive, and it risks blocking the
XCTest executor. A long manual wedge stays manual verification.

**Done when** the transition tests pass and a manual wedge produces `starved` with context, then
`recovered`.

---

## Slice 3 - reproduce and fix the layout fault

**The fault (F2):** the main thread spent 3,715 of 3,727 samples inside one view-graph flush,
descending a repeating `_FlexFrameLayout` / `_PaddingLayout` / `StackLayout` chain ~200 levels deep,
at 100% CPU. **Starvation is established only for the sample's own 3.7 s window**; a prolonged wedge
is strongly suggested by the surrounding evidence but its continuity and invocation count are not
settled. (An earlier draft of this plan asserted "never yielded usefully for nine and a half
minutes" after that claim had already been weakened in the exploration document. F2 is the
authority.)

**The mechanism is open and the preserved sample cannot select a view.** Five candidates are
live (true cycle, bounded-but-exponential re-evaluation, repeated-pass churn from an unsettled
invalidation source, a long inner loop in one framework call, or a framework control supplying
part of the depth - `DesignLibrary` frames are in the hot path). So this slice is reproduction
first, code second:

1. **Establish a reproduction - a state *sequence*, not a static snapshot.** Which meeting, how
   many transcript rows, which devices, what is on screen is necessary but not sufficient:
   repeated-pass churn may depend on transcript arrivals, timers, selection changes or other
   invalidations, none of which a still screen contains. Build a deterministic replay fixture or a
   recorded action sequence. Without one there is nothing to bisect.
2. **Profile time-ordered stacks**, not one aggregate sample. Several short samples in sequence,
   or Instruments, is what distinguishes one long invocation from repeated passes - the
   distinction the 6 Aug evidence could not settle.
3. **Bisect subtrees**: replace parts of the session screen with fixed-size placeholders until
   the pathology disappears.

**Do not** start from "measure the layout depth in the source". Source nesting and SwiftUI's
generated layout graph are different things, so that is not an executable step. And do not treat
the `GeometryReader` at `SessionView.swift:329` as the obvious suspect - `RootGeometry` is a
framework root-layout symbol and points at nothing in particular.

**Files:** unknown until step 1. Likely `SessionView.swift` and what it composes.

**Rides along: the mic-path audit (F7).** The mic stopping at 75.6 s destroyed the whole remainder
of David's own track despite 6 Jul's off-main fix, so it does not get left as a curiosity. Bounded
scope, mic only, no changes to the system or recording path:

- enumerate every remaining MainActor hop on the mic path;
- place a counter and a last-seen timestamp at three boundaries - the mic callback,
  `MicAudioForwarder`, and the backend's receive point;
- **each of the three must reach disk without traversing MainActor.** The first two go to
  `BackendLogWriter` from their own queues (as the existing mic heartbeat already does); the third
  is the backend writing its own line. Without a named durable path this audit reproduces exactly
  the defect it is investigating, which is what F3 and F4 both were.

**Done when** all three hold:
1. the session screen completes layout in bounded time under the conditions that reproduced the
   pathology;
2. there is **an automated regression test at the level of whatever was found** - a layout-depth or
   bounded-time assertion, or a pure test of the offending shape. "A note recording which shape
   caused it" is not a done condition; it is a comment;
3. a controlled acoustic run shows **all three mic boundaries advancing** in the log. Without this,
   the slice can be declared complete without the audit having been performed.

**Unsized until step 1 is done, and must be split once it is.** Ahead of the recovery work below,
because it removes the cause rather than mitigating it.

---

## Slice 4a - breadcrumb, and verify the recovery path that already exists

**The harm (F7):** `meeting.json` was left at `status: recording`, `duration_seconds: 0`, and
nothing off-main was empowered to record that the session had ended abnormally.

**Verify first, then decide whether the breadcrumb is needed at all.** The order matters and an
earlier draft had it backwards. 6 Jul's fix #6 added launch recovery for orphaned meetings and has
never been tested. So:

1. **Test `OrphanedMeetingRecovery` against a temporary incomplete meeting folder, asserting
   postconditions rather than recording behaviour.** "Establish what it actually does" (an earlier
   draft's wording) would let the test memorialise wrong behaviour as correct. The postconditions:
   given `status: recording` with `duration_seconds: 0`, what metadata state results; that completed
   artefacts are preserved untouched; and that running recovery twice is idempotent.
   **This step blocks on nothing** - it needs no watchdog.
2. **If that already recovers correctly**, and slice 2 already writes an off-main `starved` line,
   then **delete the breadcrumb from this plan as redundant.** Two records of the same fact is the
   ocean-boiling the doctrine forbids.
3. **Only if step 1 shows a demonstrated gap**, add the breadcrumb - and then it needs its own
   tests, not just `meeting.json`'s:
   - atomic, idempotent creation (a second write is a no-op, a partial write is impossible);
   - scoped by a **queue-owned active-meeting token and path**, so it can only ever name the
     meeting that was live;
   - that target cleared when recording ends;
   - **proof that a stale breadcrumb cannot alter an already-finalised meeting** - the failure mode
     that would turn a recovery feature into a corruption feature.

Do not invent a new status value at any point in this slice.

**Files:** `MuesliApp/MuesliApp/OrphanedMeetingRecovery.swift` (tests only if it already works),
`MuesliAppTests/OrphanedMeetingRecoveryTests.swift`, and
`MuesliApp/MuesliApp/MainActorStarvationWatchdog.swift` only if step 3 is reached.

**Dependency, split:** step 1 (the recovery-path tests) blocks on **nothing** and should be done
early, because it is what decides whether the breadcrumb exists at all. Only step 3 - the optional
breadcrumb - depends on slice 2.

---

## Slice 4b - emergency finalisation (needs David's decision first, and a design pass)

**Do not start this without an explicit decision.** Two reasons, and the second one is new.

**First, "recoverable without stopping" is not a coherent option.** Flushing, closing and
finalising live writers *is* stopping the recording, and doing it off-main races the capture
callbacks. There is no version of this that saves the session without ending it.

**Second, and resolved from source: no single component can finalise both artefacts.** The mp4
is written by `SCRecordingOutput` **inside the app** (`CaptureEngine.swift:205, 282-287`). The
WAVs are written by the **backend** (`muesli_backend.py:140`), on its own exit. So the app cannot
finalise the WAVs at all - its only lever is closing stdin, which is what makes the backend
finalise - and the backend cannot finalise the mp4. Any emergency stop is a **coordinated
two-process teardown**, which is a materially bigger piece of work than "one session" and needs
its own design pass on the components that actually own each writer.

**The decision David has to make:** should a sustained wedge stop the meeting automatically?
Auto-stopping on a false positive ends a live meeting, which is worse than the failure being
fixed. Recommendation: **no** - leave stopping to David, and let slice 4a plus launch recovery
carry the loss reduction. But it is his call, and slice 4b does not begin until he has made it.

**Design gates carried forward, so deferring the slice does not quietly drop them.** Whenever it is
designed, it must have: one idempotent lifecycle transition; repeated triggers as no-ops;
owner-correct stop ordering across the two processes; explicit confirmation-or-timeout for **both**
the recording finishing and the backend exiting; and atomic `meeting.json` replacement performed
only after both outcomes are known. Deferring the design is legitimate. Losing these requirements
is not.

---

## Sequencing summary

| # | Slice | Kind | Blocks on | Value if it ships alone |
|---|---|---|---|---|
| 0 | Device-routing matrix | Experiment | Nothing | Narrows the failure to a routing configuration |
| 1 | System-stream telemetry | Feature + test | Implementation and unit tests: nothing. **Completion: slice 0** for manual verification | A zeroed stream becomes localisable in the log instead of a post-mortem |
| 1b | System-audio fix | Gated build | Slices 0 and 1 | Repairs the primary fault, if slice 0 reproduced it |
| 2 | Watchdog can report | Fix + test | Nothing | The next wedge is visible, with context |
| 3 | Layout fault, plus the mic-path audit | Reproduce then fix | Nothing, but unsized | Removes the cause |
| 4a | Verify recovery, breadcrumb only if needed | Test, then maybe a small feature | **Step 1: nothing.** Step 3 (breadcrumb): slice 2 | A wedged meeting is repaired at next launch |
| 4b | Emergency finalisation | Design, then build | David's decision; a two-process teardown design | Deferred by recommendation |

**Independence, stated exactly** rather than loosely as an earlier draft had it: slices 0, 1, 2 and
4a-step-1 can all be *started* without waiting for anything. Slice 1's *completion* needs slice 0's
configurations for its manual verification. Slice 1b needs both. Slice 3 is unsized until its step 1
is done and must be split then. Slice 4b is not scheduled.

---

## Convergence-loop record

Three GPT-5 rounds, all folded in: 22 changes in round 1, 13 in round 2, 8 in round 3. Reply length
fell 12.1k → 7.8k → 4.4k characters. Prompts and replies are in the session scratchpad.

What each round actually changed, since that is the audit trail:
- **Round 1** overturned the exploration's central claim about `sample` evidence (an aggregate call
  tree cannot prove a single non-terminating invocation), caught an argument of mine that ran
  backwards, and deleted a whole slice as redundant.
- **Round 2** corrected the audio architecture: `SCRecordingOutput` and the app's stream callback are
  parallel outputs on one `SCStream`, not a chain - which relocated the F8 fault boundary and made
  emergency finalisation a two-process problem. It also caught that the plan called system-audio
  zeroing the primary fault while containing no fix for it, which produced slice 1b.
- **Round 3** caught an over-claim fixed in one document but left standing in the other, corrected
  its own round-2 wording about what the callback discriminator proves, added the fourth cell to the
  routing matrix, and caught that a callback-triggered heartbeat would be silent during exactly the
  outage it measures.

**Boss decision: the loop was stopped at round 3, not carried to the cap of 5, and it did not return
READY TO SHIP.** Rounds were still resolving real points, so this is a judgement that returns were
diminishing into test-level detail the build stage will revisit against real code anyway, not a claim
of convergence. Every round-3 point is folded in and none is outstanding. If a fourth round is wanted
before building, the round-3 prompt is in the scratchpad and re-running is cheap.
