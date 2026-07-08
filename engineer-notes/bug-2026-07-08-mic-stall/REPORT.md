# Bug: mic stream silently dead for the last third of a recording (8 Jul 2026)

**Severity: data loss.** A 90-minute recording (meeting "2026_07_08 - psc 1") lost the mic channel for its final ~31 minutes. The user's mic was working perfectly in the actual Teams call throughout - the loss is entirely inside Muesli's capture path. The UI gave no indication anything was wrong.

Artefacts in this folder: `backend.log` (full, no speech content) and `meeting.json`, copied from the meeting folder before it was processed and trashed. Line numbers below refer to `backend.log`.

## Environment

- Input device: **DJI Wireless Mic Rx** (USB receiver), `id=397`, stable for the whole session - the device never changed or disappeared.
- Output device: **Bose QC35 II** (Bluetooth), `id=377`.
- Engine: `avaudioengine`, `vpio=false`, mode=follow, unpinned.
- Backend command (log line 3): `diarise_transcribe.muesli_backend --emit-meters --transcribe-stream both --output-dir .../audio --keep-wav --live-asr-only`.
- Streams: mic + system, both 16 kHz mono per `meeting.json`.

## Observed outcome

- Recording ran 12:59:17 → 14:29 BST, `duration_seconds` 5396.
- `system.wav`: full length, 5393.6 s. Healthy.
- `mic.wav`: **frozen at 3534.08 s** (~58.9 min, i.e. ~13:58:11 BST) - file mtime 13:59, never grew again despite ~31 more minutes of recording. Every later `live_process stream=mic` line still reports `duration=3534.08s`.
- Live transcript agrees: last mic-attributed turn ends at 3531 s; system turns continue to 5391 s.

## Timeline from backend.log

Three `heartbeat.STALL` → watchdog-recovery cycles. The first recovered cleanly; the second is where the file died; the third "succeeded" at the engine level but the file never resumed.

1. **~45 s in (lines 56-75):** `engine.configchange` → mic frames freeze → `heartbeat.STALL sinceLastFrameMs=4136` → "Mic stopped delivering audio - restarting capture." → rebuild gen=5, `engine.tap.format channels=4 sampleRate=16000.0` → `mic.first-frame` → frames flow AND `mic.wav` keeps growing. **Recovery worked.**

2. **~3534 s in (lines 3413-3434) - the fatal one:** `engine.configchange` → frames freeze at 13805 → `heartbeat.STALL sinceLastFrameMs=4618` → rebuild gen=6 → **`engine.tap.format channels=4 sampleRate=44100.0`** (the only restart that came up at 44.1 kHz; every other start/restart negotiated 16000.0) → `engine.start.ok`, `mic.first-frame msSinceStart=110` → heartbeats resume with frames incrementing but `micLevel=0.000` initially. **From this moment `mic.wav` never grows again.**

3. **~3784 s in (lines 3585-3608):** another `engine.configchange` → frames freeze at 1875 → STALL → rebuild gen=7, tap format **back to 16000.0**, `mic.first-frame msSinceStart=258`, heartbeats show healthy nonzero `micLevel` (0.022, 0.058...) - the tap is demonstrably receiving real audio again - **yet `mic.wav` still never grows.** The writer/pipeline never re-attached.

4. From then to the end (line ~4915), heartbeats continue for ~27 minutes reporting `engineAlive=true`, frames incrementing, plausible mic levels - while the mic file stays dead. Clean stop at 14:29 (`engine.stop`, `meeting_stopped`, backend exit 0).

## Reading of the failure

Two distinct defects compound:

1. **The gen=6 restart negotiated a 44.1 kHz tap against a pipeline expecting 16 kHz.** Whatever consumes the tap (converter → PCM writer → pipe into `muesli_backend`) most plausibly errored or rejected the format at that point, silently. That's the moment the writer died.
2. **Writer death is unrecoverable and invisible.** The gen=7 restart restored a correct 16 kHz tap with real audio, but nothing re-attached or restarted the mic writer/feed into the backend - and nothing noticed. The watchdog only watches **tap frame delivery** (`sinceLastFrameMs`), so once frames flow into a dead sink it declares victory. There is no watchdog on the thing that actually matters: **bytes appended to mic.pcm/wav** (or turns reaching the live transcript). The system stream's writer was unaffected throughout, so per-stream isolation of the writer failure is also evident.

Likely real-world trigger for the config changes: the first Teams call ended at ~13:58-14:00 and the next one started - Teams releasing/reacquiring audio devices renegotiates formats, and the Bluetooth Bose headset switching HFP/A2DP profiles is exactly the kind of event that produces `engine.configchange` storms and a transient 44.1 kHz default. (10 configchange events in the log; the boundary between back-to-back Teams calls matches the fatal one.)

## Suggested fix directions

- Re-create/re-attach the mic writer + backend feed as part of every watchdog rebuild, and treat a tap-format mismatch (anything ≠ expected 16 kHz mono) as a hard error to convert/renegotiate rather than something to pass through silently.
- Second-level watchdog on the sink: if the tap delivers frames but mic.pcm hasn't grown for N seconds, rebuild the writer path and surface a visible UI warning ("mic not being recorded") rather than staying green.
- `backend.log` lines carry no timestamps - the whole reconstruction above had to be inferred from durations and file mtimes. Prefix log lines with wall-clock time.

## Repro pointers

Start a recording with a USB mic + Bluetooth output, then force device config churn mid-recording (join/leave a Teams call, or toggle the BT headset between HFP/A2DP). Watch for a restart that negotiates a non-16 kHz tap and check whether mic.pcm keeps growing afterwards.
