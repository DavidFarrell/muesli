# Current backend isolated V2 service

This is a new proof on application source baseline `240a7c1`, not an installed
application integration. The earlier `fe1a744` proof and diagnostic picker remain
unchanged. `build-current-proof.sh` creates a fresh private bundle with the complete
current backend package and exactly the two fixed ASR files; binaries are not in Git.

`InferenceProtocolV2.h` is the fixed client contract. Before any source-bearing run,
reserve verifies the service resource seal (including nested code), enumerated
runtime files, and the bytes of the locally validated model assets. The reservation
contains SHA-256 of the exact UTF-8 files at service `Contents/Resources/`:

- `runtime-manifest.json`: schema1, kind `actual_runtime_files`, entries of every
  directory, regular file and relative symlink under `python`. File entries contain
  resource-relative `path`, `kind`, `bytes`, `sha256`; links contain `target`.
- `model-manifest.json`: schema1, kind `validated_local_model_assets`, fixed
  `asr_directory` `models/parakeet-tdt-0.6b-v3`, role-bound actual file entries from
  current `local_assets.preflight(...diarisation=True,hashes=True)`. Senko files
  remain in the sealed Python package. Absolute staging/source paths are excluded.

The manifest parser is bounded (8MiB each, 25,000 runtime items, 128 model items,
4GiB/file, 8GiB total hashed bytes including repeated Senko assets). This is actual
local byte verification before reservation, not a guarantee that arbitrary external
actors cannot change a bundle during later execution. Runtime/model observation
emitted by the current Python remains separate from these native manifest identities.

A run must match reservation connection, process instance, job UUID and canonical
request digest. Matching cancellation latches retirement under the same lock as run
admission before scheduling native group exit. A later run cannot resolve its bookmark
or acquire source pins. The two diagnostic policy counters count native source attempts
and Python entry commitments; they carry no source path or content.

Native admission resolves only the meeting-root bookmark, compares the typed original
folder/lock identities, and holds existing read-only shared locks. LiveSource identifies
one strict child component and source UUID; native manifest admission, Python committed
prefix admission and later meetingStart all require that same UUID. No latest-session
lookup supplies it. The accepted callback binds the digest before the interpreter loads.

The bridge sets the single native-derived meeting lease token before loading Python;
package initialization acquires its independent read-only process pin before model
imports. Fixed argv selects operation, resolved meeting root, sealed model root,
stream and optional live component/UUID. There is no generic command/environment RPC,
model bookmark or missing-lease fallback in service mode. Live source mode never mkdirs
its source. Live scratch WAVs use a unique service-container directory; reprocess retains
its current private snapshot/normalization/processing-evidence implementation. The live
scratch owner is never reset/deleted merely because Python main returned; surviving
workers may still own it. No speculative startup sweep is introduced.

Native source grants/pins remain properties until actual service exit, including after
a Python result. Operation status is separate from the observed kernel wait status.
Normal cleanup requests SIGKILL for the verified owned process group, then falls back to
exit125 if that request succeeded; failure to request group retirement is exit126.
The client must retain actual NOTE_EXIT/EOF/drain proof, not synthesize exit0 from a
successful operation result. Deadlines/cancellation do not close source owners early.

The exception remains service-only: sandbox + allow-jit + unsigned executable memory,
with hardened runtime/library validation. Decoder and fixed sw_vers have only sandbox
+ inherit. Private-HOME capability transfer remains unqualified pending the separate
visible-picker test; generated `/private/tmp` fixtures prove mechanics, not that grant.

V2 preserves the application batch allowance of 3,600 seconds (preflight60s, live24h).
The old proof's 600-second batch constant is not carried into the current service.

The V2 builder captures source identity before compilation/copying, compares a
second complete input record before final signing, and hashes every actually copied
backend module against the first record. A changing worktree is not certified by a
later clean HEAD. `/private/tmp/muesli-current-v2-frozen-5480da6` was built using the
older end-only record during a deadline-only follow-up and is explicitly **not an
identified frozen qualification artifact**. Its native compile and signing succeeded;
that does not repair the source-trace inconsistency. Final qualification uses a fresh
build with the start/end input guard.
