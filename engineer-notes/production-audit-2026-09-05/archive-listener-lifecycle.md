# Archive listener startup and Quit ownership

This slice is inactive. It does not construct a listener from AppModel, change
MuesliAppApp, select a backend, process client material or call Trash. The root
adapter must still qualify the semantic handlers and participating app boundary.

`ArchiveListenerLifecycle` receives one persistent `ArchiveWorkflowOwner` and
never recreates that owner on listener restart. The convenience initializer
receives an explicit directory; the injectable factory accepts one `onClosed`
callback and returns an `ArchiveListenerHandle`. A single serial utility lane
owns construction, start, stop and completion. No native or filesystem operation
runs inside the public methods or their short state lock.

- `enable()` admits one startup using the new atomic
  `ShutdownWorkRegistry.beginUserWork`. It only admits while the registry is
  open. Repeated requests coalesce desired state without another constructor.
- `waitForStartup(timeoutSeconds:)` observes one original startup. Its deadline
  or cancellation never closes a listener, releases its token or permits a new
  constructor. The result is an observation, not permission to use a stale
  listener; the owner retains the actual instance and publishes current state.
- `closeAdmissionForQuit()` synchronously closes semantic admission, retires
  the listener generation and retires idle semantic proof through its owned
  off-UI cleanup worker. For an idle
  listener it installs a shutdown close token before dispatching stop. Existing
  startup tokens remain owned through late construction and cleanup. Call this
  from the coordinator's synchronous accepted hook with its preparation bridge
  retained, before `beginQuit`.
- `reopenAfterCancelledQuit()` reopens future semantic admission and requests
  one future listener. It cannot restore retired operation IDs. An old startup
  or close must actually return before its queued completion can start the
  replacement. A second Quit retires that desired restart too.

An idle, healthy listener has no shutdown token. All active constructor and
close paths retain tokens through actual completion, even with MainActor
blocked. An early or duplicate close callback cannot complete a constructor or
stop invocation that has not returned: the single completion job runs behind
that invocation on the same lane. A throwing factory must finish partial
allocation cleanup before returning its error. Initial failure is visible and
does not spin automatic retries. The factory and semantic admission hooks must
be finite and non-reentrant with respect to the lifecycle's state lock.

`ArchiveWorkflowServer.onClosed` runs once outside its state lock, after its
listener, original clients, socket cleanup, listener lease and retained endpoint
descriptor have actually closed. This includes stop-before-start. Reentrant
status or restart is permitted from that callback. It never signals from a
caller timeout. Stop remains nonblocking and the original native owner performs
all closure. The endpoint's close is idempotent to avoid descriptor reuse on
later deinitialization.

Status publication is coalesced to one pending MainActor delivery. It rereads
the latest snapshot at delivery, so a delayed old callback cannot publish a
retired listener's ready state. It carries fixed failure categories rather
than private endpoint/source paths or raw exception text.

`ApplicationQuitCoordinator.configure` adds an optional synchronous `accepted`
hook. The preparation bridge is installed and the Start intent is retired
before this hook runs; `beginQuit` follows it. Immediate Cancel can skip the
asynchronous prepare task but cannot skip archive retirement. Reentrant Cancel
also prevents the abandoned request from subsequently quiescing admission.
The actual semantic adapter must use `beginUserWork` for new begin/finalize
work; existing `begin` remains for successors of already accepted work.

## Validation

42 focused actual Xcode tests pass: 12 listener lifecycle, 16 socket/workflow
and 14 existing cooperative Quit tests. Synthetic fixtures cover a stalled
constructor, actual bound-but-unreturned listener, queued old request, stalled
close, early callback, duplicate callback, immediate Cancel, second Quit,
coalesced intent, throwing cleanup, delayed UI publication, retained semantic
work callback reentry after real temporary Unix socket/lease closure, and explicit
retry clearing the prior startup failure only after successful new admission.
No installed endpoint, app launch, real capture or user Quit is exercised.

Evidence paths: `/private/tmp/muesli-archive-listener-final-tests.log`,
`/private/tmp/muesli-archive-listener-strict.log` and
`/private/tmp/muesli-archive-listener-release.log`. Frozen strict concurrency and
identified Release results are reported with the handoff rather than inferred
from the test result. Separate root full-project qualification remains required.

Native prepared-resource disposal is covered by [archive-context-retirement.md](archive-context-retirement.md); its required successor factory is separate from new-user admission.

## Received request retirement correction

Independent app-wiring review reproduced an already-received request paused at the real server handler boundary after its stop/path checks. Accepted Quit followed by immediate Cancel reopened the shared semantic owner while this old connection still existed; resuming the handler started one retired preparation (expected zero). Original evidence: `/private/tmp/muesli-app-wiring-stale-dispatch-repro.log`.

Cancel now only coalesces desired listener state. Semantic admission reopens in `startLocked`, after successful new startup-token admission and after the original listener plus every accepted client/handler owner actually closes. The same semantic owner is retained. Existing finalization/disposal work stays retired and owned. A new listener request succeeds after actual closure; old received requests cannot enter during the close interval. The deterministic real temporary-socket regression retains its original failing assertion and additionally checks that the new listener can prepare once. No app launch, user support paths, hardware or Finder Trash operations are involved.

Correction qualification: all 71 native wiring integration tests passed (`/private/tmp/muesli-app-wiring-reopen-final-tests.log`), including the unchanged retired-request assertion and a successful new-listener request. Complete actual application sources passed Swift 6/default-MainActor/complete-concurrency typechecking with warnings as errors (empty `/private/tmp/muesli-app-wiring-reopen-strict.log`). Optimized Release with `ENABLE_CODE_COVERAGE=NO` passed (`/private/tmp/muesli-app-wiring-reopen-release.log`). The existing throwing-constructor test now admits an already-closed observer returning inactive while still requiring persistent startup failure, one constructor, no original owner and an empty registry. Independent correction review remains required.
