# Native callback ownership through actual retirement

6 September 2026. This correction addresses the reproduced microphone offer lease closing after its shutdown token had already finished. It does not change hardware capture policy or the separate initial-Start intent fence.

`CaptureOperationOwner.Request` is constructed synchronously into an explicit local before `perform` is awaited. It owns all four accepted callbacks: operation, adoption, failure and abandoned-start cleanup. `AppModel.nativeMicrophoneStartRequest` is synchronous too; there is no outer async adoption parameter retaining another copy of the source context. Suspended callers and queued UI notifications retain the emptyable Request, not raw callback arguments.

The original worker closes adoption admission on expiry. A UI callback that never began can be retired without executing on MainActor. A callback that already began must actually return before cleanup or capture destruction. Failure delivery is reserved once, atomically with the deadline's abandonment decision; original worker retirement also waits for a concurrently executing failure callback. Helpers return before publishing these invocation completions. Native/cleanup callbacks, UI/failure invocations and final synchronous capture destruction are all finished before the shutdown token is released. No destructor runs under the Request or lifecycle state lock. There is one original worker and at most one queued UI offer; actual-return waits add no repeated monitor jobs.

Success reports the committed **native result**, not permission to disregard outstanding Request retirement. Ordinarily `perform` also observes callback disposal. If native completion was committed before the deadline but synchronous capture destruction stalls, the waiter returns that known native result. It cannot retroactively abandon an already-owned native source after destroying the cleanup callback. The original lane remains busy and the shutdown token remains pending until actual disposal returns. A successful atomic UI Claim is the sole exception allowing a successor native operation before callback retirement; its old Request still retains shutdown ownership until the UI invocation returns.

The production callers without adoption already retain their native source before calling `perform`: `AppModel` assigns `previewMicEngine` before preview start; `CaptureEngine` assigns `nativeSource` before system start. A successful native result leaves those properties intact and avoids their error/abandon paths. Actual Stop callbacks finish before native success is committed. Directly retained caller contexts, recorder owners and system native-source owners keep their separate existing leases/tokens; an emptied Request does not claim to close independently held aliases. Generation, original-source and Quit guards around meeting microphone adoption are unchanged.

## Reproduction and verification

The unchanged `MicOfferLease.deinit` assertion requires nonempty shutdown ownership **before** closing its actual `MeetingFileAccess`. It remains in the original never-delivered UI offer regression. Only Request construction and invocation shape changed there.

A new actual-kernel-lease regression starts the UI callback and stalls it across the deadline, testing both refused and successful Claim. Against unchanged production at `9c86df0`, it fails seven assertions, including the original actual-close assertion in both paths. The baseline test has only the legacy call shape. Evidence: `/private/tmp/muesli-mic-offer-inflight-red.log`, separate archive `/private/tmp/muesli-mic-offer-red`.

The corrected cases also cover:

- Independent actual leases captured by operation, failure and cleanup, including an executing failure callback concurrent with worker completion.
- Busy rejection and an early native throw disposing all four callback slots, including callbacks never invoked.
- Actual lease destruction deliberately stalled off UI: the known native result can return, but Quit cannot seal, a next Start is refused and an independent exclusive file lease is denied until real close.
- Already claimed UI ownership admitting a successor while the old callback's token remains pending; unclaimed UI work refuses it.
- Retained completed caller tasks and Request objects do not retain closed captures.

56 focused actual Xcode tests pass in Debug and optimized Release (`ENABLE_CODE_COVERAGE=NO`), covering CaptureLifecycleTests, CooperativeQuitTests and MeetingFileAccessTests. Evidence: `/private/tmp/muesli-mic-request-final-debug-tests.log`, `/private/tmp/muesli-mic-request-optimized-tests.log`. Full actual app declarations also pass Swift 6, default MainActor, complete strict concurrency and warnings-as-errors in production and DEBUG modes: `/private/tmp/muesli-mic-request-production-strict.log`, `/private/tmp/muesli-mic-request-debug-strict.log`; inputs in `/private/tmp/muesli-mic-request-strict-inputs.txt`.

`reproductions/check_mic_adoption.py` adapts only the Request API shape and adds an optional optimized compile. Its five original source/Stop/Quit/generation/healthy scenarios pass both normally and with `--optimized`; `--source-ref ce7028c` still reproduces the original adoption defect. Logs: `/private/tmp/muesli-mic-request-production-probe.log`, `/private/tmp/muesli-mic-request-production-optimized-probe.log`, `/private/tmp/muesli-mic-request-production-original-red.log`.

These are synthetic source/ownership tests and extracted production wiring probes. They do not launch the installed app, perform capture, change a device route or qualify actual hardware.
