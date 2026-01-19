# Fix Notes - Per-stream sample rates

## Summary
Implemented per-stream sample rate/channel tracking so system + mic are written with correct WAV headers and normalized correctly.

## Swift changes
- CaptureEngine now tracks sample rate/channels separately for system and mic.
- Meeting start now includes `system_sample_rate`, `system_channels`, `mic_sample_rate`, `mic_channels` in metadata.
- Format detection waits for both streams (or timeout) and logs per-stream mismatches.

## Python changes
- BackendState now stores per-stream rates/channels.
- Writers are created with per-stream settings.
- `write_aligned_audio`, duration calculations, snapshot generation use per-stream rates.
- Finalization path (`no_live` and finalize) uses per-stream sample rate/channel.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/ContentView.swift`
- `/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`

## Verification checklist
- Debug log shows system + mic rate separately (e.g., 16k vs 48k).
- Both system and mic transcripts appear.
- If mic is 48k, ffmpeg normalization should run for mic only (system 16k skips).
