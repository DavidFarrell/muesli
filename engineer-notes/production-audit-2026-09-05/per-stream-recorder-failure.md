# Keep the other source after a stream write failure

A microphone-only append failure previously closed LocalAudioRecorder's global
admission gate. Even when system PCM, its synchronization and the shared manifest
were still writable, subsequent system packets were discarded. This compounded
an explicitly failed source with avoidable loss of the other source.

Append failure now marks that source unavailable under the admission lock. Its
accepted queued packets still receive loss accounting; later packets from that
source are rejected without occupying queue reservations. The other source can
continue using the bounded queue and commit path. The original failure remains
sticky, source-specific loss ranges remain in the manifest, and final completion
stays false. The healthy source's compatibility WAV contains its committed PCM.

A failed shared commit/sync/manifest or invalid shared stream/handle inventory
still closes the global gate. This change does not attempt to continue on storage
whose shared commit durability is unknown. Finish closes admission first, drains
the finite accepted prefix, preserves failed-stream counters, and retains the
original queue/leases through actual close. A new session has a new recorder and
cannot upgrade the failed predecessor's persisted completion state.

## Evidence

The unchanged actual-recorder test
`testPerStreamWriteFailurePreservesLaterHealthySourcePackets` injects EIO only at
`.write(.mic)`. Baseline: later system admission is false, system committed bytes
are 320 instead of 640 and 160 system samples are dropped. Corrected: admission is
true, all 640 system bytes commit and its dropped count stays zero. Both outcomes
keep the microphone source incomplete.

Additional tests cover the inverse stream, failed-source admission accounting,
new-session preservation of old failure, an in-flight failed write plus a full
accepted queue at Finish, compatibility WAV contents, repeated Finish, and global
commit/invalid-inventory refusal. All fixtures are synthetic local PCM; no capture
hardware, routes, client data or real Resume UI is used.
