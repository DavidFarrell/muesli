import json
import hashlib
import wave
import sys
from pathlib import Path

from diarise_transcribe import reprocess


def _write_wav_stub(path: Path, seconds=1) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\0\0" * int(seconds * 16000))


def test_discover_session_audio_dirs_prefers_metadata_order(tmp_path: Path) -> None:
    meeting_dir = tmp_path / "meeting"
    (meeting_dir / "audio").mkdir(parents=True)
    (meeting_dir / "audio-session-2").mkdir(parents=True)
    (meeting_dir / "audio-session-10").mkdir(parents=True)

    metadata = {
        "sessions": [
            {"session_id": 10, "audio_folder": "audio-session-10"},
            {"session_id": 1, "audio_folder": "audio"},
            {"session_id": 2, "audio_folder": "audio-session-2"},
        ]
    }
    (meeting_dir / "meeting.json").write_text(json.dumps(metadata), encoding="utf-8")

    dirs = reprocess._discover_session_audio_dirs(meeting_dir, verbose=False)
    assert [path.name for path in dirs] == ["audio", "audio-session-2", "audio-session-10"]


def test_main_applies_session_offsets(tmp_path: Path, monkeypatch) -> None:
    meeting_dir = tmp_path / "meeting"
    (meeting_dir / "audio").mkdir(parents=True)
    (meeting_dir / "audio-session-2").mkdir(parents=True)

    for folder in ("audio", "audio-session-2"):
        _write_wav_stub(meeting_dir / folder / "mic.wav", 2 if folder == "audio" else 5.5)
        _write_wav_stub(meeting_dir / folder / "system.wav", 3 if folder == "audio" else 6)

    metadata = {
        "sessions": [
            {"session_id": 1, "audio_folder": "audio"},
            {"session_id": 2, "audio_folder": "audio-session-2"},
        ]
    }
    (meeting_dir / "meeting.json").write_text(json.dumps(metadata), encoding="utf-8")

    def fake_reprocess_stream(path: Path, stream_name: str, **_kwargs):
        folder = path.parent.name
        if folder == "audio":
            if stream_name == "mic":
                return {
                    "turns": [{"speaker_id": "mic:SPEAKER_01", "stream": "mic", "t0": 1.0, "t1": 2.0, "text": "a"}],
                    "speakers": ["mic:SPEAKER_01"],
                    "duration": 2.0,
                }
            return {
                "turns": [{"speaker_id": "system:SPEAKER_01", "stream": "system", "t0": 0.5, "t1": 3.0, "text": "b"}],
                "speakers": ["system:SPEAKER_01"],
                "duration": 3.0,
            }

        if stream_name == "mic":
            return {
                "turns": [{"speaker_id": "mic:SPEAKER_01", "stream": "mic", "t0": 4.0, "t1": 5.0, "text": "c"}],
                "speakers": ["mic:SPEAKER_01"],
                "duration": 5.5,
            }
        return {
            "turns": [{"speaker_id": "system:SPEAKER_02", "stream": "system", "t0": 2.0, "t1": 6.0, "text": "d"}],
            "speakers": ["system:SPEAKER_02"],
            "duration": 6.0,
        }

    captured = []

    def fake_emit(obj):
        captured.append(obj)

    monkeypatch.setattr(reprocess, "reprocess_stream", fake_reprocess_stream)
    monkeypatch.setattr(reprocess, "get_audio_duration", lambda path: {
        ("audio", "mic.wav"): 2.0, ("audio", "system.wav"): 3.0,
        ("audio-session-2", "mic.wav"): 5.5, ("audio-session-2", "system.wav"): 6.0,
    }[(Path(path).parent.name, Path(path).name)])
    monkeypatch.setattr(reprocess, "emit", fake_emit)
    monkeypatch.setattr(
        sys,
        "argv",
        ["reprocess.py", str(meeting_dir), "--stream", "both"],
    )

    exit_code = reprocess.main()
    assert exit_code == 0

    results = [obj for obj in captured if obj.get("type") == "result"]
    assert len(results) == 1
    result = results[0]

    assert result["duration"] == 9.0
    assert result["turns"] == [
        {"speaker_id": "system:SPEAKER_01", "stream": "system", "t0": 0.5, "t1": 3.0, "text": "b", "source_session_id": "audio"},
        {"speaker_id": "mic:SPEAKER_01", "stream": "mic", "t0": 1.0, "t1": 2.0, "text": "a", "source_session_id": "audio"},
        {"speaker_id": "system:SPEAKER_02", "stream": "system", "t0": 5.0, "t1": 9.0, "text": "d", "source_session_id": "audio-session-2"},
        {"speaker_id": "mic:SPEAKER_01", "stream": "mic", "t0": 7.0, "t1": 8.0, "text": "c", "source_session_id": "audio-session-2"},
    ]


def _source(folder: Path, offset: int, mic_seconds: int, system_seconds: int) -> None:
    folder.mkdir(parents=True)
    streams = {}
    for stream, seconds in (("mic", mic_seconds), ("system", system_seconds)):
        size = seconds * 32_000
        (folder / f"{stream}.pcm").write_bytes(b"\x01\x00" * (size // 2) + b"UNCOMMITTED-TAIL")
        # Reprocess must neither read nor overwrite this stale compatibility file.
        (folder / f"{stream}.wav").write_bytes(b"existing compatibility evidence")
        streams[stream] = {"sample_rate": 16000, "channels": 1, "committed_bytes": size}
    (folder / "source-recording.json").write_text(json.dumps({
        "schema_version": 1, "session_id": folder.name, "timeline_offset_us": offset,
        "revision": 2, "completed": False, "streams": streams,
    }))


def test_committed_prefix_resume_twice_has_identical_mic_offsets_for_mic_only_and_both(tmp_path, monkeypatch):
    meeting = tmp_path / "meeting"
    _source(meeting / "audio", 0, 1, 2)
    _source(meeting / "audio-session-2", 10_000_000, 2, 3)
    _source(meeting / "audio-session-3", 25_000_000, 3, 4)
    (meeting / "meeting.json").write_text(json.dumps({"sessions": [
        {"session_id": i, "audio_folder": folder}
        for i, folder in enumerate(("audio", "audio-session-2", "audio-session-3"), 1)
    ]}))
    original = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in meeting.rglob("*") if p.is_file()}
    results = []
    exported_paths = []

    def fake_process(path, stream_name, **kwargs):
        exported_paths.append(path)
        with wave.open(str(path), "rb") as wav:
            assert wav.getframerate() == 16000
            assert wav.getnchannels() == 1
            assert wav.getnframes() in (16000, 32000, 48000, 64000)
            assert wav.readframes(wav.getnframes()) == b"\x01\x00" * wav.getnframes()
        return {"turns": [{"speaker_id": stream_name + ":one", "stream": stream_name,
                           "t0": 0.1, "t1": 0.2, "text": "same"}],
                "speakers": [stream_name + ":one"], "duration": 0.2}

    monkeypatch.setattr(reprocess, "reprocess_stream", fake_process)
    for selection in ("mic", "both"):
        events = []
        monkeypatch.setattr(reprocess, "emit", events.append)
        monkeypatch.setattr(sys, "argv", ["reprocess", str(meeting), "--stream", selection])
        assert reprocess.main() == 0
        results.append(next(e for e in events if e["type"] == "result"))
    assert [r["duration"] for r in results] == [29.0, 29.0]
    assert results[0]["sources"] == results[1]["sources"], "inventory is independent of chosen streams"
    assert [source["source_session_id"] for source in results[0]["sources"]] == ["audio", "audio-session-2", "audio-session-3"]
    assert {turn["source_session_id"] for turn in results[1]["turns"]} == {"audio", "audio-session-2", "audio-session-3"}
    assert [[t["t0"] for t in r["turns"] if t["stream"] == "mic"] for r in results] == [
        [0.1, 10.1, 25.1], [0.1, 10.1, 25.1]]
    assert all(not p.exists() for p in exported_paths), "only owned temporary exports are removed"
    assert {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in original} == original


def test_legacy_offsets_measure_both_source_files_even_for_mic_only(tmp_path, monkeypatch):
    meeting = tmp_path / "meeting"
    for folder, durations in (("audio", {"mic": 1, "system": 5}),
                              ("audio-session-2", {"mic": 2, "system": 3})):
        audio = meeting / folder
        audio.mkdir(parents=True)
        for stream, seconds in durations.items():
            with wave.open(str(audio / f"{stream}.wav"), "wb") as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
                wav.writeframes(b"\0\0" * (seconds * 16000))

    def fake_process(path, stream_name, **kwargs):
        return {"turns": [{"speaker_id": stream_name, "stream": stream_name, "t0": 0.1, "t1": 0.2, "text": "x"}],
                "speakers": [stream_name], "duration": 0.2}

    monkeypatch.setattr(reprocess, "reprocess_stream", fake_process)
    offsets = []
    for selection in ("mic", "both"):
        events = []
        monkeypatch.setattr(reprocess, "emit", events.append)
        monkeypatch.setattr(sys, "argv", ["reprocess", str(meeting), "--stream", selection])
        assert reprocess.main() == 0
        result = next(e for e in events if e["type"] == "result")
        assert result["duration"] == 8.0
        offsets.append([t["t0"] for t in result["turns"] if t["stream"] == "mic"])
    assert offsets == [[0.1, 5.1], [0.1, 5.1]]


def test_truncated_committed_source_fails_without_using_compatibility_wav(tmp_path, monkeypatch):
    meeting = tmp_path / "meeting"
    _source(meeting / "audio", 0, 1, 1)
    (meeting / "audio" / "mic.pcm").write_bytes(b"short")
    monkeypatch.setattr(sys, "argv", ["reprocess", str(meeting), "--stream", "mic"])
    events = []
    monkeypatch.setattr(reprocess, "emit", events.append)
    monkeypatch.setattr(reprocess, "reprocess_stream", lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("must not run ASR")))
    assert reprocess.main() == 1
    assert any("Truncated committed" in e.get("message", "") for e in events)
    assert (meeting / "audio" / "mic.pcm").read_bytes() == b"short"


def test_model_diagnostics_do_not_contaminate_stdout_protocol(tmp_path, monkeypatch, capsys):
    audio = tmp_path / "audio"
    audio.mkdir()
    _write_wav_stub(audio / "mic.wav")
    monkeypatch.setattr(reprocess, "get_audio_duration", lambda _: 1.0)

    def noisy_model(*args, **kwargs):
        print("model diagnostic is not JSON")
        return {"turns": [], "speakers": [], "duration": 1.0}

    monkeypatch.setattr(reprocess, "reprocess_stream", noisy_model)
    monkeypatch.setattr(sys, "argv", ["reprocess.py", str(tmp_path), "--stream", "mic"])
    assert reprocess.main() == 0
    captured = capsys.readouterr()
    events = [json.loads(line) for line in captured.out.splitlines()]
    assert events[-1]["type"] == "result"
    assert "model diagnostic is not JSON" in captured.err


def test_missing_metadata_session_does_not_compress_legacy_timeline(tmp_path, monkeypatch):
    audio = tmp_path / "audio-session-2"
    audio.mkdir()
    _write_wav_stub(audio / "mic.wav")
    (tmp_path / "meeting.json").write_text(json.dumps({"sessions": [
        {"session_id": 1, "audio_folder": "audio"},
        {"session_id": 2, "audio_folder": "audio-session-2"}]}))
    events = []
    monkeypatch.setattr(reprocess, "emit", events.append)
    monkeypatch.setattr(sys, "argv", ["reprocess", str(tmp_path), "--stream", "mic"])
    assert reprocess.main() == 1
    assert events[-1]["type"] == "error"
    assert "media extent is unknown" in events[-1]["message"]
    assert not any(event["type"] == "result" for event in events)
