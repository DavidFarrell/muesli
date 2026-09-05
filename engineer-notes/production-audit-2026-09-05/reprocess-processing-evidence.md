# Batch processing evidence, schema 1

This additive backend protocol records which physical source bytes were copied
and which normalized bytes were actually passed to ASR and diarization. It adds
no cleanup capability, archive authorization, network permission or inference
quality claim. Native callers may ignore the field until their strict verifier
is integrated.

## Result and failure contract

A terminal `result.processing` has `schema_version:1`, `complete:true`,
`requested_streams`, `recovery_requested`, and `entries`. Every discovered source
has exactly two entries, ordered system then mic, including unselected streams.
The existing `sources` inventory remains independent of stream selection.

`complete` means the requested main processing invocation finished, not that the
transcript is semantically complete. It can accompany failed or partially failed
best-effort recovery. `processed_without_turns` never means silence. Source loss,
manifest completion and model-quality eligibility need separate verification.

An error returns nonzero and emits `type:error` with bounded partial processing
evidence and `complete:false`; it emits no result. Unreached entries retain
`not_processed`, unknown availability and null call counts. Discovery can fail
before entries exist. A final encoded result including all turns, sources,
runtime identity and processing evidence must fit 4 MiB including newline before
`complete` status or result is emitted. Oversize returns a bounded error.

## Entry fields

- `source_session_id`, `audio_folder`, `stream`: identity from the frozen manifest,
  or explicitly legacy folder identity. An incomplete unparsed source can have a
  null session identity.
- `status`: `not_requested`, `not_processed`, `empty`, `processed`,
  `processed_without_turns`, or `failed`.
- `availability`: `unknown`, `present`, `empty`, `missing`, or `invalid`.
- `source_input`: null if not successfully copied. Otherwise `storage_kind`,
  `relative_path`, `byte_count`, SHA-256 `sha256`, `frame_count`, `sample_rate`,
  `channels`, and `encoding`. Legacy inputs describe the copied original WAV.
  Committed PCM inputs describe exactly its raw committed prefix and additionally
  contain `manifest_sha256`, `manifest_revision`, `committed_bytes`, `session_id`,
  `timeline_offset_us`, and `completed`. The parser and export use the same frozen
  manifest bytes. The PCM hash excludes any uncommitted tail. No source counters
  are invented: a verifier must independently read the matching manifest.
- `model_input`: null unless model processing was admitted. Otherwise exact
  private WAV `byte_count` and `sha256`, `format:"wav_pcm_s16le"`,
  `sample_rate:16000`, `channels:1`, and `frame_count`. Both main models receive
  the same path and bytes. Temporary paths and filesystem inode values are never
  emitted. A model failure can retain its admitted input but has no success claim.
- `asr_word_count`: successful main ASR call's word count, before recovery.
  `diarization_segment_count`: successful main diarization count.
  `turn_count`: final merged count including successful recovery. Null means that
  operation did not successfully return, not zero.
- `failure_code`: bounded exception type or explicit validation category, without
  exception text or temporary paths.

A verified zero-frame source is `empty` and causes no model calls; its call counts
and model input remain null. Empty WAV still has a nonzero header byte count.
Unselected streams retain `not_requested`, actual availability/source evidence,
and null model input/counts. A missing selected stream or any missing committed
PCM stream is fatal. Missing unselected legacy audio is explicitly recorded.

## Recovery

`recovery` contains `outcome` (`not_requested`, `not_run`, `not_needed`,
`completed`, `partial_failure`, `failed`), `planned_window_count`,
`attempted_window_count`, `failed_window_count`, `empty_window_count`,
`recovered_window_count`, `recovered_word_count`, `failure_code`, and `windows`.
Each attempted window records source-relative start/end seconds, `status`
(`failed`, `recovered`, `processed_without_words`), its actual slice `model_input`,
nullable `asr_word_count` / `recovered_word_count`, and `failure_code`.

Per-window failures preserve useful main/other recovery output but remain
visible. A budget or planning failure records failed recovery even if no window
could begin. Mutated model input is fatal, including recovery input: it cannot
produce a successful result by falling back to main output.

## Ownership and bounds

Source metadata and input opens walk from a retained directory descriptor with
`O_NOFOLLOW` on each component. Regular single-link files are required. Copying
checks device/inode, size and nanosecond modification/change timestamps before
and after, plus the current relative-path identity. Legacy audio is copied before
measuring both stream extents and before running either selected model.

Private intermediate snapshots are digest-bound to their source evidence. PCM
wrapping verifies the frozen raw digest and computes its canonical WAV digest;
model admission must match that expected digest. The normalization source also
retains its own inode/digest guard. Private input files remain owned until actual
model calls return. Their original
inode and SHA-256 are checked around both calls and after recovery. Replacing or
modifying a private input fails, even if its replacement has identical bytes.
Legacy originals may change after a successful snapshot; the evidence continues
to identify the old copied bytes, never a later hash of the mutable source.

Limits: 128 sources / 256 entries; 4,096 lazily enumerated root directory entries;
1,024 UTF-8 bytes per contained path (no control characters); 128 UTF-8 bytes per
manifest session ID; 4 MiB metadata; 1 MiB manifest; 24 hours per source; each copied file capped at 24 hours of
16 kHz mono PCM plus 1 MiB; 16 GiB
cumulative private snapshot reservations; 1,024 recovery windows across the
invocation; one million returned words/segments/turns; 2 MiB processing evidence;
4 MiB total final JSONL result. Counter limits reject rather than truncate.

The snapshot budget reserves raw copies, PCM-to-WAV wrapping, private model
copies, normalization's output upper bound, and recovery slices before writes.
Normalization uses a bounded PCM stdout pipe with owner-written WAV framing;
limits close and reap its decoder. Source and recovery copying use fixed-size
chunks. Reservations are cumulative and conservative even after temporary files
are released. No input or compatibility file is written or removed.

## Reproducible protocol fixture

`backend/fast_mac_transcribe_diarise_local_models_only/tests/fixtures/processing-v1/`
contains synthetic two-stream PCM, its complete manifest/index, and the full
successful `result.json`. The fixture regression runs the actual producer with
fake ASR/diarizer results; it asserts the whole result exactly. Runtime identity
is explicitly a synthetic placeholder and cannot qualify a release. This fixture
is for independent native decoder/hash interoperability tests only.

Focused regressions cover exact frozen manifest revision/prefix, uncommitted
tails, both-model input equality, post-snapshot source mutation, private file
mutation/replacement at both models, model failure and unreached streams, missing
versus empty versus unselected inputs, PCM24 normalization, actual mutation while
copying, symlink/dangling metadata rejection, derived-byte/window limits, a real
bounded decoder, lazy enumeration and the total result protocol size gate.


## Validation at freeze

- All 165 backend tests passed: `/private/tmp/muesli-processing-final-full.log`.
- The suite includes actual compiled Swift parent/child lease regressions from
  the approved base and the new bounded local decoder test, using fixtures only.
- `git diff --check` passed. No native app sources or project membership changed;
  the Swift/native processing verifier is a separate integration/review boundary.

## Producer handoff correction (2026-09-06)

The independent review of `356a051` reproduced a source-derivation gap between
normalization/recovery output production and the first model-input hash. Both
handoffs now require immutable `ProducedWAV` evidence. The producer accumulates
its PCM digest while receiving decoder output or reading the requested recovery
frames. After `wave` finalizes the header, it verifies that same retained output
descriptor against the observed PCM, canonical WAV header and exact frame count.
Only then does it return the canonical digest, format, byte/frame counts and
original inode/timestamps. No post-return pathname read establishes a new trusted
baseline.

The reprocess caller opts into the new handoff with `return_evidence=True`;
existing path-only helper callers retain their return type. `ModelInput` requires
the producer's digest, physical identity and exact shape before model admission.
Recovery also checks the requested frame interval's exact length independently.
A missing handoff, changed sample, identical-byte file replacement, disappearance,
added hard link or inconsistent count fails as `InputChanged`, including recovery;
it cannot become successful main output with a best-effort recovery fallback.
The normalized source stays separately guarded through the decoder/model calls.

Regressions use the real ffmpeg decoder and real slicer on synthetic WAVs. They
mutate output both immediately after return and immediately before the producer
finishes; the latter proves the digest came from observed derivation bytes, not a
fresh hash of a modified output. Positive cases validate exact frames, frozen
handoff fields and canonical output hashes. The native JSON schema and checked
producer interoperability fixture are unchanged.

Validation before correction freeze: 176 full backend tests passed in
`/private/tmp/muesli-processing-derivation-full.log`; all 43 focused processing
tests passed after the final hard-link/disappearance classification guards in
`/private/tmp/muesli-processing-handoff-final-focused.log`. The complete frozen
suite is rerun separately before merge. No native app or permission changes.
