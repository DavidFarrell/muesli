# Archive native context retirement

The native semantic adapter keeps catalog, output bundle and journal directory
descriptors in its prepared proof. Releasing that proof can block in synchronous
native cleanup. The workflow must finish that cleanup away from MainActor and
under actual shutdown ownership before publishing terminal completion.

`ArchiveWorkflowOwner` now stores the prepared value in one empty-capable box.
Only its original preparation/finalization worker or its admitted retirement
worker reads or clears that value. Async helpers scope callback results and
borrowed finalization arguments; they return before the remaining box is cleared.
Old job/task captures therefore retain an empty box after cleanup, not a hidden
copy of native resources. Neither the workflow lock nor the calling UI thread
performs native cleanup.

Invalid-manifest preparation and thrown preparation release resources before
the original operation token. Successful, retained and uncertain final outcomes
also clear the context before releasing that token or publishing completion.
Only explicit precommit `needsCorrection` retains a proof for another attempt.
An arbitrary thrown finalization error remains terminal uncertain.

Idle abandon and accepted Quit synchronously reserve one retirement successor,
retire the operation ID and dispatch one worker. They return without waiting
for native close. The new `retiring` wire state means disposal was accepted; it
is not a claim that resources have closed. Status/new work remains busy until
actual deinitialization and token release return. At that point the old ID is
removed. Active work remains on its original worker; a Quit retirement successor
bridges its completion to cleanup of any late prepared/correction result.
Cancel Quit and a second Quit cannot revive that proof or admit another worker.

Integration must supply both factories explicitly:

- `acquireWorkToken`: atomic `ShutdownWorkRegistry.beginUserWork` for new user
  begin/finalize intent.
- `acquireRetirementToken`: `ShutdownWorkRegistry.begin` for already accepted
  cleanup successors, including while quiescing. The accepted Quit preparation
  bridge must remain held while closing admission.

Factories must be finite, synchronous and non-reentrant with respect to the
workflow lock. Retirement admission failure retains the context and reports
admission failure; it never falls back to inline destruction. Production holds
one persistent semantic owner across listener restarts and closes its admission
before Quit. The semantic callbacks must finish their own native work before
return and may not export hidden copies or unowned cleanup tasks.

Validation: 49 focused actual Xcode tests passed (23 workflow/transport, 12
listener lifecycle and 14 cooperative Quit). Both independent original resource
regressions are included unchanged except the required retirement factory.
New real FileHandle/flock fixtures hold deinit behind a fail-safe gate and prove
off-UI cleanup, live shutdown ownership, continued archive exclusion and busy
admission for idle Quit/abandon, immediate Cancel/second Quit, terminal success
and thrown errors, invalid/throwing preparation, late prepared returns and
retryable/late finalization. No real recordings, installed listener, native Trash
or app Quit is invoked.

Logs: `/private/tmp/muesli-native-context-final-tests.log` and
`/private/tmp/muesli-native-context-strict.log` (exact production owner/protocol
and actual registry/completion dependency closure, Swift 6, default MainActor,
complete concurrency, warnings as errors). Optimized no-coverage test/identified
Release results are reported with the frozen handoff separately.
