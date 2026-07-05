from diarise_transcribe.asr import Word
from diarise_transcribe.diarisation import DiarSegment
from diarise_transcribe import recovery


def _seg(start: float, end: float, speaker: str = "SPEAKER_00") -> DiarSegment:
    return DiarSegment(start=start, end=end, speaker=speaker)


def _word(text: str, start: float, end: float) -> Word:
    return Word(text=text, start=start, end=end)


# --- segment_word_coverage / find_wordless_segments ---


def test_zero_word_segment_is_flagged() -> None:
    segments = [_seg(10.0, 15.0)]
    words = [_word("hello", 0.0, 1.0), _word("world", 20.0, 21.0)]

    flagged = recovery.find_wordless_segments(segments, words)

    assert flagged == segments


def test_well_covered_segment_is_not_flagged() -> None:
    segment = _seg(10.0, 15.0)
    words = [
        _word("one", 10.0, 11.5),
        _word("two", 11.6, 13.0),
        _word("three", 13.1, 14.9),
    ]

    flagged = recovery.find_wordless_segments([segment], words)

    assert flagged == []


def test_sub_threshold_short_segment_is_ignored() -> None:
    # Below the default 1.5s min_duration, even with zero words, should not
    # be flagged - short gaps are normal (breaths, pauses) not collapses.
    segment = _seg(10.0, 11.0)
    words: list[Word] = []

    flagged = recovery.find_wordless_segments([segment], words)

    assert flagged == []


def test_partial_coverage_below_threshold_is_flagged() -> None:
    # 5s segment with only 0.2s of words covered (4%) is below the 10% bar.
    segment = _seg(0.0, 5.0)
    words = [_word("um", 0.0, 0.2)]

    flagged = recovery.find_wordless_segments([segment], words)

    assert flagged == [segment]


def test_partial_coverage_above_threshold_is_not_flagged() -> None:
    # 5s segment with 1s covered (20%) clears the 10% bar.
    segment = _seg(0.0, 5.0)
    words = [_word("hello", 0.0, 1.0)]

    flagged = recovery.find_wordless_segments([segment], words)

    assert flagged == []


# --- cluster_recovery_windows ---


def test_cluster_pads_and_clamps_single_segment() -> None:
    segment = _seg(10.0, 15.0)

    windows = recovery.cluster_recovery_windows([segment], file_duration=100.0)

    assert len(windows) == 1
    window = windows[0]
    assert window.gap_start == 10.0
    assert window.gap_end == 15.0
    assert window.start == 9.0
    assert window.end == 16.0


def test_cluster_merges_adjacent_segments_within_gap() -> None:
    # 1.5s apart is within (strictly less than) the default 2.0s merge_gap,
    # so these should merge into a single window spanning both.
    segments = [_seg(10.0, 12.0), _seg(13.5, 16.0)]

    windows = recovery.cluster_recovery_windows(segments, file_duration=100.0)

    assert len(windows) == 1
    assert windows[0].gap_start == 10.0
    assert windows[0].gap_end == 16.0


def test_cluster_keeps_far_apart_segments_separate() -> None:
    segments = [_seg(10.0, 12.0), _seg(20.0, 22.0)]

    windows = recovery.cluster_recovery_windows(segments, file_duration=100.0)

    assert len(windows) == 2
    assert (windows[0].gap_start, windows[0].gap_end) == (10.0, 12.0)
    assert (windows[1].gap_start, windows[1].gap_end) == (20.0, 22.0)


def test_cluster_clamps_padding_to_file_bounds() -> None:
    segments = [_seg(0.0, 1.6), _seg(9.0, 10.0)]

    windows = recovery.cluster_recovery_windows(segments, file_duration=10.0)

    assert windows[0].start == 0.0  # can't pad below 0
    assert windows[-1].end == 10.0  # can't pad past file end


def test_cluster_empty_input_returns_no_windows() -> None:
    assert recovery.cluster_recovery_windows([], file_duration=100.0) == []


# --- offset_words / filter_words_in_window (midpoint dedupe) ---


def test_offset_words_shifts_start_and_end() -> None:
    words = [_word("hi", 0.0, 0.5)]

    shifted = recovery.offset_words(words, offset=80.0)

    assert shifted == [_word("hi", 80.0, 80.5)]


def test_filter_drops_edge_words_outside_gap_keeps_in_gap_words() -> None:
    window = recovery.RecoveryWindow(start=79.0, end=96.0, gap_start=80.0, gap_end=95.0)
    words = [
        _word("context-before", 79.2, 79.8),  # midpoint 79.5, before gap_start -> drop
        _word("in-gap", 85.0, 86.0),  # midpoint 85.5, inside gap -> keep
        _word("context-after", 95.2, 95.8),  # midpoint 95.5, after gap_end -> drop
    ]

    kept = recovery.filter_words_in_window(words, window)

    assert kept == [words[1]]


def test_filter_word_straddling_gap_boundary_uses_midpoint() -> None:
    window = recovery.RecoveryWindow(start=0.0, end=20.0, gap_start=10.0, gap_end=15.0)
    # Midpoint exactly at gap_start (10.0) is included (>=); midpoint at
    # gap_end (15.0) is excluded (the window is a half-open [start, end)).
    at_start = _word("edge-start", 9.5, 10.5)
    at_end = _word("edge-end", 14.5, 15.5)

    kept = recovery.filter_words_in_window([at_start, at_end], window)

    assert kept == [at_start]


# --- splice_words ---


def test_splice_words_no_recovered_is_noop() -> None:
    original = [_word("a", 0.0, 1.0), _word("b", 1.0, 2.0)]

    result = recovery.splice_words(original, [])

    assert result == original
    assert result is not original  # returns a copy, not the same list object


def test_splice_words_inserts_recovered_words_in_time_order() -> None:
    original = [_word("a", 0.0, 1.0), _word("d", 20.0, 21.0)]
    recovered = [_word("c", 15.0, 16.0), _word("b", 5.0, 6.0)]

    result = recovery.splice_words(original, recovered)

    assert [w.text for w in result] == ["a", "b", "c", "d"]
