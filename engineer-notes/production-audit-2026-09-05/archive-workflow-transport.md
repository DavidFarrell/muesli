# App-owned archive workflow and local command transport

This slice provides the coordinator, bounded local transport and packaged native
CLI. It does not enable a listener in the installed app, run inference, validate
external notes, edit the external Merge skill or call Trash. The root integration
owns those semantic handlers and must be reviewed with the actual source,
output, journal and Quit call sites before enabling the workflow.

## Native adapter

ArchiveWorkflowOwner retains exactly one generic Prepared value. Prepared is
native-only and has no decoder. The production adapter must require
BatchRediarizer.CompletedProcessingEvidence; a receipt or model-written exit
code cannot construct that proof.

- acquireWorkToken is a synchronous, finite, non-reentrant factory returning a
  native app shutdown token as any Sendable. Its release must be safe off UI.
  Factory failure prevents admission. The owner explicitly releases its boxed
  token before publishing actual completion, including after disconnection or
  cancelled Quit.
- prepare(Begin, UUID) returns Preparation(context, outputManifestPath).
  It must admit the source and selected vault on a retained worker, run the
  fixed native reprocess path under shared ownership and wait for actual
  child/stdout/writer/admission closure. Return only native proof/context plus
  a bounded, native-generated manifest path. Prepared must retain no live
  shared source lease: Resume can proceed during external note preparation.
  Physical source/vault identity, eligible source and owned output directory
  admission belong to this callback, never the wire or caller build ID.
- finalize(Prepared, receiptPath, UUID) acquires fresh exclusive source
  ownership without upgrading a shared lease. It must verify physical source
  identity, original bytes and native processing proof, then actual saved
  notes/images and the receipt. It owns durable pending intent, move,
  reconciliation and terminal evidence through their actual completion.

FinalOutcome.needsCorrection is permitted only before **any** pending marker
creation or move attempt. Arbitrary thrown errors become terminal uncertain,
never safe retry. Retained, trashed and uncertain are terminal. Repeated
identical finalize returns the original pending/terminal state; a competing
receipt cannot replace a running or terminal attempt.

Begin generates the operation UUID natively. Repeating identical source/vault
path strings returns the same unretired operation, including after a lost ACK.
Alternative/alias paths are safely busy rather than considered equivalent
without source ownership. Abandon only drops an idle operation. Starting a new
operation after abandon cannot erase a durable pending/uncertain journal: the
root source/journal gate must reject that source independently.

closeAdmissionForQuit first closes admission. Idle proof is discarded without
filesystem effects. Active operations are retired but retained until original
callbacks and tokens close. reopenAdmissionAfterCancelledQuit permits later
admission without restoring retired IDs or discarded proof. Deadline,
cancellation and disconnect are not actual work completion.

## Transport and installation

The app constructs ArchiveWorkflowServer off UI on a retained owner and calls
start explicitly. Merely linking these files never opens a listener.
The endpoint is ~/Library/Application Support/Muesli/ArchiveBridge/archive.sock.
The adapter prepares the existing app-support parent safely; the server creates
only the final private directory. It opens every ancestor descriptor-relative
without following symlinks. The final directory must be current-UID-owned 0700.
The socket and listener lock are 0600. An exclusive flock lasts through actual
listener and every accepted client closure. A second owner cannot replace a
live listener. Under that lock only a verified stale socket may be removed;
foreign files and symlinks are preserved. Overlong Unix paths fail explicitly.
There is no global temporary-directory fallback.

Both client and server check getpeereid against the current UID. This limits
access to that user; it does not authenticate a same-user process as Claude or
protect against account compromise. No remote service, URL handler, shared
secret, arbitrary process command, injected environment or serialized native
completion capability is introduced. Namespace/lock/socket identities are
checked before request dispatch.

Each connection carries one four-byte big-endian length-prefixed JSON message,
at most 16 KiB. Requests are flat, exact-key objects with numeric
protocol_version:1 and string arguments. Duplicate and escaped-alias keys,
unknown fields and nested structures are rejected. Commands:

- begin: source_path, vault_path
- status: operation_id
- finalize: operation_id, receipt_path
- abandon: operation_id

Paths are absolute, at most 4096 UTF-8 bytes, with no control characters or
parent traversal; actual path admission belongs to the native semantic owner.
No request can specify phase, success, proof or exit status. Responses contain
only the native operation ID, state, native output manifest path and fixed
error code. The transport prints no model or transcript diagnostics.

Four accepted client owners are the maximum. An absolute monotonic five-second
receive/send deadline begins at admission and cannot be reset by sending
another byte. A handler must call only the coordinator's finite synchronous
admission/status API. Business work runs independently of connections.
stop is nonblocking; isClosed becomes true only after original FD owners and
the listener lock close. A filesystem syscall that itself stalls retains its
owner; shutdown must not pretend that a caller deadline closed its descriptor.

The Xcode dependency builds MuesliArchiveCLI and copies/signs muesli-archive
inside MuesliApp.app/Contents/Helpers. The CLI accepts only these four commands,
uses the fixed endpoint and never starts an app or fallback backend.
Build identity includes CLI sources and protocol schema. verify.sh checks the
packaged executable/signature and rejects an unsupported command without
accessing an installed-app endpoint. Installation/build compatibility and
absence of an unparticipating old app remain explicit integration gates.

## Output contract assigned to the root adapter

Schema-2 receipt remains inventory/report, not authority. Verify each actual
saved raw/official byte pair using ByteEditEvidence. The root-owned typed
sidecar carries note-to-source declarations; source/stream/speaker tuples with
inferred or unresolved names, evidence and explicit uncertainty; and per-note,
per-variant image references. Those declarations establish neither semantic
completeness, speaker identity nor appropriate redaction.

Native code admits committed source PNGs through their ledger and retained
identity, copies exact bytes into the selected vault and creates the
authoritative copy catalog. Asset ID is the existing PNG basename UUID.
Use generated vault-relative embeds only:

    ![[MuesliAssets/<source-uuid>/<asset-uuid>.png]]

The output gate enumerates actual saved embeds, rejects unsupported forms
and matches every reference to the catalog and actual destination bytes.
Sidecar hashes cannot self-attest image provenance. Obsidian documents that
folder paths start at the vault root and an exclamation mark embeds a link:
[Internal links](https://obsidian.md/help/links),
[Embed files](https://obsidian.md/help/embeds), checked 2026-09-06.

## Qualification

ArchiveWorkflowTests covers MainActor-blocked preparation, token-close stalls,
connection loss, duplicate begin/finalize, competing receipts, precommit-only
correction, uncertain exceptions, idle and active Quit/reopen fences, actual
Unix sockets, four-client admission, absolute slow-client deadlines, oversized
and ambiguous input, live-listener exclusion, stale-socket recovery,
unstarted-server closure and preservation of foreign files/unsafe directories.
Fixtures use new directories under /private/tmp only.

Production files and CLI also undergo Swift 6/default-MainActor/complete-strict
checking with warnings as errors. Synthetic handler outcomes do not claim real
processing/output/Trash qualification. Logs and exact frozen validation counts
are recorded with the independent review handoff.
