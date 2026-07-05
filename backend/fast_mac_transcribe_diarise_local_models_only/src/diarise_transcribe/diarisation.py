"""
Shared diarisation data types.

The Sortformer CoreML diariser that used to live here was retired
(unused in production - Senko has been the sole diariser for months;
see `senko_diarisation.py`). `DiarSegment` is kept because it is the
shared segment type used across the merge/recovery/reprocess pipeline
regardless of which diariser produced it.
"""

from dataclasses import dataclass


@dataclass
class DiarSegment:
    """A speaker segment."""
    start: float  # seconds
    end: float  # seconds
    speaker: str  # e.g. "SPEAKER_00"

    @property
    def duration(self) -> float:
        return self.end - self.start
