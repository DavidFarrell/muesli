import json
from pathlib import Path

import pytest

from diarise_transcribe.source_recording import committed_sources


def make_source(directory: Path, size: int = 320) -> dict:
    manifest = {
        "schema_version": 1, "session_id": "session-a", "timeline_offset_us": 8000000,
        "revision": 1, "completed": False,
        "streams": {name: {"sample_rate": 16000, "channels": 1, "committed_bytes": size}
                    for name in ("mic", "system")},
    }
    for name in ("mic", "system"):
        (directory / f"{name}.pcm").write_bytes(b"\x01\x00" * (size // 2 + 20))
    (directory / "source-recording.json").write_text(json.dumps(manifest))
    return manifest


def test_only_committed_prefix_is_exposed(tmp_path):
    make_source(tmp_path)
    sources = committed_sources(tmp_path, "session-a")
    assert sources["mic"].size_bytes == 320
    assert sources["mic"].last_sample_index == 160
    assert sources["system"].timeline_offset_us == 8000000
    assert (tmp_path / "mic.pcm").stat().st_size == 360


def test_different_session_cannot_replace_live_source(tmp_path):
    make_source(tmp_path)
    with pytest.raises(ValueError, match="session changed"):
        committed_sources(tmp_path, "another-session")


@pytest.mark.parametrize("bad", [-1, 319, 2**63, True, "320"])
def test_invalid_committed_byte_counts_are_rejected(tmp_path, bad):
    manifest = make_source(tmp_path)
    manifest["streams"]["mic"]["committed_bytes"] = bad
    (tmp_path / "source-recording.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        committed_sources(tmp_path)


def test_truncated_committed_audio_is_never_treated_as_complete(tmp_path):
    make_source(tmp_path)
    (tmp_path / "mic.pcm").write_bytes(b"\x00\x00")
    with pytest.raises(ValueError, match="Truncated"):
        committed_sources(tmp_path)


def test_backend_snapshot_and_wav_copy_do_not_read_uncommitted_tail(tmp_path):
    from diarise_transcribe import muesli_backend as backend
    import wave

    make_source(tmp_path)
    source = committed_sources(tmp_path)["mic"]
    snapshot = backend.snapshot_stream(source, source.sample_rate, source.channels)
    assert snapshot.size_bytes == 320
    temporary = backend.write_wav_chunk(snapshot, tmp_path)
    try:
        with wave.open(str(temporary), "rb") as wav:
            assert wav.getnframes() == 160
    finally:
        temporary.unlink()
    assert (tmp_path / "mic.pcm").stat().st_size == 360


def test_source_mode_never_opens_or_deletes_source_files(tmp_path, monkeypatch):
    from diarise_transcribe import muesli_backend as backend
    import io
    from types import SimpleNamespace

    make_source(tmp_path)
    before = {p.name: p.read_bytes() for p in tmp_path.iterdir()}
    meta = json.dumps({"source_session_id": "session-a", "sample_rate": 48000}).encode()
    framed = backend.HDR_STRUCT.pack(backend.MSG_MEETING_START, 0, 0, len(meta)) + meta
    framed += backend.HDR_STRUCT.pack(backend.MSG_MEETING_STOP, 0, 0, 0)
    monkeypatch.setattr(backend.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(framed)))
    monkeypatch.setattr(backend, "open_stream_writer", lambda *a: pytest.fail("source overwritten"))
    monkeypatch.setattr(backend, "run_pipeline", lambda **kw: SimpleNamespace(turns=[]))
    monkeypatch.setattr(backend.TranscriptEmitter, "emit_transcript", lambda *a, **kw: None)
    args = backend.create_parser().parse_args(["--output-dir", str(tmp_path), "--source-recording", "--no-live"])
    args.observed_runtime_identity = {"schema_version": 1, "observation": "process_preflight"}
    output = io.StringIO()
    writer = backend.StdoutWriter(output)
    assert backend._run_backend(args, tmp_path, writer) == 0
    assert writer.close()
    for name, data in before.items():
        assert (tmp_path / name).read_bytes() == data
    assert "meeting_stopped" in output.getvalue()
    identity = next(json.loads(line) for line in output.getvalue().splitlines()
                    if json.loads(line).get("type") == "runtime_identity")
    assert identity["source_session_id"] == "session-a"
    assert identity["identity"] == args.observed_runtime_identity


def test_stdout_close_delivers_all_final_events_without_daemon_tail_loss():
    from diarise_transcribe.muesli_backend import StdoutWriter
    import io

    output = io.StringIO()
    writer = StdoutWriter(output, capacity=2)
    for i in range(1000):
        writer.write(f"final-{i}\n")
    assert writer.close()
    assert writer.close()
    assert output.getvalue().splitlines() == [f"final-{i}" for i in range(1000)]
    with pytest.raises(RuntimeError, match="closed"):
        writer.write("late")


def test_main_reserves_stdout_for_json_and_routes_model_diagnostics_to_stderr(tmp_path, monkeypatch):
    from diarise_transcribe import muesli_backend as backend
    import io

    protocol, diagnostics = io.StringIO(), io.StringIO()
    monkeypatch.setattr(backend.sys, "argv", ["muesli-backend", "--output-dir", str(tmp_path)])
    monkeypatch.setattr(backend.sys, "stdout", protocol)
    monkeypatch.setattr(backend.sys, "stderr", diagnostics)
    # Presence is optional so the protocol regression also covers the frozen
    # capture implementation before the separate offline preflight change.
    monkeypatch.setattr(backend, "preflight", lambda *a, **kw: None, raising=False)

    def run(args, directory, writer):
        print("model library diagnostic")
        backend.emit_jsonl({"type": "status", "message": "meeting_stopped"}, writer)
        return 0

    monkeypatch.setattr(backend, "_run_backend", run)
    assert backend.main() == 0
    assert [json.loads(line) for line in protocol.getvalue().splitlines()] == [
        {"type": "status", "message": "meeting_stopped"}]
    assert diagnostics.getvalue() == "model library diagnostic\n"
    assert backend.sys.stdout is protocol


def test_stdout_stall_has_bounded_queue_and_truthful_close_deadline():
    from diarise_transcribe.muesli_backend import StdoutWriter
    import threading
    import time

    entered, release = threading.Event(), threading.Event()
    class StalledOutput:
        def write(self, line):
            entered.set()
            release.wait(3)
        def flush(self):
            pass
    writer = StdoutWriter(StalledOutput(), capacity=1)
    writer.write("one")
    assert entered.wait(1)
    writer.write("two")
    started = time.monotonic()
    assert not writer.close(timeout=0.02)
    assert time.monotonic() - started < 0.5
    assert writer._queue.qsize() == 1
    release.set()
    assert writer.close(timeout=1)


def test_broken_stdout_is_reported_as_failure():
    from diarise_transcribe.muesli_backend import StdoutWriter
    class BrokenOutput:
        def write(self, line):
            raise BrokenPipeError("reader gone")
        def flush(self):
            pass
    writer = StdoutWriter(BrokenOutput())
    writer.write("final")
    assert not writer.close()


@pytest.mark.parametrize("no_live", [False, True])
@pytest.mark.parametrize("fail", [False, True])
def test_failed_inference_is_nonzero_but_successful_empty_transcript_is_valid(tmp_path, monkeypatch, no_live, fail):
    from diarise_transcribe import muesli_backend as backend
    from types import SimpleNamespace
    import io

    make_source(tmp_path)
    meta = json.dumps({"source_session_id": "session-a"}).encode()
    data = backend.HDR_STRUCT.pack(backend.MSG_MEETING_START, 0, 0, len(meta)) + meta
    data += backend.HDR_STRUCT.pack(backend.MSG_MEETING_STOP, 0, 0, 0)
    monkeypatch.setattr(backend.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(data)))
    def pipeline(**kwargs):
        if fail:
            raise RuntimeError("synthetic model unavailable")
        return SimpleNamespace(turns=[])
    monkeypatch.setattr(backend, "run_pipeline", pipeline)
    monkeypatch.setattr(backend.TranscriptEmitter, "emit_transcript", lambda *a, **kw: None)
    args = backend.create_parser().parse_args(["--output-dir", str(tmp_path), "--source-recording",
        "--live-asr-only"] + (["--no-live"] if no_live else []))
    output = io.StringIO()
    writer = backend.StdoutWriter(output)
    result = backend._run_backend(args, tmp_path, writer)
    assert writer.close()
    assert result == (1 if fail else 0)
    assert (tmp_path / "mic.pcm").exists()
    assert (tmp_path / "system.pcm").exists()
