# Phase 3.4 - Audio Format Propagation

## Problem
The backend assumed a single sample rate and channel count for all audio streams. When system and mic streams differ (or when metadata specifies per-stream formats), the pipeline could interpret the audio with the wrong format, causing alignment or duration errors.

## Fix
- Parse per-stream audio format metadata from the `meeting_start` message.
- Store `system_sample_rate`, `system_channels`, `mic_sample_rate`, and `mic_channels` in backend state.
- Use the appropriate format when creating stream writers, snapshots, and duration calculations.

## Implementation Details
- `meeting_start` now reads explicit per-stream values from `meeting_meta` with safe fallbacks to the shared `sample_rate` and `channels` defaults (and ultimately to 48kHz/mono).
- Stream writers are created using the per-stream values.
- Duration and snapshot calculations now reference the per-stream sample rate and channel count instead of the shared defaults.

## Why This Works
Each stream is processed with the correct format, ensuring the diarization and ASR pipeline interprets timestamps and audio durations accurately. The fallback logic guarantees compatibility with older metadata that only provides a single format.

## Files
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
