"""
Merge diarisation segments with ASR word timestamps.

Assigns speaker labels to words and produces speaker-labelled output.
"""

import json
from dataclasses import dataclass, asdict
from typing import List, Optional, Dict, Any

from .asr import Word, TranscriptResult
from .diarisation import DiarSegment
from .audio import format_timestamp, format_srt_timestamp


@dataclass
class LabelledWord:
    """A word with speaker label."""
    text: str
    start: float
    end: float
    speaker: str


@dataclass
class SpeakerTurn:
    """A continuous turn by one speaker."""
    speaker: str
    start: float
    end: float
    text: str
    words: List[LabelledWord]


@dataclass
class MergedTranscript:
    """Full transcript with speaker labels."""
    turns: List[SpeakerTurn]
    words: List[LabelledWord]
    segments: List[DiarSegment]  # Original diarisation segments


def assign_speakers_to_words(
    words: List[Word],
    segments: List[DiarSegment],
    tolerance: float = 0.5,
) -> List[LabelledWord]:
    """
    Assign speaker labels to words based on overlap with diarisation segments.

    Args:
        words: List of words with timestamps from ASR
        segments: List of speaker segments from diarisation
        tolerance: Maximum gap (seconds) to assign nearest segment

    Returns:
        List of LabelledWord with speaker assignments
    """
    # Sort words by start time and filter invalid timestamps
    sorted_words = sorted(words, key=lambda w: w.start)
    sorted_words = [w for w in sorted_words if w.end > w.start]

    labelled = []

    for word in sorted_words:
        word_mid = (word.start + word.end) / 2
        best_speaker = "UNKNOWN"
        best_overlap = 0.0
        nearest_speaker = None
        min_distance = float("inf")

        for seg in segments:
            # Calculate overlap
            overlap_start = max(word.start, seg.start)
            overlap_end = min(word.end, seg.end)
            overlap = max(0, overlap_end - overlap_start)

            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = seg.speaker

            # Also track nearest segment for fallback
            if word_mid < seg.start:
                dist = seg.start - word_mid
            elif word_mid > seg.end:
                dist = word_mid - seg.end
            else:
                dist = 0

            if dist < min_distance:
                min_distance = dist
                nearest_speaker = seg.speaker

        # Use nearest speaker within tolerance if no overlap
        if best_overlap == 0 and nearest_speaker and min_distance <= tolerance:
            best_speaker = nearest_speaker

        labelled.append(LabelledWord(
            text=word.text,
            start=word.start,
            end=word.end,
            speaker=best_speaker,
        ))

    # Post-process: interpolate UNKNOWN speakers from context
    labelled = _interpolate_unknown_speakers(labelled)

    return labelled


def _interpolate_unknown_speakers(words: List[LabelledWord]) -> List[LabelledWord]:
    """
    Fill in UNKNOWN speakers by looking at surrounding context.

    If a word is UNKNOWN but surrounded by the same speaker, inherit that speaker.
    """
    if not words:
        return words

    result = list(words)

    # Forward pass: inherit from previous known speaker
    last_known = None
    for i, word in enumerate(result):
        if word.speaker != "UNKNOWN":
            last_known = word.speaker
        elif last_known is not None:
            # Look ahead to see if next known speaker matches
            next_known = None
            for j in range(i + 1, min(i + 10, len(result))):
                if result[j].speaker != "UNKNOWN":
                    next_known = result[j].speaker
                    break

            # If surrounded by same speaker, or no next speaker, inherit
            if next_known is None or next_known == last_known:
                result[i] = LabelledWord(
                    text=word.text,
                    start=word.start,
                    end=word.end,
                    speaker=last_known,
                )

    # Backward pass: fill remaining UNKNOWNs from next known speaker
    next_known = None
    for i in range(len(result) - 1, -1, -1):
        word = result[i]
        if word.speaker != "UNKNOWN":
            next_known = word.speaker
        elif next_known is not None:
            result[i] = LabelledWord(
                text=word.text,
                start=word.start,
                end=word.end,
                speaker=next_known,
            )

    return result


def _join_words_smart(words: List[LabelledWord]) -> str:
    """
    Intelligently join words handling punctuation.

    Words are now properly merged from BPE tokens, so we mainly
    need to handle punctuation spacing.
    """
    if not words:
        return ""

    parts = []
    for w in words:
        text = w.text
        if not text:
            continue

        # Punctuation that should attach to previous word (no leading space)
        if parts and text in ".,!?;:)]}\"'":
            parts.append(text)
        # Opening brackets/quotes attach to next word (no trailing space after)
        elif text in "([{\"'" and parts:
            parts.append(" " + text)
        elif parts:
            parts.append(" " + text)
        else:
            parts.append(text)

    result = "".join(parts)
    # Clean up any double spaces
    while "  " in result:
        result = result.replace("  ", " ")
    return result.strip()


def words_to_turns(
    words: List[LabelledWord],
    gap_threshold: float = 0.8,
    max_turn_duration: float = 60.0,
) -> List[SpeakerTurn]:
    """
    Group consecutive words into speaker turns.

    A new turn starts when:
    - The speaker changes, OR
    - There's a gap > gap_threshold seconds, OR
    - The turn exceeds max_turn_duration seconds

    Args:
        words: List of speaker-labelled words
        gap_threshold: Maximum gap before starting new turn
        max_turn_duration: Maximum duration before forcing a new turn

    Returns:
        List of SpeakerTurn
    """
    if not words:
        return []

    turns = []
    current_words = [words[0]]
    current_speaker = words[0].speaker

    for word in words[1:]:
        gap = word.start - current_words[-1].end
        speaker_change = word.speaker != current_speaker
        turn_duration = word.end - current_words[0].start

        # Break turn if speaker changes, gap too large, or turn too long
        if speaker_change or gap > gap_threshold or turn_duration > max_turn_duration:
            # Finish current turn
            turn_text = _join_words_smart(current_words)
            turns.append(SpeakerTurn(
                speaker=current_speaker,
                start=current_words[0].start,
                end=current_words[-1].end,
                text=turn_text,
                words=list(current_words),
            ))
            current_words = [word]
            current_speaker = word.speaker
        else:
            current_words.append(word)

    # Don't forget last turn
    if current_words:
        turn_text = _join_words_smart(current_words)
        turns.append(SpeakerTurn(
            speaker=current_speaker,
            start=current_words[0].start,
            end=current_words[-1].end,
            text=turn_text,
            words=list(current_words),
        ))

    return turns


def merge_transcript_with_diarisation(
    transcript: TranscriptResult,
    segments: List[DiarSegment],
    gap_threshold: float = 0.8,
    speaker_tolerance: float = 0.5,
    max_turn_duration: float = 60.0,
) -> MergedTranscript:
    """
    Merge ASR transcript with diarisation segments.

    Args:
        transcript: ASR result with words
        segments: Diarisation segments
        gap_threshold: Gap threshold for turn splitting
        speaker_tolerance: Tolerance for speaker assignment
        max_turn_duration: Maximum turn duration before splitting

    Returns:
        MergedTranscript with speaker-labelled turns and words
    """
    # Assign speakers to words
    labelled_words = assign_speakers_to_words(
        transcript.words,
        segments,
        tolerance=speaker_tolerance,
    )

    # Group into turns
    turns = words_to_turns(
        labelled_words,
        gap_threshold=gap_threshold,
        max_turn_duration=max_turn_duration,
    )

    return MergedTranscript(
        turns=turns,
        words=labelled_words,
        segments=segments,
    )


# Output formatters

def format_text_output(merged: MergedTranscript) -> str:
    """Format as plain text with speaker labels and timestamps."""
    lines = []
    for turn in merged.turns:
        start_ts = format_timestamp(turn.start)
        end_ts = format_timestamp(turn.end)
        lines.append(f"[{start_ts} - {end_ts}] {turn.speaker}: {turn.text}")
    return "\n".join(lines)


def format_json_output(merged: MergedTranscript) -> str:
    """Format as JSON with full detail."""
    data = {
        "turns": [
            {
                "speaker": turn.speaker,
                "start": turn.start,
                "end": turn.end,
                "text": turn.text,
                "words": [
                    {
                        "text": w.text,
                        "start": w.start,
                        "end": w.end,
                        "speaker": w.speaker,
                    }
                    for w in turn.words
                ],
            }
            for turn in merged.turns
        ],
        "segments": [
            {
                "speaker": seg.speaker,
                "start": seg.start,
                "end": seg.end,
            }
            for seg in merged.segments
        ],
    }
    return json.dumps(data, indent=2)


def format_srt_output(merged: MergedTranscript) -> str:
    """Format as SRT with speaker labels."""
    lines = []
    for i, turn in enumerate(merged.turns, start=1):
        start_ts = format_srt_timestamp(turn.start)
        end_ts = format_srt_timestamp(turn.end)
        lines.append(str(i))
        lines.append(f"{start_ts} --> {end_ts}")
        lines.append(f"[{turn.speaker}] {turn.text}")
        lines.append("")  # Blank line between entries
    return "\n".join(lines)


def format_rttm_output(segments: List[DiarSegment], filename: str = "audio") -> str:
    """
    Format as RTTM (Rich Transcription Time Marked).

    RTTM format: SPEAKER <file> <channel> <start> <duration> <NA> <NA> <speaker> <NA> <NA>
    """
    lines = []
    for seg in segments:
        duration = seg.end - seg.start
        # SPEAKER file channel start duration NA NA speaker NA NA
        lines.append(
            f"SPEAKER {filename} 1 {seg.start:.2f} {duration:.2f} <NA> <NA> {seg.speaker} <NA> <NA>"
        )
    return "\n".join(lines)
