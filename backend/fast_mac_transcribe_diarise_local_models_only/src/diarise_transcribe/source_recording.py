"""Read-only access to app-owned, committed source recordings.

The PCM file length can run ahead of the atomic manifest. Readers must use the
committed prefix, never stat() as a substitute for the commit boundary. No code
in this module opens source files for writing or deletes them.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

MANIFEST_NAME = "source-recording.json"
MAX_SOURCE_BYTES = 24 * 60 * 60 * 32_000


@dataclass(frozen=True)
class CommittedSource:
    path: Path  # Compatibility WAV name; the authoritative data is .pcm.
    size_bytes: int
    sample_rate: int
    channels: int
    session_id: str
    timeline_offset_us: int
    completed: bool

    @property
    def last_sample_index(self) -> int:
        return self.size_bytes // (2 * self.channels)

    @property
    def bytes_written(self) -> int:
        return self.size_bytes


def _integer(value: object, name: str, minimum: int, maximum: int) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"Invalid source recording {name}")
    return value


def committed_sources(directory: Path, expected_session_id: str | None = None) -> dict[str, CommittedSource]:
    manifest_path = directory / MANIFEST_NAME
    # A bounded manifest is also an input validation contract for crash/recovery
    # tooling. Normal manifests retain at most 512 coalesced loss intervals.
    if manifest_path.stat().st_size > 1024 * 1024:
        raise ValueError("Source recording manifest exceeds the size limit")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise ValueError("Unsupported source recording schema")
    session_id = manifest.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        raise ValueError("Missing source recording session identity")
    if expected_session_id is not None and session_id != expected_session_id:
        raise ValueError("Source recording session changed while processing")
    offset = _integer(manifest.get("timeline_offset_us"), "timeline offset", 0, 2**63 - 1)
    _integer(manifest.get("revision"), "revision", 0, 2**63 - 1)
    completed = manifest.get("completed")
    if type(completed) is not bool:
        raise ValueError("Invalid source recording completion state")
    streams = manifest.get("streams")
    if not isinstance(streams, dict) or set(streams) != {"mic", "system"}:
        raise ValueError("Source recording must identify both independent streams")
    result = {}
    for name in ("mic", "system"):
        stream = streams[name]
        if not isinstance(stream, dict) or stream.get("sample_rate") != 16000 or stream.get("channels") != 1:
            raise ValueError(f"Unsupported source format for {name}")
        size = _integer(stream.get("committed_bytes"), f"{name} committed bytes", 0, MAX_SOURCE_BYTES)
        if size % 2:
            raise ValueError(f"Unaligned source recording for {name}")
        pcm = directory / f"{name}.pcm"
        if pcm.stat().st_size < size:
            raise ValueError(f"Truncated committed source recording for {name}")
        result[name] = CommittedSource(directory / f"{name}.wav", size, 16000, 1,
                                       session_id, offset, completed)
    return result
