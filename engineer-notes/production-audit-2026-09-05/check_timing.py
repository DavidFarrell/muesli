"""Hardware-free audit experiment; executes the repository's alignment function.

Run with Python 3 from any directory. Does not import MLX, record audio, or
modify meetings. AST extraction avoids loading unrelated model dependencies.
The fake sink preserves the real function's padding/trimming behaviour.
"""
import ast
import io
import json
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py"
tree = ast.parse(SOURCE.read_text())
function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "write_aligned_audio")


def count_drop(writer, stream_name, *, dropped_bytes, **kwargs):
    writer.dropped_bytes += dropped_bytes


scope = {"StreamWriter": object, "BYTES_PER_SAMPLE": 2, "_log_and_count_drop": count_drop}
exec(compile(ast.Module(body=[function], type_ignores=[]), str(SOURCE), "exec"), scope)


class WaveSink:
    def __init__(self):
        self.data = io.BytesIO()

    def writeframes(self, payload):
        self.data.write(payload)


def experiment(timestamps):
    writer = SimpleNamespace(wav=WaveSink(), pcm=io.BytesIO(), last_sample_index=0,
                             bytes_written=0, dropped_bytes=0)
    for pts in timestamps:
        # Three consecutive 100 ms nonzero source chunks, 16 kHz mono.
        scope["write_aligned_audio"](writer, b"\x01\x00" * 1600, pts, 16000, 1, "mic")
    samples = writer.pcm.getvalue()
    zero_samples = sum(samples[i:i + 2] == b"\x00\x00" for i in range(0, len(samples), 2))
    return {"source_ms": 300, "file_ms": len(samples) / 32,
            "inserted_silence_ms": zero_samples / 16, "discarded_source_ms": writer.dropped_bytes / 32}


aligned = experiment([0, 100_000, 200_000])
delayed_delivery = experiment([100_000, 300_000, 301_000])
assert aligned["discarded_source_ms"] == 0
assert delayed_delivery["discarded_source_ms"] == 99
assert delayed_delivery["inserted_silence_ms"] == 200
print(json.dumps({"source_timestamps": aligned, "delivery_time_timestamps": delayed_delivery}, indent=2))
