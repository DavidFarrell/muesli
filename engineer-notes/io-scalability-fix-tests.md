# I/O Scalability Fix - Unit Tests

## Summary
- Added a lightweight unit test script for `write_wav_chunk` and `timestamp_offset` behavior.
- Executed via system Python with module stubs because the backend venv Python aborts in this sandbox.

## Test Script
- Path: `backend/fast_mac_transcribe_diarise_local_models_only/scripts/test_io_scalability.py`
- Covers:
  - Full-file chunk writes
  - Offset chunk writes
  - Timestamp offset application in `run_pipeline` (with dummy ASR/diarizer/merge)

## Command Used
```bash
PYTHONPATH=backend/fast_mac_transcribe_diarise_local_models_only/src \
  /usr/bin/python3 backend/fast_mac_transcribe_diarise_local_models_only/scripts/test_io_scalability.py
```

## Notes
- `backend/fast_mac_transcribe_diarise_local_models_only/.venv/bin/python` aborts with SIGABRT in this sandbox, so tests were run with system Python and stubbed imports.
