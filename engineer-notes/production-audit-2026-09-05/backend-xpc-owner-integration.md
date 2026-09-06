# Signed model-free backend owner integration

This test-only slice exercises the real `BackendProcess` XPC adapter from
`df98740` (local equivalent `1168561`) on the native target/source integration
`3f54fef`. It changes no production process, admission, writer, reader, client,
native observer, source lease, or application activation implementation.

The host compiles actual `BackendAdmissionOwner`, `BackendProcess` (including
`FramedWriter` and typed native evidence), `BackendOutputReader`,
`MeetingFileAccess`, `ShutdownWorkRegistry`, and their actual supporting types.
The `FrameSending` declaration is extracted verbatim from the app source,
matching the existing native-parent lease harness. It links the canonical
Swift XPC client and real Objective-C protocol, source admission and native
process observer. There is no simulated process-exit callback or substitute
file-owner implementation.

The existing signed `ClientFixtureService` gains compile-time-only test controls
enabled by this new driver. It validates a real frame written by `FramedWriter`,
returns valid JSON of type `fixture_result`, and uses its original fixed native
reservation, acknowledgement, disconnection, cancellation and exit scenarios.
Test traces use one unique generated file in the service's existing container
temporary directory because its sandbox rejects writes to the host fixture
directory. The trace contains only fixed event names and the test process PID.
No trace path, command, environment, or failure mode comes from an RPC request.
The existing client-only driver does not enable these controls.

The host is signed with no entitlements. This model-free service has only
`com.apple.security.app-sandbox`; neither receives a JIT, unsigned-memory,
network, or file-selection exception. The driver records actual entitlement
dictionaries and rejects unexpected keys. This is not the production Python
helper entitlement qualification. All source sentinels are newly generated
under `/private/tmp`, with their inode, size, timestamps and SHA-256 checked
before and after each run. No installed app, user recording, hardware, picker,
archive operation, or Trash operation is involved.

The eleven cases cover:

- Operation0 with actual kernel exit125, and separately actual SIGKILL9, retain
  their distinct OS termination in typed native completion.
- Operation66 produces no typed successful completion.
- Actual connection invalidation precedes service exit; source pins remain
  held, and a bounded exit wait does not confuse disconnect with process death.
- Cancellation occurs after native source pinning but before acknowledgement.
  The cancellation RPC remains deliverable during the synchronous startup wait;
  its reply does not release source ownership before kernel termination.
- A real nine-second service reservation is accepted with the enclosing
  53-second admission budget. Retirement after an actual delayed reservation
  prevents all source-bookmark calls.
- With the UI sequence unconsumed, all 601 final ordered JSON events become
  durable while its bounded projection drops 101 lines.
- A blocked journal write or final synchronization outlives the helper and
  the admission maintainer's five-second stdout deadline. The real source,
  backend and journal locks, admission slot, and shutdown token remain held;
  another factory is rejected. Only releasing the actual I/O checkpoint lets
  the original writer, journal and scope close.
- ENOSPC at write or final synchronization preserves a possible native
  operation0 candidate while `finishStdout` reports incomplete output and the
  actual journal error. Native completion is not durable-output completion.

Every successful fixture is deliberately a **preflight** candidate. The actual
native evidence API refuses to use it as successful archive reprocessing. This
suite does not exercise the full source/processing/output archive validator, and
does not treat a `fixture_result` line as production processing evidence.

Reproduce (use a new output directory and the authorized local signing identity):

```sh
python3 release/inference-service/tests/run-backend-process-fixture.py \
  /private/tmp/muesli-backend-xpc-debug SIGNING_IDENTITY
python3 release/inference-service/tests/run-backend-process-fixture.py \
  /private/tmp/muesli-backend-xpc-optimized SIGNING_IDENTITY --optimized
```

Both variants use Swift6, default MainActor isolation, complete strict
concurrency and warnings as errors. The optimized variant additionally uses
`-O -whole-module-optimization`; the Debug variant uses `-Onone -D DEBUG`.
These are the actual minimal production dependency bodies, not a whole-project
test-target migration claim. Native peer observation must run outside a second
enclosing sandbox. Each host has a 60-second alarm and an external 65-second
failsafe; every fixture service has its own 55-second alarm. The driver retains
failure output and confirms the exact traced fixture executables retire,
including source-free reservations. It never signals a PID from a stale trace.

Each output includes a source-input SHA-256 manifest, actual entitlement
dictionaries, service traces, per-case reports, preserved stdout/stderr,
source-preservation observations and the aggregate result. Test input hashes
are rechecked at the end so edits during compilation/execution fail the run.

The existing native-parent and Python pin regressions remain relevant:

```sh
cd backend/fast_mac_transcribe_diarise_local_models_only
PYTHONPATH=src /path/to/existing/venv/bin/python -m pytest \
  tests/test_meeting_lease.py tests/test_xpc_entry.py -q
```

Use the worktree's `PYTHONPATH=src`: an existing editable environment can otherwise
import the main checkout's older package and fail collection before testing
this candidate.
