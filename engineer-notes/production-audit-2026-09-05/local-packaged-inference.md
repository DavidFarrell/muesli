# Local packaged inference integration

The Release app uses its sealed inference service and bundled runtime/model
manifests. A native source-access service asks for the Muesli Meetings directory
once per app session. It derives an implicit read-only bookmark for each admitted
direct child, using the original main-process directory/lock identity. The main
app forwards those bytes; it never resolves or regenerates the bookmark.

The source-access service is sandboxed with only user-selected read-only access.
The inference service is sandboxed with the separately qualified JIT and unsigned
executable-memory exceptions. The main app and archive command have no sandbox or
JIT exceptions. The hardened main app has the audio-input entitlement required
for its microphone capture; the archive command has no entitlements. The decoder
retains only sandbox inheritance. Runtime and model
bytes are copied from the qualified package, checked against their full manifests
and current Python source, and sealed by the enclosing development signature.
Distribution signing, notarization and redistribution remain deferred.

## Admission and lifecycle

`LocalInferenceSession` retains preparation on a worker with a cooperative-Quit
work token. Folder selection completes before capture begins or inference enters
its bounded admission. Quit retires the original authorization session
synchronously. Retirement rejects new capabilities while preserving claimed live jobs for the existing Stop-and-drain path. Cancelling Quit admits new intent but cannot revive that session.
A failed transcription setup leaves the existing source-recording fallback
available; a cancelled meeting-start intent does not proceed to capture.

Each helper reservation is authenticated and observed by PID plus process birth
identity before a source capability request. `BackendXPCJobOwner` registers the
capability token before asking the broker for the bookmark, replays any kernel
termination that has already arrived, and retires the token only for that actual
process instance. Broker loss requests cancellation. It does not imply helper
exit or release the app's original source/journal ownership.

The broker closes its temporary admission SH locks before returning the grant.
The main and inference service retain their own continuous source pins. There is
therefore no third, asynchronous lock owner that can survive the app's native
completion barrier.

Reservation verification has a 45-second bound; authenticated source/launch
admission then has eight seconds. App and batch outer startup bounds allow 53
seconds. User folder selection is a separate, retained preparation, with a
five-minute bound and cancellation support.

## Application consumers

Release recording and reprocessing construct fixed native operation enums. They
cannot select an external executable, Python environment, model directory or
import path. Debug retains the existing development-folder controls.

Batch reprocessing captures its original source inventory inside the existing
admission owner and passes that snapshot digest into the native completion
binding. Archive preparation captures the app's configured selection once per
operation and requires the same complete source, output-drain and actual native
closure evidence as before. A helper JSON result or stdout EOF alone cannot
permit finalization. No archive move is performed by package assembly or tests.

## Local assembly

Build an optimized Release app from a clean source checkout. Then run
`scripts/package-local-app.py` with that app, the qualified inference payload,
a fresh temporary output directory, and the existing development signing
identity/team. The script compiles current native services, validates current
Python source and every payload manifest entry, signs inner services and the
outer app, and runs the exhaustive native entitlement/signature audit. Its
sealed package record binds the app build ID, source commit/tree, manifest
digests and intended client identifier.

Assembly does not install or launch the app. Installation and the user hardware
check are separate steps. Session authorization is deliberately not persisted.

The additional prepared broker-exit/receiver/decoder experiment is optional for
this local installation. Production keeps the broker for active helpers and
cancels on broker loss; it does not rely on continued access after issuer exit.
No such post-exit capability-survival result is claimed. The earlier actual
private-source inference and root-to-child narrowing checks remain the relevant
current-machine capability evidence.

## Validation before final assembly

The integration's first Release compile, 64 native admission/batch/archive tests,
17 archive-bridge/cooperative-Quit tests and 11 optimized signed adapter cases
passed. The original nine runtime-closure tests and 11 additional local-packager
manifest/source rejection tests passed. Full Python execution reported 193 passes
and three native-parent harness compilation errors; adding the newly required
source-owner compilation unit fixed that harness, with all 27 focused lease tests
passing afterward. Full current runtime/model inventories and all 21 packaged
Python sources matched the qualified payload. Final corrected-session tests and
clean signed-package verification are recorded separately when complete.


The final combined source passed all 639 Xcode tests and all 196 backend tests,
plus the nine runtime-closure and 11 local-packager tests. The final session
correction was imported byte-for-byte from `011415b3b101b5c87d7ccfaab8abe2d5e8f4cc6d`;
its 30 session/package cases and actual signed claimed-job scenario pass against
the final source owner. Independent Astra review closed both the early live-job
cancellation and stale readiness findings with no new supported P1/P2 defect.
Evidence is retained at `/private/tmp/muesli-final-app-tests-authorized.log`,
`/private/tmp/muesli-final-python-tests.log`,
`/private/tmp/muesli-local-session-verification.json`, and
`/private/tmp/muesli-app-final-corrections-astra-evidence.json`. These are source
and generated-fixture results; signed assembly and user hardware validation are
separate qualifications.

Claude Fable 5.1 identified a packaging defect in the first signed candidate:
hardening the main app without `com.apple.security.device.audio-input` prevents
its microphone capture. The Release entitlement and both package verification
checks now require exactly that audio-input entitlement for the main app. The
inference, broker, decoder and archive entitlements are unchanged. Apple documents
this resource permission at
https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input.
The previous package is a negative audit control; the corrected package must be
rebuilt from its new clean source identity and audited before installation.
