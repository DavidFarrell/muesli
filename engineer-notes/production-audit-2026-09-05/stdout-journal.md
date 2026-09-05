# Independent backend event journal

5 September 2026. F7 stdout implementation slice; AppModel integration belongs
to the recording-owner change. FramedWriter is unchanged in this commit.

BackendProcess accepts `eventJournalURL: URL?` and
`maximumStdoutLineBytes: Int` (4 MiB default and hard maximum). With a journal
configured, complete UTF-8 JSON objects are appended without transforming their
contents, then synchronized before callbacks or lossy UI delivery. The journal
directory entry is synchronized at setup. An existing journal must end on a
newline boundary; a torn previous tail is preserved and append is refused.

BackendOutputReader owns both nonblocking pipe reads, framing buffers, journal
writes/synchronization, and closure on one serial dispatch queue. Dispatch read
sources coalesce readiness; each handler reads at most 128 KiB, so continuous
output cannot enqueue unbounded reader jobs or starve cleanup on that queue.
The stdout framing buffer is capped at 4 MiB. Stderr is bounded at 64 KiB per
line. No reader callback is sent through MainActor.

`stdoutLines` is a BackendEventLines AsyncSequence, preserving existing
`for await` consumption. Its disposable buffer has both a 500-line cap and an
8 MiB payload cap. Byte reservations are released when a line is consumed,
evicted, or abandoned. Framing buffers, temporary copies, and fixed per-line
bookkeeping are additional bounded memory. Journal admission precedes this UI
budget; dropping or cancelling UI delivery cannot cancel source journaling.

`await finishStdout(timeoutSeconds:)` returns BackendStdoutDrainResult:

- `.drained(status)` means the reader reached terminal closure. Only
  `status.isComplete` proves EOF with no framing, read, journal, or close error.
- `.timedOut(status)` and `.cancelled(status)` end only that wait; the original
  reader retains ownership and continues. They do not close the pipe.

`stdoutStatus()` provides the same independent snapshot. `journaledLines` and
`journaledBytes` count successful writes in this process session;
`durableLines` and `durableBytes` advance only after successful synchronization.
`journalStartOffset` identifies the pre-existing append prefix. UI drop counts,
rejected-line counts, observed framing-buffer maximum, EOF, cleanup, and first
failure are separate fields. A journal failure latches, preserves its first
error, and suppresses later unpersisted UI events while the pipe continues to
drain. Invalid/oversized events are counted and subsequent valid events can
still be preserved. A final object without a newline is accepted at EOF only
if it is complete JSON; a truncated object cannot become a finalized event.

`cleanup()` is an explicit queued abort. It reads a bounded amount of currently
available output before cancelling the pipe sources. Without observed EOF its
terminal status is incomplete. It never touches stdin. Safe integration waits
for process exit, awaits finishStdout, checks both the enum and isComplete,
then cleans up and reconstructs authoritative UI state from the journal.

Verification: 140 XCTest tests passed, including 13 new subprocess cases:
1,200 final events persisted during an actual MainActor block with no UI reader;
consumer cancellation; exit/EOF tails; incomplete JSON and malformed UTF-8/JSON;
reader timeout and wait cancellation; cleanup before EOF; injected write and
sync failures; oversized-line recovery; UI byte bounds; raw append; and torn
existing journals. Real subprocesses use the installed `/usr/bin/python3`.
The intentionally blocked-main test has an independent kernel timeout; Xcode's
performance checker observes the deliberately injected priority inversion.

Release compiled with ad-hoc signing. The actual reader, completion gate, and
BackendProcess section extracted before the unchanged FramedWriter separately
pass Swift 6 typechecking with MainActor default isolation, upcoming isolation
features, and warnings as errors. Existing unrelated app warnings remain.

Logs: `/private/tmp/muesli-stdout-tests-final.log`,
`/private/tmp/muesli-stdout-tests-final.xcresult`, and
`/private/tmp/muesli-stdout-release-final.log`. Builds use installed Xcode via
DEVELOPER_DIR and derived data under `/private/tmp`. No application was
installed, hardware changed, dependency installed, or recording created.
