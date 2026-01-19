import struct
import tempfile
import types
import wave
from pathlib import Path

import sys

parakeet_stub = types.ModuleType("parakeet_mlx")
parakeet_stub.from_pretrained = lambda _model_id: None
sys.modules.setdefault("parakeet_mlx", parakeet_stub)
numpy_stub = types.ModuleType("numpy")
numpy_stub.ndarray = object
sys.modules.setdefault("numpy", numpy_stub)
sys.modules.setdefault("librosa", types.ModuleType("librosa"))
huggingface_stub = types.ModuleType("huggingface_hub")
huggingface_stub.hf_hub_download = lambda *args, **kwargs: None
huggingface_stub.snapshot_download = lambda *args, **kwargs: None
sys.modules.setdefault("huggingface_hub", huggingface_stub)
sys.modules.setdefault("soundfile", types.ModuleType("soundfile"))

from diarise_transcribe import muesli_backend as mb
from diarise_transcribe.asr import Word, TranscriptResult
from diarise_transcribe.diarisation import DiarSegment


def write_pcm(path: Path, samples) -> bytes:
    data = struct.pack("<" + "h" * len(samples), *samples)
    path.write_bytes(data)
    return data


def write_wav(path: Path, samples, sample_rate=16000, channels=1):
    with wave.open(str(path), "wb") as wav_out:
        wav_out.setnchannels(channels)
        wav_out.setsampwidth(mb.BYTES_PER_SAMPLE)
        wav_out.setframerate(sample_rate)
        wav_out.writeframes(struct.pack("<" + "h" * len(samples), *samples))


def read_wav_frames(path: Path) -> bytes:
    with wave.open(str(path), "rb") as wav_in:
        frames = wav_in.getnframes()
        return wav_in.readframes(frames)


def test_write_wav_chunk_full():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        pcm_path = tmp_path / "audio.pcm"
        samples = list(range(-200, 200))
        pcm_data = write_pcm(pcm_path, samples)

        snapshot = mb.StreamSnapshot(
            pcm_path=pcm_path,
            sample_rate=16000,
            channels=1,
            size_bytes=pcm_path.stat().st_size,
        )
        wav_path = mb.write_wav_chunk(snapshot, tmp_path, start_byte=0)
        assert wav_path is not None
        wav_data = read_wav_frames(wav_path)
        assert wav_data == pcm_data


def test_write_wav_chunk_offset():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        pcm_path = tmp_path / "audio.pcm"
        samples = list(range(-500, 500))
        pcm_data = write_pcm(pcm_path, samples)
        bytes_per_frame = mb.BYTES_PER_SAMPLE
        start_frames = 100
        start_byte = start_frames * bytes_per_frame

        snapshot = mb.StreamSnapshot(
            pcm_path=pcm_path,
            sample_rate=16000,
            channels=1,
            size_bytes=pcm_path.stat().st_size,
        )
        wav_path = mb.write_wav_chunk(snapshot, tmp_path, start_byte=start_byte)
        assert wav_path is not None
        wav_data = read_wav_frames(wav_path)
        assert wav_data == pcm_data[start_byte:]


def test_timestamp_offset():
    class DummyASR:
        def __init__(self, model_id):
            self.model_id = model_id

        def transcribe(self, audio_path, language=None):
            return TranscriptResult(
                text="hello",
                words=[Word(text="hello", start=1.0, end=2.0)],
            )

    class DummyDiarizer:
        def __init__(self, model_name=None, quiet=True):
            self.model_name = model_name

        def diarise(self, audio_path):
            return [DiarSegment(start=0.5, end=1.5, speaker="SPEAKER_00")]

    class DummyMerged:
        def __init__(self, transcript, segments):
            self.turns = []
            self.words = transcript.words
            self.segments = segments

    def dummy_merge(transcript, segments, gap_threshold, speaker_tolerance):
        return DummyMerged(transcript, segments)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        wav_path = tmp_path / "audio.wav"
        write_wav(wav_path, [0, 0, 0, 0])

        original_asr = mb.ASRModel
        original_sortformer = mb.SortformerDiarizer
        original_merge = mb.merge_transcript_with_diarisation
        original_is_wav = mb.is_wav_16k_mono

        try:
            mb.ASRModel = DummyASR
            mb.SortformerDiarizer = DummyDiarizer
            mb.merge_transcript_with_diarisation = dummy_merge
            mb.is_wav_16k_mono = lambda _: True

            merged = mb.run_pipeline(
                input_path=wav_path,
                diar_backend="sortformer",
                diar_model="dummy",
                asr_model="dummy",
                language=None,
                gap_threshold=0.5,
                speaker_tolerance=0.5,
                timestamp_offset=10.0,
                verbose=False,
            )

            assert merged.words[0].start == 11.0
            assert merged.words[0].end == 12.0
            assert merged.segments[0].start == 10.5
            assert merged.segments[0].end == 11.5
        finally:
            mb.ASRModel = original_asr
            mb.SortformerDiarizer = original_sortformer
            mb.merge_transcript_with_diarisation = original_merge
            mb.is_wav_16k_mono = original_is_wav


if __name__ == "__main__":
    tests = [
        test_write_wav_chunk_full,
        test_write_wav_chunk_offset,
        test_timestamp_offset,
    ]
    for test in tests:
        test()
        print(f"PASS: {test.__name__}")
