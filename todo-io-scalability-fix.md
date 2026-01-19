# TODO: Backend I/O Scalability Fix

## Phase 0 - Prep
- [ ] Locate current `write_wav_from_pcm()` usage in `muesli_backend.py`.
- [ ] Confirm live processor path and finalize path in `muesli_backend.py`.

## Phase 1 - Incremental WAV Writing
- [ ] Add `CONTEXT_SECONDS = 30.0` constant.
- [ ] Implement `write_wav_chunk(snapshot, temp_dir, start_byte=0)` with seek + frame alignment.
- [ ] Keep existing full-file writer available for finalize flow (or route through `start_byte=0`).

## Phase 2 - Live Processor State
- [ ] Add `_last_processed_byte` (and optionally `_last_processed_duration`) to `LiveProcessor`.
- [ ] In `_maybe_process(finalize=False)`, compute bytes/sec and enforce `live_interval` on new audio duration.
- [ ] Compute `read_start_byte = max(0, last_processed - context_bytes)`.
- [ ] Compute `timestamp_offset = read_start_byte / bytes_per_sec`.
- [ ] After successful processing, set `_last_processed_byte = total_bytes`.

## Phase 3 - Timestamp Offsets in Pipeline
- [ ] Add `timestamp_offset` parameter to `run_pipeline()`.
- [ ] Apply offset to ASR word timestamps.
- [ ] Apply offset to diarization segments.
- [ ] Pass `timestamp_offset` from live processor when chunked.

## Phase 4 - Finalize Behavior
- [ ] Ensure finalize path uses full-file processing (`read_start_byte = 0`, `timestamp_offset = 0`).
- [ ] Confirm `_last_processed_byte` update only after success.

## Phase 5 - Testing
- [ ] Unit: `write_wav_chunk` start_byte=0 matches old output.
- [ ] Unit: `write_wav_chunk` start_byte>0 produces valid WAV with expected duration.
- [ ] Unit: `timestamp_offset` shifts words and segments.
- [ ] Integration: 5 min run matches prior behavior.
- [ ] Integration: 30+ min run stays responsive (no lag).
- [ ] Manual: verify speaker IDs correct after finalize.

## Rollback
- [ ] Document quick rollback: force `read_start_byte=0` and `timestamp_offset=0`.
