"""Versioned batch evidence and bounded, read-only source snapshots.

Evidence identifies bytes presented to model calls, not semantic completeness.
Source paths are opened relative to a retained directory without symlink traversal.
Only private invocation-owned snapshots may be passed to models.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
import hashlib
import json
import os
from pathlib import Path
import stat
import soundfile as sf
from typing import Literal, TypedDict
import wave

from .source_recording import MAX_SOURCE_BYTES
from .wav_derivation import InputChanged, ProducedWAV, file_identity

MAX_SESSIONS = 128
MAX_METADATA_BYTES = 4 * 1024 * 1024
MAX_FILE_BYTES = MAX_SOURCE_BYTES + 1024 * 1024
MAX_SNAPSHOT_BYTES = 16 * 1024**3
MAX_RECOVERY_WINDOWS = 1024  # across the invocation, never per source
MAX_COUNT = 1_000_000
MAX_EVIDENCE_BYTES = 2 * 1024 * 1024


class ModelInputRecord(TypedDict):
    format: Literal["wav_pcm_s16le"]
    sample_rate: int
    channels: int
    frame_count: int
    byte_count: int
    sha256: str


class SourceInputRecord(TypedDict, total=False):
    relative_path: str
    storage_kind: Literal["committed_pcm", "legacy_wav"]
    byte_count: int
    sha256: str
    sample_rate: int
    channels: int
    frame_count: int
    encoding: str
    manifest_sha256: str
    manifest_revision: int
    committed_bytes: int
    session_id: str
    timeline_offset_us: int
    completed: bool


class RecoveryWindowRecord(TypedDict):
    start_seconds: float
    end_seconds: float
    status: Literal["failed", "recovered", "processed_without_words"]
    model_input: ModelInputRecord | None
    asr_word_count: int | None
    recovered_word_count: int | None
    failure_code: str | None


def bounded_count(value: int) -> int:
    if type(value) is not int or not 0 <= value <= MAX_COUNT:
        raise ValueError("Processing count exceeds the supported limit")
    return value


@dataclass
class SnapshotBudget:
    copied_bytes: int = 0
    recovery_windows: int = 0

    def reserve_bytes(self, count: int) -> None:
        if count < 0 or self.copied_bytes + count > MAX_SNAPSHOT_BYTES:
            raise ValueError("Private source snapshot budget exceeded")
        self.copied_bytes += count

    def reserve_windows(self, count: int) -> None:
        if count < 0 or self.recovery_windows + count > MAX_RECOVERY_WINDOWS:
            raise ValueError("Recovery evidence window budget exceeded")
        self.recovery_windows += count


@dataclass
class RecoveryEvidence:
    outcome: Literal["not_requested", "not_needed", "completed", "partial_failure", "failed", "not_run"]
    planned_window_count: int = 0
    attempted_window_count: int = 0
    failed_window_count: int = 0
    empty_window_count: int = 0
    recovered_window_count: int = 0
    recovered_word_count: int = 0
    failure_code: str | None = None
    windows: list[RecoveryWindowRecord] = field(default_factory=list)


@dataclass
class ProcessingEntry:
    source_session_id: str | None
    audio_folder: str
    stream: Literal["system", "mic"]
    status: Literal["not_requested", "not_processed", "empty", "processed", "processed_without_turns", "failed"]
    availability: Literal["unknown", "present", "empty", "missing", "invalid"] = "unknown"
    source_input: SourceInputRecord | None = None
    model_input: ModelInputRecord | None = None
    asr_word_count: int | None = None
    diarization_segment_count: int | None = None
    turn_count: int | None = None
    failure_code: str | None = None
    recovery: RecoveryEvidence = field(default_factory=lambda: RecoveryEvidence("not_run"))


@dataclass
class ProcessingEvidence:
    requested_streams: list[str]
    recovery_requested: bool
    schema_version: int = 1
    complete: bool = False
    entries: list[ProcessingEntry] = field(default_factory=list)

    def payload(self) -> dict:
        value = asdict(self)
        if len(self.entries) > MAX_SESSIONS * 2 or len(json.dumps(value, allow_nan=False, ensure_ascii=False).encode()) > MAX_EVIDENCE_BYTES:
            raise ValueError("Processing evidence exceeds the supported limit")
        return value


def _identity(info: os.stat_result) -> tuple:
    return file_identity(info)


def _regular(fd: int) -> os.stat_result:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("Source input must be a single-link regular file")
    return info


class SourceDirectory:
    def __init__(self, path: Path):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        self.identity = os.fstat(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        os.close(self.fd)

    @staticmethod
    def parts(relative: str) -> list[str]:
        parts = relative.split("/")
        if (len(relative.encode()) > 1024 or any(ord(c) < 32 or ord(c) == 127 for c in relative) or not parts or
                any(part in ("", ".", "..") for part in parts)):
            raise ValueError("Invalid source-relative path")
        return parts

    def validate(self) -> None:
        info = os.stat(self.path, follow_symlinks=False)
        if (info.st_dev, info.st_ino) != (self.identity.st_dev, self.identity.st_ino):
            raise InputChanged("Source folder identity changed")

    def open(self, relative: str, *, directory: bool = False) -> int:
        self.validate()
        parts = self.parts(relative)
        current = os.dup(self.fd)
        try:
            for index, part in enumerate(parts):
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
                if index < len(parts) - 1 or directory:
                    flags |= os.O_DIRECTORY
                child = os.open(part, flags, dir_fd=current)
                os.close(current)
                current = child
            if not directory:
                _regular(current)
            return current
        except BaseException:
            os.close(current)
            raise

    def names(self) -> list[str]:
        result = []
        with os.scandir(self.fd) as entries:
            for entry in entries:
                if len(result) >= 4096:
                    raise ValueError("Meeting directory entry limit exceeded")
                result.append(entry.name)
        return result

    def read_optional(self, relative: str, limit: int) -> bytes | None:
        try:
            fd = self.open(relative)
        except FileNotFoundError:
            return None
        try:
            before = _regular(fd)
            if before.st_size > limit:
                raise ValueError("Source metadata exceeds the size limit")
            data = bytearray()
            while len(data) < before.st_size:
                chunk = os.read(fd, min(65536, before.st_size - len(data)))
                if not chunk:
                    raise InputChanged("Source metadata truncated while reading")
                data.extend(chunk)
            self.verify(relative, fd, before)
            return bytes(data)
        finally:
            os.close(fd)

    def verify(self, relative: str, fd: int, before: os.stat_result) -> None:
        if _identity(_regular(fd)) != _identity(before):
            raise InputChanged("Source input changed while copying")
        other = self.open(relative)
        try:
            if _identity(_regular(other)) != _identity(before):
                raise InputChanged("Source input path changed while copying")
        finally:
            os.close(other)

    def copy(self, relative: str, destination: Path, budget: SnapshotBudget,
             *, committed_bytes: int | None = None) -> dict:
        fd = self.open(relative)
        try:
            before = _regular(fd)
            count = before.st_size if committed_bytes is None else committed_bytes
            if count > MAX_FILE_BYTES or count < 0:
                raise ValueError("Source snapshot exceeds the size limit")
            if before.st_size < count:
                raise ValueError("Truncated committed source recording")
            budget.reserve_bytes(count)
            destination.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with destination.open("xb") as output:
                remaining = count
                while remaining:
                    chunk = os.read(fd, min(65536, remaining))
                    if not chunk:
                        raise InputChanged("Source input truncated while copying")
                    output.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
            self.verify(relative, fd, before)
            return {"relative_path": relative, "byte_count": count, "sha256": digest.hexdigest()}
        finally:
            os.close(fd)


class OwnedFile:
    """Retain one private inode and verify bytes around every actual call."""
    def __init__(self, path: Path, expected_sha256: str | None = None):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            self.identity = _regular(self.fd)
            if self.identity.st_size > MAX_FILE_BYTES:
                raise ValueError("Normalized model input exceeds the size limit")
            self.sha256 = self._digest()
            if expected_sha256 is not None and self.sha256 != expected_sha256:
                raise InputChanged("Owned source bytes changed before processing")
            self.verify()
        except BaseException:
            os.close(self.fd)
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        os.close(self.fd)

    def _digest(self) -> str:
        os.lseek(self.fd, 0, os.SEEK_SET)
        digest = hashlib.sha256()
        remaining = self.identity.st_size
        while remaining:
            chunk = os.read(self.fd, min(remaining, 65536))
            if not chunk:
                raise InputChanged("Owned model input truncated")
            digest.update(chunk)
            remaining -= len(chunk)
        return digest.hexdigest()

    def verify(self) -> None:
        try:
            self._verify()
        except InputChanged:
            raise
        except (OSError, ValueError) as error:
            raise InputChanged("Owned model input became unavailable or changed shape") from error

    def _verify(self) -> None:
        info = os.stat(self.path, follow_symlinks=False)
        if (_identity(info) != _identity(self.identity) or
                _identity(_regular(self.fd)) != _identity(self.identity) or self._digest() != self.sha256 or
                _identity(_regular(self.fd)) != _identity(self.identity) or
                _identity(os.stat(self.path, follow_symlinks=False)) != _identity(self.identity)):
            raise InputChanged("Owned model input changed during processing")

class ModelInput(OwnedFile):
    def __init__(self, path: Path, expected: ProducedWAV | None = None):
        try:
            super().__init__(path, expected.sha256 if expected else None)
        except (OSError, ValueError) as error:
            if expected is None or isinstance(error, InputChanged):
                raise
            raise InputChanged("Produced WAV became unavailable or changed shape before admission") from error
        try:
            if expected is not None and (
                    _identity(self.identity) != expected.file_identity or
                    (expected.sample_rate, expected.channels, expected.sample_width) != (16000, 1, 2)):
                raise InputChanged("Produced WAV identity or format changed before admission")
            with wave.open(str(path), "rb") as wav:
                if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getcomptype()) != (16000, 1, 2, "NONE"):
                    raise ValueError("Model input is not normalized PCM16 mono 16 kHz")
                self.frame_count = wav.getnframes()
                if expected is not None and (
                        expected.frame_count != self.frame_count or expected.sample_rate != 16000 or
                        expected.channels != 1 or expected.sample_width != 2 or
                        expected.byte_count != self.identity.st_size):
                    raise InputChanged("Produced WAV shape changed before admission")
                # Read the declared frames to reject truncated WAV data; chunked.
                remaining = self.frame_count
                while remaining:
                    data = wav.readframes(min(remaining, 32768))
                    if not data or len(data) % 2:
                        raise ValueError("Truncated normalized model input")
                    remaining -= len(data) // 2
            self.verify()
        except BaseException:
            os.close(self.fd)
            raise

    def payload(self) -> ModelInputRecord:
        return {"format": "wav_pcm_s16le", "sample_rate": 16000, "channels": 1,
                "frame_count": self.frame_count, "byte_count": self.identity.st_size,
                "sha256": self.sha256}


def legacy_wav_details(path: Path) -> dict:
    """Verify source frames on the private copy, including unselected streams.

    Empty is exactly zero readable frames, never a model or timestamp inference.
    Only uncompressed WAV families are the supported historical app sources.
    """
    with sf.SoundFile(str(path)) as source:
        if (source.format not in ("WAV", "WAVEX", "RF64") or
                source.subtype not in ("PCM_U8", "PCM_16", "PCM_24", "PCM_32", "FLOAT", "DOUBLE") or
                not 1 <= source.samplerate <= 384000 or not 1 <= source.channels <= 32 or
                not 0 <= source.frames <= source.samplerate * 86400):
            raise ValueError("Unsupported historical source WAV")
        remaining = source.frames
        while remaining:
            data = source.buffer_read(min(remaining, 32768), dtype="int16")
            frames = len(data) // (source.channels * 2)
            if not frames:
                raise ValueError("Truncated historical source WAV")
            remaining -= frames
        return {"sample_rate": source.samplerate, "channels": source.channels,
                "frame_count": source.frames, "encoding": source.subtype}
