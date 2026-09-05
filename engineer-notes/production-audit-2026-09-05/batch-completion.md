# Batch subprocess completion and protocol integrity

BatchRediarizer consumes authoritative stdout from the reader callback into a
bounded lock-owned accumulator: one result, first error, last 20 stderr lines,
and a finite set of progress stages. No result depends on the newest-500 UI
projection. Exit alone is insufficient; finishStdout must return drained with
isComplete before the caller reads a result. A malformed EOF tail invalidates an
earlier result. Reader line limits remain in force; an oversized event is an
explicit incomplete-output failure, not a partial successful transcription.

Cancellation immediately requests termination. On timeout, cancellation, or any
failure, one cleanup task independent of the cancelled caller sends SIGTERM,
waits 0.5 seconds, escalates to SIGKILL if needed, waits 1 second, and then gives
stdout 1 second to drain before explicit cleanup. These bounds cover the wait;
cleanup is never evidence of successful output. Process installation and
cancellation share a lock, and cancellation is checked again after launch.

Reprocess model imports/inference redirect Python diagnostics to stderr while
emit retains the original stdout for JSONL. Source PCM and original audio files
are never removed by this change. MUESLI_ALLOW_MODEL_DOWNLOADS=0 and
HF_HUB_OFFLINE=1 remain in the batch environment.

Verification: five real subprocess tests pass: final result beyond 700 status
lines with no UI consumer, EOF tail without newline, terminal error after result,
malformed EOF after result, and bounded timeout/cancellation with SIGTERM-ignoring
children (the timeout/cancellation behaviors have separate tests). Twelve Python
reprocess/recovery tests pass with synthetic sources and mocked models, including
stdout diagnostic separation. Strict Swift 6/default-MainActor typecheck passes
for the actual BatchRediarizer, TaskCompletion and reader plus the unmodified
BackendProcess class prefix (excluding unrelated FramedWriter dependencies).
Release builds. No capture, model download, or hardware change was performed.
Logs: /private/tmp/muesli-artifacts-tests.log, /private/tmp/muesli-batch-strict.log,
/private/tmp/muesli-reprocess-integrity-tests.log,
/private/tmp/muesli-artifacts-release.log.
