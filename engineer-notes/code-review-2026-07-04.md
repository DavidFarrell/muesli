# Muesli Whole-Project Review - 2026-07-04

_Four independent passes merged: Claude (audio/state core), a SwiftUI/UX reviewer, a Python-backend reviewer, and a GPT-5 second opinion (codex, read-only). GPT-5 independently confirmed all five of Claude's core hypotheses. Repo was clean and pushed at review time (HEAD ec24653)._

Owner-reported symptoms driving the review:
1. App gets slow when left open for ages.
2. Audio sometimes still fails to connect after lots of device swapping.
3. "Refresh audio sources" button seems to do nothing.
4. Meeting rename UX inconsistent (click-title vs click-button).
5. Suspicion that live diarisation is a waste; live "Mic/System" labels would do.

Verdict up front: all five symptoms have confirmed mechanisms in the code. The working core (Senko + Parakeet, `reprocess.py` as source of truth, the ec24653 follow/pin device redesign) is sound. Nearly everything slow or fragile lives in (a) one-ObservableObject-to-rule-them-all SwiftUI state, and (b) the live-diarisation scaffolding.

---

## A. Symptom root causes

### A1. "Slow when left open for ages" - four compounding mechanisms

**Frontend invalidation storm (primary).** Everything funnels through `AppModel.objectWillChange`:
- `CaptureEngine.onLevelsUpdated` fires `objectWillChange.send()` once per audio sample buffer on the main thread (`CaptureEngine.swift:370-379`, relay at `AppModel.swift:299-303`).
- `handleMicAudio` mutates 5-6 `@Published` vars per mic buffer (`AppModel.swift:638-646`).
- `transcriptModel.objectWillChange` is relayed into `AppModel.objectWillChange` (`AppModel.swift:309-313`), so every partial re-renders everything.
- `TranscriptRow` declares `@EnvironmentObject var model: AppModel` (`TranscriptRow.swift:4`) - every realized transcript row is invalidated on every level tick.
- `MeetingViewer.transcriptPane` re-runs `segments.filter { !$0.isPartial }` in the body every recompute (`MeetingViewer.swift:271`).
Net: the whole view tree re-diffs at audio-buffer rate, and each re-diff costs more as the transcript grows.

**The start screen is never idle.** `startHomeLevelPreviewNow` (`AppModel.swift:840`) keeps a full SCStream + preview MicEngine running whenever the app sits on the start screen, feeding the invalidation storm indefinitely. Hours of "idle" = hours of full-tree invalidation at buffer rate.

**TranscriptModel is quadratic over a meeting.** Every `ingest` does O(n) filter + O(n) merge scan + occasional sort + whole-array `@Published` replace (`TranscriptModel.swift:151-237`, merge `:89-114`). Bonus bug: a final segment rebuilds from `segments.filter { !$0.isPartial }`, silently dropping ALL current partials from both streams (live-line flicker).

**Backend model-reload churn (major, previously unspotted).** `run_pipeline` constructs a fresh `ASRModel` on every live chunk (`muesli_backend.py:260`, `asr.py:53-58`) - the entire Parakeet-MLX model is re-deserialised every live interval per stream (Debug build: every 5s, both streams; Release default 15s). Constant MLX/Metal alloc+teardown and memory pressure over a long session. The Senko diarizer IS cached (`senko_diarisation.py:16`) - the ASR model conspicuously is not.

Also: `rms_int16` is a pure-Python per-sample loop run per frame for the whole meeting (`muesli_backend.py:130-139`; `--emit-meters` always on).

### A2. "Audio fails to connect after device swapping" - remaining holes after ec24653

The ec24653 redesign (follow/pin by UID, serialized restarts via `micLifecycleTask`, watchdog, configchange observer) is structurally good for the MEETING engine. Remaining gaps:
- **Preview parity (biggest).** The start-screen preview engine starts WITHOUT `onConfigurationChange` (`AppModel.swift:878-882`), has no watchdog, and `loadInputDevices` only restarts when `isCapturing` (`:1489`). A device swap on the start screen can leave the meters dead - which reads as "not connected to audio" - and nothing recovers it except manually picking a device.
- **Config-change no-op when IDs match.** The meeting configchange callback only calls `loadInputDevices()` (`AppModel.swift:981-988`); if the OS moved the route but resolved-device == `micEngineBoundDeviceID`, no restart happens. The watchdog eventually catches it (4s stall) - but only if frames had flowed since the last restart (`guard let last = self.lastMicAudioAt` at `:1119`).
- **No automatic recovery from persistent start failure.** `handleMicStartFailure` leaves `micEngine = nil` with a log line (`:1029-1038`); the startup health check ignores the `micEngine == nil` case (`:1169`). Dead mic persists until manual Refresh.
- **Failures are invisible.** All of this surfaces only in the backend log tail - no banner, no meter-adjacent "mic dead" state.
- Start-failure cleanup can leak: the catch in `startMeeting` calls `stopMeeting()`, which returns immediately because `isCapturing` was never set (`:1949-1963`) - backend/capture/mic started before the failure keep running. (GPT-5 finding.)

### A3. "Refresh does nothing" - confirmed, three ways
- On the start screen, `refreshMicrophones()` (`AppModel.swift:1144-1157`) only reloads device lists; the force-restart branch is gated on `isCapturing`. It never restarts the preview engines that drive the meters. The restart helper exists (`restartPreviewMicEngineForInputSwitch` `:1067`) - refresh just doesn't call it.
- Zero feedback in all cases: `.buttonStyle(.link)`, no spinner/tick. `isSwitchingInputDevice` is NEVER set true anywhere - dead flag, dead "Switching..." spinner, vestigial guards (`AppModel.swift:160`, `:1148`, `:1489`; `ContentView.swift:287-289`; `SessionView.swift:91-111`).
- Two confusable buttons: "Refresh sources" (`ContentView.swift:191`) = screen/window capture; "Refresh devices" (`:283`) = audio.

### A4. Rename inconsistency - confirmed, 4 surfaces / 3 patterns
| Surface | Interaction | Code |
|---|---|---|
| New Meeting title field | typed TextField | `ContentView.swift:172-176` |
| Recent meetings row | right-click context menu → sheet (undiscoverable) | `ContentView.swift:434-440` |
| Live session header | click the title → inline edit | `SessionView.swift:236-242` |
| Meeting viewer header | pencil button → sheet (title NOT clickable) | `MeetingViewer.swift:215, 225-231` |

Two duplicated model entry points: `renameMeeting` (`AppModel.swift:2633`) and `renameCurrentMeeting` (`:2663`). Recommendation: the SessionView inline click-to-edit pattern (commit on Enter/blur, Esc cancels, `SessionView.swift:254-279`) everywhere; one shared rename path; keep the pencil at most as a secondary trigger. Also: rename failures are silent - UI shows the new name even when the metadata write failed (`:2659`, `:2695`).

### A5. Live diarisation - drop it (all reviewers agree, including GPT-5)
- The live path runs the FULL pipeline (ASR + Senko diarisation + merge) on overlapping windows (new bytes + 30s context) of BOTH streams every interval, serialised behind `RUN_PIPELINE_LOCK` (`muesli_backend.py:365-507`). Debug builds pass `--live-interval 5` (`AppModel.swift:1785`), the heaviest possible config.
- **It is incoherent by construction:** Senko assigns per-window speaker ids with no cross-window identity - SPEAKER_00/01 flip identity every chunk. The emitter forwards raw labels (`:336-343`). This is the technical reason it "doesn't really work".
- Roughly a third of `muesli_backend.py` exists only for this: `LiveProcessor`, `TranscriptEmitter` cross-chunk bookkeeping, the `.pcm` side-channel + windowing, the lock, three CLI knobs. The fragile overlap-merge heuristics in `TranscriptModel.mergeSegment` exist solely to stitch the re-emissions.
- The stop-time whole-file finalize pass (`:460-462`) runs the full pipeline on the ENTIRE meeting, once per stream, synchronously before exit - fully redundant with `reprocess.py` and the reason "stop" stalls.
- Risk of removal: low. `reprocess.py` is already the authoritative transcript. Keep ASR-only live text with `speaker_id` = "Microphone"/"System"; do not delete diariser code until the new mode has soaked.

---

## B. Other findings (ranked)

1. **Meetings folder is 8.2GB** - `--keep-wav` is unconditional (`AppModel.swift:1783`), ~400MB/hour meeting. Add a setting or auto-prune after successful reprocess.
2. **Muesli temp folders accumulate** in $TMPDIR since May (`saveTranscriptFiles` `AppModel.swift:1313-1326`); never cleaned.
3. **`diarisation.py` (Sortformer, ~470 lines) is dead in production** - every entry point defaults to senko and the app never overrides. Biggest safe deletion; keep `DiarSegment`.
4. **Three near-identical pipeline orchestrations** (`cli.py:146`, `muesli_backend.py:236`, `reprocess.py:120`) - consolidate to one function taking injected persistent models.
5. **`MEETING_START` handled twice leaks writers** (`muesli_backend.py:689-698`, no guard).
6. **Broken-pipe blindness**: `emit_jsonl`/`StdoutWriter` swallow all write errors (`:85-86`, `:97-98`) - backend transcribes into a dead pipe until stdin EOF.
7. **`reprocess.py` aborts a whole batch on one missing stream file** (`:283-286`) instead of degrading.
8. **Transcript row identity churn**: `TranscriptSegment.id = UUID()` regenerated on re-created segments + whole-array replaces recreate ForEach identity (`TranscriptModel.swift:7`).
9. **SpeakerIdentifier.swift (1,431 lines)** - ~40 heuristic functions cleaning Ollama output, hardcoded `gemma3:27b`. Second god-file; candidate for later decomposition + model config.
10. UX polish set: export icon differs between Session (`arrow.down`) and Viewer (`arrow.up`); copy-confirm glyph differs; disabled buttons don't say why; `NewMeetingView.body` ~350 lines; `formatDuration` copy-pasted; `MeetingViewer` has 19 `@State` props driving two near-identical async flows; 60s title rollover ticker can rewrite the title mid-type.
11. `stopHomeLevelPreviewNow` mutates `captureEngine.systemLevel` directly (`AppModel.swift:923`) - layering smell.
12. `retiredEngines` 2s retention in MicEngine can transiently stack engines during a swap storm (by design; low).

---

## C. Recommended sequence (safety-first, no big bang)

Each step is independently shippable and testable; stop at any point with the app better than before.

**Phase 1 - performance, no behaviour change:**
1. Backend: hold ONE persistent `ASRModel` (+ diarizer) for process lifetime, inject into `run_pipeline`. Biggest single win, low risk.
2. Frontend: extract `micLevel`/`systemLevel` + debug counters into a small `AudioLevelsModel` observed ONLY by the meters, throttled to ~10-15Hz. Stop relaying `onLevelsUpdated` into `AppModel.objectWillChange`.
3. Stop relaying `transcriptModel.objectWillChange` through AppModel; views observe `TranscriptModel` directly. Drop `@EnvironmentObject` from `TranscriptRow` (pass name + callback).
4. Vectorise `rms_int16` with numpy.

**Phase 2 - kill live diarisation:**
5. Backend flag `--live-asr-only` (default on from the app): same JSONL schema, `speaker_id` = stream label; skip diariser + lock + 30s context; delete the finalize pass (reprocess supersedes it).
6. Simplify `TranscriptModel.ingest` accordingly (partials tracked per stream, in place; keep unrelated partials when a final lands; stable row identity; coalesced publishes).

**Phase 3 - device UX:**
7. Give the preview engine parity: configchange observer + watchdog or, simpler, make `refreshMicrophones()` also restart the preview path when not capturing.
8. Delete `isSwitchingInputDevice` or actually set it; give Refresh real feedback (spinner→tick); rename the two refresh buttons ("Refresh capture sources" / "Refresh audio devices"); surface mic-dead state next to the meter, not just the log tail.
9. Fix `startMeeting` failure cleanup (explicit teardown instead of relying on `stopMeeting`'s `isCapturing` guard).

**Phase 4 - consistency + decay:**
10. One rename interaction everywhere (SessionView inline pattern), one model entry point, error surfaced on failure.
11. Retire Sortformer path; consolidate the three pipeline orchestrations; delete `muesli_backend_demo.py` or move to examples/.
12. Disk hygiene: keep-wav setting / auto-prune, clean old Muesli temp folders on launch.

**Phase 5 (only after the above are stable) - decompose AppModel (3,126 lines):**
`AudioController` (engines, devices, watchdog, levels) → `BackendSession` (process, writer, stdout parsing, stop handshake) → `MeetingStore` (metadata, history, rename/delete/resume/export). TranscriptModel stays independent.
