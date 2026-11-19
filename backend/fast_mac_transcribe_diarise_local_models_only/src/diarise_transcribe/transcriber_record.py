"""Who transcribed a meeting: the `transcriber` record on a reprocess result.

One shape for both machines. The Mac fills it from its own options; the whitebox
client adds one `TrackRecord` per track it sent, from that job's own answer.
Nothing in a record is assumed: a value the service did not give is "unknown".
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

UNKNOWN = "unknown"


@dataclass
class TrackRecord:
    """One track as the whitebox handled it."""
    stream: str
    upload_format: str                 # "flac", or "opus" past the upload cap
    engine: str = UNKNOWN              # as the job's answer named it
    model: str = UNKNOWN
    language: str | None = None        # what the service detected or was told
    incomplete: bool = False           # the service's own coverage verdict
    coverage: dict | None = None


@dataclass
class TranscriberRecord:
    machine: str                       # "local" or "whitebox"
    engine: str
    model: str
    service: str | None = None
    language: str = "auto"             # what was asked for; "auto" = detect
    fallback_reason: str | None = None
    tracks: list[TrackRecord] = field(default_factory=list)

    @classmethod
    def local(cls, asr_model: str, language: str | None,
              fallback_reason: str | None = None) -> "TranscriberRecord":
        return cls("local", "parakeet", asr_model, language=language or "auto",
                   fallback_reason=fallback_reason)

    def add_track(self, track: TrackRecord) -> None:
        """Record a track, and let the run's engine and model follow its tracks:
        the one value they all share, else "mixed"."""
        self.tracks.append(track)
        for key in ("engine", "model"):
            values = {getattr(t, key) for t in self.tracks}
            setattr(self, key, values.pop() if len(values) == 1 else "mixed")

    def payload(self) -> dict:
        return asdict(self)
