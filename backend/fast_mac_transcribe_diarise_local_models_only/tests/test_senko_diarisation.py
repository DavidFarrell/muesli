import types

import numba

from diarise_transcribe import senko_diarisation


def test_restore_numba_njit_uses_senko_original() -> None:
    original_njit = numba.njit

    def patched_njit(*args, **kwargs):
        return original_njit(*args, **kwargs)

    fake_senko = types.SimpleNamespace(
        config=types.SimpleNamespace(_original_njit=original_njit)
    )

    numba.njit = patched_njit
    try:
        senko_diarisation._restore_numba_njit(fake_senko)
        assert numba.njit is original_njit
    finally:
        numba.njit = original_njit


def test_diarise_retries_once_after_transient_reference_error(monkeypatch) -> None:
    senko_diarisation._native_diarizer_cache.clear()

    warmup_values: list[bool] = []
    attempts = {"count": 0}

    class FakeNativeDiarizer:
        def __init__(self, *, warmup: bool):
            self._warmup = warmup

        def diarize(self, _audio_path: str, generate_colors: bool = False):
            assert generate_colors is False
            attempts["count"] += 1
            if attempts["count"] == 1:
                raise ReferenceError("underlying object has vanished")
            return {
                "merged_segments": [
                    {"start": 0.0, "end": 1.25, "speaker": "SPEAKER_01"},
                ],
                "merged_speakers_detected": 1,
            }

    class FakeSenkoModule:
        class config:
            _original_njit = numba.njit

        @staticmethod
        def Diarizer(device: str, warmup: bool, quiet: bool):
            assert device == "auto"
            assert quiet is True
            warmup_values.append(warmup)
            return FakeNativeDiarizer(warmup=warmup)

    monkeypatch.setattr(senko_diarisation, "_import_senko", lambda: FakeSenkoModule)

    diarizer = senko_diarisation.SenkoDiarizer(warmup=True, quiet=True)
    segments = diarizer.diarise("example.wav")

    assert warmup_values == [True, False]
    assert [(segment.start, segment.end, segment.speaker) for segment in segments] == [
        (0.0, 1.25, "SPEAKER_01"),
    ]
