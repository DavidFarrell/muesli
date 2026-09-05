# Capture lifecycle reliability slice — 5 September 2026

Implements audit F2–F5 and the capture ownership/deadline portion of F8. Built on the independently reviewed F1/F6 ingress and streaming conversion work, the deadline helpers, and the recording-artifact delegate dependency. Durable PCM storage, backend/event persistence, complete meeting finalization, screenshot ownership and recovery metadata are separate concurrent slices.

## Behavior

- Preview and recording share the same source health policy. Native sample progress, including silence, establishes health. A failed initial/replacement microphone remains supervised even when its engine is nil. Three unsuccessful starts converge to a visible failure; configuration changes, user route intent and Refresh can reset the budget. Voice-processing failures downgrade once, in preview as well as recording.
- Native configuration invalidation has its own generation-bound callback. One callback per generation is admitted before any UI task is created. The latest desired route replaces pending route work, and preview operations also coalesce. A fallback native engine receives a new generation.
- Microphone and system lifecycle operations have separate synchronized owners. Each native operation has an eight-second caller deadline. A timeout ends the wait; the native operation and its late-start cleanup retain ownership until their actual completion. A failed SCStream stop keeps the old source quarantined; it cannot certify retirement or permit a competing source.
- Explicit SCStream stop/conversion failures trigger system-only recovery. System silence alone never triggers a restart. Recovery preserves the source timeline and output sink. Video recovery requires a fresh URL supplied by the session artifact owner; each SCRecordingOutput uses its own retained delegate, registered before capture starts. Source stop does not certify MP4 completion.
- Preview Refresh reacquires both sources. Recording Refresh restarts affected sources and leaves healthy sources running. The result distinguishes healthy, failed and unverified sources. The button shows a checkmark only for observed health; zero amplitude is described as potentially normal silence.
- Native conversion, native start/stop and configuration failures report directly through immutable source-sink callbacks before UI delivery. A final invalid packet can therefore degrade a source without a later timestamp gap. Known native ranges report normalized missing frames; unknown timestamp/format failures report a source problem without inventing a range. The ingress retains a bounded latest problem/count; retirement retains the last generation snapshot. The durable sink receives every admitted problem.

## Verification

`xcodebuild test`, Debug, macOS destination, ad-hoc signing: **156 tests, zero failures**. Log: `/private/tmp/muesli-lifecycle-tests.log`.

The added tests exercise the actual synchronized operation owner and ingress callback factory: late start completion and cleanup, independent source ownership, blocked-UI deadline evidence, 10,000 configuration notifications during a blocked UI, same-ID/stale-generation invalidation, finite thrown-start retries, permission parking, repeated conversion-error retry scheduling, valid silence, no-first-sample recovery, final unsupported-format/timestamp errors, and source-specific Refresh results.

Release compilation succeeds with ad-hoc signing. Log: `/private/tmp/muesli-lifecycle-release.log`. Existing AppModel cleanup/backend callback isolation warnings remain outside this slice; the new capture owner, relay, ingress and callback code introduces none.

## Integration and limits

The source sink must implement `FrameSending.reportFailure(stream:message:)` and `reportLoss(stream:ptsUs:frames:reason:)`; their default no-op implementations preserve existing transport/test conformers. The durable recorder integration replaces AppModel's two early-start `writer?.reportFailure` calls with its recorder sink and preserves its `outputEnabled`/ingress-rejection wiring. The native source callbacks capture the forwarder's actual sink and epoch before capture begins.

No real microphone/system capture, route changes, hardware fault injection, installation, distribution signing or long-run clock measurement was performed. Recovery intent/UI presentation still reconciles on MainActor; native capture, failure evidence and deadline ownership do not depend on it. A permanently wedged native call remains quarantined and needs the separate starvation/finalization policy; this slice does not claim a Swift cancellation can terminate it. Failed SCStream stop behavior and video segment completion require the hardware acceptance matrix before public release.

## Adversarial review correction

The first frozen lifecycle review found two ownership defects: an older system recovery could restart after a public Stop, and resetting retry allowance on an unchanged device policy could retire the active health generation without rebuilding it. The correction separates desired request revisions from native generations. Public Stop retires desired intent immediately, start checks it across setup/native awaits, and recovery checks the scheduling-time request token and rechecks after native stop. A superseded start performs cleanup on the original native owner; it cannot restore retired intent. Preview reconciliation applies current meeting/navigation state before each coalesced operation, so a delayed start notification cannot replace required preview retirement.

Retry-budget reset now preserves a valid active health generation and its progress. Only actual source retirement uses a full reset. Native busy rejection also records the requested source failure through the independent callback.

The corrected snapshot passes **160 Swift tests, zero failures**, and the Release ad-hoc build. Logs: `/private/tmp/muesli-lifecycle-review-fix-tests.log` and `/private/tmp/muesli-lifecycle-review-fix-release.log`. Four additional regression tests cover stop during a delayed recovery operation, unchanged-ID policy transitions, preview retirement precedence, and failure evidence on busy admission.

A final retry-admission check keeps due recovery pending while its native owner or recovery worker is unavailable. It cannot consume a retry ticket without launching the corresponding reconciliation. The final snapshot passes **161 Swift tests** and the Release build (`/private/tmp/muesli-lifecycle-final-{tests,release}.log`).
