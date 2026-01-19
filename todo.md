# TODO (Next Steps)

- [x] PRD-grade graceful stop: add `sendSync` for `meetingStop`, drain writer queue, then close stdin and wait for backend exit (timeout + terminate fallback).
- [x] PRD-grade transcript persistence: append backend JSONL events to disk as they arrive (crash-safe), not only on stop.
- [x] Write final transcript artifacts to a temp folder on stop (and surface the path in UI/logs), while keeping the meeting folder copy.
- [x] Fix backend dual-stream emission by tracking `last_emitted_t1` and partials per stream in `TranscriptEmitter`.
- [x] Reset transcript state on meeting start (clear segments and decide whether speaker names carry over).
- [x] Make meeting folder naming collision-proof (auto-suffix `-01`, `-02`, …).
- [x] Add “Copy transcript” and “Export transcript.txt/jsonl” controls in the Session UI.
- [x] Clarify audio scope for window capture (warn in UI or separate audio filter so system audio is always captured).
- [x] Reduce live ffmpeg dependency: capture at 16 kHz where possible and/or skip normalization when already 16 kHz mono.
- [ ] Harden `AudioSampleExtractor` buffer list allocation for multi-buffer formats.
- [x] Dedupe overlapping transcript segments on ingest to avoid duplicates/out-of-order exports.
