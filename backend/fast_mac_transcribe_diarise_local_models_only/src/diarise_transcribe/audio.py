"""
Audio normalisation and I/O utilities.

Converts any audio input to 16kHz mono WAV for both ASR and diarisation.
"""

import os
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Optional, Tuple

import numpy as np
import soundfile as sf


def check_ffmpeg() -> bool:
    """Check if ffmpeg is available in PATH."""
    try:
        result = subprocess.run(
            ["ffmpeg", "-version"],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode == 0
    except FileNotFoundError:
        return False


def is_wav_16k_mono(path: str) -> bool:
    """Return True if the WAV is already 16kHz mono PCM."""
    try:
        info = sf.info(path)
    except Exception:
        return False
    if info.samplerate != 16000:
        return False
    if info.channels != 1:
        return False
    return True


def normalise_audio(
    input_path: str,
    output_path: Optional[str] = None,
    sample_rate: int = 16000,
    mono: bool = True,
) -> str:
    """
    Convert any audio file to normalised WAV format using ffmpeg.

    Args:
        input_path: Path to input audio file (any format ffmpeg supports)
        output_path: Path for output WAV file. If None, uses temp file.
        sample_rate: Target sample rate (default 16000 for ASR/diarisation)
        mono: Convert to mono (default True)

    Returns:
        Path to the normalised WAV file

    Raises:
        RuntimeError: If ffmpeg is not available or conversion fails
    """
    if not check_ffmpeg():
        raise RuntimeError(
            "ffmpeg is not installed or not in PATH. "
            "Please install ffmpeg: brew install ffmpeg"
        )

    input_path = Path(input_path).resolve()
    if not input_path.exists():
        raise FileNotFoundError(f"Audio file not found: {input_path}")

    if output_path is None:
        # Create temp file in same directory for easier cleanup
        fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="normalised_")
        os.close(fd)

    output_path = Path(output_path).resolve()

    # Build ffmpeg command
    cmd = [
        "ffmpeg",
        "-y",  # Overwrite output
        "-i", str(input_path),
        "-ar", str(sample_rate),  # Sample rate
    ]

    if mono:
        cmd.extend(["-ac", "1"])  # Mono

    cmd.extend([
        "-f", "wav",  # Output format
        "-acodec", "pcm_s16le",  # 16-bit PCM
        str(output_path),
    ])

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg conversion failed:\n{result.stderr}"
        )

    return str(output_path)


def slice_wav_to_temp(input_path: str, start: float, end: float) -> str:
    """
    Slice a 16kHz mono PCM WAV file to [start, end) seconds and write the
    slice to a new temp WAV file.

    Args:
        input_path: Path to a 16kHz mono WAV file (as produced by
            normalise_audio / checked by is_wav_16k_mono).
        start: Slice start in seconds, clamped to the file bounds.
        end: Slice end in seconds, clamped to the file bounds.

    Returns:
        Path to the temp WAV file containing the slice. Caller owns
        cleanup (the file is not tracked/deleted automatically).
    """
    with wave.open(input_path, "rb") as src:
        framerate = src.getframerate()
        n_frames = src.getnframes()
        sample_width = src.getsampwidth()
        n_channels = src.getnchannels()

        start_frame = max(0, min(n_frames, int(round(start * framerate))))
        end_frame = max(start_frame, min(n_frames, int(round(end * framerate))))

        src.setpos(start_frame)
        frame_data = src.readframes(end_frame - start_frame)

    fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="recovery_slice_")
    os.close(fd)

    with wave.open(output_path, "wb") as dst:
        dst.setnchannels(n_channels)
        dst.setsampwidth(sample_width)
        dst.setframerate(framerate)
        dst.writeframes(frame_data)

    return output_path


def load_audio(path: str) -> Tuple[np.ndarray, int]:
    """
    Load audio file using soundfile.

    Args:
        path: Path to audio file

    Returns:
        Tuple of (audio_data as float32 numpy array, sample_rate)
    """
    audio, sr = sf.read(path, dtype="float32")

    # Ensure mono
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    return audio, sr


def get_audio_duration(path: str) -> float:
    """Get duration of audio file in seconds."""
    info = sf.info(path)
    return info.duration


def format_timestamp(seconds: float) -> str:
    """Format seconds as MM:SS.ss for display."""
    minutes = int(seconds // 60)
    secs = seconds % 60
    return f"{minutes:02d}:{secs:05.2f}"


def format_srt_timestamp(seconds: float) -> str:
    """Format seconds as HH:MM:SS,mmm for SRT format."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int((seconds % 1) * 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"
