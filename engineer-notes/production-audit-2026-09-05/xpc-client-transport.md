# Isolated XPC client transport

6 September 2026. `release/inference-service/BackendXPCJobOwner.swift` is an
isolated client prototype. It is not in the application target or installed app.
It uses the fixed V2 wire contract, authenticates the source-free reservation,
compares expected manifest byte hashes, and arms the native kernel observer
before creating or sending a source bookmark. The independently armed PID/start
tuple is retained separately from actual termination evidence.

Source/lease/stream/request identity, the admission acknowledgement, operation
reply and actual kernel exit remain separate facts. The client closes only its
service-facing pipe copies after native admission or actual process exit. The
parent input writer remains independently owned. Cancellation uses the original
service connection/job/instance and never performs a host PID check-then-kill.
The client's own eight-second admission deadline is checked before bookmark
creation and immediately before source transfer, as well as during waiting.

The typed archive completion slice was separately reviewed by root and passed
38 root tests. Its XPC evidence constructor is still inactive: real application
owner wiring, EOF/journal barriers and the current backend must be integrated
and independently reviewed before this can authorize processing or archiving.

Actual development-signed model-free XPC fixtures passed **13 cases** using the
production Swift owner, V2 serialization, frozen native observer and native
read-only source admission. Evidence:
`/private/tmp/muesli-xpc-client-fixtures-v4/results.json` and its per-case reports.
They cover successful completion, mismatched reservation hashes before any
bookmark creation, wrong acknowledgement instance, result-before-ack ordering,
missing acknowledgement, actual SIGKILL, rejection before admission, connection
invalidation preceding actual exit, cancellation while awaiting acceptance,
bookmark/launch work exceeding the admission deadline, source-free service exit
and a missing reservation reply. Successful cases retain both original source
locks until actual kernel exit; the next exclusive lock acquisition succeeds.
Strict Swift 6/default MainActor/complete-concurrency/warnings-as-errors checks
and strict development signatures passed.

The original signal-only fixture had an immediate `_exit(125)` after self-kill;
that exit could win. Its failed SIGKILL-only assertion is preserved in
`/private/tmp/muesli-xpc-client-fixtures-v1/results.json`. The fixture was corrected
to wait for its signal; v2 observed raw wait status 9, and the full v3/v4 suites
passed. Neither normal exit 125 nor SIGKILL alone proves child-group termination.

These fixtures use generated temporary source directories, no Python/models,
and fixed test manifest hashes. They do not qualify current-package inference,
actual bundled manifest content, private-folder capability, decoder children,
application integration, hardware recording, installation or distribution.
Cancellation-before-run is a required separate current-service regression: the
service must latch cancellation before resolving or pinning a later request.
Independent final client/native reviews remain required before integration.
