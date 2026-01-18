"""
Speaker diarisation using Senko on Apple Silicon.

Senko uses CoreML for both VAD (pyannote segmentation-3.0) and speaker
embeddings (CAM++), running on the Apple Neural Engine.

Reference: https://github.com/narcotic-sh/senko
"""

from typing import List, Optional

from .diarisation import DiarSegment


class SenkoDiarizer:
    """
    CoreML-based speaker diarizer using Senko.

    Senko provides efficient speaker diarisation on Apple Silicon,
    processing ~1 hour of audio in ~7.7 seconds on M3.
    """

    def __init__(
        self,
        device: str = "auto",
        warmup: bool = True,
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

    def _ensure_loaded(self):
        """Lazy load Senko diarizer on first use."""
        if self._diarizer is not None:
            return

        try:
            import senko
        except ImportError as e:
            raise ImportError(
                "Senko is not installed. Install with:\n"
                "  pip install 'git+https://github.com/narcotic-sh/senko.git'\n"
                f"Original error: {e}"
            )

        if not self._quiet:
            print("Initializing Senko diarizer...")

        self._diarizer = senko.Diarizer(
            device=self._device,
            warmup=self._warmup,
            quiet=self._quiet,
        )

        if not self._quiet:
            print("Senko diarizer ready.")

    def diarise(self, audio_path: str) -> List[DiarSegment]:
        """
        Run speaker diarisation on audio file.

        Args:
            audio_path: Path to 16kHz mono WAV file

        Returns:
            List of DiarSegment with speaker labels
        """
        self._ensure_loaded()

        if not self._quiet:
            print(f"Running Senko diarisation on: {audio_path}")

        # Run Senko diarisation
        result = self._diarizer.diarize(audio_path, generate_colors=False)

        # Convert Senko segments to our DiarSegment format
        segments = []
        for seg in result["merged_segments"]:
            segments.append(DiarSegment(
                start=seg["start"],
                end=seg["end"],
                speaker=seg["speaker"],
            ))

        if not self._quiet:
            n_speakers = result.get("merged_speakers_detected", len(set(s.speaker for s in segments)))
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
