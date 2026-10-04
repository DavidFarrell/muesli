# Incident: start screen pins one core for days (2026-10-04)

**Status: root cause identified, fix prepared on branch `fix/segmented-picker-observation-leak`, not merged.**
The spinning process (PID 43738) was left running throughout; nothing in this
investigation quit, signalled or interacted with it beyond `sample`, `heap`,
`vmmap`, `atos -p` and a read-only Accessibility query.

## What David saw

`/Applications/MuesliApp.app` (Release, built 6 Sep 2026 from commit `0d69645`,
clean tree, Xcode 26.6 SDK) launched Thu 1 Oct 08:18:37 and was at ~100% of one
core when checked on 4 Oct ~17:15. `coreaudiod` (~22%) and `replayd` (~17%)
were also elevated. No recording was in progress; the newest meeting folder was
2 Oct 14:09. The Mac had been on battery and cycling sleep/DarkWake for most of
3 and 4 Oct.

## Headline

The start screen (`NewMeetingView`) uses two `Picker`s with
`.pickerStyle(.segmented)`. On macOS 26.6.2 that control is built on Apple's
private `DesignLibrary` framework (`MacSegmentedControlItem`,
`SelectedSegmentState`) and **leaks one `@Observable` registrar per segment on
every render of the containing view**. The start screen re-renders whenever
the level meters publish, so the leak accrues for as long as the app sits on
the start screen with the live preview running. SwiftUI's observation tracking
for the segment labels spans every registrar accumulated so far, so each layout
pass cancels and re-registers tracking across all of them. By the time the
process was examined it held **337,000 leaked registrars**, every layout pass
cost about a second of CPU, and the run loop had been doing nothing else for
days.

Confidence: **high** that the segmented pickers are the site and that the leak
is in the framework, not in Muesli (100% of hot layout samples pass through
`SystemSegmentedControl`; the count grows 4.7/s while idle; a 120-line harness
with no Muesli code reproduces it in 15 seconds and the leak disappears when
the style is changed). **Inferred**, not proven: the exact reason SwiftUI's
`ObservationCenter` re-registers across the whole accumulated set on each pass
(read off the heap census, see below).

## Timeline

| When | Event | Source |
|---|---|---|
| 26 Aug | macOS 26.6.2 installed | `softwareupdate --history` |
| 6 Sep | Installed build compiled (commit `0d69645`) | `build-identity.json` |
| 28 Sep 10:11, 14:55 | `cpu_resource.diag` for an earlier MuesliApp process (PID 664) | `/Library/Logs/DiagnosticReports` |
| 30 Sep 18:39 | `cpu_resource.diag` for another process, 38 min after the "awin" meeting ended | same |
| 1 Oct 08:18 | PID 43738 launched; meeting recorded 08:18-08:43, completed normally | `meeting.json` status fields |
| 1 Oct 08:45 | Display sleep | unified log (SkyLight) |
| 1 Oct 10:22 | Display wake | unified log |
| 1 Oct 10:39:54 | `cpu_resource.diag` fires for 43738 (52% over 172 s) - the storm is already under way | diag report |
| 1 Oct 14:31-15:31, 2 Oct 12:58-14:09 | Two further meetings recorded and completed normally in the same process | `meeting.json` |
| 3 Oct 08:08 | Preview SCStream stops with "Failed to find any displays" at generation 83 (lid closed; the preview has restarted 83 times across sleep/wake) | `com.muesli.audio` log line |
| 4 Oct 20:35-20:54 | This investigation: three `sample`s, two `heap` censuses, harness | this folder |

Across the three onsets that can be dated, Muesli itself logged nothing. Each
one came minutes after a display or lid wake with the app idle on the start
screen (28 Sep: 3 min after a lid wake; 30 Sep: 14 min; 1 Oct: 17 min). The
onset is not an event; it is the point where the per-render cost crossed the
CPU-report threshold. The diag reports fire once per process, so the 1 Oct
report marks "first exceeded 50%", not "started".

## Live evidence

### Process

- `ps`: state R, 1,036 min of CPU over 3 d 12 h elapsed; **all of it on the
  main thread** (972 min user time on thread 1; every other thread under a
  minute). No child processes - the Python backend only runs during a meeting.
- `lsof`: nothing unusual. Open files are the archive-bridge socket and lock,
  Metal shader caches and dyld images. No audio or meeting files held open.
- Window (Accessibility, read-only): one 980x801 window, not minimised, app not
  frontmost, start screen showing.
- Physical footprint 514 MB at 20:35, 543 MB at 20:49, versus 150-164 MB
  during the 1 Oct diag. `vmmap`: the growth is `MALLOC_SMALL` (295 MB), which
  is where the registrar dictionaries live.

### Samples (`evidence/sample-43738-*.txt`, three 10 s samples 18 min apart)

All three have the same shape. In the first (6,738 main-thread samples):

- **61%** - SwiftUI run-loop observer flush:
  `NSHostingView.beginTransaction -> GraphHost.flushTransactions ->
  RootGeometry.value.getter -> (ScrollView, VStack, GroupBox, padding and
  frame layouts) -> FlexibleButtonFrameLayout -> PlatformViewLayoutEngine ->
  SystemSegmentedControl._overrideSizeThatFits -> (AppKit) ->
  ViewGraph.sizeThatFits -> StaticBody.updateValue ->
  ObservationCenter.invalidate`.
  3,933 of the 3,944 layout samples pass through `SystemSegmentedControl`. The
  two branches under it (1,978 and 1,966 samples) are the two segmented
  pickers: "Mode" in the top HStack and "Echo cancellation" inside the
  Microphone GroupBox.
- **39%** - AppKit display cycle: `NSWindow layoutIfNeeded -> twelve levels of
  _layoutSubtreeWithOldSize -> _NSViewLayout -> NSAnimationContext
  runAnimationGroup -> ViewGraphRootValueUpdater.render ->
  StaticBody.updateValue -> ObservationCenter.invalidate`. Same leaf, reached
  from the segmented control's own `layout`.
- Under `StaticBody.updateValue` the time is almost entirely
  `ObservationTracking.cancel -> ObservationRegistrar.Context.cancel` (957
  samples) and `ObservationTracking._installTracking ->
  ObservationRegistrar.Context.registerTracking` (715 samples), with
  `Hasher`, `AnyKeyPath.hash`, `Set<AnyKeyPath>` iteration and
  `_NativeDictionary._delete` as the hot leaves. The body closures themselves
  are a few dozen samples.
- Muesli's own code barely appears: `NewMeetingView.body.getter` and its
  closures total ~20 samples per 10 s. The mic preview callback
  (`MicAudioIngress.callback`) is live on its own thread (33 samples), which
  is why `coreaudiod` and `replayd` were busy - the home-level preview is
  running as designed.

The 1 Oct `cpu_resource.diag` (`evidence/MuesliApp_2026-10-01-104246...`)
shows the same two paths and the same `SystemSegmentedControl ->
StaticBody.updateValue -> ObservationCenter.invalidate` leaf, as do the 28 and
30 Sep reports for earlier processes. This has been happening on every launch
since at least 28 Sep.

### Heap census (`evidence/heap-census-*.txt`)

`heap 43738` at 20:49:41 and again at 20:53:08:

| Object | 20:49:41 | 20:53:08 |
|---|---|---|
| `ObservationRegistrar` state (one per `@Observable` instance) | 336,226 | 337,194 |
| `Dictionary<AnyKeyPath, Set<Int>>` (per registrar) | 336,217 | - |
| `Dictionary<Int, Observation>` (per registrar) | 336,217 | 337,185 |
| `Set<AnyKeyPath>` | 336,230 | - |
| Closure contexts | 241,434 | 206,382 |
| `Dictionary<ObjectIdentifier, ObservationTracking.Id>` | 22 instances, **767 KB each** | same |
| `Dictionary<ObjectIdentifier, SwiftUI.ObservationEntry>` | 12 instances, **1.58 MB each** | same |
| `DesignLibrary.SelectedSegmentState` | 18 | 18 |

Growth while idle: **+968 registrars in 207 s, 4.7 per second**. There are
five segments across the two pickers (2 + 3), and at ~1 s per layout pass that
is one leaked registrar per segment per pass.

Muesli declares no `@Observable` types at all (`grep` of the whole repo), and
no class with hundreds of thousands of instances appears in the census - the
owning objects are gone; only their registrar contexts survive, kept alive by
the trackings that still reference them. The 22 tracking Id dictionaries at
767 KB each and 12 SwiftUI `ObservationEntry` maps at 1.58 MB each are the
accumulated sets that each pass cancels and re-registers. That last sentence
is the inferred layer.

## Mechanism

1. The start screen shows the live level meters. `AudioMetersModel` publishes
   at most 15 Hz per stream (gated, deduped, silent at rest), and
   `NewMeetingView` reads `meters.mic.level` and `meters.system.level` in its
   body, so the whole start screen re-renders on every publish.
2. Each render re-evaluates the two segmented pickers. On macOS 26.6.2 the
   segmented style's per-segment item creates an `@Observable` state object
   whose registrar is captured by SwiftUI's observation tracking for the label
   body and never released when the item is replaced.
3. SwiftUI re-installs that tracking on every evaluation of the label body,
   across every registrar it has ever accumulated, so the cost of measuring a
   segmented control grows linearly with the number of renders so far.
4. Measuring the segmented control happens inside the root layout pass, so
   the cost lands on every transaction, not just on the ones the meters
   caused. Once a pass costs more than the interval between invalidations,
   the main thread never goes idle: 100% of one core, run loop still turning
   (slowly), UI still technically responsive.
5. The process cannot recover on its own. The registrars are never freed;
   quitting is the only way to clear them.

Why idle on the start screen matters: `SessionView` and `MeetingViewer` have no
segmented pickers. During the three meetings recorded by this process the
start screen was not on screen, so the leak paused, then resumed on return.

## Why the existing watchdogs did not catch it

- `MainActorStarvationWatchdog` measures echo latency with a 5 s threshold.
  The main thread here is not blocked; it turns the run loop roughly once a
  second, so every echo returns well inside 5 s and `mainactor.starved` never
  fires. It is the right tool for the 6 Jul livelock (a blocked main thread)
  and blind to this (a saturated but turning one).
- `RunLoopStormTripwire` (`ui.storm`, turns per second) was removed on 5 Sep
  2026 in commits `a267cc6` / `9fd3bd4` ("Make starvation diagnostics
  independent and bound stdout drain waits"). It would also have struggled:
  the loop is slow, not fast.
- `MeterPublishGate` is working as designed; it bounds the render rate, it
  cannot bound the cost per render.
- Nothing in Muesli measures main-thread CPU time. Recommendation below.

## Relationship to the 6 Jul livelock and to sleep/wake

**6 Jul 2026:** same symptom class (sustained SwiftUI layout storm on the main
thread with `StackLayout`/`_FlexFrameLayout`/`_PaddingLayout` recursion and no
app symbols) and the segmented pickers already existed then (Mode since the
initial commit, Echo cancellation since 29 May). The July note says the
loop-closer was never convicted. It is plausible this is the same bug on
macOS 26.5, but it is not confirmed: the only July-era sample preserved
(`incident-2026-08-06-evidence/app-sample-39594.txt`, macOS 26.5.2) is of a
blocked app during the stderr deadlock, not a CPU storm, and contains none of
the frames above. Treat the July link as a hypothesis.

**Sleep/wake:** indirect only. Each wake restarts the preview `SCStream` and
the mic engine (generation 83 by 3 Oct), the meters start publishing again
after a quiet period, and the render rate rises. That accelerates the leak; it
does not cause it. The onsets cluster after wakes because that is when the
start screen starts re-rendering again.

## Reproduction harness (`harness/harness.swift`)

A single-file SwiftUI app with the start screen's shape (ScrollView, VStack, a
Mode picker in an HStack with `.frame(maxWidth: 420)`, an Echo cancellation
picker inside a GroupBox, a 15 Hz published value driving a level bar).
`HARNESS_STYLE` selects the picker style. Built with the Command Line Tools
Swift 6.3.3 compiler, run on this Mac (macOS 26.6.2), `heap` taken at ~15 s
and ~56 s:

| Style | Registrars at ~15 s | at ~56 s | CPU |
|---|---|---|---|
| `.segmented` | 1,033 | 3,373 | 16.5% rising to 20.2% |
| custom (HStack of Buttons) | 7 | 7 | 4-7% |
| `.menu` | 7 (at 35 s) | - | 16% |
| `.radioGroup` + `.horizontalRadioGroupLayout()` | 7 (at 35 s) | - | 8% |

5 segments x 15 Hz x 41 s = 3,075 expected, 2,340 observed (the gate dedupes
some ticks). Full numbers in `harness/census-results.txt`.

## Fix (branch `fix/segmented-picker-observation-leak`, based on `origin/main` fa151a6)

`MuesliApp/MuesliApp/ContentView.swift`, two edits, nine added lines: both
start-screen pickers move from `.pickerStyle(.segmented)` to
`.pickerStyle(.radioGroup)` plus `.horizontalRadioGroupLayout()`, with a
comment pointing here. Radio group is native, accessible, leak-free in the
harness, and the smallest change. `.menu` or a hand-rolled segmented control
are also leak-free if the look matters more; the custom control in the harness
is a starting point.

No other `.segmented` use exists in the app. No model, backend or test code
changed.

No automated test was added. Every existing test in `MuesliAppTests` is a
state-machine or model test; there are no view tests and no pattern to follow,
and a malloc-count view test would be flaky and unrunnable today (see below).
The harness in this folder is the regression check: run it with
`HARNESS_STYLE=segmented` on a new macOS to see whether Apple has fixed the
leak, and with the chosen style to confirm it stays flat.

## Verification

- **Swift tests: not run.** `/Applications/Xcode.app` is now Xcode 27.0
  (27A266a) and its licence has not been accepted, so `xcodebuild` refuses
  every operation (`You have not agreed to the Xcode license agreements`).
  The same blocks the rebuild step in `~/dfsystem/muesli-build.md`. Until
  `sudo xcodebuild -license` has been run, nothing Xcode-based works on this
  machine. The Command Line Tools (26.6, Swift 6.3.3) still work, which is how
  the harness was built.
- **Whole-module type-check with the Command Line Tools compiler:** see the
  note at the end of this section.
- **Python suite (`backend/.../.venv`, pytest):** untouched by this branch. A
  full run shows 164 passed, 33 failed, 1 collection error; every failing file
  passes when run alone (`test_processing_evidence.py` 49/49,
  `test_reprocess_sessions.py` 7/7). The failures are test-order pollution
  (`soundfile` and `numpy` lose attributes mid-run, so something stubs
  `sys.modules` and does not restore it) and `test_senko_diarisation.py`
  cannot import `numba` under pytest for the same reason. Pre-existing, not
  caused by and not fixed by this branch; worth its own small ticket.

Type-check result: `swiftc -typecheck` over `MuesliApp/MuesliApp/*.swift`
plus `release/inference-service/*.swift` with the project's
`-default-isolation MainActor` and `MemberImportVisibility` settings reports
**no diagnostics in `ContentView.swift`**. It cannot complete the module: two
errors in `AppModel.swift` (lines 2585 and 2630) reference `MuesliLiveSource`,
which is not defined in any checked-in Swift file and is produced by the build's
generator step, so a full compile needs the Xcode pipeline. Treat the change as
compile-checked at file level only until `xcodebuild` runs.

## What David needs to do

1. **Quit and relaunch MuesliApp** when convenient. The current process will
   never recover; its 337k registrars go away only with the process. Nothing
   is lost by quitting it - no meeting is in progress and all three meetings
   it recorded are `completed`.
2. Run `sudo xcodebuild -license` once (Xcode 27.0), then on the branch:
   `xcodebuild -scheme MuesliApp -configuration Release -derivedDataPath
   /tmp/muesli-build test` (or the usual build + `ditto` from the runbook).
3. Look at the two pickers once in the running app - radio buttons instead of
   segments - and decide whether that is acceptable or whether the custom
   segmented control from the harness should replace them.
4. Gate and merge. Until the rebuilt app is installed, leaving Muesli on the
   start screen for hours will reproduce the spin; parking it in a meeting
   viewer or quitting it avoids it.
5. Optional, recommended: a main-thread CPU tripwire in
   `MainActorStarvationWatchdog`'s utility-queue timer (read the main thread's
   `thread_info` CPU time each tick; log `mainthread.cpu_storm` with the
   context provider's screen when utilisation stays above ~85% for 30 s while
   not capturing, and `mainthread.cpu_recovered` after). That is the probe
   that would have put this incident in `backend.log` on 28 Sep. Deliberately
   not added on this branch because it cannot be tested on this machine today.

## Evidence index

- `evidence/sample-43738-2035.txt`, `-2037.txt`, `-2053.txt` - the three
  10 s samples.
- `evidence/lsof-43738.txt`.
- `evidence/heap-census-1-2049.txt`, `heap-census-2-2053.txt` - `heap`
  headers, top classes and every Observation / DesignLibrary / Segment line.
- `evidence/MuesliApp_2026-09-28-*.cpu_resource.diag`,
  `MuesliApp_2026-09-30-184243...cpu_resource.diag`,
  `MuesliApp_2026-10-01-104246...cpu_resource.diag` - the four CPU reports;
  `MuesliApp_2026-09-30-180135...diag` is a disk-writes report from the 30 Sep
  meeting, kept for completeness.
- `evidence/unified-log-43738-extract.txt`,
  `unified-log-27sep-1oct-extract.txt` - MuesliApp's unified-log lines
  filtered to Muesli's own subsystem plus display and sleep notifications.
- `harness/harness.swift`, `harness/census-results.txt`.

Nothing in this folder contains meeting audio, transcripts, notes or meeting
folder names beyond what `meeting.json` status fields and folder timestamps
expose in the timeline above.
