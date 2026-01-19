# TODO: Backend I/O Scalability Fix

## Phase 0 - Prep
- [x] Locate current `write_wav_from_pcm()` usage in `muesli_backend.py`.
- [x] Confirm live processor path and finalize path in `muesli_backend.py`.

## Phase 1 - Incremental WAV Writing
- [x] Add `CONTEXT_SECONDS = 30.0` constant.
- [x] Implement `write_wav_chunk(snapshot, temp_dir, start_byte=0)` with seek + frame alignment.
- [x] Keep existing full-file writer available for finalize flow (or route through `start_byte=0`).

## Phase 2 - Live Processor State
- [x] Add `_last_processed_byte` (and optionally `_last_processed_duration`) to `LiveProcessor`.
- [x] In `_maybe_process(finalize=False)`, compute bytes/sec and enforce `live_interval` on new audio duration.
- [x] Compute `read_start_byte = max(0, last_processed - context_bytes)`.
- [x] Compute `timestamp_offset = read_start_byte / bytes_per_sec`.
- [x] After successful processing, set `_last_processed_byte = total_bytes`.

## Phase 3 - Timestamp Offsets in Pipeline
- [x] Add `timestamp_offset` parameter to `run_pipeline()`.
- [x] Apply offset to ASR word timestamps.
- [x] Apply offset to diarization segments.
- [x] Pass `timestamp_offset` from live processor when chunked.

## Phase 4 - Finalize Behavior
- [x] Ensure finalize path uses full-file processing (`read_start_byte = 0`, `timestamp_offset = 0`).
- [x] Confirm `_last_processed_byte` update only after success.

## Phase 5 - Testing
- [x] Unit: `write_wav_chunk` start_byte=0 matches old output.
- [x] Unit: `write_wav_chunk` start_byte>0 produces valid WAV with expected duration.
- [x] Unit: `timestamp_offset` shifts words and segments.
- [ ] Integration: 5 min run matches prior behavior.
- [ ] Integration: 30+ min run stays responsive (no lag).
- [ ] Manual: verify speaker IDs correct after finalize.

## Rollback
- [ ] Document quick rollback: force `read_start_byte=0` and `timestamp_offset=0`.
