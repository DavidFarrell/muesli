"""
Speaker diarisation using Sortformer CoreML on Apple Silicon.

Pure CoreML/NumPy implementation without PyTorch/NeMo dependencies.
Based on FluidInference/diar-streaming-sortformer-coreml.
"""

import math
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Literal, Optional, Tuple

import librosa
import numpy as np
from huggingface_hub import hf_hub_download, snapshot_download


@dataclass
class DiarSegment:
    """A speaker segment."""
    start: float  # seconds
    end: float  # seconds
    speaker: str  # e.g. "SPEAKER_00"

    @property
    def duration(self) -> float:
        return self.end - self.start


# Model configurations for different Sortformer variants
# Using .mlpackage format for coremltools compatibility
MODEL_CONFIGS = {
    "default": {
        "model_file": "Sortformer.mlpackage",
        "chunk_len": 4,  # encoder frames per chunk
        "chunk_left_context": 2,
        "chunk_right_context": 1,
        "fifo_len": 40,
        "spkcache_len": 188,
        "subsampling_factor": 8,  # mel frames per encoder frame
        "n_speakers": 4,
        "embed_dim": 512,
        "chunk_input_frames": 112,  # (chunk + left + right) * 8 = 7*8 = 56... but model expects 112
        "spkcache_input_len": 188,
        "fifo_input_len": 40,
    },
    "nvidia_low": {
        "model_file": "SortformerNvidiaLow.mlpackage",
        "chunk_len": 4,
        "chunk_left_context": 2,
        "chunk_right_context": 1,
        "fifo_len": 40,
        "spkcache_len": 188,
        "subsampling_factor": 8,
        "n_speakers": 4,
        "embed_dim": 512,
        "chunk_input_frames": 112,
        "spkcache_input_len": 188,
        "fifo_input_len": 40,
    },
    "nvidia_high": {
        "model_file": "SortformerNvidiaHigh.mlpackage",
        "chunk_len": 4,
        "chunk_left_context": 2,
        "chunk_right_context": 1,
        "fifo_len": 40,
        "spkcache_len": 188,
        "subsampling_factor": 8,
        "n_speakers": 4,
        "embed_dim": 512,
        "chunk_input_frames": 112,
        "spkcache_input_len": 188,
        "fifo_input_len": 40,
    },
}

# Mel spectrogram settings matching NeMo's defaults
MEL_CONFIG = {
    "sample_rate": 16000,
    "n_fft": 512,
    "hop_length": 160,  # 10ms at 16kHz
    "win_length": 400,  # 25ms at 16kHz
    "n_mels": 128,
    "fmin": 0.0,
    "fmax": 8000.0,
}

REPO_ID = "FluidInference/diar-streaming-sortformer-coreml"


@dataclass
class StreamingState:
    """Streaming state buffers for Sortformer."""
    spkcache: np.ndarray  # [1, spkcache_len, embed_dim]
    fifo: np.ndarray  # [1, fifo_len, embed_dim]
    spkcache_len: int = 0
    fifo_len: int = 0
    chunk_idx: int = 0


def download_model(model_name: str = "default", cache_dir: Optional[str] = None) -> str:
    """
    Download Sortformer CoreML model from HuggingFace.

    Args:
        model_name: One of 'default', 'nvidia_low', 'nvidia_high'
        cache_dir: Optional cache directory

    Returns:
        Path to the downloaded .mlpackage directory
    """
    if model_name not in MODEL_CONFIGS:
        raise ValueError(f"Unknown model: {model_name}. Choose from: {list(MODEL_CONFIGS.keys())}")

    config = MODEL_CONFIGS[model_name]
    model_file = config["model_file"]

    print(f"Downloading {model_file} from {REPO_ID}...")

    # Download all files for this model using hf_hub_download for each file
    # This ensures complete download unlike snapshot_download with patterns
    from huggingface_hub import list_repo_files

    try:
        # Get list of files for this model
        all_files = list_repo_files(REPO_ID)
        model_files = [f for f in all_files if f.startswith(model_file + "/")]

        if not model_files:
            raise RuntimeError(f"No model files found for {model_file}")

        print(f"  Found {len(model_files)} files to download...")

        # Download each file individually to ensure completeness
        downloaded_dir = None
        for i, rel_path in enumerate(model_files, 1):
            print(f"  Downloading [{i}/{len(model_files)}]: {rel_path.split('/')[-1]}")
            local_path = hf_hub_download(
                repo_id=REPO_ID,
                filename=rel_path,
                cache_dir=cache_dir,
            )
            if downloaded_dir is None:
                # Get the base directory from the first downloaded file
                # local_path is like: /cache/.../snapshots/xxx/Sortformer.mlpackage/Data/.../file
                # We need: /cache/.../snapshots/xxx/Sortformer.mlpackage
                path_parts = local_path.split(model_file)
                if len(path_parts) >= 2:
                    downloaded_dir = path_parts[0] + model_file

        if downloaded_dir is None or not os.path.exists(downloaded_dir):
            raise RuntimeError(f"Failed to determine model directory after download")

        # Verify the manifest exists (required for .mlpackage)
        manifest_path = os.path.join(downloaded_dir, "Manifest.json")
        if not os.path.exists(manifest_path):
            raise RuntimeError(f"Model incomplete: Manifest.json not found at {manifest_path}")

        print(f"Model downloaded to: {downloaded_dir}")
        return downloaded_dir

    except Exception as e:
        print(f"  Download error: {e}")
        raise RuntimeError(f"Failed to download model {model_file}: {e}")


def compute_mel_spectrogram(audio: np.ndarray, sr: int = 16000) -> np.ndarray:
    """
    Compute log-mel spectrogram matching NeMo's preprocessing.

    Args:
        audio: Audio samples as float32 numpy array
        sr: Sample rate (should be 16000)

    Returns:
        Mel spectrogram as [n_mels, time] numpy array
    """
    # Compute mel spectrogram
    mel = librosa.feature.melspectrogram(
        y=audio,
        sr=sr,
        n_fft=MEL_CONFIG["n_fft"],
        hop_length=MEL_CONFIG["hop_length"],
        win_length=MEL_CONFIG["win_length"],
        n_mels=MEL_CONFIG["n_mels"],
        fmin=MEL_CONFIG["fmin"],
        fmax=MEL_CONFIG["fmax"],
        power=2.0,
    )

    # Convert to log scale (matching NeMo's log_zero approach)
    mel = np.log(mel + 1e-9)

    return mel.astype(np.float32)


class SortformerDiarizer:
    """
    CoreML-based speaker diarizer using Sortformer.

    Implements streaming inference with pure NumPy state management.
    """

    def __init__(
        self,
        model_name: str = "default",
        model_path: Optional[str] = None,
        compute_units: str = "ALL",
    ):
        """
        Initialize the diarizer.

        Args:
            model_name: One of 'default', 'nvidia_low', 'nvidia_high'
            model_path: Optional explicit path to .mlpackage
            compute_units: CoreML compute units - 'CPU_ONLY', 'CPU_AND_GPU', or 'ALL'
        """
        self.model_name = model_name
        self.config = MODEL_CONFIGS[model_name]
        self._model = None
        self._model_path = model_path
        self._compute_units_name = compute_units
        self._compute_units = None

    def _ensure_loaded(self):
        """Load model on first use."""
        if self._model is not None:
            return

        if self._model_path is None:
            self._model_path = download_model(self.model_name)

        # Copy model to local cache to avoid symlink issues with CoreML
        local_model_path = self._resolve_symlinks(self._model_path)

        import coremltools as ct
        self._compute_units = getattr(ct.ComputeUnit, self._compute_units_name, ct.ComputeUnit.ALL)

        print(f"Loading CoreML model: {local_model_path}")
        self._model = ct.models.MLModel(
            local_model_path,
            compute_units=self._compute_units,
        )
        print("CoreML model loaded.")

    def _resolve_symlinks(self, model_path: str) -> str:
        """
        Copy model to local path, resolving all symlinks.

        HuggingFace cache uses symlinks which can cause issues with CoreML compilation.
        """
        import shutil
        from pathlib import Path

        model_path = Path(model_path)
        model_name = model_path.name

        # Create local models directory
        local_dir = Path(__file__).parent.parent.parent / "models"
        local_dir.mkdir(exist_ok=True)
        local_model_path = local_dir / model_name

        if local_model_path.exists():
            # Check if it's complete (has Manifest.json)
            if (local_model_path / "Manifest.json").exists():
                print(f"  Using cached model: {local_model_path}")
                return str(local_model_path)
            else:
                # Incomplete - remove and re-copy
                shutil.rmtree(local_model_path)

        print(f"  Copying model to local cache (resolving symlinks)...")
        # Copy with symlinks followed (default behavior of copytree)
        shutil.copytree(model_path, local_model_path, symlinks=False)
        print(f"  Model copied to: {local_model_path}")

        return str(local_model_path)

    def _init_state(self) -> StreamingState:
        """Initialize streaming state buffers."""
        config = self.config
        return StreamingState(
            spkcache=np.zeros(
                (1, config["spkcache_input_len"], config["embed_dim"]),
                dtype=np.float32,
            ),
            fifo=np.zeros(
                (1, config["fifo_input_len"], config["embed_dim"]),
                dtype=np.float32,
            ),
            spkcache_len=0,
            fifo_len=0,
            chunk_idx=0,
        )

    def _update_state(
        self,
        state: StreamingState,
        new_embeddings: np.ndarray,
        emb_len: int,
    ) -> StreamingState:
        """
        Update spkcache and fifo buffers with new embeddings.

        This is a simplified implementation of NeMo's streaming_update.
        """
        config = self.config
        fifo_max = config["fifo_input_len"]
        spkcache_max = config["spkcache_input_len"]

        # Extract valid embeddings
        new_embs = new_embeddings[0, :emb_len, :]  # [emb_len, embed_dim]

        # Add to FIFO
        new_fifo_len = state.fifo_len + emb_len

        if new_fifo_len <= fifo_max:
            # FIFO has room - just append
            state.fifo[0, state.fifo_len:new_fifo_len, :] = new_embs
            state.fifo_len = new_fifo_len
        else:
            # FIFO overflow - move oldest to spkcache
            overflow = new_fifo_len - fifo_max

            # Move overflow from FIFO head to spkcache tail
            new_spkcache_len = min(state.spkcache_len + overflow, spkcache_max)
            if state.spkcache_len + overflow <= spkcache_max:
                state.spkcache[0, state.spkcache_len:new_spkcache_len, :] = (
                    state.fifo[0, :overflow, :]
                )
            else:
                # Spkcache also full - shift left and add
                shift = state.spkcache_len + overflow - spkcache_max
                state.spkcache[0, :-shift, :] = state.spkcache[0, shift:, :]
                state.spkcache[0, -overflow:, :] = state.fifo[0, :overflow, :]
            state.spkcache_len = new_spkcache_len

            # Shift FIFO left and add new embeddings
            remaining = state.fifo_len - overflow
            if remaining > 0:
                state.fifo[0, :remaining, :] = state.fifo[0, overflow:state.fifo_len, :]
            state.fifo[0, remaining:remaining + emb_len, :] = new_embs
            state.fifo_len = remaining + emb_len

        state.chunk_idx += 1
        return state

    def _extract_chunk_predictions(
        self,
        speaker_preds: np.ndarray,
        state: StreamingState,
        emb_len: int,
        left_context: int,
        right_context: int,
    ) -> np.ndarray:
        """
        Extract predictions for current chunk (excluding context).

        Args:
            speaker_preds: Full predictions [total_len, n_speakers]
            state: Current streaming state
            emb_len: Number of embeddings in current chunk
            left_context: Left context encoder frames
            right_context: Right context encoder frames

        Returns:
            Predictions for this chunk [chunk_len, n_speakers]
        """
        # Predictions layout: [spkcache, fifo, left_ctx, chunk, right_ctx]
        pred_offset = state.spkcache_len + state.fifo_len + left_context
        chunk_pred_len = emb_len - left_context - right_context

        if chunk_pred_len <= 0:
            return np.array([])

        return speaker_preds[pred_offset : pred_offset + chunk_pred_len, :]

    def diarise(self, audio_path: str) -> List[DiarSegment]:
        """
        Run speaker diarisation on audio file.

        Args:
            audio_path: Path to 16kHz mono WAV file

        Returns:
            List of DiarSegment with speaker labels
        """
        self._ensure_loaded()
        config = self.config

        # Load and preprocess audio
        print(f"Loading audio: {audio_path}")
        audio, sr = librosa.load(audio_path, sr=MEL_CONFIG["sample_rate"], mono=True)
        print(f"Audio loaded: {len(audio)} samples ({len(audio)/sr:.2f}s)")

        # Compute mel spectrogram
        print("Computing mel spectrogram...")
        mel = compute_mel_spectrogram(audio, sr)  # [128, time]
        mel = mel.T  # [time, 128] for easier chunking
        total_frames = mel.shape[0]
        print(f"Mel spectrogram: {mel.shape}")

        # Initialize streaming state
        state = self._init_state()

        # Streaming parameters
        chunk_len = config["chunk_len"]
        left_ctx = config["chunk_left_context"]
        right_ctx = config["chunk_right_context"]
        sub_factor = config["subsampling_factor"]
        chunk_input_frames = config["chunk_input_frames"]

        # Process in chunks
        all_predictions = []
        frame_offset = 0
        chunk_num = 0

        print("Running diarisation...")
        while frame_offset < total_frames:
            # Calculate chunk boundaries with context
            left_frames = min(left_ctx * sub_factor, frame_offset)
            chunk_end = min(frame_offset + chunk_len * sub_factor, total_frames)
            right_frames = min(right_ctx * sub_factor, total_frames - chunk_end)

            # Extract chunk with context
            chunk_start = frame_offset - left_frames
            chunk_stop = chunk_end + right_frames
            chunk_mel = mel[chunk_start:chunk_stop, :]  # [T, 128]
            actual_len = chunk_mel.shape[0]

            # Pad to fixed size if needed
            if actual_len < chunk_input_frames:
                pad_len = chunk_input_frames - actual_len
                chunk_mel = np.pad(chunk_mel, ((0, pad_len), (0, 0)), mode="constant")

            # Prepare inputs [1, T, 128]
            chunk_input = chunk_mel[np.newaxis, :chunk_input_frames, :].astype(np.float32)

            # Run CoreML inference
            try:
                outputs = self._model.predict({
                    "chunk": chunk_input,
                    "chunk_lengths": np.array([actual_len], dtype=np.int32),
                    "spkcache": state.spkcache,
                    "spkcache_lengths": np.array([state.spkcache_len], dtype=np.int32),
                    "fifo": state.fifo,
                    "fifo_lengths": np.array([state.fifo_len], dtype=np.int32),
                })
            except Exception as e:
                print(f"CoreML inference error at chunk {chunk_num}: {e}")
                raise

            # Get outputs
            speaker_preds = outputs["speaker_preds"]  # [total, n_speakers] or [1, total, n_speakers]
            # Handle batch dimension if present
            if speaker_preds.ndim == 3:
                speaker_preds = speaker_preds[0]  # [total, n_speakers]
            chunk_embs = outputs["chunk_pre_encoder_embs"]  # [1, T, embed_dim]
            chunk_emb_len = int(outputs["chunk_pre_encoder_lengths"][0])

            # Calculate context in encoder frames
            lc = round(left_frames / sub_factor)
            rc = math.ceil(right_frames / sub_factor)

            # Extract predictions for this chunk
            chunk_preds = self._extract_chunk_predictions(
                speaker_preds, state, chunk_emb_len, lc, rc
            )

            if len(chunk_preds) > 0:
                all_predictions.append(chunk_preds)

            # Update state
            state = self._update_state(state, chunk_embs, chunk_emb_len)

            # Move to next chunk
            frame_offset = chunk_end
            chunk_num += 1

            if chunk_num % 10 == 0:
                progress = frame_offset / total_frames * 100
                print(f"  Progress: {progress:.1f}%")

        print(f"Processed {chunk_num} chunks.")

        if not all_predictions:
            print("Warning: No predictions generated.")
            return []

        # Concatenate all predictions
        all_preds = np.concatenate(all_predictions, axis=0)  # [total_frames, n_speakers]
        # Ensure 2D shape
        if all_preds.ndim == 3:
            all_preds = all_preds.squeeze(0)
        print(f"Total predictions shape: {all_preds.shape}")

        # Convert frame predictions to segments
        segments = self._predictions_to_segments(all_preds, sr)
        print(f"Generated {len(segments)} segments.")

        return segments

    def _median_filter(self, probs: np.ndarray, kernel_size: int = 5) -> np.ndarray:
        """Apply median filter to smooth frame probabilities."""
        from scipy.ndimage import median_filter
        return median_filter(probs, size=kernel_size, mode='nearest')

    def _apply_hysteresis(
        self,
        probs: np.ndarray,
        on_threshold: float = 0.4,
        off_threshold: float = 0.6,
    ) -> np.ndarray:
        """
        Apply hysteresis thresholding to prevent rapid on/off switching.

        Speaker turns ON when prob >= on_threshold
        Speaker turns OFF when prob < off_threshold
        """
        is_active = np.zeros(len(probs), dtype=bool)
        currently_active = False

        for i, prob in enumerate(probs):
            if currently_active:
                # Stay active until we drop below off_threshold
                if prob < off_threshold:
                    currently_active = False
            else:
                # Turn on when we exceed on_threshold
                if prob >= on_threshold:
                    currently_active = True
            is_active[i] = currently_active

        return is_active

    def _predictions_to_segments(
        self,
        predictions: np.ndarray,
        sample_rate: int,
        min_segment_duration: float = 0.3,
        median_kernel: int = 5,
        silence_threshold: float = 0.15,
    ) -> List[DiarSegment]:
        """
        Convert frame-level predictions to speaker segments using argmax.

        Uses winner-take-all approach: assigns each frame to the speaker
        with highest probability (if above silence threshold).

        Args:
            predictions: [n_frames, n_speakers] probabilities
            sample_rate: Original audio sample rate
            min_segment_duration: Minimum segment duration in seconds
            median_kernel: Kernel size for median filter smoothing
            silence_threshold: Minimum max probability to assign any speaker

        Returns:
            List of DiarSegment
        """
        n_frames, n_speakers = predictions.shape

        # Frame duration in seconds
        hop_length = MEL_CONFIG["hop_length"]
        sub_factor = self.config["subsampling_factor"]
        frame_duration = (hop_length * sub_factor) / sample_rate

        # Step 1: Apply median filter to smooth each speaker's probabilities
        smoothed = np.zeros_like(predictions)
        for speaker_idx in range(n_speakers):
            smoothed[:, speaker_idx] = self._median_filter(
                predictions[:, speaker_idx], kernel_size=median_kernel
            )

        # Step 2: Argmax - assign each frame to highest probability speaker
        max_probs = np.max(smoothed, axis=1)
        speaker_ids = np.argmax(smoothed, axis=1)

        # Mark frames as silence if max prob below threshold
        speaker_ids[max_probs < silence_threshold] = -1

        # Step 3: Convert frame-level labels to segments
        segments = []
        if len(speaker_ids) == 0:
            return segments

        current_speaker = speaker_ids[0]
        segment_start = 0

        for frame_idx in range(1, len(speaker_ids)):
            if speaker_ids[frame_idx] != current_speaker:
                # End current segment
                if current_speaker >= 0:  # Not silence
                    start_time = segment_start * frame_duration
                    end_time = frame_idx * frame_duration
                    duration = end_time - start_time

                    if duration >= min_segment_duration:
                        segments.append(DiarSegment(
                            start=round(start_time, 2),
                            end=round(end_time, 2),
                            speaker=f"SPEAKER_{current_speaker:02d}",
                        ))

                # Start new segment
                current_speaker = speaker_ids[frame_idx]
                segment_start = frame_idx

        # Don't forget final segment
        if current_speaker >= 0:
            start_time = segment_start * frame_duration
            end_time = n_frames * frame_duration
            duration = end_time - start_time

            if duration >= min_segment_duration:
                segments.append(DiarSegment(
                    start=round(start_time, 2),
                    end=round(end_time, 2),
                    speaker=f"SPEAKER_{current_speaker:02d}",
                ))

        # Merge adjacent segments from same speaker (within gap threshold)
        segments = self._merge_overlapping_segments(segments, gap_threshold=0.5)

        return segments

    def _merge_overlapping_segments(
        self,
        segments: List[DiarSegment],
        gap_threshold: float = 0.3,
    ) -> List[DiarSegment]:
        """Merge adjacent segments from same speaker."""
        if not segments:
            return segments

        merged = []
        current = segments[0]

        for seg in segments[1:]:
            if (
                seg.speaker == current.speaker
                and seg.start <= current.end + gap_threshold
            ):
                # Extend current segment
                current = DiarSegment(
                    start=current.start,
                    end=max(current.end, seg.end),
                    speaker=current.speaker,
                )
            else:
                merged.append(current)
                current = seg

        merged.append(current)
        return merged


def diarise_audio(
    audio_path: str,
    model_name: str = "default",
) -> List[DiarSegment]:
    """
    Convenience function to diarise audio.

    Args:
        audio_path: Path to 16kHz mono WAV file
        model_name: Model variant ('default', 'nvidia_low', 'nvidia_high')

    Returns:
        List of DiarSegment
    """
    diarizer = SortformerDiarizer(model_name=model_name)
    return diarizer.diarise(audio_path)
