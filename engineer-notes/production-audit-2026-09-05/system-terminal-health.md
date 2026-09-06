# System terminal evidence precedes progress publication

The native system relay records a framework stop before its MainActor notification
runs. Previously `CaptureEngine.supervise` ignored that stored flag. A Refresh
observation or coalesced meter callback could promote old conversions to healthy
while the stop notification remained queued. A pending conversion failure had the
same meter-publication window, although the watchdog already detected it.

The relay now retains the first native stop error and admits one notification per
generation. Supervision, meter publication and the queued notification all inspect
the same retained terminal/problem evidence before allowing successful progress.
A later notification cannot duplicate the published error or reset reserved retry
admission. Existing generations and native-operation quarantine still govern
recovery. System silence does not become a callback-age failure.

This change affects health/recovery reporting. Native stop and conversion problems
already reached the source recorder independently of UI delivery; the reproduction
does not claim another missing PCM interval or a hardware cause.

## Deterministic reproduction

`reproductions/check_system_stop_health.py` extracts the actual relay stop method,
CaptureEngine supervision, meter callback and queued stop callback. Its framework,
converted-buffer and UI containers are stand-ins; no SCStream is started. It delays
the stop notification until after the supervision/display observation.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 engineer-notes/production-audit-2026-09-05/reproductions/check_system_stop_health.py --source-ref 19dd0b7
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 engineer-notes/production-audit-2026-09-05/reproductions/check_system_stop_health.py
```

Baseline exits 1: both observers report healthy after a recorded native stop;
the meter also reports healthy after a recorded conversion failure. Corrected
source exits 0: all three refuse verified health, repeated observation plus late
notification reports the stop once, and successful digital silence remains healthy.
The result mapping uses the actual AudioRefreshResult type; the microphone health
reproduction separately exercises the complete AppModel Refresh method.

An actual Xcode relay test blocks MainActor, records 100 synthetic native stop
callbacks on a worker, verifies immediate retained error and exactly one downstream
notification, then confirms retirement preserves that evidence and a new relay has
no inherited stop. It uses no recording hardware, real route changes or sleep.
