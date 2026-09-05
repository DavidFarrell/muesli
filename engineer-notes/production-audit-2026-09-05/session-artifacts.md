# Session screenshots and video completion (F9)

Each source session owns artifacts/<source UUID>/ with a fresh screenshots/
folder, video/ folder, and append-only assets.jsonl. The optional artifacts_folder
in meeting.json records that source owner. Every screenshot filename and every
video retry filename is a fresh UUID. Existing files cannot be overwritten by a
resume or restarted ScreenCaptureKit output.

ScreenshotScheduler runs off MainActor and admits one outstanding SDK screenshot
request across stop/start. A delayed reply releases only its original slot;
its immutable generation, owner, and optional backend event sink never adopt a
new session. Image conversion and PNG persistence run off UI. The store admits
one image in persistence, checks ImageIO finalization, syncs the file, atomically
publishes without replacement, syncs the directory, then syncs its event ledger.
Only a committed screenshot can reach the captured backend event sink. Stopping
invalidates admission immediately, including while image encoding is underway.
A PNG committed during stop can remain as an unindexed recoverable file; it is
never routed into a resumed session. Screenshot t is already meeting-relative:
source timeline offset + native host PTS - source epoch. Do not offset it again.

Each native output has a RecordingDelegate. Its actual SDK finish/failure callback
is the terminal authority. The store retains the delegate, syncs a finished MP4,
and writes its exact outcome to the original ledger. A timeout does not claim
that macOS cancelled the output. Late callbacks still persist there. A maximum
of 16 unsettled output reservations bounds ownership per store; requests reject
when closing or when this bound/persistence failure is reached. Settled delegates
are removed, and the ledger is streamed rather than retained in memory. A failed
ledger write prevents every later append, preserving a potentially partial tail.

Finalizer integration API (root-owned orchestration): takeSessionArtifactStore()
invalidates screenshot admission and removes the active retry callbacks. Retain
the returned owner through native stop, then await finish(timeoutSeconds: 5).
Only .completed(status) with status.isComplete proves asset completion. The other
outcomes remain degraded; status reports pending videos, finished videos,
committed screenshots, first error, closure, and known mediaEndSeconds. A pending
SDK delegate deliberately retains the original store until its true callback.
SCStream.stopCapture's Bool is source termination, not MP4 completion.

Verification: seven artifact tests plus four delegate tests pass. They cover two
resumes, unique PNG/video paths, common source offsets, one outstanding request,
a late callback, actual ImageIO destination failure, stop during image encoding,
real SDK terminal-callback handling after a deadline, failed output, and bounded
unregistered reservations. Synthetic buffers/output callbacks only: no real
capture or hardware configuration changed. Strict Swift 6 typecheck with default
MainActor isolation passes for TaskCompletion, CaptureTimeline, RecordingArtifact,
SessionArtifactStore and ScreenshotScheduler. Release builds with ad-hoc signing.
Logs: /private/tmp/muesli-artifacts-tests.log,
/private/tmp/muesli-artifacts-strict.log, /private/tmp/muesli-artifacts-release.log.
