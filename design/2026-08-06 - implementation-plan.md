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
| 3 | Bose QC35 II | Bose QC35 II |

Two minutes each. Then measure digital-zero runs in both WAVs per run and compare against the
6 Aug numbers.

**Done when** each configuration has a recorded result: the failure reproduced in a named
configuration, or a recorded non-reproduction. That is what the experiment can establish. It
cannot establish a cause, and the write-up must not claim one.

**Cost:** fifteen minutes including analysis. **Blocks:** the eventual system-audio fix and
slice 3's manual verification. **Blocks nothing else.**

---

## Slice 1 - system-stream telemetry

**The gap (F5):** the mic gets heartbeats with level, frame count, time since last frame and
bound device, plus cumulative drop accounting. System audio gets nothing. The stream that failed
first and hardest is the unmonitored one, and the failure mode was **zero-valued samples in
arriving buffers** (F8), which no existing counter would catch because buffers kept flowing and
the file kept growing.

**Change:** emit one `[audio] system.heartbeat` every ~2 s from the existing
`muesli.audio.system` queue, alongside the mic heartbeat, carrying: RMS, peak, callback count,
zero-buffer ratio over the window, and consecutive-zero duration. Straight to
`BackendLogWriter`, no MainActor hop.

**Treat silence as telemetry, not a detected fault.** Legitimate system silence can last far
longer than a few seconds - nobody is playing anything - so a "silence alarm" would fire
constantly. One honest heartbeat carrying the numbers is strictly better than a new alert state
machine, and it is what makes the 6 Aug failure legible in the log: a 91.9%-zero recording would
have shown a zero-buffer ratio pinned at 1.0 for minutes.

Read the output-device description **outside** the realtime callback.

**Files:** `MuesliApp/MuesliApp/CaptureEngine.swift`, plus
`MuesliAppTests/SystemAudioStatsTests.swift`. Keep the implementation in `CaptureEngine.swift`
unless an existing helper already owns audio statistics.

**Test:** the pure sample-statistics accumulator - feed it buffers, assert RMS, peak,
zero-buffer ratio and consecutive-zero duration, and assert the consecutive-zero clock resets on
a non-zero buffer. Delete the accumulator and this test fails in a way that explains why it
mattered. This is the one new test that would have turned the 6 Aug failure into a logged fact
rather than a post-mortem.

**Manual verification:** play a known continuous signal through each slice 0 configuration and
confirm the heartbeat tracks it. **Not** by muting or unplugging the output - muting produces
expected silence and does not reproduce the alleged failure.

**First code slice, and independent.** If one slice ships before the next meeting, this is the
one: it converts a silent total loss into a visible one.

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

**Fold in the context the deleted turn-duration slice would have carried:** have MainActor push
a small snapshot (active screen, transcript rows, history count) into a lock-guarded slot while
it is healthy, and have the `starved` line read that slot. A wedge then cannot suppress the
context, because nothing on the reporting path needs MainActor.

**Files:** `MuesliApp/MuesliApp/MainActorStarvationWatchdog.swift`,
`MuesliApp/MuesliApp/AppModel.swift` (snapshot push, replacing `RunLoopStormTripwire`'s
MainActor context provider), `MuesliAppTests/MainActorStarvationWatchdogTests.swift`. Retire
`RunLoopStormTripwire.swift`.

**Test:** occupy MainActor with a short task blocked on a semaphore that a background queue
releases, run with a sub-second threshold and an off-main test sink. Assert `starved` arrives
before the release and `recovered` after it. Deliberately **not** a ten-second busy loop - slow,
timing-sensitive, and it risks blocking the XCTest executor. Keep a long manual wedge as manual
verification.

**Done when** that test passes and a manual wedge produces `starved` with context, then
`recovered`.

---

## Slice 3 - reproduce and fix the layout fault

**The fault (F2):** the main thread spent 3,715 of 3,727 samples inside one view-graph flush,
descending a repeating `_FlexFrameLayout` / `_PaddingLayout` / `StackLayout` chain ~200 levels
deep, at 100% CPU, and never yielded usefully to queued MainActor work for nine and a half
minutes.

**The mechanism is open and the preserved sample cannot select a view.** Five candidates are
live (true cycle, bounded-but-exponential re-evaluation, repeated-pass churn from an unsettled
invalidation source, a long inner loop in one framework call, or a framework control supplying
part of the depth - `DesignLibrary` frames are in the hot path). So this slice is reproduction
first, code second:

1. **Establish the captured session state that reproduces the screen.** Which meeting, how many
   transcript rows, which devices, what is on screen. Without a reproduction there is nothing to
   bisect.
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

**Done when** the session screen completes layout in bounded time under the conditions that
reproduced the pathology, with a note recording which shape caused it.

**Unsized until step 1 is done, and must be split once it is.** Ahead of the recovery work
below, because it removes the cause rather than mitigating it.

---

## Slice 4a - breadcrumb, and verify the recovery path that already exists

**The harm (F7):** `meeting.json` was left at `status: recording`, `duration_seconds: 0`, and
nothing off-main was empowered to record that the session had ended abnormally.

**Change, deliberately minimal:** on a sustained `starved` signal from slice 2, write **one
atomic, idempotent breadcrumb file** into the meeting folder from the watchdog's own queue - a
path to disk that does not traverse MainActor. Nothing else. No new status value, no writer
mutation.

**Then verify the recovery path that is already meant to handle this.** 6 Jul's fix #6 added
launch recovery for orphaned meetings and has never been tested. Test `OrphanedMeetingRecovery`
against a temporary incomplete meeting folder and confirm what it does with a `status: recording`
folder, with and without the breadcrumb. Do not invent a new status until the existing path's
behaviour is known - it may already be sufficient.

**Files:** `MuesliApp/MuesliApp/MainActorStarvationWatchdog.swift`,
`MuesliApp/MuesliApp/OrphanedMeetingRecovery.swift` (tests only, if it already works),
`MuesliAppTests/OrphanedMeetingRecoveryTests.swift`.

**Test:** recovery against a temp folder fixture, plus atomic idempotent `meeting.json`
replacement if a write turns out to be needed. **Depends on slice 2.**

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

---

## Sequencing summary

| # | Slice | Kind | Blocks on | Value if it ships alone |
|---|---|---|---|---|
| 0 | Device-routing matrix | Experiment | Nothing | Says whether the app is implicated at all |
| 1 | System-stream telemetry | Feature + test | Nothing | A zeroed stream becomes a logged fact, not a post-mortem |
| 2 | Watchdog can report | Fix + test | Nothing | The next wedge is visible, with context |
| 3 | Layout fault | Reproduce then fix | Nothing, but unsized | Removes the cause |
| 4a | Breadcrumb + verify recovery | Small feature + test | Slice 2 | A wedged meeting is repaired at next launch |
| 4b | Emergency finalisation | Design, then build | David's decision; a two-process teardown design | Deferred by recommendation |

Slices 0, 1 and 2 are independent and each sized for one focused session. Slice 3 is unsized
until its step 1 is done. Slice 4a is small. Slice 4b is not scheduled.
