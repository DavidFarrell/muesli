# Todo Item 4 - Fix dual-stream transcript emission

## Goal
Ensure live transcript emission works when both system + mic streams are enabled by keeping per-stream state for emitted segments and partials.

## What I changed
- `TranscriptEmitter` now tracks `last_emitted_t1` and `last_partial` per stream key.
- Segment emission and partial updates use per-stream state to avoid cross-stream suppression.

## Files touched
- `/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
  - `TranscriptEmitter.__init__` uses dicts for per-stream state.
  - `emit_transcript` reads/writes per-stream `last_emitted_t1` and `last_partial`.

## Notes for reviewer
- With both streams enabled, segments from one stream no longer prevent emissions from the other.
- Speaker IDs remain stream-scoped (`stream:speaker`) as before.
