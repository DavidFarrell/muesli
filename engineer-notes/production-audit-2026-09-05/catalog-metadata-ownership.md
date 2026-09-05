# Catalog and metadata ownership correction

Scope: remaining history initialization, legacy migration, orphan recovery, title/speaker metadata edits, and the existing confirmed deletion action. Canonical source/transaction formats are unchanged.

## Corrected boundaries

- Initial history enumeration no longer runs on MainActor. A single retained catalog worker admits one independently scheduled folder owner at a time. A deadline ends the UI wait; it cannot create another scan or release a stalled folder operation. Other folders remain independently readable/writable through the shared store.
- Reading, migration, and orphan recovery share a folder reservation. An invalidated start intent fences older recovery writes. A source's OS lease blocks recovery while its writer is active. Folders used by this app instance are protected through the gap between actual source close and final metadata save; their finalizer owns their outcome.
- Catalog UI publication checks its original revision and clears pending notices only on actual terminal observation. Metadata/finalizer publication invalidates older history snapshots. Unreadable existing metadata is preserved and reported, not overwritten by legacy fallback. Previously visible unreadable rows remain visible.
- Legacy JSONL inspection reads bounded chunks and rejects oversized complete records. An interrupted final JSON record is preserved and excluded from statistics. Every discovered audio source folder is indexed; committed PCM offsets determine recovered extent, including sessions with zero transcript segments. Recovered status stays interrupted and wall-clock stop times remain unknown.
- Title and speaker edits perform a fresh metadata read, field patch, and recoverable transaction under the same owner. They preserve decoded session/source/artifact fields. One active edit plus one coalesced set of later speaker edits bounds UI typing work. The actual owner callback publishes saved changes; pending deadlines cannot override that terminal result.
- Reviewed speaker names retain exact source/session + stream + raw-speaker scope. A late edit may complete on its original disk folder, but cannot publish into a replaced/reopened transcript generation. Title callbacks patch only title mirrors, not old counts/status snapshots.
- Batch replacement rejects a pending metadata edit. Deletion uses the same retained folder owner, rejects active source leases, and removes UI rows only after the actual move succeeds. Tests replace the move with a fixture callback: no test performs a Trash operation.
- Unused pre-owner setup/stream/resume metadata helpers were removed. The defensive failed-start path now preserves the indexed session and delegates to the existing owned incomplete finalizer instead of restoring a stale whole-metadata snapshot.

## Validation

The full Swift suite passed 259 tests on the implementation before the final discarded-notice refinement. The focused suite and Release build are rerun on the frozen final code; exact logs and final counts accompany the commit handoff.

Tests exercise blocked MainActor while the actual catalog worker finishes, a stalled folder with independent deadline and unrelated-folder progress, repeated admission rejection, recovery invalidation, source lease ownership through close, corrupt metadata, two committed source sessions without a transcript, bounded legacy records, coalesced edits, stage/rename/commit failures, stale transcript generation, and late title completion.

## Remaining scope

This does not qualify attachments, external transcript export panels, arbitrary backend-folder validation, or the platform's filesystem failure behavior. Source recording, startup, batch replacement, and finalizer transactions retain their separately reviewed contracts. A stalled catalog operation can withhold the next history snapshot until its original I/O returns; it leaves the UI and unrelated folder operations available and reports that state truthfully.
