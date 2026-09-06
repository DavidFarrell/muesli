# Sleep/wake evidence and recovery

The host clock used by captured PCM does not represent time spent asleep. Previously a sleep/wake cycle could leave adjacent PCM timestamps, healthy-looking new callbacks, and no durable evidence of an unrecorded interval. This correction keeps the existing media clock and records the observed power transition separately.

## Ownership and delivery

`SystemPowerObserver` registers once for the process lifetime with `IORegisterForSystemPower` and installs a dedicated dispatch queue. It immediately acknowledges only CanSystemSleep and SystemWillSleep, before clock sampling, locks, callbacks or disk work. It never vetoes or intentionally delays sleep. SystemHasPoweredOn records wake; early SystemWillPowerOn is ignored. The SDK's macro constants are resolved by small C header functions rather than copied numeric values.

`CapturePowerLifecycle` receives notifications independently of MainActor. Its binding contains the adopted source UUID, immutable timeline and original recorder, or a distinct preview-lifecycle token. WillSleep captures that binding. Stop and failed-start teardown retire the binding before suspending. A later wake cannot write to or request recovery for a resumed source or a replacement preview lifecycle. Duplicate notifications do not create duplicate cycles. At most one UI mailbox delivery is queued; later cycles replace pending recovery intent without dropping their bounded source evidence.

The UI wake handler invalidates matching mic/system/preview health. Existing bounded capture supervision reconciles those sources, including silent system audio. Old-generation samples cannot clear wake invalidation; a new native generation must begin. Native timeouts retain their existing operation ownership. No new native recovery queue or permission to overlap quarantined operations is introduced.

## Persistent contract

Source manifest schema 1 gains optional `power_events` and `power_events_omitted` fields. Old manifests still decode. Events have `kind` (`will_sleep`, `did_wake`, `monitor_unavailable`, `binding_during_sleep`), `cycle_id`, `source_time_us`, `process_continuous_us` and optional `observed_pause_us`. Source time uses the existing source host epoch; the manifest's timeline offset remains separate. Continuous time is elapsed on the process's Swift `ContinuousClock`, not wall-clock time or an absolute boot timestamp. The pause is the interval between observed notifications, which includes delivery latency; it is not claimed exact kernel sleep duration or captured media.

A first or replacement source bound after observed WillSleep but before HasPoweredOn gets `binding_during_sleep`: its continuity is unknown, even when the earlier cycle belonged to no source. It does not borrow the old cycle identity, pause duration or recovery request. This closes the independent review's reproduced false-clean first-Start/Resume case while preserving the old-wake fence.

Recorder admission retains at most 128 pending events. The persisted ledger retains at most 128 events and a saturating omission count. The existing source queue synchronizes PCM and commits evidence and the incomplete marker through its normal manifest transaction. New post-wake frames cannot make the source complete. Pending or failed observer registration at source binding produces `monitor_unavailable`, so unavailable observation cannot silently certify continuity. Missing evidence because storage cannot commit remains an explicit recording failure; no notification promises that disk synchronization finished before forced sleep.

## Verification

- Nine actual synthetic power tests, plus 16 recorder tests, passed: `/private/tmp/muesli-power-tests-final.log`.
- Full 402-test Swift suite passed: `/private/tmp/muesli-power-full-tests.log`.
- The pending-sleep binding review correction passed 43 focused tests, including ten power, seventeen capture lifecycle and sixteen recorder tests: `/private/tmp/muesli-power-pending-bind-tests.log`.
- The UI-blocked regression waits for an actual committed manifest before releasing MainActor. Other cases cover unchanged PCM duration across a 60-second observed pause, Stop/Resume before delayed wake, duplicate/burst notifications, bounded omission, unavailable registration, legacy decoding, latched health invalidation, acknowledgment order and a stalled manifest retaining its original source lease through an expired finish.
- New lifecycle/observer source and the actual timeline file passed Swift 6, default MainActor isolation and warnings-as-errors type checking. That narrow check supplies minimal recorder/log dependency signatures; full real AppModel/recorder integration is compiled by Xcode. Log: `/private/tmp/muesli-power-strict/check.log`.

No actual sleep, wake, hardware capture, route change, user source file, installed application or entitlement was changed by these tests. Actual sleep/wake recovery remains part of hardware qualification. The implementation does not promise that an application can capture while the machine sleeps.

Apple contracts: [sleep/wake registration and acknowledgment](https://developer.apple.com/library/archive/qa/qa1340/_index.html). The installed macOS 26.5 SDK's `IOPMLib.h` explicitly permits `IONotificationPortSetDispatchQueue` delivery and distinguishes WillSleep from HasPoweredOn acknowledgment requirements.
