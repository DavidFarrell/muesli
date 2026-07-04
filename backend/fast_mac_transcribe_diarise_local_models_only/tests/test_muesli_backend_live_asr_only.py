"""Tests for live-asr-only mode (--live-asr-only): diariser-free live turns
labelled by stream, and the fast incremental finalize pass on stop.
"""

import wave
from pathlib import Path

from diarise_transcribe import muesli_backend as mb
from diarise_transcribe.asr import TranscriptResult, Word


def _write_silent_wav(path: Path, seconds: float = 1.0, sample_rate: int = 16000) -> None:
    n_frames = int(seconds * sample_rate)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * n_frames)


class _FakeASRModel:
    """Stand-in for ASRModel that returns a fixed transcript without loading
    any real model, so run_pipeline can be exercised in isolation."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id

    def transcribe(self, path, language=None) -> TranscriptResult:
        words = [
            Word(text="hello", start=0.0, end=0.5),
            Word(text="there", start=0.5, end=1.0),
            # Gap larger than the default gap_threshold (0.8s) should still
            # split into a second turn even though the speaker is the same.
            Word(text="world", start=3.0, end=3.5),
        ]
        return TranscriptResult(text="hello there world", words=words)


def test_synthetic_stream_segments_spans_transcript_word_range():
    transcript = TranscriptResult(
        text="a b",
        words=[Word(text="a", start=1.0, end=1.5), Word(text="b", start=2.0, end=2.5)],
    )
    segments = mb._synthetic_stream_segments(transcript, "Microphone")
    assert len(segments) == 1
    assert segments[0].speaker == "Microphone"
    assert segments[0].start == 1.0
    assert segments[0].end == 2.5


def test_synthetic_stream_segments_empty_when_no_words():
    transcript = TranscriptResult(text="", words=[])
    assert mb._synthetic_stream_segments(transcript, "System") == []


def test_run_pipeline_live_asr_only_labels_turns_by_stream(tmp_path, monkeypatch):
    monkeypatch.setattr(mb, "ASRModel", _FakeASRModel)

    def _diarizer_should_not_be_called(*args, **kwargs):
        raise AssertionError("diariser must not run in live-asr-only mode")

    monkeypatch.setattr(mb, "SortformerDiarizer", _diarizer_should_not_be_called)

    wav_path = tmp_path / "chunk.wav"
    _write_silent_wav(wav_path)

    merged = mb.run_pipeline(
        input_path=wav_path,
        diar_backend="senko",  # would normally import senko_diarisation; must be bypassed
        diar_model="default",
        asr_model="fake",
        language=None,
        gap_threshold=0.8,
        speaker_tolerance=0.25,
        verbose=False,
        live_asr_only=True,
        stream_label="Microphone",
    )

    # Turn splitting on the >0.8s gap still happens (existing merge machinery).
    assert len(merged.turns) == 2
    assert all(turn.speaker == "Microphone" for turn in merged.turns)
    assert merged.turns[0].text == "hello there"
    assert merged.turns[1].text == "world"


def test_run_pipeline_live_asr_only_applies_timestamp_offset(tmp_path, monkeypatch):
    monkeypatch.setattr(mb, "ASRModel", _FakeASRModel)

    wav_path = tmp_path / "chunk.wav"
    _write_silent_wav(wav_path)

    merged = mb.run_pipeline(
        input_path=wav_path,
        diar_backend="senko",
        diar_model="default",
        asr_model="fake",
        language=None,
        gap_threshold=0.8,
        speaker_tolerance=0.25,
        verbose=False,
        timestamp_offset=100.0,
        live_asr_only=True,
        stream_label="System",
    )

    assert merged.turns[0].start == 100.0
    assert merged.turns[-1].end == 103.5


def test_emit_transcript_live_asr_only_speaker_id_has_no_stream_prefix():
    from diarise_transcribe.merge import LabelledWord, MergedTranscript, SpeakerTurn

    class _FakeWriter:
        def __init__(self):
            self.lines = []

        def write(self, line):
            self.lines.append(line)

    writer = _FakeWriter()
    emitter = mb.TranscriptEmitter(writer, finalize_lag=0.0)
    turn = SpeakerTurn(speaker="Microphone", start=0.0, end=1.0, text="hi", words=[])
    merged = MergedTranscript(turns=[turn], words=[], segments=[])

    emitter.emit_transcript(merged, current_duration=1.0, finalize=True, stream_name="mic", live_asr_only=True)

    import json
    events = [json.loads(line) for line in writer.lines]
    segment_events = [e for e in events if e["type"] == "segment"]
    assert len(segment_events) == 1
    assert segment_events[0]["speaker_id"] == "Microphone"


def test_emit_transcript_default_mode_still_prefixes_speaker_id():
    from diarise_transcribe.merge import MergedTranscript, SpeakerTurn

    class _FakeWriter:
        def __init__(self):
            self.lines = []

        def write(self, line):
            self.lines.append(line)

    writer = _FakeWriter()
    emitter = mb.TranscriptEmitter(writer, finalize_lag=0.0)
    turn = SpeakerTurn(speaker="SPEAKER_00", start=0.0, end=1.0, text="hi", words=[])
    merged = MergedTranscript(turns=[turn], words=[], segments=[])

    emitter.emit_transcript(merged, current_duration=1.0, finalize=True, stream_name="mic", live_asr_only=False)

    import json
    events = [json.loads(line) for line in writer.lines]
    segment_events = [e for e in events if e["type"] == "segment"]
    assert segment_events[0]["speaker_id"] == "mic:SPEAKER_00"


def test_compute_incremental_window_looks_back_by_context_and_clamps_at_zero():
    bytes_per_sec = 32000.0  # 16kHz mono 16-bit

    # Plenty of history before last_processed_byte: window starts context seconds back.
    read_start, offset = mb.compute_incremental_window(
        last_processed_byte=int(100 * bytes_per_sec),
        bytes_per_sec=bytes_per_sec,
        context_seconds=30.0,
    )
    assert read_start == int(70 * bytes_per_sec)
    assert offset == 70.0

    # Not enough history: clamp to the start of the stream.
    read_start, offset = mb.compute_incremental_window(
        last_processed_byte=int(10 * bytes_per_sec),
        bytes_per_sec=bytes_per_sec,
        context_seconds=30.0,
    )
    assert read_start == 0
    assert offset == 0.0


class _FakeState:
    def __init__(self, writer, sample_rate, channels, stream_name):
        self.lock = _NullLock()
        self._writer = writer
        self._sample_rate = sample_rate
        self._channels = channels
        self._stream_name = stream_name
        self.system_sample_rate = sample_rate
        self.system_channels = channels
        self.mic_sample_rate = sample_rate
        self.mic_channels = channels
        self.stdout_writer = _NullWriter()

    def get_stream(self, name):
        return self._writer if name == self._stream_name else None


class _NullLock:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _NullWriter:
    def write(self, line):
        pass


def _make_writer(tmp_path: Path, seconds: float, sample_rate: int = 100) -> mb.StreamWriter:
    path = tmp_path / "mic.wav"
    writer = mb.open_stream_writer(path, sample_rate, 1)
    n_bytes = int(seconds * sample_rate) * mb.BYTES_PER_SAMPLE
    mb.write_aligned_audio(writer, b"\x00" * n_bytes, pts_us=0, sample_rate=sample_rate, channels=1)
    return writer


def test_maybe_process_finalize_is_incremental_in_live_asr_only_mode(tmp_path, monkeypatch):
    sample_rate = 100
    writer = _make_writer(tmp_path, seconds=40.0, sample_rate=sample_rate)
    state = _FakeState(writer, sample_rate, 1, "mic")

    captured_start_bytes = []

    def _fake_write_wav_chunk(snapshot, temp_dir, start_byte=0):
        captured_start_bytes.append(start_byte)
        dummy = tmp_path / "dummy.wav"
        _write_silent_wav(dummy, seconds=0.1)
        return dummy

    def _fake_run_pipeline(**kwargs):
        class _Merged:
            turns = []

        return _Merged()

    monkeypatch.setattr(mb, "write_wav_chunk", _fake_write_wav_chunk)
    monkeypatch.setattr(mb, "run_pipeline", _fake_run_pipeline)

    processor = mb.LiveProcessor(
        stream_name="mic",
        state=state,
        emitter=mb.TranscriptEmitter(_NullWriter(), finalize_lag=0.0),
        output_dir=tmp_path,
        diar_backend="senko",
        diar_model="default",
        asr_model="fake",
        language=None,
        gap_threshold=0.8,
        speaker_tolerance=0.25,
        live_interval=15.0,
        live_min_seconds=10.0,
        verbose=False,
        live_asr_only=True,
    )
    bytes_per_sec = sample_rate * mb.BYTES_PER_SAMPLE
    last_processed_byte = int(35 * bytes_per_sec)  # only 5s of new audio
    processor._last_processed_byte = last_processed_byte

    handled = processor._maybe_process(finalize=True)

    assert handled is True
    expected_start, _ = mb.compute_incremental_window(last_processed_byte, float(bytes_per_sec))
    assert captured_start_bytes == [expected_start]
    assert expected_start != 0  # confirms this is a tail read, not byte-0


def test_maybe_process_finalize_is_full_reprocess_in_default_mode(tmp_path, monkeypatch):
    sample_rate = 100
    writer = _make_writer(tmp_path, seconds=40.0, sample_rate=sample_rate)
    state = _FakeState(writer, sample_rate, 1, "mic")

    captured_start_bytes = []

    def _fake_write_wav_chunk(snapshot, temp_dir, start_byte=0):
        captured_start_bytes.append(start_byte)
        dummy = tmp_path / "dummy.wav"
        _write_silent_wav(dummy, seconds=0.1)
        return dummy

    def _fake_run_pipeline(**kwargs):
        class _Merged:
            turns = []

        return _Merged()

    monkeypatch.setattr(mb, "write_wav_chunk", _fake_write_wav_chunk)
    monkeypatch.setattr(mb, "run_pipeline", _fake_run_pipeline)

    processor = mb.LiveProcessor(
        stream_name="mic",
        state=state,
        emitter=mb.TranscriptEmitter(_NullWriter(), finalize_lag=0.0),
        output_dir=tmp_path,
        diar_backend="senko",
        diar_model="default",
        asr_model="fake",
        language=None,
        gap_threshold=0.8,
        speaker_tolerance=0.25,
        live_interval=15.0,
        live_min_seconds=10.0,
        verbose=False,
        live_asr_only=False,
    )
    bytes_per_sec = sample_rate * mb.BYTES_PER_SAMPLE
    processor._last_processed_byte = int(35 * bytes_per_sec)

    handled = processor._maybe_process(finalize=True)

    assert handled is True
    assert captured_start_bytes == [0]  # unchanged: default finalize reprocesses from byte 0


def test_maybe_process_finalize_in_live_asr_only_skips_live_gates(tmp_path, monkeypatch):
    """Even with very little new audio (below live_min_seconds/live_interval),
    the live-asr-only finalize pass must still run so trailing speech isn't lost."""
    sample_rate = 100
    writer = _make_writer(tmp_path, seconds=12.0, sample_rate=sample_rate)
    state = _FakeState(writer, sample_rate, 1, "mic")

    calls = []

    def _fake_write_wav_chunk(snapshot, temp_dir, start_byte=0):
        calls.append(start_byte)
        dummy = tmp_path / "dummy.wav"
        _write_silent_wav(dummy, seconds=0.1)
        return dummy

    def _fake_run_pipeline(**kwargs):
        class _Merged:
            turns = []

        return _Merged()

    monkeypatch.setattr(mb, "write_wav_chunk", _fake_write_wav_chunk)
    monkeypatch.setattr(mb, "run_pipeline", _fake_run_pipeline)

    processor = mb.LiveProcessor(
        stream_name="mic",
        state=state,
        emitter=mb.TranscriptEmitter(_NullWriter(), finalize_lag=0.0),
        output_dir=tmp_path,
        diar_backend="senko",
        diar_model="default",
        asr_model="fake",
        language=None,
        gap_threshold=0.8,
        speaker_tolerance=0.25,
        live_interval=15.0,
        live_min_seconds=10.0,
        verbose=False,
        live_asr_only=True,
    )
    bytes_per_sec = sample_rate * mb.BYTES_PER_SAMPLE
    # Only ~2s of new audio since the last live pass - well under live_interval (15s).
    processor._last_processed_byte = int(10 * bytes_per_sec)

    handled = processor._maybe_process(finalize=True)

    assert handled is True
    assert len(calls) == 1
