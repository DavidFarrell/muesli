## 1) Review of what we have said so far, and corrections

### The strategic choice still holds: ScreenCaptureKit is the right foundation

Given you want both (a) system audio + mic and (b) screen access for screenshots or recording, ScreenCaptureKit remains the cleanest single “capture surface” for Muesli.

### Two important corrections to the earlier Swift-side spec

1. **Do not default to 48 kHz unless you need it. Set 16 kHz.**
   ScreenCaptureKit supports specific audio sample rates including **16,000 Hz**, and falls back to 48 kHz if you set an unsupported value. This is documented. ([Apple Developer][1])
   Because your current diarisation + ASR pipeline normalises to 16 kHz mono anyway, you should capture **16 kHz, mono** directly in the stream configuration to remove a whole class of resampling overhead and avoid repeatedly calling ffmpeg in the live loop.

2. **Use the system picker instead of building your own window/display selection UI**
   Apple now provides **SCContentSharingPicker** as a system picker UI for capture selection. ([Apple Developer][2])
   You can still offer “Display” vs “Window” choices in your UI, but the actual selection should go through the OS picker for consistency and fewer edge cases.

### Confirmed API points (so we are not guessing)

* `captureMicrophone` exists on `SCStreamConfiguration` and is **macOS 15+**. ([Apple Developer][3])
* `excludesCurrentProcessAudio` exists and does what we want (avoid feedback / self-capture). ([Apple Developer][4])
* `sourceRect` exists for capture region cropping. ([Apple Developer][5])
* `SCScreenshotManager.captureSampleBuffer(...)` exists for screenshots from a content filter. ([Apple Developer][6])
* `SCRecordingOutputConfiguration` exists (macOS 15+) for writing a recording to a file. ([Apple Developer][7])
* `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()` are the canonical “check and request” primitives for screen recording permission checks. ([Apple Developer][8])

One nuance: there are real-world reports of recurring prompts / nags for Screen Recording in macOS 15, especially with older capture approaches. Treat this as a UX risk and build your onboarding and “re-check permissions” flow to be resilient. ([AAPL Ch.][9])

---

## 2) In-depth review of your code as it stands now

You effectively have **two deliverables** in the uploaded bundle:

* `fast_diarize/` (your working transcription + diarisation package, plus a streaming backend entrypoint)
* `muesli/` (engineering specs + a demo backend script)

The good news is you have already built the hard part on the Python side: a framed stdin protocol and a live JSONL stdout protocol.

### 2.1 What is solid and worth keeping

#### A) CLI pipeline is cleanly separated

`src/diarise_transcribe/cli.py` keeps the file-based workflow intact and readable. That is important for “maintain functionality”.

#### B) Your streaming backend protocol is pragmatic and testable

`src/diarise_transcribe/muesli_backend.py`:

* Fixed-size binary header + payload for audio chunks and control events
* JSONL output for UI events

That is exactly the right split. It is easy to debug, easy to stream, and easy to extend without breaking everything.

#### C) You already handle timestamp alignment and gaps

`write_aligned_audio()` is doing the right kind of defensive work:

* inserts silence if there is a gap
* discards overlaps if timestamps jitter backwards

This is a necessary defensive layer for real capture.

---

### 2.2 Critical issues to fix (these will bite immediately)

#### P0: Live processing reloads models repeatedly

In `muesli_backend.py`, `run_pipeline()` creates new `ASRModel()` and new diariser objects every time it is called. That is fine for one-shot CLI execution but it is a problem in the live processor because `_maybe_process()` calls it repeatedly.

Concretely:

* `run_pipeline()` is called inside `LiveProcessor._maybe_process()`
* every call constructs:

  * `asr = ASRModel(asr_model)`
  * a new diariser object

This almost certainly reloads models repeatedly (or at least reinitialises heavy objects). It will destroy latency and stability.

**Fix**: Create a persistent “live pipeline” object:

* initialise ASR and diariser once at backend startup
* reuse them for every snapshot

Minimal refactor direction:

* create `class LivePipeline:` holding:

  * `self.asr = ASRModel(...)`
  * `self.diariser = ...`
* change `run_pipeline(...)` into a method on that class, or accept the instances as parameters.

This change must not affect `cli.py` behaviour.

#### P0: The live loop reprocesses the whole recording on every update

Your current design snapshots the entire PCM file and re-runs diarisation + ASR on the full audio, every `--live-interval` seconds.

That will work for a short meeting, but it scales badly:

* file copy time grows linearly
* ASR time grows linearly
* you will eventually fall behind realtime

**For v0.1**, you can keep it, but you should do two things now:

1. increase default `--live-interval` to something realistic (eg 20-30s) for stability
2. add a guard: if the previous processing run is still going, skip starting a new one

Your `LiveProcessor` already prevents concurrent runs by only having one thread, but it can still permanently lag. Emit a `status` event when you skip processing due to lag.

#### P0: Flush per chunk is a performance killer

You do `writer.pcm.flush()` for every audio chunk. If chunk sizes are small (they often are), this is a lot of syscalls and will create backpressure up the pipe to the Swift app.

**Fix**: remove per-chunk flush, and flush:

* on a timer (eg every 0.5-1.0s), or
* right before snapshotting in `snapshot_stream()`

Because `snapshot_stream()` runs in the live processing thread, you can coordinate with the writer via shared state:

* add a `StreamWriter.flush()` method
* call it during snapshot

#### P1: RMS computation is inefficient

`compute_rms_i16le()` uses `struct.unpack` which allocates a tuple of all samples. That is avoidable.

**Fix**: use NumPy if present (it is already a dependency):

* `arr = np.frombuffer(pcm, dtype=np.int16)`
* compute RMS without huge tuple allocation

This matters because meters run at capture rate.

#### P1: Unused import adds confusion

`from diarise_transcribe.cli import run_pipeline as file_pipeline` is unused in `muesli_backend.py`. Remove it.

---

### 2.3 Feature gaps versus the target Muesli experience

#### A) Backend transcribes only one stream

You currently support `--transcribe-stream {system,mic}`.

But your intended UX is a meeting transcript that includes:

* “Them” (system audio, diarised)
* “Me” (mic audio)

If you do not handle both, the transcript will always be incomplete.

**Spec-level decision**: Add `--transcribe-stream both` and make it the default for Muesli.

Suggested behaviour:

* System stream:

  * diarise + ASR
* Mic stream:

  * ASR only (speaker fixed as `me`)
* Merge by timestamps into a single event stream for the UI

You already have merge logic (`merge.py`) for word-to-speaker within one stream. For two streams, you need a simpler merge:

* treat “mic transcript segments” and “system diarised segments” as two sorted lists by time
* interleave them

#### B) You have screenshot events, but nothing persists them

You pass screenshot events through as JSONL.
That is good, but you should also store them (append to `transcript.jsonl` in the meeting folder) so that:

* if the UI crashes, you still have the artefacts
* you can run offline processing later

This can be done in Swift (recommended) or in the backend.

#### C) There is no “meeting folder replay” command yet

You will want a deterministic offline command:

* input: meeting folder containing:

  * `system.wav` and `mic.wav` (or pcm)
  * screenshots folder
  * transcript.jsonl (optional)
* output:

  * final transcript json + txt + srt

This keeps your existing CLI intact while adding a Muesli-specific workflow.

---

## 3) Updated engineering spec: from current state to the full Muesli target

### 3.1 Target architecture

```text
+--------------------------------------------------------------+
|                         Muesli.app (SwiftUI)                 |
|--------------------------------------------------------------|
| Onboarding + Permission health checks                         |
| Meeting manager (folder, metadata, session state)             |
| SCContentSharingPicker source selection                       |
| ScreenCaptureKit capture engine (audio + mic + optional video)|
| Screenshot scheduler (every 5s)                               |
| Backend process manager (spawn + stdin write + stdout read)   |
| Transcript model + speaker rename UI                          |
+----------------------------|---------------------------------+
                             |
                             | framed binary protocol (stdin)
                             v
+--------------------------------------------------------------+
|             diarise_transcribe.muesli_backend (Python)        |
|--------------------------------------------------------------|
| Stream writers (system + mic) -> WAV/PCM artefacts            |
| LivePipeline (models loaded once)                             |
| Periodic processing -> JSONL events (stdout)                  |
| Optional: persist transcript.jsonl (or Swift does it)         |
+--------------------------------------------------------------+
```

**Key implementation choices:**

* Capture **16 kHz mono** from ScreenCaptureKit to match the models and reduce backend load. ([Apple Developer][1])
* Use ScreenCaptureKit mic capture (macOS 15+) so system and mic share a consistent timing basis. ([Apple Developer][3])
* Use the system picker for selection. ([Apple Developer][2])

---

### 3.2 Meeting folder layout

Keep the meeting folder as the single source of truth:

```
Meetings/
  2026-01-18-meeting/
    meta.json
    transcript.jsonl
    speakers.json
    recording.mp4                  (optional)
    audio/
      system.wav
      mic.wav
      system.pcm                   (optional, debug)
      mic.pcm                      (optional, debug)
    screenshots/
      t+0000.000.png
      t+0005.000.png
      ...
```

Where:

* `transcript.jsonl` is append-only (events from backend and UI actions)
* `speakers.json` maps `speaker_id -> chosen name`

---

### 3.3 Capture and selection requirements

#### Source selection

Use `SCContentSharingPicker.shared` for selection. ([Apple Developer][2])

Supported:

* **Single display**
* **Single window**
* **Multiple windows** (optional, later)
* **Single application** (optional, later)

Note: “tab capture” is not a first-class ScreenCaptureKit concept. What you can deliver reliably:

* capture a browser window, optionally crop to a region with `sourceRect` ([Apple Developer][5])
* document the workaround: “move tab to its own window”

#### Dedicated area capture

Implement “Area” as:

* user selects a display
* user draws a rectangle overlay
* set `SCStreamConfiguration.sourceRect` to that rect ([Apple Developer][5])

---

### 3.4 Audio capture configuration

**Stream configuration**

* `capturesAudio = true`
* `captureMicrophone = true` (macOS 15+) ([Apple Developer][3])
* `sampleRate = 16000` ([Apple Developer][1])
* `channelCount = 1`
* `excludesCurrentProcessAudio = true` ([Apple Developer][4])

This choice has a direct knock-on benefit:

* backend can skip ffmpeg resampling in the live loop (still keep ffmpeg path for the original CLI).

---

### 3.5 Screenshots

Use `SCScreenshotManager.captureSampleBuffer(...)` or `captureImage(...)` every 5 seconds. ([Apple Developer][6])

Filename must include:

* seconds since meeting start, to millisecond precision:

  * `t+0035.000.png`

Also emit a screenshot event to backend (and persist in transcript.jsonl).

---

### 3.6 IPC protocol (keep what you have, extend minimally)

Your existing header is good:

`<BBqI` = type, stream, pts_us, payload_len
Little-endian, fixed 14-byte header.

**Keep it**, but extend meeting_start metadata:

Meeting start JSON should include:

* `protocol_version: 1`
* `sample_format: "s16le"`
* `sample_rate: 16000`
* `channels: 1`

This makes the backend reject incompatible streams early with a clear `error` event.

Add one message type:

* `5 = speaker_map_update` (optional)

  * payload: JSON `{ "speaker_id": "...", "name": "..." }`
  * only needed if you want the backend to write “final transcript with names” itself
  * otherwise do renaming purely in Swift UI

---

## 4) Concrete changes required in your Python project (while keeping current functionality)

Everything below is designed so that:

* `diarise-transcribe` CLI keeps working as-is
* `muesli-backend` becomes robust and efficient

### 4.1 Refactor: load models once in `muesli_backend.py`

Add a new object:

* `class LivePipeline:`

  * holds `ASRModel` and diariser instance
  * exposes `process(audio_wav_path) -> MergedTranscript`

Then:

* instantiate it once in `main()`
* pass it into `LiveProcessor`

This alone is a big stability step.

### 4.2 Skip ffmpeg normalisation when already 16 kHz mono

In `run_pipeline()` (or `LivePipeline.process()`):

* if input WAV is already 16 kHz mono s16le, do not call `normalise_audio()`
* otherwise use the existing ffmpeg path

This means:

* live capture path (16 kHz mono) becomes much lighter
* file-based CLI keeps using ffmpeg normalisation as before

### 4.3 Add `--transcribe-stream both`

Update:

* `TranscribeStream` enum to include `both`
* stream writers already exist for both system and mic, so it is mostly orchestration

Implement:

* system transcript: diarise + ASR
* mic transcript: ASR only, speaker fixed to `me`
* merge the two segment lists into one event stream

### 4.4 Remove per-chunk flush

Replace per-chunk `flush()` with:

* flush before snapshotting (or on a timer)
* track bytes written in memory, so you can meter progress without flushing

### 4.5 Speed up RMS

Replace `struct.unpack` RMS with NumPy RMS.

### 4.6 Add a replay tool (new entrypoint, does not replace the old CLI)

Add a new console script, for example:

* `muesli-replay --meeting-dir <path>`

It should:

* read `audio/system.wav` and `audio/mic.wav`
* read `screenshots/` paths (optional)
* produce final outputs:

  * `final_transcript.json`
  * `final_transcript.txt`
  * `final_transcript.srt`

This avoids contorting the original `diarise-transcribe` interface.

---

## 5) SwiftUI app implementation spec (the “next part” you asked for)

You do not yet have Swift code in the uploaded bundle, only specs. This is the next build step.

### 5.1 Project setup

* macOS app target, SwiftUI lifecycle
* Minimum deployment target: **macOS 15** (matches `captureMicrophone` availability) ([Apple Developer][3])
* Add entitlements:

  * Microphone capability (if sandboxed)
* Info.plist:

  * `NSMicrophoneUsageDescription` (required)

There is no equivalent Info.plist key for screen recording in the same way as mic/camera, so onboarding must explain what the OS prompt means. (This matches real-world developer experience; you cannot rely on a plist string the way you can for mic.) ([Stack Overflow][10])

### 5.2 Permissions and onboarding

Implement a `PermissionsManager` that:

* checks:

  * screen: `CGPreflightScreenCaptureAccess()` ([Apple Developer][8])
  * mic: `AVAudioApplication.shared.requestRecordPermission` (or equivalent)
* requests:

  * screen: `CGRequestScreenCaptureAccess()` ([Apple Developer][8])
  * mic: standard request flow

UI requirements:

* first-run wizard
* “re-check permissions” always accessible
* include a “Open System Settings” deep link (practical)

### 5.3 Source selection

Use `SCContentSharingPicker.shared`. ([Apple Developer][2])

Configuration:

* allow window and display selection (single window, single display)
* optionally add single application later

### 5.4 Capture engine

Implement `CaptureEngine`:

* creates an `SCStream` with the chosen filter
* configures audio:

  * sampleRate 16000 ([Apple Developer][1])
  * channelCount 1
  * capturesAudio true
  * captureMicrophone true ([Apple Developer][3])
  * excludesCurrentProcessAudio true ([Apple Developer][4])
* receives sample buffers for `.audio` and `.microphone`
* converts to `s16le` bytes
* sends framed messages to backend stdin

Timestamping:

* meeting start is defined as the PTS of the first received audio buffer (system or mic)
* compute `pts_us = (bufferPTS - startPTS)` in microseconds
* use that exact `pts_us` for audio frames and screenshot events

### 5.5 Screenshot scheduler

Implement with `SCScreenshotManager.captureSampleBuffer(contentFilter:configuration:...)` every 5 seconds. ([Apple Developer][6])

Save PNG and emit screenshot event to backend.

### 5.6 Transcript UI model

Implement:

* `TranscriptModel` storing:

  * segments: `{speaker_id, t0, t1, text}`
  * partials
  * speaker map `{speaker_id -> display_name}`
* Ingest backend JSONL events:

  * `segment`, `partial`, `speakers`, `meter`, `status`, `error`, `screenshot`
* Speaker rename:

  * update the map only (historic entries update automatically at render time)
  * persist to `speakers.json`

### 5.7 Backend process manager

Spawn your existing backend entrypoint:

* recommended: call `uv run muesli-backend ...` (developer workflow)
* pass `--output-dir <meeting/audio>`
* set `--transcribe-stream both`
* optionally `--emit-meters`

Read stdout line-by-line and push to `TranscriptModel`.

Persist `transcript.jsonl` in Swift:

* append every JSONL line the backend emits
* append UI-side events too (speaker renames, meeting start/stop)

---

## 6) Tests: what to add now so this stays defensive

### 6.1 Python tests (pytest)

Add tests that do not require ML models:

1. **Protocol framing decode**

* given a byte stream containing multiple framed messages, ensure:

  * header parse is correct
  * payload boundaries are respected
  * partial reads are handled correctly

2. **Alignment logic**

* feed audio chunks with:

  * contiguous timestamps
  * a gap
  * a backwards overlap
* verify output PCM length and silence insertion

3. **Meter RMS correctness**

* generate known sine wave samples, verify RMS is within tolerance

4. **LivePipeline caching**

* monkeypatch ASRModel initialisation and assert it is called once across multiple process runs

### 6.2 Swift unit tests

You can unit test without invoking ScreenCaptureKit:

1. **FramedWriter correctness**

* encode header + payload
* verify byte layout matches the Python `<BBqI` expectation

2. **Timestamp conversion**

* given synthetic CMTime values, confirm `pts_us` conversion is correct and monotonic

3. **TranscriptModel rename**

* ingest segments for `spk0`, rename `spk0` to “Alice”
* confirm rendered display strings update for old segments

4. **JSONL parsing robustness**

* feed unknown event types and ensure they are ignored (or surfaced as warnings) without crashing

### 6.3 End-to-end “works at all” checks (manual but scripted)

Make these part of your build checklist:

1. Start meeting, play audio from YouTube:

* system meter moves
* backend writes `audio/system.wav`
* transcript shows system segments

2. Speak into mic:

* mic meter moves
* backend writes `audio/mic.wav`
* transcript includes “me” segments

3. Screenshot every 5 seconds:

* files appear in `screenshots/` with correct `t+` names
* screenshot events appear in transcript.jsonl

4. Deny permission test:

* deny screen recording, confirm onboarding blocks start and explains fix
* deny mic, confirm onboarding blocks mic capture but can still run system capture if you choose to support that mode

---

## 7) The concrete “delta spec”: what to change in your repo right now

### In `fast_diarize/src/diarise_transcribe/muesli_backend.py`

* [ ] Remove unused import `file_pipeline`
* [ ] Implement `LivePipeline` caching models
* [ ] Add `TranscribeStream.both`
* [ ] Add “skip ffmpeg if already 16k mono”
* [ ] Remove per-chunk flush, flush on snapshot/timer
* [ ] Replace RMS with NumPy implementation
* [ ] Add protocol version and sample format validation

### Add new entrypoint

* [ ] `muesli-replay` for offline meeting folder processing (keep `diarise-transcribe` unchanged)

### In the new Swift app repo/folder (not present yet)

* [ ] Implement SwiftUI app with:

  * onboarding
  * meeting start/stop
  * SCContentSharingPicker
  * CaptureEngine at 16 kHz mono
  * screenshot scheduler
  * backend process manager
  * transcript UI with renaming and persistence

---

If you want, I can take the Python side first and write the exact patch-level changes (as a structured diff) for `muesli_backend.py` to address the P0 issues (model caching, both-stream transcription, skip ffmpeg, no per-chunk flush).

[1]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate?utm_source=chatgpt.com "sampleRate | Apple Developer Documentation"
[2]: https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker?utm_source=chatgpt.com "SCContentSharingPicker | Apple Developer Documentation"
[3]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone?utm_source=chatgpt.com "captureMicrophone | Apple Developer Documentation"
[4]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio?utm_source=chatgpt.com "excludesCurrentProcessAudio | Apple Developer Documentation"
[5]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect?utm_source=chatgpt.com "sourceRect | Apple Developer Documentation"
[6]: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturesamplebuffer%28contentfilter%3Aconfiguration%3Acompletionhandler%3A%29?utm_source=chatgpt.com "captureSampleBuffer(contentFilter:configuration ..."
[7]: https://developer.apple.com/documentation/screencapturekit/screcordingoutputconfiguration?utm_source=chatgpt.com "SCRecordingOutputConfiguration - Apple Developer"
[8]: https://developer.apple.com/forums/thread/732726?utm_source=chatgpt.com "Understanding CGRequestScreenCaptu… | Apple Developer ..."
[9]: https://applech2.com/archives/monthly-permission-prompt-macos-15-sequoia-screen-recording.html?utm_source=chatgpt.com "macOS 15 Sequoiaでは古いScreen Recording APIを利用した ..."
[10]: https://stackoverflow.com/questions/62641652/is-there-an-info-plist-key-privacy-usage-description-for-screen-recordin?utm_source=chatgpt.com "Is there an Info.plist key \"Privacy - ... Usage Description\" for ..."
