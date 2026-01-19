# I/O Scalability Fix Implementation

## Summary
- Implemented incremental WAV chunk writing with seek + context overlap.
- Live processor now tracks last processed byte and applies timestamp offsets for chunked processing.
- Pipeline applies timestamp offsets to ASR words and diarization segments.

## Files
- Updated: `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
- Updated: `todo-io-scalability-fix.md`

## Notes
- Tests and rollback checklist items remain to be exercised/documented.
