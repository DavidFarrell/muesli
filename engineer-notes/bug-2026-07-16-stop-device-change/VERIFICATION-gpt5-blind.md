# GPT-5 blind independent RCA (Codex CLI, 16 Jul 2026)

> Run blind: GPT-5 (codex-cli 0.144.1, read-only sandbox) was given the incident evidence + repo access and explicitly forbidden from reading RCA-2026-07-16.md. Its independent verdict below concurs with the RCA: hypothesis B. Preserved verbatim from the session's final answer.

# Independent RCA verdict

The evidence strongly supports **(B): the Python backend never reached or progressed through the framed-stdin read loop far enough to process `meeting_start`**. Swift capture was healthy, but persistence was not.

The durable files are created by Python at `meeting_start` and extended for every PCM frame—not assembled at stop. An empty `audio/` directory therefore rules out a stop-only flush failure. The exact place where Python wedged is underdetermined; a pre-read-loop module import, especially `parakeet_mlx`/MLX initialization, is the leading code-level candidate, but there is no Python stack sample proving it.

## 1. Audio path and file-creation timing

### Microphone path

1. `AVAudioEngine` installs an input-node tap using the device’s native format ([MicEngine.swift:127](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/MicEngine.swift:127)).

2. Each tap buffer is downmixed and resampled to 16 kHz mono int16 by `AudioConverterHelper`. This explicitly handles multichannel USB receivers such as the DJI device ([AudioConverterHelper.swift:37](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AudioConverterHelper.swift:37), [AudioConverterHelper.swift:64](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AudioConverterHelper.swift:64)).

3. The converted `Data` is passed through the mic engine callback ([MicEngine.swift:272](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/MicEngine.swift:272)) to `MicAudioForwarder.deliver()` ([AppModel.swift:1259](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:1259)).

4. `MicAudioForwarder` computes RMS, increments its Swift-side frame count, and calls `writer.send(...)` ([MicAudioForwarder.swift:248](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/MicAudioForwarder.swift:248), [MicAudioForwarder.swift:252](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/MicAudioForwarder.swift:252)).

### System-audio path

1. ScreenCaptureKit requests 16 kHz mono system audio ([CaptureEngine.swift:270](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/CaptureEngine.swift:270)).

2. `AudioSampleExtractor` converts incoming buffers to int16 mono ([CaptureEngine.swift:29](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/CaptureEngine.swift:29)).

3. PTS is calculated relative to the first ScreenCaptureKit audio buffer ([CaptureEngine.swift:380](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/CaptureEngine.swift:380)), and enabled buffers are sent through the same `FramedWriter` ([CaptureEngine.swift:430](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/CaptureEngine.swift:430), [CaptureEngine.swift:453](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/CaptureEngine.swift:453)).

### Swift-to-Python transport

`BackendProcess` connects a `Pipe` to the Python process’s stdin ([BackendProcess.swift:7](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:7), [BackendProcess.swift:34](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:34)). `FramedWriter` serializes:

```text
message type | stream id | PTS microseconds | payload length | payload
```

onto a private serial queue ([BackendProcess.swift:147](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:147), [BackendProcess.swift:169](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:169)).

Crucially, `send()` only asynchronously enqueues work ([BackendProcess.swift:157](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:157)). Thus the incident log’s `Sent meeting_start` ([backend.log:10](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:10>)) means “Swift enqueued the frame,” not “Python read or acknowledged it.”

### Who creates `audio/*`, and when?

Swift creates only the `audio/` directory ([AppModel.swift:2171](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2171)). Python creates:

- `system.wav`
- `system.pcm`
- `mic.wav`
- `mic.pcm`

immediately upon processing `MSG_MEETING_START` ([muesli_backend.py:815](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:815), [muesli_backend.py:834](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:834)).

Every accepted audio message is then written immediately to both WAV and PCM, with PCM explicitly flushed per frame ([muesli_backend.py:245](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:245)). Stop closes the writers and finalizes WAV headers ([muesli_backend.py:888](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:888), [muesli_backend.py:896](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:896)). `--keep-wav` preserves the WAVs, while PCM is normally deleted after successful completion ([muesli_backend.py:969](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:969)).

Therefore: **WAV creation is start-time and WAV/PCM growth is per-frame. Stop is not when the recording is materialized.**

One secondary defect is visible in startup ordering: mic output is enabled as soon as its engine starts ([AppModel.swift:1289](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:1289)), while `meeting_start` is enqueued later ([AppModel.swift:2371](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2371)). A healthy backend can therefore receive and discard a few mic frames before its writers exist. That does not explain 26 minutes of loss, but it should be fixed.

## 2. Root cause verdict

### (A) Stop-time flush killed: rejected

This is inconsistent with the implementation and evidence:

- Processing `meeting_start` alone would create four filesystem entries, even before useful audio.
- PCM is flushed after every frame, and WAV is written incrementally.
- `--keep-wav` prevents normal cleanup of the final recordings.
- The directory was already empty during the meeting, with `lsof` showing no audio file open.
- No Python `meeting_started` status ever appears. Python emits it immediately after opening both writers ([muesli_backend.py:845](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:845)).
- No stdout event reached `transcript_events.jsonl`; Swift writes every backend stdout line there before interpreting it ([AppModel.swift:657](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:657)).

There was consequently no durable backend state for stop to flush.

There probably was a large in-memory backlog in Swift: each `send()` closure retains its payload while queued. Once the pipe filled behind a non-reading child, subsequent meeting audio accumulated on `muesli.framed-writer`. That backlog was not an intentional recoverable recording, had no durable representation, and could not drain while the backend remained wedged. It does not make this a normal stop-flush failure.

### (B) Backend did not consume the protocol: strongly supported

The decisive chain is:

1. Swift starts Python and creates the framed writer ([AppModel.swift:2258](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2258), [AppModel.swift:2291](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2291)).

2. Swift’s mic path remains healthy for the full meeting: native tap format, `engine.start.ok`, first frame, and then continuously rising frame counts with nonzero RMS ([backend.log:8](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:8>), [backend.log:11](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:11>), [backend.log:716](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:716>)).

3. Python never handles `meeting_start`: otherwise the files would exist and `meeting_started` would be emitted.

4. Python remains alive through stop. Swift waits 120 seconds, gets no exit, and calls `terminate()` ([AppModel.swift:2634](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2634)); incident evidence at [backend.log:734](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:734>)).

5. A non-reading child fills its stdin pipe quickly. `FileHandle.write` at [BackendProcess.swift:180](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:180) then blocks rather than throwing. Because it blocks on the writer’s serial queue:

   - later audio accumulates behind it;
   - `onWriteError` never fires;
   - `meetingStop` and `closeStdinAfterDraining()` remain queued behind the blocked write ([AppModel.swift:2550](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2550));
   - Python never sees either stop or EOF.

**Verdict:** the direct root cause is an alive but non-consuming Python subprocess, followed by an undetected full-pipe/backpressure failure in Swift.

### Exact Python wedge: underdetermined

The available artifacts cannot distinguish among:

- a hang during module import;
- a hang in the small amount of initialization before the read loop;
- the process being externally suspended;
- an extremely unlikely failure to schedule the Swift writer queue.

The leading code candidate is a pre-loop import. `muesli_backend.py` imports audio libraries and ASR before entering `main()` ([muesli_backend.py:22](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:22)); `asr.py` imports `parakeet_mlx` at module scope ([asr.py:11](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/asr.py:11)). Only after all imports does `main()` create its helper threads and enter stdin reading ([muesli_backend.py:771](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:771), [muesli_backend.py:804](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:804)).

A `parakeet_mlx`/MLX import hang fits: process alive, no stdout/stderr, no read, no files. But it is still an inference. A `sample`/spindump of the live Python PID was needed to identify the exact frame.

This is not ASR model-weight loading: weights are lazy-loaded only inside `_ensure_loaded()` ([asr.py:62](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/asr.py:62)), which cannot be reached until PCM has already been accepted and a live-ASR window begins.

The earlier 8 July bug is a different failure class: Python was demonstrably writing files, but a generation-relative PTS reset caused later frames to fall behind the existing write cursor and be discarded ([RCA-2026-07-08.md:7](/Users/david/git/ai-sandbox/projects/muesli/engineer-notes/bug-2026-07-08-mic-stall/RCA-2026-07-08.md:7), [RCA-2026-07-08.md:22](/Users/david/git/ai-sandbox/projects/muesli/engineer-notes/bug-2026-07-08-mic-stall/RCA-2026-07-08.md:22)). Here Python never created the writers, so PTS alignment code was never reached.

## 3. Bose output-device change

It did not cause the data loss.

The output switch appears only after `engine.stop` at [backend.log:717](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:717>). The listener’s own subsequent state says `isCapturing=false`, `boundID=0`, and `willRestart=false` ([backend.log:723](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/backend.log:723>)).

The code agrees:

- output changes enter `handleOutputDeviceChange()` ([AppModel.swift:391](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:391));
- it returns without restarting anything unless `isCapturing && transcribeMic` ([AppModel.swift:1627](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:1627)).

By that time the backend had failed to create any audio file for 26 minutes. The Bose transition is temporally adjacent to stop, not causal.

It also did not plausibly cause the backend’s stop hang. `meetingStop` and stdin close were already queued behind the blocked `FramedWriter`; changing the output route has no connection to the Python pipe.

## 4. Why the UI meter bounced while live ASR stayed empty

The visible meter is entirely Swift-side and occurs before confirmed delivery:

- RMS is calculated in `MicAudioForwarder.deliver()` ([MicAudioForwarder.swift:248](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/MicAudioForwarder.swift:248)).
- The Swift frame count is incremented immediately afterward.
- `writer.send()` merely enqueues work asynchronously.
- The RMS result is then published to the UI by `onMicAudioDelivered()` ([AppModel.swift:748](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:748), [AppModel.swift:774](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:774)).

There is no acknowledgment that Python read or persisted that frame. Thus the meter proved only:

```text
DJI input → AVAudioEngine tap → conversion → MicAudioForwarder
```

It did not prove:

```text
FramedWriter write completed → Python read → PCM/WAV append → ASR
```

Live ASR snapshots the Python-side PCM file and returns immediately when no writer/file or zero bytes exist ([muesli_backend.py:539](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:539), [muesli_backend.py:561](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:561)). Its duration notification is issued only after `write_aligned_audio()` accepts a frame ([muesli_backend.py:847](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:847)).

So zero ASR and empty audio are the same failure, not separate VAD/recognition failures. Silence or poor recognition would still have created files, emitted `meeting_started`, and emitted backend meter events.

The “completed” metadata is also not proof of successful recording. Finalization unconditionally computes duration from wall-clock elapsed time and sets `.completed`, even with zero transcript segments ([AppModel.swift:2904](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2904), [AppModel.swift:2910](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2910), [AppModel.swift:2917](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2917)). That exactly explains the incident metadata at [meeting.json:3](</Users/david/Library/Application Support/Muesli/Meetings/2026_07_16 - heiko/meeting.json:3>).

## 5. Morning `pkill -9` and relaunch

There is no established code-level causal connection.

Each meeting creates a fresh `Process`, pipe, `BackendProcess`, and writer ([AppModel.swift:2258](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2258), [AppModel.swift:2305](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2305)). A full application relaunch also recreates `AppModel` and its queues. Ordinary process-local locks, Python globals, pipes, file descriptors, and Dispatch queues cannot survive SIGKILL.

The Python ASR cache is explicitly process-local ([asr.py:14](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/asr.py:14)). Killing Python discards it rather than poisoning the next process.

A narrow speculative mechanism remains: if the killed Python process was inside MLX/Metal initialization, a dependency or driver bug could conceivably leave external driver state or a persistent lock/cache that later blocks `import parakeet_mlx`. Likewise, a persistent on-disk dependency cache could theoretically have been damaged. Nothing in this repository demonstrates either mechanism, and no Python stack, import trace, or reproduction exists.

Therefore my verdict is:

- **pkill is a weak temporal clue, not a root cause;**
- it becomes credible only if “kill backend during import/model work, then relaunch” reproduces the import hang;
- do not put it in the causal chain without that reproduction or a stack trace.

## 6. Top three fixes

### 1. Add an independent, durable Swift-side audio sink — effort M–L

Tee mic and system int16 PCM to crash-recoverable local files before attempting the backend pipe:

- mic anchor: [MicAudioForwarder.swift:227](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/MicAudioForwarder.swift:227)
- system anchor: [CaptureEngine.swift:430](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/CaptureEngine.swift:430)

Prefer append-only raw PCM or CAF with periodic synchronization and enough metadata to reconstruct WAVs after relaunch. Python reprocessing can then regenerate transcripts even if live ASR is dead.

This is the strongest data-loss fix because it removes the Python process and pipe from the only durable recording path.

### 2. Require a backend readiness/`meeting_started` acknowledgment — effort S–M

After enqueuing `meeting_start`, wait for Python’s `meeting_started` status before:

- enabling mic/system forwarding;
- setting `isCapturing=true`;
- presenting the meeting as successfully recording.

Relevant anchors:

- current unacknowledged send: [AppModel.swift:2371](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2371)
- current output enabling: [AppModel.swift:2381](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:2381)
- Python acknowledgment: [muesli_backend.py:845](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:845)

Timeout after a few seconds, terminate the child, and fail meeting startup visibly. This would have converted the incident from 26 minutes of silent loss into an immediate start failure.

It also fixes the current protocol-ordering bug where mic frames may be sent before `meeting_start`.

### 3. Add sink-level backpressure and accepted-byte watchdogs — effort M

The existing heartbeat observes only Swift tap delivery ([AppModel.swift:1403](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:1403)). Add:

- queue-depth and last-successful-write completion telemetry to `FramedWriter`;
- a bounded backlog or spill-to-disk policy;
- Python acknowledgments containing accepted bytes/sample indices per stream;
- a visible fatal alert if Swift frames advance while completed writes or Python accepted-byte counters do not.

Anchor the completion measurement after the payload write at [BackendProcess.swift:180](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/BackendProcess.swift:180), and emit accepted counters where Python currently finishes each stream append at [muesli_backend.py:847](/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py:847).

A blocked `write()` must be treated as a failure, not merely wait forever for EPIPE. The present error handler only runs after an exception ([AppModel.swift:649](/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/AppModel.swift:649)), so it cannot detect an alive-but-non-reading child.

As targeted hardening, I would also lazy-import `parakeet_mlx` inside `_ensure_loaded()` rather than at module scope and add startup-stage status markers. That is worthwhile, but it is not a substitute for the three protections above because the exact Python wedge site remains unproven.
