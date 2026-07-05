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
    """
    Stands in for asr.ASRModel: no real model load, scripted transcripts (or
    exceptions) per path. If the scripted value for a path is an Exception
    instance, transcribe() raises it instead of returning - used to test
    that a single window's ASR failure doesn't take down the whole stream.
    """

    def __init__(self, model_id: str, transcripts_by_path: dict) -> None:
        self.model_id = model_id
        self._transcripts_by_path = transcripts_by_path
        self.calls: list[str] = []

    def transcribe(self, path: str, language=None) -> TranscriptResult:
        self.calls.append(path)
        value = self._transcripts_by_path[path]
        if isinstance(value, Exception):
            raise value
        return value


class FakeDiarizer:
    def __init__(self, segments: list[DiarSegment], **_kwargs) -> None:
        self._segments = segments

    def diarise(self, _path: str) -> list[DiarSegment]:
        return self._segments


def _default_slice_fn(wav_path, start, end):
    return SLICE_WAV


def _patch_common(monkeypatch, segments, transcripts_by_path, file_duration=120.0, slice_fn=None):
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
        slice_fn or _default_slice_fn,
    )
    return fake_asr


def _run(audio_path, recovery: bool):
    return reprocess.reprocess_stream(
        audio_path,
        "system",
        diar_backend="senko",
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


def test_recovery_isolates_a_failing_window_and_still_recovers_the_others(
    monkeypatch, tmp_path
) -> None:
    """
    Gate fix (BLOCKING): a slice/ASR failure on one recovery window must not
    take down the stream, and must not stop other windows from being tried.
    """
    audio_path = tmp_path / "MAIN.wav"
    segments = [
        DiarSegment(start=0.0, end=3.0, speaker="SPEAKER_00"),
        DiarSegment(start=20.0, end=25.0, speaker="SPEAKER_03"),  # window A - will fail
        DiarSegment(start=50.0, end=55.0, speaker="SPEAKER_04"),  # window B - recovers fine
        DiarSegment(start=90.0, end=93.0, speaker="SPEAKER_01"),
    ]
    main_transcript = TranscriptResult(
        text="hello there general kenobi",
        words=[
            Word(text="hello", start=0.0, end=1.0),
            Word(text="there", start=1.2, end=2.0),
            Word(text="general", start=90.0, end=90.8),
            Word(text="kenobi", start=91.0, end=91.8),
        ],
    )
    # Window A is padded to start at 19.0, window B at 49.0 - use that to
    # give each window a distinguishable fake slice path.
    slice_path_a = "SLICE_A_19.0.wav"
    slice_path_b = "SLICE_B_49.0.wav"

    def fake_slice(wav_path, start, end):
        return slice_path_a if abs(start - 19.0) < 0.01 else slice_path_b

    recovered_transcript_b = TranscriptResult(
        text="found it",
        words=[
            Word(text="found", start=1.5, end=2.0),  # slice-relative -> absolute 50.5-51.0
            Word(text="it", start=2.1, end=2.4),  # absolute 51.1-51.4
        ],
    )

    fake_asr = _patch_common(
        monkeypatch,
        segments,
        {
            str(audio_path): main_transcript,
            slice_path_a: RuntimeError("simulated zero-frame slice failure"),
            slice_path_b: recovered_transcript_b,
        },
        slice_fn=fake_slice,
    )

    # Must not raise - a window failure is swallowed, not propagated.
    result = _run(audio_path, recovery=True)

    # Both windows were attempted despite A raising.
    assert fake_asr.calls == [str(audio_path), slice_path_a, slice_path_b]

    speaker_ids = {turn["speaker_id"] for turn in result["turns"]}
    # A's speaker never got words (recovery failed) - correctly still absent.
    assert "system:SPEAKER_03" not in speaker_ids
    # B's speaker was recovered despite A's failure.
    assert "system:SPEAKER_04" in speaker_ids
    # The main transcript's untouched speakers are still present.
    assert "system:SPEAKER_00" in speaker_ids
    assert "system:SPEAKER_01" in speaker_ids

    recovered_turn = next(t for t in result["turns"] if t["speaker_id"] == "system:SPEAKER_04")
    assert "found" in recovered_turn["text"]
    assert "it" in recovered_turn["text"]


def test_recovery_replaces_partial_coverage_words_without_duplicating(
    monkeypatch, tmp_path
) -> None:
    """
    Gate fix (ADVISORY): a segment with partial (<10%) coverage has its
    few original words REPLACED by the recovered words, not duplicated
    alongside them.
    """
    audio_path = tmp_path / "MAIN.wav"
    segments = [DiarSegment(start=0.0, end=10.0, speaker="SPEAKER_00")]
    # "um" covers 0.3s of a 10s segment (3%) - below the 10% coverage bar,
    # so the whole segment is flagged for recovery despite having a word.
    main_transcript = TranscriptResult(
        text="um",
        words=[Word(text="um", start=0.0, end=0.3)],
    )
    # Window is padded to [0.0, 11.0] (clamped at 0); slice-relative == the
    # same absolute values here since the window starts at 0.
    slice_transcript = TranscriptResult(
        text="right now we are on the build screen",
        words=[
            Word(text="right", start=1.0, end=1.5),
            Word(text="now", start=1.6, end=1.9),
            Word(text="we", start=2.0, end=2.2),
            Word(text="are", start=2.3, end=2.5),
        ],
    )
    fake_asr = _patch_common(
        monkeypatch,
        segments,
        {str(audio_path): main_transcript, SLICE_WAV: slice_transcript},
    )

    result = _run(audio_path, recovery=True)

    assert fake_asr.calls == [str(audio_path), SLICE_WAV]
    assert len(result["turns"]) == 1
    turn = result["turns"][0]
    assert "um" not in turn["text"].split()
    assert "right" in turn["text"]
    assert "are" in turn["text"]


def test_recovery_leaves_partial_words_in_place_when_that_window_recovers_nothing(
    monkeypatch, tmp_path
) -> None:
    """
    Gate fix (ADVISORY, negative case): if a partial-coverage window's
    recovery attempt comes back empty, its original words must survive
    untouched - only windows that actually recovered replacement words get
    their originals dropped.
    """
    audio_path = tmp_path / "MAIN.wav"
    segments = [
        DiarSegment(start=0.0, end=10.0, speaker="SPEAKER_00"),  # partial coverage, recovers nothing
        DiarSegment(start=50.0, end=55.0, speaker="SPEAKER_01"),  # zero coverage, recovers fine
    ]
    main_transcript = TranscriptResult(
        text="um",
        words=[Word(text="um", start=0.0, end=0.3)],
    )
    slice_path_x = "SLICE_X_0.0.wav"
    slice_path_y = "SLICE_Y_49.0.wav"

    def fake_slice(wav_path, start, end):
        return slice_path_x if abs(start - 0.0) < 0.01 else slice_path_y

    recovered_transcript_y = TranscriptResult(
        text="found it",
        words=[Word(text="found", start=1.5, end=2.0), Word(text="it", start=2.1, end=2.4)],
    )

    fake_asr = _patch_common(
        monkeypatch,
        segments,
        {
            str(audio_path): main_transcript,
            slice_path_x: TranscriptResult(text="", words=[]),  # still empty
            slice_path_y: recovered_transcript_y,
        },
        slice_fn=fake_slice,
    )

    result = _run(audio_path, recovery=True)

    assert fake_asr.calls == [str(audio_path), slice_path_x, slice_path_y]

    speaker_00_turn = next(t for t in result["turns"] if t["speaker_id"] == "system:SPEAKER_00")
    assert "um" in speaker_00_turn["text"].split()

    speaker_01_turn = next(t for t in result["turns"] if t["speaker_id"] == "system:SPEAKER_01")
    assert "found" in speaker_01_turn["text"]
