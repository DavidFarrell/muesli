# Batch source and replacement integrity

This correction starts from the independently approved shared ownership foundation `570768d`.

## Failure and boundary

Previously, a second valid final result silently replaced the first in the reader accumulator. A result produced before Resume could also replace all four canonical transcript files after a newer source session was appended: the save read fresh metadata but did not compare its source inventory with the batch inputs. Fresh metadata alone was not a source guard.

The reader now requires exactly one final result and rejects invalid, negative, reversed, nonfinite or out-of-range timing. Source IDs and folders must be unique, every scoped turn must refer to a declared source, and the declared total duration must match the complete inventory. A one-sample tolerance (1/16000 second) covers numeric rounding. Timing outside that tolerance fails explicitly; it is not silently clamped.

`BatchSourceSnapshot` is app-owned evidence and is omitted from the result's Codable representation. Production batch admission captures it before launching the child, under `TranscriptPersistenceStore`'s folder transaction. The snapshot records the verified meeting identity, sorted session index, source identities and offsets, both physical stream durations, selected stream scope, original reviewed names and SHA-256 fingerprints. PCM hashes cover exactly the manifest's committed prefix. Compatibility WAVs and uncommitted PCM tails are preserved. Source/manifest reads use retained directory descriptors, no-follow regular-file admission, bounded chunks and identity/change checks. Metadata is capped at 8 MiB, manifests at 1 MiB, sessions at 1024 and directory enumeration at 10000 entries; the original recorder's 24-hour per-source bound remains in force.

The snapshot runs inside the existing retained backend admission factory. Its one nested folder operation owns all source I/O, even after the caller's deadline. The original admission remains busy until the worker and its resources really close. There is no timeout retry, replacement worker or late child launch. No MainActor disk read or task-group cancellation deadline is introduced.

At application, the canonical folder transaction recaptures and compares the sources before staging any replacement files. Appended/resumed sessions, changed bytes or manifest, a still-live recorder, recording status, missing indexed sources, or unindexed audio evidence reject replacement. Names edited during the batch also reject it, preserving the newer reviewed mappings. Unrelated title edits remain compatible. On an approved successful replacement, prior speaker names clear because diarization labels can denote different people; the confirmation explicitly says so. Saved capture/video extents remain intact even when the audio interval is shorter.

## Deliberate legacy compatibility

Unscoped old results remain decodable but cannot independently authorize a canonical replacement. An app-captured single legacy WAV source can normalize such a result to the explicit legacy folder ID, provided its full physical media duration and selected-stream intervals match. Both streams establish duration even for mic-only processing. Indexed multiple legacy sources require a complete scoped result inventory. Pre-index fallback accepts only one unambiguous `audio` folder. PCM evidence without its commit manifest never falls back to a compatibility WAV. Unknown, corrupt or missing inputs fail before replacement.

The subprocess must still report a complete inventory, including silent sessions with no turns. No claim is made that counts of turns or inferred speaker labels prove semantic transcription accuracy. The snapshot protects cooperative current-source identity and byte coverage; it is not a substitute for operating-system isolation of an untrusted process.

## Verification

The original full Swift suite plus the new tests passed (335 tests) before the final unindexed-source regression; a final focused rerun covers the frozen source enumeration and application code. Tests use only synthetic temporary files and model-free subprocesses. They exercise duplicate finals, malformed and invalid times, an actual child held while a newer session is committed, content/prefix changes, silent inventory coverage, per-stream EOF, legacy normalization, lost manifests, reviewed-name edits, preserved titles and artifact extents, and retained snapshot ownership through a deadline. The deadline regression waits for actual resource closure before asserting the child never launched.

No model download, actual capture, user-file mutation, installed-app replacement, external Merge edit or publication is part of this slice. Child crash pins and the modern screenshot input compatibility correction remain separate work.
