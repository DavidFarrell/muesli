# Interrupted-session recovery and reprocessing

5 September 2026. This increment changes source recovery and reprocessing;
unique screenshot/video asset indexing is a subsequent F9 increment.

Startup snapshots meetings left recording, recovers committed source prefixes
on a detached task, and applies results only if the meeting/session identity
still matches and there is no live session for that folder. Metadata stays
interrupted. Recovery never invents a wall-clock endedAt or derives duration
from modified files or days spent waiting for the next launch. It preserves
known title/speaker metadata and the original PCM/manifest. Compatibility WAVs
are rebuilt only from committed prefixes. Truncation/export failure remains
explicit; a stale WAV cannot substitute for a failed authoritative PCM source.

Per-session optional timeline_offset_seconds and duration_seconds fields retain
measured evidence while old metadata remains decodable. Explicit source
manifest offsets establish the meeting timeline. Legacy sessions use both
physical source lengths, irrespective of which stream is selected for ASR.
Unknown legacy durations are not silently compressed out of later recovery
offsets. Legacy meetings without clean-completion evidence are interrupted.

Reprocess reads source-recording.json when present and exports only that
committed prefix into an invocation-owned temporary directory. Existing WAVs,
PCM, and manifests are not rewritten or deleted. Normalization also targets an
explicit owned temporary file. Explicit manifest offsets and both-stream legacy
media durations are independent of selected ASR streams and transcript word
ends. Empty committed streams do not invoke ASR.

Verification: 7 Swift recovery tests passed, covering interruption, days-idle
duration, optional metadata decoding, preserved PCM/manifest bytes, uncommitted
tails, two resumes with explicit offsets, and truncated source rejection.
11 backend reprocessing/recovery tests passed with mocked models and synthetic
audio, including identical mic-only/both offsets and byte-preserved originals.
Release build passed with ad-hoc signing. Logs are
/private/tmp/muesli-session-recovery-tests.log,
/private/tmp/muesli-session-recovery-release.log, and
/private/tmp/muesli-reprocess-integrity-tests.log. No real capture or model
download was used.
