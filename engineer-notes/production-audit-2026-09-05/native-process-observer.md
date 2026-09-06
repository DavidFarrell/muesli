# Native XPC process termination observer

This isolated library adds native termination evidence for the process behind an
authenticated `NSXPCConnection`. It does not send source or model capabilities,
launch inference, terminate a PID, or change the application/Xcode project.

## Admission and ownership contract

The caller first activates and authenticates a source-free connection, then calls
`MuesliNativeProcessObserver.armConnection`. Its expected signing requirement must
identify the intended production service and signing authority. The native worker
independently obtains the connection's actual PID and validates its dynamic
`SecCode` against that requirement. A caller-provided numeric PID is not a public
API.

Before admission, the worker records `PROC_PIDTBSDINFO` start seconds/microseconds,
registers `EVFILT_PROC` with `NOTE_EXIT | NOTE_EXITSTATUS` and an acknowledged
`EV_RECEIPT`, then re-reads the process start tuple and the connection's PID. A
successful receipt, matching identity, and an open deadline gate are all required.
Only after the synchronous arm call succeeds may the caller grant capabilities.
The immutable PID/start tuple is available on the returned observer immediately.

Registration runs on a self-retaining dedicated pthread. The caller's wait is
bounded by a finite timeout in `(0, 60]` seconds. A native call that outlives that
deadline remains owned by the worker. The closed admission gate prevents later
success from being adopted; once the actual registration call returns, the worker
closes its unclaimed queue. No source capability can have been granted through a
failed arm call. Worker creation and registration errors are returned to the
caller, not delivered as termination.

After acceptance, the worker owns the exact kqueue registration until a real
kernel exit event or a separately reported observation failure. Dropping the
returned observer, invalidating an XPC connection, cancellation, a service reply,
and a timeout do not manufacture an exit event. The observer has no cancellation
or signal-sending API. A queued exit during the final arming handoff is retained.

An event must match the registered PID/filter and contain both `NOTE_EXIT` and
`NOTE_EXITSTATUS`. The result preserves raw wait status and flags and decodes
normal exit, signal termination, or another status without conflating them:

| Kernel result | Raw wait status | Kind | Exit code | Signal |
| --- | ---: | --- | ---: | ---: |
| Normal exit 125 | 32000 | exited | 125 | 0 |
| SIGKILL | 9 | signalled | -1 | 9 |
| Normal exit 126 | 32256 | exited | 126 | 0 |

Callbacks execute on the dedicated worker, may occur before the arm method
returns, and run outside its state lock. The terminal result is retained for later
inspection. Unexpected kernel errors are stored and delivered separately as
`observationFailure`; they do not prove death. The integration's owner must keep
all granted source leases and pending-Quit work when observation fails. The
library owns observation resources, not the caller's source lease policy.

## Reproducible verification

Run from this checkout on macOS:

```sh
bash release/inference-service/tests/run-native-observer-tests.sh /private/tmp/muesli-native-observer-verification
```

The script compiles with Clang ARC/modules and `-Wall -Wextra -Werror`, signs its
generated test executable ad hoc, and checks the public header's Swift 6 import
with default MainActor isolation, complete concurrency checking, and warnings as
errors. It launches only generated local child processes. Each child waits for a
one-byte control message and exits itself; no test sends a signal to a stored PID.

The 33 checks passed on 2026-09-06. The accompanying JSON retains every case and
the actual kernel and `waitpid` statuses. Coverage includes the three distinct
statuses above; 20 immediate exits after arming; an exit queued before arm returns;
once-only delivery; actual observer self-retention after caller release and
connection invalidation; invalid/nonexistent PIDs; invalid or nonmatching signing
requirements; changed connection PID during registration; a blocked native PID
getter with bounded caller timeout and eventual release; and real kqueue failure
under descriptor exhaustion.

The test substitutes only the connection PID getter and the timing of descriptor
exhaustion immediately before the real `kqueue()` syscall. This is necessary to
reach kqueue's actual `EMFILE` failure after Security's own descriptor use. All
other calls use actual signed executable processes, `SecCode`, `proc_pidinfo`,
registration receipts, kernel exit events, and `waitpid` control evidence. The
library source contains no test branch; the test build renames the kqueue call to
a wrapper that otherwise calls the real syscall unchanged.

These are native library checks, not proof of the application sandbox's XPC
entitlements, the production inference backend, descendant process containment,
source-lease integration, installed-build behavior, or the separately required
signed XPC protocol fixture. No app launch, capture, hardware route/sleep change,
installed artifact, customer source/model capability, or publication occurs here.
