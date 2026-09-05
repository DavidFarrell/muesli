"""Producer-owned evidence for a private canonical PCM WAV handoff.

The PCM digest is accumulated from the bytes being derived, before admission.
Finishing verifies the original output descriptor against those observations;
a caller must never establish a new baseline by hashing a returned pathname.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
import stat
import struct
from typing import BinaryIO


class InputChanged(ValueError):
    """Source derivation or model input changed; its output is not certifiable."""


def file_identity(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def canonical_pcm_header(data_bytes: int, sample_rate: int, channels: int,
                         sample_width: int) -> bytes:
    if (type(data_bytes) is not int or not 0 <= data_bytes <= 2**32 - 37 or
            type(sample_rate) is not int or not 1 <= sample_rate <= 384000 or
            type(channels) is not int or not 1 <= channels <= 32 or
            type(sample_width) is not int or not 1 <= sample_width <= 4 or
            data_bytes % (channels * sample_width)):
        raise ValueError("Invalid canonical PCM WAV shape")
    frame_bytes = channels * sample_width
    return struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", data_bytes + 36,
                       b"WAVE", b"fmt ", 16, 1, channels, sample_rate,
                       sample_rate * frame_bytes, frame_bytes, sample_width * 8,
                       b"data", data_bytes)


@dataclass(frozen=True)
class ProducedWAV:
    path: str
    sha256: str
    frame_count: int
    sample_rate: int
    channels: int
    sample_width: int
    byte_count: int
    file_identity: tuple[int, ...]

    def __fspath__(self) -> str:
        return self.path


class WAVDerivation:
    """Track incoming PCM and certify the same descriptor the producer wrote."""
    def __init__(self, sample_rate: int, channels: int, sample_width: int):
        canonical_pcm_header(0, sample_rate, channels, sample_width)
        self.sample_rate = sample_rate
        self.channels = channels
        self.sample_width = sample_width
        self.data_bytes = 0
        self.pcm_digest = hashlib.sha256()

    def observe(self, pcm: bytes) -> None:
        count = self.data_bytes + len(pcm)
        canonical_pcm_header(count, self.sample_rate, self.channels, self.sample_width)
        self.pcm_digest.update(pcm)
        self.data_bytes = count

    def finish(self, output: BinaryIO, path: str) -> ProducedWAV:
        try:
            return self._finish(output, path)
        except OSError as error:
            raise InputChanged("Produced WAV became unavailable before handoff") from error

    def _finish(self, output: BinaryIO, path: str) -> ProducedWAV:
        # wave has finalized its header, but the original producer descriptor
        # remains open. No reopen of the returned path defines this digest.
        output.flush()
        before = os.fstat(output.fileno())
        expected_header = canonical_pcm_header(
            self.data_bytes, self.sample_rate, self.channels, self.sample_width)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or
                before.st_size != self.data_bytes + len(expected_header)):
            raise InputChanged("Produced WAV size or identity changed")
        output.seek(0)
        if output.read(len(expected_header)) != expected_header:
            raise InputChanged("Produced WAV header changed")
        observed_pcm = hashlib.sha256()
        canonical_wav = hashlib.sha256(expected_header)
        remaining = self.data_bytes
        while remaining:
            chunk = output.read(min(remaining, 65536))
            if not chunk:
                raise InputChanged("Produced WAV was truncated")
            observed_pcm.update(chunk)
            canonical_wav.update(chunk)
            remaining -= len(chunk)
        if (observed_pcm.digest() != self.pcm_digest.digest() or
                file_identity(os.fstat(output.fileno())) != file_identity(before) or
                file_identity(os.stat(path, follow_symlinks=False)) != file_identity(before)):
            raise InputChanged("Produced WAV bytes or identity changed")
        return ProducedWAV(path, canonical_wav.hexdigest(),
                           self.data_bytes // (self.channels * self.sample_width),
                           self.sample_rate, self.channels, self.sample_width,
                           before.st_size, file_identity(before))
