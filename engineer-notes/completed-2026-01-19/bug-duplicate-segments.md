# Bug: Duplicate and overlapping segments in transcript output

## Symptoms

Exported transcript contains:
1. **Exact duplicates** - Same text, same t0, slightly different t1
2. **Superseded fragments** - Partial segments that were later replaced by merged/corrected versions, but both appear in output
3. **Out of order segments** - Segments not sorted by timestamp

## Example from real output

```
Line 1: t=1.12-9.12   "Okay, so let's test to see whether this is working."
Line 2: t=1.12-9.20   "Okay, so let's test to see whether this is working."  ← duplicate
...
Line 8:  t=33.12-41.12  "transcription seems to be working. The permissions button is already at"
Line 9:  t=41.12-42.40  "the top right of"
Line 10: t=42.40-45.68  "the window, so we don't need it underneath the controls."
Line 11: t=33.20-61.92  "transcription seems to be working. The permissions button is already at the top right of the window, so we don't need it underneath the controls."
```

Line 11 is the corrected/merged version of lines 8-10, but all four appear in the output.

## Root cause hypothesis

The live transcription pipeline emits incremental segments as audio is processed. When more audio arrives, the backend may:
- Re-transcribe and emit a corrected version of earlier segments
- Merge previously fragmented segments into one

But the `TranscriptModel` on the Swift side (or the emitter on the Python side) doesn't:
- Deduplicate segments with matching t0
- Replace/remove segments that are superseded by a longer segment covering the same time range

## Where to look

**Python backend (`muesli_backend.py`):**
- `TranscriptEmitter.emit_transcript()` - Does it check for overlapping segments before emitting?
- `_last_emitted_t1` logic - May not handle re-transcription of earlier time ranges

**Swift app (`ContentView.swift`):**
- `TranscriptModel.ingest()` - Does it deduplicate when adding segments?
- `segments` array - Should probably replace/merge overlapping entries

## Suggested fix approaches

**Option A: Dedupe on ingest (Swift side)**
When a new segment arrives, check if any existing segment overlaps significantly (same t0 or contained time range). If so, replace the old one instead of appending.

**Option B: Dedupe on emit (Python side)**
Before emitting a segment, check if it supersedes a previously emitted segment. Only emit if it's genuinely new content.

**Option C: Dedupe on export**
When building the export, sort by t0 and remove segments that are fully contained within another segment's time range.

Option A or B fixes it at the source. Option C is a band-aid but would at least produce clean exports.

## Acceptance criteria

- No duplicate lines with same/similar t0 in exported transcript
- When a segment is re-transcribed with corrections, only the final version appears
- Segments are ordered by t0 in the output
