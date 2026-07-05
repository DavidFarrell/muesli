"""
Tests for the ASR recovery pass wired into reprocess_stream.

These mock the ASR model, diarizer, and audio helpers - no models are
loaded and no real audio files are touched, matching the project's
existing reprocess tests.
"""

from diarise_transcribe import reprocess
from diarise_transcribe.asr import TranscriptResult, Word
from diarise_transcribe.diarisation import DiarSegment


SLICE_WAV = "SLICE.wav"


class FakeASRModel:
    """Stands in for asr.ASRModel: no real model load, scripted transcripts per path."""

    def __init__(self, model_id: str, transcripts_by_path: dict) -> None:
        self.model_id = model_id
        self._transcripts_by_path = transcripts_by_path
        self.calls: list[str] = []

    def transcribe(self, path: str, language=None) -> TranscriptResult:
        self.calls.append(path)
        return self._transcripts_by_path[path]


class FakeDiarizer:
    def __init__(self, segments: list[DiarSegment], **_kwargs) -> None:
        self._segments = segments

    def diarise(self, _path: str) -> list[DiarSegment]:
        return self._segments


def _patch_common(monkeypatch, segments, transcripts_by_path, file_duration=120.0):
    fake_asr = FakeASRModel(reprocess.DEFAULT_MODEL, transcripts_by_path)

    monkeypatch.setattr(reprocess, "is_wav_16k_mono", lambda path: True)
    monkeypatch.setattr(reprocess, "get_audio_duration", lambda path: file_duration)
    monkeypatch.setattr(reprocess, "ASRModel", lambda model_id: fake_asr)
    monkeypatch.setattr(
        reprocess,
        "SenkoDiarizer",
        lambda **kwargs: FakeDiarizer(segments, **kwargs),
    )
    monkeypatch.setattr(
        reprocess,
        "slice_wav_to_temp",
        lambda wav_path, start, end: SLICE_WAV,
    )
    return fake_asr


def _run(audio_path, recovery: bool):
    return reprocess.reprocess_stream(
        audio_path,
        "system",
        diar_backend="senko",
        diar_model="default",
        asr_model=reprocess.DEFAULT_MODEL,
        language=None,
        gap_threshold=reprocess.DEFAULT_GAP_THRESHOLD_SECONDS,
        speaker_tolerance=reprocess.DEFAULT_SPEAKER_TOLERANCE_SECONDS,
        verbose=False,
        recovery=recovery,
    )


def test_recovery_noop_when_all_segments_well_covered(monkeypatch, tmp_path) -> None:
    audio_path = tmp_path / "MAIN.wav"
    segments = [
        DiarSegment(start=0.0, end=5.0, speaker="SPEAKER_00"),
        DiarSegment(start=5.5, end=10.0, speaker="SPEAKER_01"),
    ]
    main_transcript = TranscriptResult(
        text="hello there general kenobi",
        words=[
            Word(text="hello", start=0.0, end=1.0),
            Word(text="there", start=1.5, end=2.5),
            Word(text="general", start=5.5, end=6.5),
            Word(text="kenobi", start=7.0, end=8.0),
        ],
    )

    fake_asr = _patch_common(monkeypatch, segments, {str(audio_path): main_transcript})
    result_with_recovery = _run(audio_path, recovery=True)

    # Only the one main-pass transcribe call - recovery found nothing to do,
    # so it never touched ASR again.
    assert fake_asr.calls == [str(audio_path)]

    _patch_common(monkeypatch, segments, {str(audio_path): main_transcript})
    result_without_recovery = _run(audio_path, recovery=False)

    # Recovery enabled-but-inert output is identical to recovery disabled.
    assert result_with_recovery == result_without_recovery


def test_recovery_recovers_wordless_segment_and_splices_speaker_back_in(
    monkeypatch, tmp_path
) -> None:
    audio_path = tmp_path / "MAIN.wav"
    # Speaker in the middle segment (83.7-95.0) got zero words from the main
    # ASR pass (the decoder-collapse bug), even though Senko detected them.
    # The flanking segments carry words densely enough (well over the 10%
    # coverage bar) that they must NOT be flagged for recovery themselves.
    segments = [
        DiarSegment(start=0.0, end=3.0, speaker="SPEAKER_00"),
        DiarSegment(start=83.7, end=95.0, speaker="SPEAKER_03"),
        DiarSegment(start=96.5, end=100.0, speaker="SPEAKER_01"),
    ]
    main_transcript = TranscriptResult(
        text="intro video here outro video there",
        words=[
            Word(text="intro", start=0.0, end=0.8),
            Word(text="video", start=0.9, end=1.6),
            Word(text="here", start=1.7, end=2.4),
            Word(text="outro", start=96.6, end=97.4),
            Word(text="video", start=97.5, end=98.2),
            Word(text="there", start=98.3, end=99.0),
        ],
    )
    # The recovery slice covers [82.7, 96.0] (padded start 82.7 = gap_start
    # 83.7 - 1.0s padding). ASR on a slice returns timestamps relative to
    # that slice, so these are slice-relative (0.0 = 82.7s absolute) - the
    # code under test is what re-applies the +82.7 offset. "ignored" sits at
    # slice-relative 12.5s = absolute 95.2s, in the padded margin beyond the
    # gap (which ends at 95.0), and must be dropped by the midpoint filter.
    slice_transcript = TranscriptResult(
        text="right now we are on the build screen ignored",
        words=[
            Word(text="right", start=1.3, end=1.8),
            Word(text="now", start=1.9, end=2.2),
            Word(text="we", start=2.3, end=2.5),
            Word(text="are", start=2.6, end=2.8),
            Word(text="on", start=2.9, end=3.0),
            Word(text="the", start=3.1, end=3.2),
            Word(text="build", start=3.3, end=3.8),
            Word(text="screen", start=3.9, end=4.3),
            Word(text="ignored", start=12.5, end=12.9),  # outside the gap -> dropped
        ],
    )
    fake_asr = _patch_common(
        monkeypatch,
        segments,
        {str(audio_path): main_transcript, SLICE_WAV: slice_transcript},
    )

    result = _run(audio_path, recovery=True)

    assert fake_asr.calls == [str(audio_path), SLICE_WAV]

    speaker_ids = {turn["speaker_id"] for turn in result["turns"]}
    assert "system:SPEAKER_03" in speaker_ids

    recovered_turn = next(t for t in result["turns"] if t["speaker_id"] == "system:SPEAKER_03")
    assert "build" in recovered_turn["text"]
    assert "screen" in recovered_turn["text"]
    assert "ignored" not in recovered_turn["text"]


def test_recovery_still_empty_after_attempt_leaves_transcript_unchanged(
    monkeypatch, tmp_path
) -> None:
    audio_path = tmp_path / "MAIN.wav"
    segments = [
        DiarSegment(start=0.0, end=2.0, speaker="SPEAKER_00"),
        DiarSegment(start=10.0, end=15.0, speaker="SPEAKER_01"),  # never gets words
    ]
    main_transcript = TranscriptResult(
        text="hello",
        words=[Word(text="hello", start=0.0, end=1.0)],
    )
    # Recovery slice ASR also returns nothing - genuinely unrecoverable audio.
    empty_slice_transcript = TranscriptResult(text="", words=[])
    fake_asr = _patch_common(
        monkeypatch,
        segments,
        {str(audio_path): main_transcript, SLICE_WAV: empty_slice_transcript},
    )

    result = _run(audio_path, recovery=True)

    # One recovery attempt was made (ASR called twice) but nothing came
    # back, so no SPEAKER_01 turn should appear and no infinite retry.
    assert fake_asr.calls == [str(audio_path), SLICE_WAV]
    speaker_ids = {turn["speaker_id"] for turn in result["turns"]}
    assert "system:SPEAKER_01" not in speaker_ids
