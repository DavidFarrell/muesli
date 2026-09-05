# Reliability implementation ledger

Goal opened 5 September 2026 at David's request. Completion requires all audit issues corrected and an independent final Astra adversarial review with no P2-or-higher findings. Hardware claims require hardware evidence. This ledger does not replace those gates.

## Baseline

- Audited source: `64cbcafd9d046c65f89934588cd1d13d29a17351`.
- Audit/evidence checkpoint: `b072fd6`.
- GitHub main verified to match the audited source at implementation start.
- User authorizes implementation, PR creation, resolving reviewer disagreements, and merging only after Astra approval. Ask David only at a true impasse.

## Work and gates

| Item | Implementation | Independent review | Verification / remaining work |
|---|---|---|---|
| F1 bounded non-UI microphone ingress | In progress, `codex/capture-ingress` | Pending | Actual callback while UI blocked; no per-buffer UI task |
| F6 original capture timestamps, shared clock, streaming converter | In progress with F1 | Pending | Jitter, partition, restart, cross-source clock tests; hardware alignment |
| F8 independent starvation detection and genuine completion deadline | In progress, `codex/capture-watchdog` | Pending | Off-UI probe test while MainActor blocked; stale event tests |
| F7 authoritative local recording independent of inference | Design reviewed; in progress | Pending implementation review | Read-only inference; committed prefix; crash recovery; disk failure |
| F2/F3/F4/F5 unified preview/recording supervision and honest recovery | Pending | Pending | Same-ID invalidation, absent-engine retries, system reset, coalescing |
| F8 complete lifecycle bounds and artifact outcomes | Pending | Pending | Start/stop callback timeouts, no competing owner, MP4 completion, interrupted metadata |
| F9 session-scoped screenshot/video integrity | Pending | Pending | Resume, late callbacks, failed writes, common time |
| Offline mode/assets and Merge handoff | Discovery underway | Pending | Disconnected runtime; locate/review external Merge; recoverable source deletion |
| Distribution, build identity, CI, clean install/rollback | Pending | Pending | Signed release/runtime manifest; exact supported matrix |
| Duration/media integrity semantics | Pending | Pending | Recorded duration excludes idle gaps between sessions |
| Whole-project adversarial Astra audit | Not started | Must be a fresh review | No open P2+ findings |
| Release soak/hardware matrix | Not started | Pending | Actual wall time/routes and controlled signals, no substitute from unit tests |

## Design decisions

- Keep independent system and mic capture; a mic replacement must not stop system capture or MP4.
- Use a shared source clock created before capture, with original buffer timestamps. Explicitly journal sleep transitions; do not relabel delayed buffers with delivery time.
- Swift owns source PCM and a committed-byte manifest. Python reads only committed prefixes in the new mode; it must never open source files for writing or delete them. Existing framed-stdin mode remains supported for compatibility/tests.
- Authoritative events reach disk before UI delivery. Meter messages are disposable; transcript/control events are not.
- A timeout must report uncertainty and retain ownership correctly. Cancelling a Task is not proof that a framework operation ended.
- Preserve existing meetings/readers; schema changes need migration/defaults and tests.

## Review record

No implementation has yet passed independent review or been merged.
