# Local inference session ownership and package expectations

This slice changes `LocalInferenceSession` and adds model-free tests. The
borrowed runtime, source-capability owner and fixed broker protocol are separate
dependency snapshot `74ef990`; do not import that snapshot over their authors'
newer files. Its original session/runtime came from the root application-adapter
worktree. The capability owner is the ingress author's read-only-retirement and
availability-observer API (SHA-256
`b26c663196fe753ae999615ffa7536c11510a69124a6ce0e672b658c5c4c9903`).
The final optimized validation additionally compiles the owner's frozen
`4e74c2b` correction (SHA-256
`5c928a170c853bef7589ac0687b58d0ac8ca18f6efbdaf7e68b425535dc07a77`)
through `--owner-source`; the correction prevents reconnecting an already-failed
native transport. This author slice does not overwrite that owner's source.

The manager changes are:

- Check Task cancellation before the cached-selection fast path. A cancelled
  caller cannot return an authorized selection or retire another caller's valid
  cached session.
- Use `SourceCapabilityOwner.retireAdmission()` for preparation cancellation,
  late owner installation and accepted Quit. New capability requests stop, while
  claimed jobs retain their existing token and can finish normal stop/drain.
- Expose thread-safe `isReady` and
  `observeUnavailability(@Sendable () -> Void)`. Source notifications bind the
  original source owner/preparation; they clear only that cached selection and
  retire only that preparation's publication intent. Notification delivery is
  outside locks. UI consumers must recheck `isReady` on their publication actor
  so a queued old notice cannot clear a new ready selection.
- Recheck the actual source owner's authorization inside the publication gate.
  Loss after authorization but before publication cannot restore ready state.
  Weak preparation/owner captures avoid retaining an idle owner in a cycle.

Default production factories remain fixed: the app's packaged runtime, its
Application Support Meetings directory, the shared shutdown registry and the
native source broker. Only `MUESLI_LOCAL_INFERENCE_TESTING` enables alternate
registry/runtime/root/source factories and two synchronous worker checkpoints.
The real source owner similarly uses its existing compile-time
`MUESLI_SOURCE_OWNER_TESTING` transport seam. Neither flag belongs in app build
settings. Production definitions are independently typechecked with both seams
disabled before the test binary is compiled.

The thirty model-free manager/package cases include blocked package and source
factories, cancellation and immediate Quit/Cancel before install, cancellation
during authorization, late success, worker-return token retention, duplicate
setup refusal, cached reuse, sealed Quit admission, failure before publication,
stale old-session failure/queued UI notice, and idle-manager release. Package
fixtures exercise actual manifest-byte hashes, record/build/source/team/client
mismatches, dirty/unknown builds, malformed/missing/oversized files, symlinks and
hard links. They do not simulate signature verification or complete sealed model
validation; the actual service still performs that separate reservation check.

A separate signed integration case uses the real manager, source-capability
owner, capability-aware XPC client, `BackendProcess`, `BackendAdmissionOwner`,
`FramedWriter`, output journal and native process observer. The fake broker
returns a bookmark only for a newly generated temporary meeting. The existing
model-free service validates the real native lease and waits for an actual
frame. After the job is claimed, accepted Quit followed immediately by Cancel
retires the session: another configuration/grant is rejected, but no token
retirement or broker close occurs. The existing job receives its frame, reports
operation0, actually exits125, durably drains, and only its kernel event retires
the original token. Generated source bytes/inode/timestamps remain unchanged.
The host has no entitlements; the model-free helper has only app-sandbox.

This does **not** qualify a private read-only grant, models, a real source-broker
panel, simultaneous broker sessions, capture, application activation, or archive
processing. The actual broker intentionally accepts one original connection per
client-app service process. Logical replacement tests use independent fake
transports; a real new authorization while an old live token still retains its
broker can fail and may need retry after that job exits.

Two negative controls were retained:

- The original manager plus factory seams failed exactly the already-cancelled
  cached-return assertion:
  `/private/tmp/muesli-local-session-cancel-red/results.json`.
- The signed active-job test with only retirement calls restored to the old
  `beginShutdown()` behavior failed its successful native-completion assertion:
  `/private/tmp/muesli-local-session-native-red/results.json`.

Reproduce from an integrated source tree:

```sh
python3 release/inference-service/tests/run-local-session-tests.py \
  /private/tmp/muesli-local-session-debug --identity SIGNING_IDENTITY
python3 release/inference-service/tests/run-local-session-tests.py \
  /private/tmp/muesli-local-session-optimized --identity SIGNING_IDENTITY --optimized
```

For the isolated author tree, pass
`--client-source /private/tmp/muesli-local-session-dependencies/BackendXPCJobOwner.swift`.
That is a frozen byte-copy of the root capability-aware client, SHA-256
`eddccfe66c9efe7788ab092143fd5798911d24d146e2e55f3a24e028868bd28c`;
this commit does not overwrite the older canonical client in this worktree.
For the final owner validation, also pass
`--owner-source /private/tmp/muesli-local-session-dependencies/SourceCapabilityOwnerFinal.swift`.
`--session-source` permits replaying the exact negative-control manager copy,
and `--native-only` selects only the signed scenario. These are build-harness
arguments, never application or service RPC fields.

The compile uses actual production dependency bodies, Swift6/default MainActor,
complete strict concurrency and warnings as errors. Debug uses `-Onone -D DEBUG`;
optimized uses `-O -whole-module-optimization`. This is not a whole-project test
target migration or clean application Release qualification. Each report retains
source hashes, actual outcomes, errors and observed entitlement dictionaries;
the input hashes are rechecked after the signed native case finishes.
