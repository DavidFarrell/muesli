# Current-backend isolated protocol contract

`InferenceProtocolV2.h` and `.m` define the next fixed client/service wire contract. The types and canonical request digest have actual secure-coding/bounds tests. They are not yet connected to the original V1 service or to Muesli. The old frozen proof/picker is unchanged.

The first source-free message is `reserveJob`. Its fixed reply identifies protocol version 2, the job UUID, a random per-service-process instance UUID, actual PID, and 32-byte SHA-256 identities of the actual bundled runtime and model manifests. These must describe copied/validated bytes, not an expected lock or caller-supplied model metadata. The proof will copy the fixed staged model into its own signed Resources and remove the external model bookmark entirely. No model binaries enter Git.

Before sending source data, the eventual client binds the connection's actual PID and process start tuple and arms its kernel exit observer. The helper reserves one job for the exact connection and instance, with an independent finite reservation deadline. Run/cancel always bind both instance and job. Cancellation handling must remain independent while source admission or Python initialization is blocked. Native process-group retirement remains in the service; fallback exit 125 follows a successful group-signal request, while a failed group-signal request must be distinguishable (126). Neither operation result zero nor transport EOF is an OS exit status.

`MuesliSourceLease.record` is exactly 56 bytes: seven unsigned big-endian 64-bit words, version 1 then directory/access-lock/backend-lock device/inode pairs. The source bookmark always names the immutable meeting root. Native admission must acquire existing read-only handles and both shared locks, validate identities and path binding, and retain those resources until actual service exit. Python receives only the service-derived fixed `MUESLI_MEETING_LEASE` token and independently pins in package initialization. Missing or invalid app-service admission never falls back to standalone mode.

For live work, `MuesliLiveSource` supplies one prepared child component (`audio` or `audio-session-N`, bounded nine positive digits) and an NSUUID. The native helper must compare its canonical UUID to that child's current source manifest. The backend must also compare the later meetingStart `source_session_id` to the exact admitted UUID. No latest-session inference is allowed. The meeting lease still protects the outer meeting root.

The only configurable processing field currently needed by the Release application is the stream enum: system, mic or both. Its launch uses fixed app-owned source recording, live ASR-only, meter emission and required admission. Model selection is the fixed copied Parakeet model; diarization is Senko; language remains automatic, recovery enabled, gap/tolerance and Release live timing remain the current defaults. Generic arguments, environment, commands, import paths, arbitrary model paths and DEBUG timing overrides are not wire fields.

`MuesliInferenceRequestDigest` canonically binds protocol, operation, stream, exact bookmark bytes, lease identities, optional live source, job and instance. The fixed exported `acceptedJob:instanceID:requestDigest:` callback is sent only after native source/lock/live-manifest admission and before Python load/import. It acknowledges ownership, not model readiness; the existing meeting_started stream event still serves the live protocol's readiness role. `MuesliOperationResult.operationStatus` describes the operation's own return; actual process exit, output EOF and durable journal closure remain separate client observations.

Validation command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun clang -fobjc-arc -fblocks -arch arm64 -mmacosx-version-min=26.2 -Wall -Wextra -Werror -framework Foundation release/inference-service/InferenceProtocolV2.m release/inference-service/tests/ProtocolV2Tests.m -o /private/tmp/muesli-inference-protocol-v2-tests
/private/tmp/muesli-inference-protocol-v2-tests
```

The pending implementation must still demonstrate actual XPC serialization/peer checks, source-free reservation, native admission-before-import, private-container derived writes, current processing/runtime evidence, and generated framed live controls. No main-app adapter or installation is included in this step.
