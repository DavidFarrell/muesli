"""`reprocess --transcriber whitebox` against a fake shared STT service (whitebox-audio#10).

The fake listens on 127.0.0.1; production refuses any address outside the tailnet,
so the tests swap in an address check that accepts loopback. Audio is synthetic.
"""
import json
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import pytest

from diarise_transcribe import reprocess, whitebox_stt

HEALTH = {"ok": True, "default_engine": "whisper", "diarize_enabled": True,
          "engines": {"whisper": {"model": "large-v3", "ready": True},
                      "parakeet": {"model": "nvidia/parakeet-tdt-0.6b-v3", "ready": True}}}


def diarised(*segments):
    return {"text": " ".join(s[3] for s in segments), "language": "en",
            "segments": [{"speaker": s[0], "start": s[1], "end": s[2], "text": s[3]} for s in segments],
            "speakers": len({s[0] for s in segments}), "incomplete": False, "coverage": {}}


class FakeSTT:
    """The fake service in its own process (tests/fake_stt_server.py). `replies` maps
    a stream (mic/system) to a JSON body, a (status, body[, headers]) tuple, or a
    list of those used in order."""

    def __init__(self, replies, health=HEALTH):
        folder = Path(tempfile.mkdtemp(prefix="fake-stt-"))
        self.log = folder / "uploads.jsonl"
        config = {"health": health, "replies": {
            stream: [self._reply(r) for r in (reply if isinstance(reply, list) else [reply])]
            for stream, reply in replies.items()}}
        (folder / "config.json").write_text(json.dumps(config))
        self.process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("fake_stt_server.py")),
             str(folder / "config.json"), str(self.log)], stdout=subprocess.PIPE, text=True)
        self.url = f"http://localhost:{int(self.process.stdout.readline())}"

    @staticmethod
    def _reply(reply):
        if isinstance(reply, tuple):
            return {"status": reply[0], "body": reply[1], "headers": reply[2] if len(reply) > 2 else []}
        return {"status": 200, "body": reply}

    @property
    def uploads(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def close(self):
        self.process.kill()
        self.process.wait()


@pytest.fixture
def loopback_allowed(monkeypatch):
    monkeypatch.setattr(whitebox_stt, "tailnet_address", lambda host, port: "127.0.0.1")
    monkeypatch.setattr(whitebox_stt.time, "sleep", lambda _s: None)


def _meeting(tmp_path: Path) -> Path:
    meeting = tmp_path / "meeting"
    (meeting / "audio").mkdir(parents=True)
    for stream, seconds in (("mic", 2), ("system", 3)):
        with wave.open(str(meeting / "audio" / f"{stream}.wav"), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\x10\x00\xf0\xff" * (seconds * 8000))
    return meeting


def _run(monkeypatch, meeting, *extra):
    events = []
    monkeypatch.setattr(reprocess, "emit", events.append)
    monkeypatch.setattr(sys, "argv", ["reprocess", str(meeting), "--stream", "both", *extra])
    return reprocess.main(), events


def _local_inference(monkeypatch):
    """Stands in for Parakeet + Senko on the Mac; records which streams it saw."""
    seen = []

    def fake(temp_wav, stream_name, *args):
        seen.append(stream_name)
        evidence = args[7]
        evidence.status = "processed"
        return {"turns": [{"speaker_id": f"{stream_name}:SPEAKER_00", "stream": stream_name,
                           "t0": 0.0, "t1": 1.0, "text": "local words"}],
                "speakers": [f"{stream_name}:SPEAKER_00"], "duration": 1.0, "processing": evidence}

    monkeypatch.setattr(reprocess, "_process_owned_stream", fake)
    return seen


def test_whitebox_mode_returns_the_usual_turns_and_says_who_transcribed(tmp_path, monkeypatch, loopback_allowed):
    fake = FakeSTT({"mic": diarised(("SPEAKER_00", 0.0, 1.5, "Hello from the room.")),
                    "system": diarised(("SPEAKER_00", 0.2, 1.0, "Remote one."),
                                       ("SPEAKER_01", 1.2, 2.8, "Remote two."))})
    local = _local_inference(monkeypatch)
    try:
        code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                            "--whitebox-url", fake.url)
    finally:
        fake.close()

    assert code == 0
    assert local == []
    [result] = [e for e in events if e.get("type") == "result"]
    assert result["turns"] == [
        {"speaker_id": "mic:SPEAKER_00", "stream": "mic", "t0": 0.0, "t1": 1.5,
         "text": "Hello from the room.", "source_session_id": "audio"},
        {"speaker_id": "system:SPEAKER_00", "stream": "system", "t0": 0.2, "t1": 1.0,
         "text": "Remote one.", "source_session_id": "audio"},
        {"speaker_id": "system:SPEAKER_01", "stream": "system", "t0": 1.2, "t1": 2.8,
         "text": "Remote two.", "source_session_id": "audio"},
    ]
    assert result["speakers"] == ["mic:SPEAKER_00", "system:SPEAKER_00", "system:SPEAKER_01"]
    assert result["transcriber"] == {"machine": "whitebox", "engine": "whisper", "model": "large-v3",
                                     "service": fake.url, "fallback_reason": None}


def test_each_track_goes_up_on_its_own_with_no_engine_named(tmp_path, monkeypatch, loopback_allowed):
    fake = FakeSTT({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")),
                    "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    _local_inference(monkeypatch)
    try:
        code, _ = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox", "--whitebox-url", fake.url)
    finally:
        fake.close()

    assert code == 0
    assert sorted(u["stream"] for u in fake.uploads) == ["mic", "system"]
    for upload in fake.uploads:
        assert not upload["engine_field"]
        assert upload["diarize_true"]
        assert upload["flac"]                      # lossless FLAC, not the raw WAV
        assert upload["host"].startswith("localhost:")


def test_unreachable_whitebox_falls_back_to_the_mac_and_says_so(tmp_path, monkeypatch, loopback_allowed):
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                        "--whitebox-url", "http://localhost:9")   # nothing listens on port 9

    assert code == 0
    assert sorted(local) == ["mic", "system"]
    [fallback] = [e for e in events if e.get("stage") == "transcriber_fallback"]
    assert "unreachable" in fallback["reason"]
    [result] = [e for e in events if e.get("type") == "result"]
    assert result["transcriber"]["machine"] == "local"
    assert result["transcriber"]["engine"] == "parakeet"
    assert "unreachable" in result["transcriber"]["fallback_reason"]
    assert {t["text"] for t in result["turns"]} == {"local words"}


def test_an_address_outside_the_tailnet_is_never_sent_audio(tmp_path, monkeypatch):
    monkeypatch.setattr(whitebox_stt.socket, "getaddrinfo",
                        lambda *a, **k: [(2, 1, 6, "", ("93.184.216.34", 8081))])
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                        "--whitebox-url", "http://stt.example.com:8081")

    assert code == 0
    assert sorted(local) == ["mic", "system"]
    [result] = [e for e in events if e.get("type") == "result"]
    assert "not a Tailscale address" in result["transcriber"]["fallback_reason"]


@pytest.mark.parametrize("bad_system_reply, reason", [
    ({**diarised(("SPEAKER_00", 0.0, 1.0, "b")), "incomplete": True}, "incomplete"),
    ({**diarised(), "segments": [{"start": 0.0, "end": 1.0, "text": "b"}],
      "diarize_error": "RuntimeError: no speakers detected"}, "no speakers detected"),
    ((500, {"detail": "transcription failed: boom"}), "HTTP 500"),
])
def test_an_unusable_answer_mid_run_redoes_the_whole_meeting_on_the_mac(
        tmp_path, monkeypatch, loopback_allowed, bad_system_reply, reason):
    fake = FakeSTT({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")), "system": bad_system_reply})
    local = _local_inference(monkeypatch)
    try:
        code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                            "--whitebox-url", fake.url)
    finally:
        fake.close()

    assert code == 0
    assert sorted(local) == ["mic", "system"]          # both tracks, not just the bad one
    assert not [e for e in events if e.get("type") == "error"]
    [result] = [e for e in events if e.get("type") == "result"]
    assert result["transcriber"]["machine"] == "local"
    assert reason in result["transcriber"]["fallback_reason"]
    assert {t["text"] for t in result["turns"]} == {"local words"}


def test_a_silent_track_is_an_empty_stream_not_a_failure(tmp_path, monkeypatch, loopback_allowed):
    silent = {"text": "", "segments": [], "error": "no speech detected - audio track is effectively silent",
              "audio_level": {"peak_db": -90.0}, "diarize_error": "RuntimeError: not diarised - no speech detected",
              "incomplete": False}
    fake = FakeSTT({"mic": silent, "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    local = _local_inference(monkeypatch)
    try:
        code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox", "--whitebox-url", fake.url)
    finally:
        fake.close()

    assert code == 0 and local == []
    [result] = [e for e in events if e.get("type") == "result"]
    assert [t["speaker_id"] for t in result["turns"]] == ["system:SPEAKER_00"]
    statuses = {e["stream"]: e["status"] for e in result["processing"]["entries"]}
    assert statuses == {"mic": "processed_without_turns", "system": "processed"}


def test_a_busy_service_is_waited_for_not_abandoned(tmp_path, monkeypatch, loopback_allowed):
    fake = FakeSTT({"mic": [(503, {"detail": "busy"}, [("Retry-After", "5")]),
                            diarised(("SPEAKER_00", 0.0, 1.0, "a"))],
                    "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    local = _local_inference(monkeypatch)
    try:
        code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox", "--whitebox-url", fake.url)
    finally:
        fake.close()

    assert code == 0 and local == []
    [result] = [e for e in events if e.get("type") == "result"]
    assert result["transcriber"]["machine"] == "whitebox"
    assert len(fake.uploads) == 3


def test_local_mode_records_the_mac_when_asked(tmp_path, monkeypatch):
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "local")

    assert code == 0 and sorted(local) == ["mic", "system"]
    assert not [e for e in events if e.get("stage") == "transcriber_fallback"]
    [result] = [e for e in events if e.get("type") == "result"]
    assert result["transcriber"]["machine"] == "local"
    assert result["transcriber"]["fallback_reason"] is None


def test_without_the_option_the_result_the_app_reads_is_unchanged(tmp_path, monkeypatch):
    _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path))

    assert code == 0
    [result] = [e for e in events if e.get("type") == "result"]
    assert "transcriber" not in result
