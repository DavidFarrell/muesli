# Todo Item 9 - Reduce ffmpeg dependency / 16k capture

## Goal
Reduce reliance on ffmpeg for live processing by capturing at 16 kHz when possible and skipping normalization when input is already 16 kHz mono.

## What I changed
### Swift (capture + metadata)
- Requested 16 kHz in `SCStreamConfiguration`.
- Added format detection + buffering so we send `meeting_start` with the **actual** sample rate/channel count (not just requested).
- Buffered audio until `meeting_start` is sent, then flushed buffered frames.
- Added warnings when actual format differs from requested.

### Python (backend normalization)
- Added `is_wav_16k_mono` helper.
- `run_pipeline` now skips ffmpeg normalization if input is already 16 kHz mono; otherwise falls back to ffmpeg.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
  - `CaptureEngine` now requests 16 kHz, buffers audio until meeting start, detects actual format, and flushes on enable.
  - `startMeeting()` now waits for format, sends `meeting_start` with actual values, then enables audio output.
- `/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/audio.py`
  - Added `is_wav_16k_mono`.
- `/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
  - `run_pipeline` skips normalization when already 16 kHz mono.

## Notes for reviewer
- If the OS refuses 16 kHz, we log the mismatch and still send the actual sample rate to the backend to avoid incorrect timestamps.
- ffmpeg is still required when the input is not 16 kHz mono.
- Buffering prevents audio from being sent before `meeting_start` without dropping the first frames.
