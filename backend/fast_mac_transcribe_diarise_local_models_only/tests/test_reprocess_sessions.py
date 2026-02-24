import json
import sys
from pathlib import Path

from diarise_transcribe import reprocess


def _write_wav_stub(path: Path) -> None:
    path.write_bytes(b"RIFF")


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
        _write_wav_stub(meeting_dir / folder / "mic.wav")
        _write_wav_stub(meeting_dir / folder / "system.wav")

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
        {"speaker_id": "system:SPEAKER_01", "stream": "system", "t0": 0.5, "t1": 3.0, "text": "b"},
        {"speaker_id": "mic:SPEAKER_01", "stream": "mic", "t0": 1.0, "t1": 2.0, "text": "a"},
        {"speaker_id": "system:SPEAKER_02", "stream": "system", "t0": 5.0, "t1": 9.0, "text": "d"},
        {"speaker_id": "mic:SPEAKER_01", "stream": "mic", "t0": 7.0, "t1": 8.0, "text": "c"},
    ]
