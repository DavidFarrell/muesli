"""
Speaker diarisation using Senko on Apple Silicon.

Senko uses CoreML for both VAD (pyannote segmentation-3.0) and speaker
embeddings (CAM++), running on the Apple Neural Engine.

Reference: https://github.com/narcotic-sh/senko
"""

import threading
from typing import Any, List, Optional

from .diarisation import DiarSegment


_native_diarizer_cache: dict[tuple[str, bool, bool], Any] = {}
_native_diarizer_cache_lock = threading.Lock()
_senko_import_lock = threading.Lock()


def _restore_numba_njit(senko_module: Any) -> None:
    """
    Senko globally patches numba.njit(cache=True), which can make UMAP/HDBSCAN
    try to cache transient dispatcher objects and trigger:
      ReferenceError: underlying object has vanished
    Restore the original njit before Senko imports its clustering stack.
    """
    try:
        import numba
    except Exception:
        return

    original_njit = getattr(getattr(senko_module, "config", None), "_original_njit", None)
    if original_njit is not None:
        numba.njit = original_njit


def _import_senko() -> Any:
    with _senko_import_lock:
        import senko

        _restore_numba_njit(senko)
        return senko


class SenkoDiarizer:
    """
    CoreML-based speaker diarizer using Senko.

    Senko provides efficient speaker diarisation on Apple Silicon,
    processing ~1 hour of audio in ~7.7 seconds on M3.
    """

    def __init__(
        self,
        device: str = "auto",
        warmup: bool = False,
        quiet: bool = False,
    ):
        """
        Initialize the Senko diarizer.

        Args:
            device: Computation device ('auto', 'cuda', 'cpu', 'coreml')
            warmup: Whether to warm up models during initialization
            quiet: Suppress console output
        """
        self._device = device
        self._warmup = warmup
        self._quiet = quiet
        self._diarizer = None

    def _cache_key(self) -> tuple[str, bool, bool]:
        return (self._device, self._warmup, self._quiet)

    def _reset_cached_diarizer(self) -> None:
        key = self._cache_key()
        with _native_diarizer_cache_lock:
            cached = _native_diarizer_cache.get(key)
            if cached is not None and cached is self._diarizer:
                _native_diarizer_cache.pop(key, None)
        self._diarizer = None

    def _ensure_loaded(self):
        """Lazy load Senko diarizer on first use."""
        if self._diarizer is not None:
            return

        try:
            senko = _import_senko()
        except ImportError as e:
            raise ImportError(
                "Senko is not installed. Install with:\n"
                "  pip install 'git+https://github.com/narcotic-sh/senko.git'\n"
                f"Original error: {e}"
            )

        key = self._cache_key()
        with _native_diarizer_cache_lock:
            cached = _native_diarizer_cache.get(key)
            if cached is None:
                if not self._quiet:
                    print("Initializing Senko diarizer...")

                cached = senko.Diarizer(
                    device=self._device,
                    warmup=self._warmup,
                    quiet=self._quiet,
                )
                _native_diarizer_cache[key] = cached

                if not self._quiet:
                    print("Senko diarizer ready.")

            self._diarizer = cached

    @staticmethod
    def _is_transient_reference_error(error: Exception) -> bool:
        return isinstance(error, ReferenceError) and "underlying object has vanished" in str(error)

    def diarise(self, audio_path: str) -> List[DiarSegment]:
        """
        Run speaker diarisation on audio file.

        Args:
            audio_path: Path to 16kHz mono WAV file

        Returns:
            List of DiarSegment with speaker labels
        """
        for attempt in range(2):
            try:
                self._ensure_loaded()

                if not self._quiet:
                    print(f"Running Senko diarisation on: {audio_path}")

                # Run Senko diarisation
                result = self._diarizer.diarize(audio_path, generate_colors=False)
                break
            except Exception as error:
                if attempt == 0 and self._is_transient_reference_error(error):
                    if not self._quiet:
                        print("Senko hit a transient Numba cache error; retrying without warmup...")
                    self._reset_cached_diarizer()
                    self._warmup = False
                    continue
                raise
        else:
            raise RuntimeError("Senko diarisation did not produce a result.")

        # Senko can return None / empty output for silent inputs.
        if not result:
            if not self._quiet:
                print("No speakers detected in the audio.")
            return []

        merged_segments = result.get("merged_segments")
        if not merged_segments:
            if not self._quiet:
                print("No speakers detected in the audio.")
            return []

        # Convert Senko segments to our DiarSegment format
        segments = []
        for seg in merged_segments:
            segments.append(DiarSegment(
                start=seg["start"],
                end=seg["end"],
                speaker=seg["speaker"],
            ))

        if not self._quiet:
            n_speakers = result.get(
                "merged_speakers_detected",
                len(set(s.speaker for s in segments)),
            )
            print(f"  Detected {n_speakers} speakers, {len(segments)} segments")

        return segments


def diarise_audio_senko(
    audio_path: str,
    device: str = "auto",
) -> List[DiarSegment]:
    """
    Convenience function to diarise audio using Senko.

    Args:
        audio_path: Path to 16kHz mono WAV file
        device: Computation device

    Returns:
        List of DiarSegment
    """
    diarizer = SenkoDiarizer(device=device)
    return diarizer.diarise(audio_path)
