# Speaker identification screenshot provenance

Speaker identification now reads the modern screenshot ledgers through the
existing `MeetingScreenshotInput` folder owner. The previous implementation
scanned only the meeting-root legacy `screenshots/` directory and passed bare
URLs to a filename timestamp heuristic.

The snapshot reads only metadata-indexed `artifacts/<source UUID>/assets.jsonl`
under `MeetingFileAccess`. Each modern artifact owner must actually release its
native/store lease before the reader opens the ledger, so a still-pending writer
cannot expose a complete-looking line before its synchronization finishes. The
reader freezes the file length, processes bounded complete records, and ignores
a trailing incomplete record. Unlisted PNGs and unindexed artifact directories
are not screenshot evidence. A pending writer or malformed/missing indexed
record fails visibly instead of producing a misleading partial image set.

The existing writer's session header is unversioned. This reader requires that
header and rejects unknown version fields; it does not invent a required version
or screenshot `id` field. Image identity is the existing UUID PNG basename plus
its recorded relative path. Each event must match the indexed source UUID,
header/metadata offsets, contained source screenshot path, and monotonic source
time; a known capture end bounds its final screenshot. The reader rejects
traversal, every symlink path component, hard-linked images, missing files,
repeated source/image records, and mismatched source IDs. Limits are 1,000 indexed
sessions, 64 MiB of total ledger data, 100,000 rows, 64 KiB per row, and 10,000
images/legacy entries. These limits fail explicitly rather than truncate evidence.

Each selected image carries its source UUID, stable artifact path/ID and already
meeting-relative ledger time into the encoded payload. The session offset is not
added again. Selection uses these recorded times, and duplicate image suppression
does not merge images from different sources. Legacy images retain unknown
source/time; a `t+` filename is not promoted to verified timing. Unreadable legacy
images can be skipped, with annotations assembled from the payloads that were
actually encoded. An unreadable committed image fails visibly. The model prompt
keeps presence distinct from evidence of who spoke and forbids transferring a
name across sources on visual presence or timing alone.

The image path now reads at most 32 MiB from a regular, non-symlink file, verifies
it did not change during the read, checks a 16-megapixel limit from ImageIO
metadata before decoding, and creates thumbnails: 8 pixels for hashing, at most
1,024 pixels for a model payload. Candidate iteration and chunked reads check
cancellation. All unconditional speaker-ID debug printing of transcript text,
user hints, names and model responses was removed.

A short in-memory admission reserves one identification per physical meeting
(directory device/inode), with eight total. Cancellation does not release the
reservation while the original image read or model call remains unfinished.
The existing shared access reference remains retained through actual operation
return; the transcript transaction is not kept locked during the model request.
Viewer request/content generations reject stale results and progress after
replacement or cancellation. Names used as existing evidence come from the same
captured transcript generation.

## Validation

The 13 focused tests use real `SessionArtifactStore` PNG/ledger commits, resumed
source offsets, existing ownership leases, mixed legacy evidence, malformed
provenance, torn tails, missing/foreign images, actual JPEG payload decoding,
image byte/dimension caps, and cancellation. A valid compressed 5,000 x 4,000 PNG
fixture proves rejection from metadata before allocating its declared bitmap.
The actual identification pipeline is blocked at its preparation checkpoint;
MainActor continues, a cancelled attempt retains admission, a competing request
is refused, and only actual return permits the next attempt. The fixture aborts
before any model request.

All 345 app tests passed; the 13 focused tests, strict compilation, and Release
build also passed.

Focused log: `/private/tmp/muesli-screenshot-final-admission-tests.log`.
Full suite log: `/private/tmp/muesli-screenshot-tests-complete.log`.
Strict Swift 6, default MainActor isolation, complete strict concurrency and
warnings-as-errors over actual shared source membership:
`/private/tmp/muesli-screenshot-strict-complete.log`.
Release build: `/private/tmp/muesli-screenshot-release.log`.

This slice extends the reviewed archive-ownership integration at `1765bef`.
`SpeakerIdStatus` moves unchanged from `AppModel` into `SpeakerIdentifier` so the
real identifier, selection and encoding code can be included in the test target.
It does not qualify a model's naming accuracy or change native capture, backend
runtime selection, sandbox entitlements, or the external archive workflow.
