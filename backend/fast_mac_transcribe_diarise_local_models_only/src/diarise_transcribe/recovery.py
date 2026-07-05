"""
ASR recovery pass for the batch reprocess pipeline.

Parakeet occasionally suffers a decoder collapse over a real speech span and
silently returns zero words for it, even though diarisation (Senko/Sortformer)
correctly detects a speaker there. Because the merge step only ever assigns
speakers to existing words, that speaker's turn vanishes from the output with
no error - silent data loss.

This module holds the pure logic for detecting and fixing that: find
diarised segments the main ASR pass produced little or no text for, cluster
them into re-transcription windows, and dedupe the recovered words against
the main pass. It has no model or file-I/O dependencies so it can be unit
tested without loading ASR/diarisation models.

The actual re-transcription (slicing audio, running the ASR model on each
window) happens in reprocess.py, which owns the ASRModel instance and the
audio file.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List

from .asr import Word
from .diarisation import DiarSegment


DEFAULT_MIN_SEGMENT_DURATION = 1.5
DEFAULT_COVERAGE_THRESHOLD = 0.10
DEFAULT_MERGE_GAP_SECONDS = 2.0
DEFAULT_WINDOW_PADDING_SECONDS = 1.0


@dataclass
class RecoveryWindow:
    """A span of audio to re-run ASR over.

    `start`/`end` are the padded bounds actually sliced for re-ASR, giving
    the model surrounding context. `gap_start`/`gap_end` are the un-padded
    bounds of the wordless diar segment(s) this window covers - a recovered
    word is only kept if its midpoint falls inside that un-padded range, so
    the padding never contributes duplicate words that the main pass already
    covered.
    """
    start: float
    end: float
    gap_start: float
    gap_end: float


def segment_word_coverage(segment: DiarSegment, words: List[Word]) -> float:
    """Seconds of `words` that overlap `segment`."""
    coverage = 0.0
    for word in words:
        overlap = min(word.end, segment.end) - max(word.start, segment.start)
        if overlap > 0:
            coverage += overlap
    return coverage


def find_wordless_segments(
    segments: List[DiarSegment],
    words: List[Word],
    min_duration: float = DEFAULT_MIN_SEGMENT_DURATION,
    coverage_threshold: float = DEFAULT_COVERAGE_THRESHOLD,
) -> List[DiarSegment]:
    """
    Return diar segments long enough to matter (> min_duration) whose ASR
    word coverage is zero, or below coverage_threshold of the segment's
    duration.
    """
    marked = []
    for segment in segments:
        duration = segment.end - segment.start
        if duration <= min_duration:
            continue
        coverage = segment_word_coverage(segment, words)
        if coverage == 0.0 or (coverage / duration) < coverage_threshold:
            marked.append(segment)
    return marked


def cluster_recovery_windows(
    segments: List[DiarSegment],
    file_duration: float,
    merge_gap: float = DEFAULT_MERGE_GAP_SECONDS,
    padding: float = DEFAULT_WINDOW_PADDING_SECONDS,
) -> List[RecoveryWindow]:
    """
    Merge overlapping/nearby (< merge_gap apart) wordless segments into
    recovery windows, then pad each by `padding` on both sides and clamp to
    [0, file_duration].
    """
    if not segments:
        return []

    ordered = sorted(segments, key=lambda seg: seg.start)

    spans: List[List[float]] = []
    for seg in ordered:
        if spans and seg.start - spans[-1][1] < merge_gap:
            spans[-1][1] = max(spans[-1][1], seg.end)
        else:
            spans.append([seg.start, seg.end])

    windows = []
    for gap_start, gap_end in spans:
        padded_start = max(0.0, gap_start - padding)
        padded_end = gap_end + padding
        if file_duration > 0:
            padded_end = min(file_duration, padded_end)
        windows.append(RecoveryWindow(
            start=padded_start,
            end=padded_end,
            gap_start=gap_start,
            gap_end=gap_end,
        ))
    return windows


def offset_words(words: List[Word], offset: float) -> List[Word]:
    """Shift word timestamps by `offset` seconds (e.g. a window's slice start)."""
    return [Word(text=w.text, start=w.start + offset, end=w.end + offset) for w in words]


def filter_words_in_window(words: List[Word], window: RecoveryWindow) -> List[Word]:
    """
    Keep only words whose midpoint falls inside the window's un-padded
    [gap_start, gap_end) span. Words re-transcribed from the padded context
    duplicate what the main ASR pass already produced there, so dropping
    them here is what makes splicing safe against double words.
    """
    kept = []
    for word in words:
        midpoint = (word.start + word.end) / 2
        if window.gap_start <= midpoint < window.gap_end:
            kept.append(word)
    return kept


def splice_words(original: List[Word], recovered: List[Word]) -> List[Word]:
    """Merge recovered words into the original list, sorted by start time."""
    if not recovered:
        return list(original)
    combined = list(original) + list(recovered)
    combined.sort(key=lambda w: w.start)
    return combined
