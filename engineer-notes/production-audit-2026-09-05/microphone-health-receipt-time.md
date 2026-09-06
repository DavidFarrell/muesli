# Microphone health uses receipt time

The UI mailbox can publish its last packet after a long MainActor stall. Previously
both meeting and preview callbacks advanced `CaptureSourceHealth` using the UI's
current time. The independent watchdog could not repair that timestamp because
its snapshot had the same frame count, and Refresh could report verified audio
without restarting a microphone whose final packet was already 15 seconds old.

`DeliveryResult.receivedAt` now carries the forwarding actor's original receipt
Date. Latest-only mailbox coalescing preserves the latest packet's receipt while
retaining first-frame/resumption flags. Microphone callbacks and watchdog snapshot
observations share the same freshness rule. Stale observations cannot reset the
retry budget, clear warnings, or advertise recovery; fresh converted digital silence
remains progress. Existing source/generation/invalidation checks remain in place.
Refresh rechecks microphone freshness during its observation loop and immediately
before returning. System capture retains its separate silence-tolerant policy.

## Verification

`reproductions/check_mic_health.py` extracts the actual complete AppModel meeting
callback, preview callback and Refresh method, plus actual CaptureSourceHealth.
Peripheral UI/device enumeration and native restart are synthetic stand-ins; a
restart records admission and fails promptly. There is no hardware-backed AppModel
initialization, recording, route change or real sleep. Run from the repository:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 engineer-notes/production-audit-2026-09-05/reproductions/check_mic_health.py --source-ref 2163311
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 engineer-notes/production-audit-2026-09-05/reproductions/check_mic_health.py
```

The unchanged baseline reports healthy/cleared warnings for both 15-second-old
callbacks, and meeting Refresh returns verified with zero recovery admissions
(exit 1). Corrected source refuses both stale callbacks, retains warnings, admits
meeting recovery and returns an unverified/failed result (exit 0). Fresh delivery
and an old-generation callback are also checked.

Actual Xcode tests additionally exercise forwarder receipt/snapshot equality,
real mailbox coalescing before MainActor publication with a controlled observation
time, repeated stale snapshots without retry reset, same-generation fresh recovery,
and invalidated/retired generation refusal. This is deterministic liveness and
UI-publication coverage, not all-day hardware qualification or a new wall-clock
adjustment policy.
