# Engineering Spec: Backend I/O Scalability Fix

**Author:** David (via Claude)
**Date:** 2026-01-19
**Priority:** Critical
**Estimated Effort:** 2-4 hours

---

## 1. Problem Statement

### Current Behavior

The live transcription loop in `muesli_backend.py` has an **O(N²) I/O bottleneck** that causes the application to become unusable for meetings longer than ~15-20 minutes.

**Root Cause:** Every `live_interval` (default 15 seconds), the function `write_wav_from_pcm()` reads the **entire cumulative PCM file from byte 0**, converts it to WAV, and feeds it to the ASR pipeline.

```python
# Current code in muesli_backend.py
def write_wav_from_pcm(snapshot: StreamSnapshot, temp_dir: Path) -> Optional[Path]:
    # ...
    with open(snapshot.pcm_path, "rb") as pcm:
        while remaining > 0:
            chunk = pcm.read(min(1024 * 1024, remaining))  # Always starts at byte 0
            # ...
```

### Impact

| Meeting Length | PCM Size (16kHz mono) | I/O per interval | Cumulative I/O |
|---------------|----------------------|------------------|----------------|
| 5 min | 9.6 MB | 9.6 MB | ~200 MB |
| 30 min | 57.6 MB | 57.6 MB | ~7 GB |
| 1 hour | 115 MB | 115 MB | ~28 GB |
| 2 hours | 230 MB | 230 MB | ~110 GB |

At 1+ hours, the disk I/O and ASR processing time will exceed the `live_interval`, causing the pipeline to lag indefinitely or exhaust system resources.

---

## 2. Solution Overview

### Approach: Incremental Processing with Context Overlap

Instead of processing the entire file every interval, we will:

1. **Track the last processed byte position**
2. **Seek to that position minus a context buffer** (30 seconds)
3. **Read only from there to EOF**
4. **Apply a timestamp offset** so results align with global meeting time
5. **On finalize (Stop), process the full file** to get clean speaker IDs

### Why 30 Seconds of Context?

We considered a "pure sliding window" approach (only process new audio), but this has critical flaws:

| Approach | ASR Quality | Diarization Quality | Complexity |
|----------|-------------|---------------------|------------|
| Full file every time | ✅ Best | ✅ Best | ❌ O(N²) |
| Pure sliding window (no overlap) | ❌ Words cut at boundaries | ❌ Speaker fragmentation | Medium |
| **Incremental + 30s overlap** | ✅ Good | ⚠️ Acceptable live, fixed on finalize | ✅ Low |

**ASR models (Parakeet/Whisper) need context** to:
- Determine if a sound is the start or end of a word
- Apply language model predictions based on preceding words
- Handle words that span chunk boundaries (e.g., "comput|er")

30 seconds provides sufficient context while keeping I/O bounded.

### Diarization Trade-off

Speaker diarization builds voice embeddings and clusters them. With chunked processing:
- **Live mode:** Speaker IDs may drift between chunks (Speaker A in chunk 1 → Speaker B in chunk 2)
- **Finalize mode:** Running on the full file at the end produces globally consistent speaker IDs

**This is acceptable for a PoC** because:
1. Users primarily care about the final transcript
2. The Swift frontend already handles segment deduplication via `TranscriptModel.insertSegment()`
3. Speaker names can be edited by the user regardless

---

## 3. Implementation Details

### 3.1 New Function: `write_wav_chunk()`

Replace the existing `write_wav_from_pcm()` or add a new function that accepts a `start_byte` parameter.

**File:** `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`

```python
def write_wav_chunk(
    snapshot: StreamSnapshot,
    temp_dir: Path,
    start_byte: int = 0
) -> Optional[Path]:
    """
    Writes PCM data from start_byte to EOF as a WAV file.

    Args:
        snapshot: Stream metadata including pcm_path, size_bytes, sample_rate, channels
        temp_dir: Directory for temporary WAV file
        start_byte: Byte offset to start reading from (default 0 = full file)

    Returns:
        Path to temporary WAV file, or None if no data to process
    """
    if snapshot.size_bytes <= start_byte:
        return None

    # Calculate bytes per frame for alignment
    bytes_per_frame = BYTES_PER_SAMPLE * snapshot.channels

    # Align start_byte to frame boundary
    start_byte = (start_byte // bytes_per_frame) * bytes_per_frame

    temp = tempfile.NamedTemporaryFile(
        suffix=".wav",
        prefix="muesli_chunk_",
        dir=temp_dir,
        delete=False
    )
    temp_path = Path(temp.name)
    temp.close()

    with wave.open(str(temp_path), "wb") as wav_out:
        wav_out.setnchannels(snapshot.channels)
        wav_out.setsampwidth(BYTES_PER_SAMPLE)
        wav_out.setframerate(snapshot.sample_rate)

        with open(snapshot.pcm_path, "rb") as pcm:
            pcm.seek(start_byte)  # <-- KEY CHANGE: Seek to position

            while True:
                chunk = pcm.read(1024 * 1024)  # 1MB at a time
                if not chunk:
                    break
                wav_out.writeframes(chunk)

    return temp_path
```

### 3.2 Modify `LiveProcessor` Class

Add state tracking for the last processed position and implement the context overlap logic.

```python
# Constants (add near top of file)
CONTEXT_SECONDS = 30.0  # Overlap for ASR context

class LiveProcessor:
    def __init__(self, ...):
        # ... existing init ...
        self._last_processed_byte = 0  # <-- NEW: Track position

    def _maybe_process(self, finalize: bool) -> bool:
        snapshot = self._snapshot()
        if not snapshot or snapshot.size_bytes <= 0:
            return False

        total_bytes = snapshot.size_bytes

        # Calculate bytes per second for this stream
        bytes_per_sec = snapshot.sample_rate * snapshot.channels * BYTES_PER_SAMPLE
        total_duration = total_bytes / bytes_per_sec

        # Determine read strategy
        if finalize:
            # FINALIZE: Process full file for clean speaker IDs
            read_start_byte = 0
            timestamp_offset = 0.0
        else:
            # LIVE: Check if enough new data
            new_bytes = total_bytes - self._last_processed_byte
            new_duration = new_bytes / bytes_per_sec

            if new_duration < self._live_interval:
                return False  # Not enough new audio yet

            # Calculate start position with context overlap
            context_bytes = int(CONTEXT_SECONDS * bytes_per_sec)
            read_start_byte = max(0, self._last_processed_byte - context_bytes)
            timestamp_offset = read_start_byte / bytes_per_sec

        # Write the chunk
        temp_wav = write_wav_chunk(snapshot, self._output_dir, read_start_byte)
        if not temp_wav:
            return False

        try:
            with RUN_PIPELINE_LOCK:
                merged = run_pipeline(
                    input_path=temp_wav,
                    diar_backend=self._diar_backend,
                    diar_model=self._diar_model,
                    asr_model=self._asr_model,
                    language=self._language,
                    gap_threshold=self._gap_threshold,
                    speaker_tolerance=self._speaker_tolerance,
                    timestamp_offset=timestamp_offset,  # <-- NEW PARAMETER
                    verbose=self._verbose,
                )
        except Exception as exc:
            emit_jsonl({
                "type": "error",
                "stream": self._stream_name,
                "message": str(exc)
            }, self._state.stdout_lock)
            return False
        finally:
            Path(temp_wav).unlink(missing_ok=True)

        # Update state AFTER successful processing
        self._last_processed_byte = total_bytes
        self._last_processed_duration = total_duration

        # Emit results (existing logic)
        self._emitter.emit_transcript(
            merged,
            current_duration=total_duration,
            finalize=finalize,
            stream_name=self._stream_name
        )

        return True
```

### 3.3 Modify `run_pipeline()` Function

Add the `timestamp_offset` parameter and apply it to all timestamps.

```python
def run_pipeline(
    input_path: Path,
    diar_backend: str,
    diar_model: str,
    asr_model: str,
    language: str,
    gap_threshold: float,
    speaker_tolerance: float,
    timestamp_offset: float = 0.0,  # <-- NEW PARAMETER
    verbose: bool = False,
) -> "MergedTranscript":
    """
    Run ASR + Diarization pipeline on audio file.

    Args:
        ...
        timestamp_offset: Seconds to add to all timestamps (for chunked processing)
    """
    # ... existing setup and ASR code ...

    asr = ASRModel(asr_model)
    transcript = asr.transcribe(temp_wav, language=language)

    # Apply offset to ASR results
    if timestamp_offset > 0:
        for word in transcript.words:
            word.start += timestamp_offset
            word.end += timestamp_offset

    # ... existing diarization code ...

    if diar_backend == "senko":
        diarizer = SenkoDiariser(diar_model, verbose=verbose)
    else:
        diarizer = SortformerDiariser(diar_model, verbose=verbose)

    segments = diarizer.diarise(temp_wav)

    # Apply offset to diarization results
    if timestamp_offset > 0:
        for seg in segments:
            seg.start += timestamp_offset
            seg.end += timestamp_offset

    # Merge (existing logic)
    merged = merge_transcript_with_diarisation(
        transcript,
        segments,
        gap_threshold=gap_threshold,
        speaker_tolerance=speaker_tolerance,
    )

    return merged
```

---

## 4. Complexity Analysis

### Before (Current)

| Operation | Frequency | Cost | Total for T seconds |
|-----------|-----------|------|---------------------|
| Read PCM | Every 15s | O(T) | O(T²) |
| Write WAV | Every 15s | O(T) | O(T²) |
| ASR | Every 15s | O(T) | O(T²) |

### After (Fixed)

| Operation | Frequency | Cost | Total for T seconds |
|-----------|-----------|------|---------------------|
| Read PCM | Every 15s | O(15s + 30s context) = O(1) | O(T) |
| Write WAV | Every 15s | O(45s) = O(1) | O(T) |
| ASR | Every 15s | O(45s) = O(1) | O(T) |
| Finalize | Once | O(T) | O(T) |

**Result:** Total I/O reduced from O(T²) to O(T)

---

## 5. Testing Plan

### Unit Tests

1. **`write_wav_chunk()` with start_byte=0** → Should produce identical output to original function
2. **`write_wav_chunk()` with start_byte > 0** → Should produce valid WAV with correct duration
3. **`timestamp_offset` application** → Verify all word.start, word.end, seg.start, seg.end are offset correctly

### Integration Tests

1. **Short meeting (5 min)** → Should work identically to before
2. **Long meeting (30+ min)** → Should remain responsive (no lag)
3. **Finalize produces clean speaker IDs** → Compare live vs finalized transcript

### Manual Verification

1. Run a 30-minute test meeting
2. Monitor memory/CPU usage (should remain stable)
3. Verify transcript quality at chunk boundaries
4. Verify speaker IDs are unified after Stop

---

## 6. Files to Modify

| File | Changes |
|------|---------|
| `muesli_backend.py` | Add `write_wav_chunk()`, modify `LiveProcessor`, add `CONTEXT_SECONDS` constant |
| `muesli_backend.py` | Modify `run_pipeline()` to accept and apply `timestamp_offset` |

**No changes required to:**
- Swift frontend (already handles overlapping segments via `insertSegment()`)
- ASR module (`asr.py`)
- Diarization modules
- Merge module

---

## 7. Rollback Plan

If issues arise, revert to the original `write_wav_from_pcm()` behavior by:
1. Setting `read_start_byte = 0` always
2. Setting `timestamp_offset = 0` always

This restores original behavior (with O(N²) cost) for debugging.

---

## 8. Future Improvements (Out of Scope)

These are not required for this fix but noted for future consideration:

1. **Smarter deduplication in Emitter** - Currently relies on frontend; could dedupe in backend
2. **Adaptive context window** - Use shorter context for fast speech, longer for slow
3. **Incremental diarization** - Research if speaker embeddings can be accumulated across chunks
4. **The merge.py O(N·M) issue** - Use binary search for word→segment assignment (only matters for very long meetings with full-file processing)
