# I/O Scalability Fix - --no-live Indentation

## Summary
- Fixed indentation in the `--no-live` path so `run_pipeline` runs inside the `RUN_PIPELINE_LOCK` block.

## Files
- Updated: `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
