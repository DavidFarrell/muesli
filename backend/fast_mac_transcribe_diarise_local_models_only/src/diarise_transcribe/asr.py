"""
ASR module using parakeet-mlx on Apple Silicon.

Provides word-level timestamps for alignment with diarisation.
"""

from dataclasses import dataclass
from typing import List, Optional

from parakeet_mlx import from_pretrained


@dataclass
class Word:
    """A single word with timestamp."""
    text: str
    start: float  # seconds
    end: float  # seconds

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass
class TranscriptResult:
    """Full transcript with word-level timestamps."""
    text: str
    words: List[Word]


# Default model - Parakeet TDT 0.6B v3
DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


class ASRModel:
    """
    Wrapper for parakeet-mlx ASR model.

    Provides transcription with word-level timestamps using MLX acceleration.
    """

    def __init__(self, model_id: str = DEFAULT_MODEL):
        """
        Initialize the ASR model.

        Args:
            model_id: HuggingFace model ID for parakeet-mlx model
        """
        self.model_id = model_id
        self._model = None

    def _ensure_loaded(self):
        """Lazy load the model on first use."""
        if self._model is None:
            print(f"Loading ASR model: {self.model_id}")
            self._model = from_pretrained(self.model_id)
            print("ASR model loaded.")

    def transcribe(
        self,
        audio_path: str,
        language: Optional[str] = None,
        chunk_duration: float = 120.0,
        overlap_duration: float = 15.0,
    ) -> TranscriptResult:
        """
        Transcribe audio file with word-level timestamps.

        Args:
            audio_path: Path to 16kHz mono WAV file
            language: Language code (auto-detected if None)
            chunk_duration: Duration of audio chunks for long files
            overlap_duration: Overlap between chunks

        Returns:
            TranscriptResult with full text and word-level timestamps
        """
        self._ensure_loaded()

        # Transcribe with parakeet-mlx
        result = self._model.transcribe(
            audio_path,
            chunk_duration=chunk_duration,
            overlap_duration=overlap_duration,
        )

        # Extract words by merging BPE subword tokens
        # BPE tokens starting with space (or ▁) indicate new word boundaries
        words = []
        current_word_tokens = []

        for sentence in result.sentences:
            for token in sentence.tokens:
                token_text = token.text
                if not token_text:
                    continue

                # Check if this token starts a new word
                # New word indicators: leading space, leading ▁, or first token
                is_new_word = (
                    token_text.startswith(" ") or
                    token_text.startswith("▁") or
                    not current_word_tokens
                )

                if is_new_word and current_word_tokens:
                    # Finish previous word
                    word_text = "".join(t.text for t in current_word_tokens)
                    word_text = word_text.strip().replace("▁", "")
                    if word_text:
                        words.append(Word(
                            text=word_text,
                            start=current_word_tokens[0].start,
                            end=current_word_tokens[-1].end,
                        ))
                    current_word_tokens = []

                current_word_tokens.append(token)

        # Don't forget the last word
        if current_word_tokens:
            word_text = "".join(t.text for t in current_word_tokens)
            word_text = word_text.strip().replace("▁", "")
            if word_text:
                words.append(Word(
                    text=word_text,
                    start=current_word_tokens[0].start,
                    end=current_word_tokens[-1].end,
                ))

        return TranscriptResult(
            text=result.text,
            words=words,
        )


def transcribe_audio(
    audio_path: str,
    model_id: str = DEFAULT_MODEL,
    language: Optional[str] = None,
) -> TranscriptResult:
    """
    Convenience function to transcribe audio.

    Args:
        audio_path: Path to 16kHz mono WAV file
        model_id: HuggingFace model ID
        language: Language code (auto-detected if None)

    Returns:
        TranscriptResult with words and timestamps
    """
    model = ASRModel(model_id)
    return model.transcribe(audio_path, language=language)
