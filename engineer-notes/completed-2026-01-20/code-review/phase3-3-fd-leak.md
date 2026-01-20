# Phase 3.3 - Backend File Descriptor Leak

## Problem
`open_stream_writer` opened a WAV file and then attempted to open a matching PCM file. If the PCM open failed (disk full, permissions, etc.), the WAV file descriptor remained open. Repeated failures could leak file descriptors and keep corrupted files open.

## Fix
- Wrapped PCM open in a `try/except` block and explicitly closed the WAV handle if the PCM open fails.

## Implementation Details
- `open_stream_writer` now opens the WAV, configures headers, then attempts to open the PCM file.
- On exception, the WAV handle is closed before re-raising the error.
- `close_stream_writer` already closes both handles; no changes required there.

## Why This Works
Closing the WAV handle on failure prevents descriptor leaks and avoids leaving partially created WAV files open. The behavior on success is unchanged.

## Files
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
