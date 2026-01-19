# Batch Re-Diarization Phase 1.0 - Backend CLI

## Summary
- Added a standalone `muesli-reprocess` CLI (`reprocess.py`) that runs batch ASR + diarization on meeting audio and outputs JSON results.
- Implemented `--stream system|mic|both` with a merged, timestamp-sorted turn list for the combined case.

## Approach
- Reused existing ASR and diarization modules to avoid duplicating model logic.
- Emitted JSON status lines (`type: status`) for progress updates and a final `type: result` payload with turns, speakers, and duration.
- Added a dedicated entrypoint in `pyproject.toml` to keep this command separate from the live backend.

## Files
- Added: `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/reprocess.py`
- Updated: `backend/fast_mac_transcribe_diarise_local_models_only/pyproject.toml`
