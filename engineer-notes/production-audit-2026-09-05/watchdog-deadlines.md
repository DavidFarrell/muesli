# Watchdog and stdout-wait slice

5 September 2026. This implements only the independent starvation diagnostic
and stdout-drain wait portions of F8. It does not establish bounded SCStream or
microphone teardown, lifecycle ownership, or truthful artifact finalization.

The watchdog now owns its probe state on a serial queue. A monotonic clock
measures one outstanding MainActor echo; timer ticks report starvation while
that echo remains pending, without joining it or awaiting microphone telemetry.
Stop/start retains the outstanding slot, so repeated restarts cannot enqueue
more echoes behind a blocked actor. Late and duplicate acknowledgments have
explicit state transitions. Reports are rate limited and recovery is logged
after a reported stall receives its echo.

The watchdog and BackendLogWriter explicitly opt out of the project's default
MainActor isolation. Their unchecked Sendable conformances describe documented
queue confinement. Neither timer execution nor the log append requires MainActor.
Reports carry the previous responsive UI context with its age, or say that it is
unavailable. This context does not establish current microphone health. The old
RunLoopStormTripwire is removed: it queued separate MainActor aggregation tasks
while that actor was blocked. The replacement diagnoses starvation; it no longer
reports responsive UI run-loop turns per second.

CompletionTrackedTask installs a completion signal in the original operation's
defer. Each TaskCompletion wait registers only a continuation and timer; timeout,
cancellation, and completion arbitrate under a lock and remove the registration.
Repeated waits do not create observer tasks suspended on task.value. A timeout
means only that the wait expired. AppModel requests stdout-task cancellation and
logs that completion is unconfirmed; its consumer checks cancellation before
processing a late buffered line, preserving the MainActor ordering with session
file closure. This is not cancellation or termination of an arbitrary hardware
operation. A caller resuming on a blocked executor can still be delayed by that
executor even after the independent deadline has fired.

Verification:

- 127 XCTest tests passed (116 existing and 11 new), with zero failures. New
  tests cover deterministic probe transitions, long stalls, report throttling,
  cached-context age, stop/restart, stale replies, completion/cancellation races,
  repeated wait cleanup, independent waiters, and a noncooperative task.
- The actual MainActor is temporarily blocked by a synchronous test-only wait.
  The watchdog callback records that it ran off the main thread, then reads both
  the writer tail and a real temporary log file before releasing MainActor. A
  separate two-second fail-safe prevents a regression from hanging the suite.
  Recovery is asserted after release. Xcode's performance checker reports the
  intentional priority inversion from this injected block.
- Release app build passed with ad-hoc signing. The watchdog, writer, and
  completion helper separately pass Swift 6 typechecking with MainActor default
  isolation, NonisolatedNonsendingByDefault, InferIsolatedConformances, and warnings
  treated as errors. Existing unrelated app isolation warnings remain.
- Test output: `/private/tmp/muesli-watchdog-tests-runtime.log` and
  `/private/tmp/muesli-watchdog-tests-runtime.xcresult`. Release output:
  `/private/tmp/muesli-watchdog-release-verified.log`. Xcode is selected through
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; derived data and
  module caches remain under `/private/tmp`.

The first sandboxed XCTest launch compiled but could not contact testmanagerd.
The successful run used authorized local runtime access. No app was installed,
meeting recorded, hardware route changed, or dependency installed.
