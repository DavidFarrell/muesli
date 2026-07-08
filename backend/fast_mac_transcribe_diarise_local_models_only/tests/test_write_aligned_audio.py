"""Tests for write_aligned_audio's PTS-alignment behaviour, in particular the
drop/trim path that used to be entirely silent: no log line, no counter. The
2026-07-08 mic-stall incident's ~60s of lost mic audio could only be proven
after the fact by inference because of this - see
engineer-notes/bug-2026-07-08-mic-stall/RCA-2026-07-08.md. These tests pin
down the fix: forward gaps still pad with silence exactly as before (no
behaviour change there, kept as insurance), and both drop shapes (whole
frame behind, front trimmed) now count and loudly (rate-limited) log.
"""

from diarise_transcribe import muesli_backend as mb

SAMPLE_RATE = 16000
CHANNELS = 1
BYTES_PER_FRAME = mb.BYTES_PER_SAMPLE * CHANNELS


def _make_writer(tmp_path):
    return mb.open_stream_writer(tmp_path / "stream.wav", SAMPLE_RATE, CHANNELS)


def _frame_payload(n_frames: int, value: int = 1) -> bytes:
    return value.to_bytes(2, "little", signed=False) * n_frames


def _pts_us_for_sample(sample_index: int) -> int:
    return int(round(sample_index / SAMPLE_RATE * 1_000_000.0))


def test_forward_gap_is_padded_with_silence(tmp_path):
    """Existing behaviour, kept as insurance: a frame starting AHEAD of the
    write position pads the gap with silence rather than dropping anything.
    """
    writer = _make_writer(tmp_path)
    try:
        payload = _frame_payload(10)
        pts_us = _pts_us_for_sample(5)
        mb.write_aligned_audio(writer, payload, pts_us, SAMPLE_RATE, CHANNELS, stream_name="test")

        assert writer.last_sample_index == 15  # 5 silence frames + 10 payload frames
        assert writer.frames_dropped == 0
        assert writer.bytes_dropped == 0
    finally:
        mb.close_stream_writer(writer)

    pcm_bytes = writer.path.with_suffix(".pcm").read_bytes()
    assert pcm_bytes[: 5 * BYTES_PER_FRAME] == b"\x00" * (5 * BYTES_PER_FRAME)
    assert pcm_bytes[5 * BYTES_PER_FRAME :] == _frame_payload(10)


def test_whole_frame_behind_write_position_is_dropped_and_counted(tmp_path, capsys):
    """The core regression case: a frame whose PTS lands entirely behind the
    current write position - exactly what a mid-meeting PTS-epoch reset
    produces - must be counted AND loudly logged, not silently discarded.
    """
    writer = _make_writer(tmp_path)
    try:
        mb.write_aligned_audio(writer, _frame_payload(10), 0, SAMPLE_RATE, CHANNELS, stream_name="mic")
        assert writer.last_sample_index == 10

        payload = _frame_payload(4)
        mb.write_aligned_audio(writer, payload, 0, SAMPLE_RATE, CHANNELS, stream_name="mic")

        assert writer.last_sample_index == 10, "a fully-behind frame must not move the write position"
        assert writer.frames_dropped == 1
        assert writer.bytes_dropped == len(payload)
    finally:
        mb.close_stream_writer(writer)

    captured = capsys.readouterr()
    assert "AUDIO DROP" in captured.err
    assert "stream=mic" in captured.err
    assert f"dropped_bytes={len(payload)}" in captured.err
    assert "cumulative_frames_dropped=1" in captured.err


def test_partial_front_trim_is_counted_and_remainder_still_written(tmp_path, capsys):
    """A frame that only PARTIALLY overlaps the write position has its
    overlapping front dropped (counted + logged) but the non-overlapping
    remainder is still written, same as before.
    """
    writer = _make_writer(tmp_path)
    try:
        mb.write_aligned_audio(writer, _frame_payload(10), 0, SAMPLE_RATE, CHANNELS, stream_name="mic")
        assert writer.last_sample_index == 10

        # Payload covers frames [8, 14): 2 frames (8, 9) overlap what's
        # already written, 4 new frames (10..13) are unique.
        payload = _frame_payload(6, value=2)
        pts_us = _pts_us_for_sample(8)
        mb.write_aligned_audio(writer, payload, pts_us, SAMPLE_RATE, CHANNELS, stream_name="mic")

        assert writer.last_sample_index == 14
        assert writer.frames_dropped == 1
        assert writer.bytes_dropped == 2 * BYTES_PER_FRAME
    finally:
        mb.close_stream_writer(writer)

    assert "AUDIO DROP" in capsys.readouterr().err


def test_drop_logging_is_rate_limited_per_writer(tmp_path, monkeypatch, capsys):
    """At most one log line per writer per DROP_LOG_MIN_INTERVAL_SECONDS,
    plus an unconditional first-occurrence line - counters must keep
    incrementing even while logging is suppressed, so a sustained stall
    (the incident's shape: continuous drops for tens of seconds) doesn't
    spam a line per frame but is never invisible either.
    """
    writer = _make_writer(tmp_path)
    fake_now = [0.0]
    monkeypatch.setattr(mb.time, "monotonic", lambda: fake_now[0])
    try:
        mb.write_aligned_audio(writer, _frame_payload(10), 0, SAMPLE_RATE, CHANNELS, stream_name="mic")

        for _ in range(3):
            mb.write_aligned_audio(writer, _frame_payload(4), 0, SAMPLE_RATE, CHANNELS, stream_name="mic")
            fake_now[0] += 0.1

        first_batch = capsys.readouterr().err
        assert first_batch.count("AUDIO DROP") == 1, "only the first-occurrence line should print inside the window"
        assert writer.frames_dropped == 3

        fake_now[0] += mb.DROP_LOG_MIN_INTERVAL_SECONDS + 0.01
        mb.write_aligned_audio(writer, _frame_payload(4), 0, SAMPLE_RATE, CHANNELS, stream_name="mic")

        second_batch = capsys.readouterr().err
        assert second_batch.count("AUDIO DROP") == 1, "a drop past the rate-limit window must log again"
        assert writer.frames_dropped == 4
    finally:
        mb.close_stream_writer(writer)


def test_drop_counters_are_per_writer_not_global(tmp_path):
    """Two independent streams (system/mic) must not share drop counters or
    rate-limit state - a stall on one stream shouldn't suppress logging for
    the other.
    """
    system_writer = mb.open_stream_writer(tmp_path / "system.wav", SAMPLE_RATE, CHANNELS)
    mic_writer = mb.open_stream_writer(tmp_path / "mic.wav", SAMPLE_RATE, CHANNELS)
    try:
        mb.write_aligned_audio(system_writer, _frame_payload(10), 0, SAMPLE_RATE, CHANNELS, stream_name="system")
        mb.write_aligned_audio(system_writer, _frame_payload(4), 0, SAMPLE_RATE, CHANNELS, stream_name="system")

        assert system_writer.frames_dropped == 1
        assert mic_writer.frames_dropped == 0
    finally:
        mb.close_stream_writer(system_writer)
        mb.close_stream_writer(mic_writer)
