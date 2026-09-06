# Original source admission before native archive processing

The semantic adapter initially releases its exclusive source observation before
starting Batch's shared source owner. Passing only a pathname let a replacement
folder or changed source be freshly rebased by Batch before the later archive
check rejected it. An independent actual model-free child reproduced this by
copying replacement PCM from that pathname. No move occurred, but the wrong
source had already reached processing.

The adapter now passes its immutable native folder/lock identity and a native
original-inventory validator into Batch. These values cannot come from the wire
request or subprocess proof. Backend admission compares the acquired access
identity before source snapshot, backend factory or child work. Under the actual
folder transaction, the validator checks identity before reading descendants,
then compares the original complete file/hash list, empty directories and
per-entry physical identities. The same predicate runs before and after Batch's
source snapshot. Archive expected-source snapshots use the read-only purpose
from the first transaction onward; a newly pending save is refused without
repairing canonical files or removing its journal. Ordinary reprocess keeps its
existing explicit recovery behavior. A completed appended Resume, substituted PCM, extra empty
directory or replaced lock must fail before backend construction.

`ArchiveSourceInventory.captureForProcessing(context:)` is a read-only API that
requires an actual TranscriptPersistenceStore.Context. It reuses the original
bounded no-follow walker. It does not grant archive authority: ordinary
`capture(access:)`, relocated capture and semantic/move consumers retain their
exclusive-access requirements. Ordinary reprocess callers omit the new optional
parameters and retain their existing behavior and compatibility.

For explicit expected-source admission, Batch also wraps the actual native
Process.run invocation in one retained read transaction. After the final native
beforeRun checkpoint, it rechecks the complete original inventory while holding
that transaction, then invokes Process.run and retains the transaction until
the actual invocation returns. The process-control queue stays serialized across
this scope. A blocked validator or native launch keeps the same transaction,
backend admission and shutdown work; cancellation/deadlines end only the caller's
wait. There is one store operation for this scope, with no polling observer task.
This read-only scope refuses an unresolved transaction rather than recovering it.

Root/lock identity is checked again immediately before the actual launch. The
original child-owned identity pin is unchanged. Escaping launch callback copies
retain an empty-capable validation box; it is cleared before the launch helper
returns, so delayed callback destruction cannot retain a source lease beyond
actual-close publication.

This is an admission boundary through actual Process.run invocation return,
not an atomic source snapshot across child execution. Later source changes
still require the existing process-proof and final source checks to reject
the operation. No permission to move is derived from admission alone.

Validation uses only synthetic temporary sources and model-free native children.
The original independent replacement-folder test is unchanged and passes after
previously failing. Additional tests cover original lock/PCM bytes/PCM inode,
empty directory and completed Resume changes before processing; PCM/directory/
completed-session substitutions at actual beforeRun; late root/lock substitution;
a stalled actual native invocation retaining both process-local and OS
transaction ownership after caller cancellation; and a retained callback that
cannot retain the source lease after real close. Existing batch snapshot,
source inventory, admission and child-lifetime regressions run alongside them.

Exact focused log: `/private/tmp/muesli-archive-source-admission-exact-tests.log`.
Independent red evidence: `/private/tmp/muesli-adapter-independent-prelaunch-repro.log`.
Strict production/DEBUG and identified no-coverage Release outcomes are recorded
with the frozen handoff. No installed app, user source, hardware or Trash action
is exercised.

A follow-up actual interrupted-commit/failed-rollback regression demonstrated
that the ordinary initial snapshot purpose restored canonical metadata and
deleted its pending journal before rejection. The archive-only read purpose
corrects that behavior and retains both pending bytes and originals untouched.
Red evidence: `/private/tmp/muesli-archive-admission-recovery-red.log`.
