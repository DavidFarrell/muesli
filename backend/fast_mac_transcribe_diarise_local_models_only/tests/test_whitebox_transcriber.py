"""`reprocess --transcriber whitebox` against a fake shared STT service (whitebox-audio#10).

The fake listens on 127.0.0.1; production refuses any address outside the tailnet,
so the tests swap in an address check that accepts loopback. Audio is synthetic.
"""
import inspect
import json
import os
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import pytest

from diarise_transcribe import reprocess, whitebox_stt

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg to encode uploads")

HEALTH = {"ok": True, "default_engine": "whisper", "diarize_enabled": True,
          "engines": {"whisper": {"model": "large-v3", "ready": True},
                      "parakeet": {"model": "nvidia/parakeet-tdt-0.6b-v3", "ready": True}}}


def diarised(*segments, words=None, engine="whisper", model="large-v3", language="en"):
    """The shared-shape answer to a diarised job that NAMED an engine: speaker
    turns in `segments` plus speaker-labelled word timings in `words`. Unless given,
    each segment's words share its time evenly."""
    if words is None:
        words = []
        for speaker, start, end, text in segments:
            parts = text.split()
            step = (end - start) / len(parts)
            words += [(speaker, start + i * step, start + (i + 1) * step, part)
                      for i, part in enumerate(parts)]
    payload = {"text": " ".join(s[3] for s in segments), "language": language,
               "segments": [{"speaker": s[0], "start": s[1], "end": s[2], "text": s[3]}
                            for s in segments],
               "words": [{"speaker": w[0], "start": w[1], "end": w[2], "text": w[3]} for w in words],
               "speakers": len({s[0] for s in segments}), "incomplete": False, "coverage": {}}
    if engine is not None:
        payload["engine"] = engine
    if model is not None:
        payload["model"] = model
    return payload


class FakeSTT:
    """The fake service in its own process (tests/fake_stt_server.py). `replies` maps
    a stream (mic/system) to a JSON body, a (status, body[, headers]) tuple, or a
    list of those used in order."""

    def __init__(self, folder: Path, replies, health=HEALTH):
        folder.mkdir()
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
        self.process.stdout.close()


@pytest.fixture
def fake_stt(tmp_path):
    """Starts fake STT services under tmp_path; every one is stopped afterwards."""
    started = []

    def start(replies, health=HEALTH):
        fake = FakeSTT(tmp_path / f"fake-stt-{len(started)}", replies, health)
        started.append(fake)
        return fake

    yield start
    for fake in started:
        fake.close()


@pytest.fixture
def loopback_allowed(monkeypatch):
    """Production refuses anything off the tailnet; the fake listens on loopback.
    `waited` collects every busy wait instead of sleeping through it."""
    waited = []
    monkeypatch.setattr(whitebox_stt, "tailnet_address", lambda host, port: "127.0.0.1")
    monkeypatch.setattr(whitebox_stt.time, "sleep", waited.append)
    return waited


def _meeting(tmp_path: Path, noise: bool = False) -> Path:
    meeting = tmp_path / "meeting"
    (meeting / "audio").mkdir(parents=True)
    for stream, seconds in (("mic", 2), ("system", 3)):
        with wave.open(str(meeting / "audio" / f"{stream}.wav"), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(os.urandom(seconds * 32000) if noise else b"\x10\x00\xf0\xff" * (seconds * 8000))
    return meeting


def _run(monkeypatch, meeting, *extra):
    events = []
    monkeypatch.setattr(reprocess, "emit", events.append)
    monkeypatch.setattr(sys, "argv", ["reprocess", str(meeting), "--stream", "both", *extra])
    return reprocess.main(), events


def _local_inference(monkeypatch):
    """Stands in for Parakeet + Senko on the Mac; records which streams it saw."""
    seen = []
    signature = inspect.signature(reprocess._process_owned_stream)

    def fake(*args, **kwargs):
        call = signature.bind(*args, **kwargs).arguments
        seen.append(call["stream_name"])
        stream_name, evidence = call["stream_name"], call["evidence"]
        evidence.status = "processed"
        return {"turns": [{"speaker_id": f"{stream_name}:SPEAKER_00", "stream": stream_name,
                           "t0": 0.0, "t1": 1.0, "text": "local words"}],
                "speakers": [f"{stream_name}:SPEAKER_00"], "duration": 1.0, "processing": evidence}

    monkeypatch.setattr(reprocess, "_process_owned_stream", fake)
    return seen


def _result(events):
    [result] = [e for e in events if e.get("type") == "result"]
    return result


def _whitebox(monkeypatch, tmp_path, fake, *extra):
    return _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                "--whitebox-url", fake.url, *extra)


def _track(stream, upload_format="flac", incomplete=False, coverage=None, language="en",
           engine="whisper", model="large-v3"):
    return {"stream": stream, "upload_format": upload_format, "incomplete": incomplete,
            "coverage": {} if coverage is None else coverage, "language": language,
            "engine": engine, "model": model}


def _by_stream(tracks):
    return sorted(tracks, key=lambda t: t["stream"])


def test_whitebox_mode_returns_the_usual_turns_and_says_who_transcribed(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.5, "Hello from the room.")),
                     "system": diarised(("SPEAKER_00", 0.2, 1.0, "Remote one."),
                                        ("SPEAKER_01", 1.2, 2.8, "Remote two."))})
    local = _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert local == []
    result = _result(events)
    assert result["turns"] == [
        {"speaker_id": "mic:SPEAKER_00", "stream": "mic", "t0": 0.0, "t1": 1.5,
         "text": "Hello from the room.", "source_session_id": "audio"},
        {"speaker_id": "system:SPEAKER_00", "stream": "system", "t0": 0.2, "t1": 1.0,
         "text": "Remote one.", "source_session_id": "audio"},
        {"speaker_id": "system:SPEAKER_01", "stream": "system", "t0": 1.2, "t1": 2.8,
         "text": "Remote two.", "source_session_id": "audio"},
    ]
    assert result["speakers"] == ["mic:SPEAKER_00", "system:SPEAKER_00", "system:SPEAKER_01"]
    transcriber = result["transcriber"]
    assert _by_stream(transcriber.pop("tracks")) == [_track("mic"), _track("system")]
    assert transcriber == {"machine": "whitebox", "engine": "whisper", "model": "large-v3",
                           "service": fake.url, "language": "auto", "fallback_reason": None}


def test_each_track_goes_up_on_its_own_naming_the_services_default_engine(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    """Naming the default engine is what makes the service return word timings
    and say which engine ran; no language means detect it, as the Mac does."""
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")),
                     "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    _local_inference(monkeypatch)
    code, _ = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert sorted(u["stream"] for u in fake.uploads) == ["mic", "system"]
    for upload in fake.uploads:
        assert upload["engine"] == "whisper"
        assert upload["language"] == "auto"
        assert upload["diarize"] == "true"
        assert upload["vad"] == "true"             # no "Thank you." invented in the silences
        assert upload["flac"]                      # lossless FLAC, not the raw WAV
        assert upload["host"].startswith("localhost:")


def test_a_named_language_is_sent_and_recorded(tmp_path, monkeypatch, loopback_allowed, fake_stt):
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "hallo"), language="de"),
                     "system": diarised(("SPEAKER_00", 0.0, 1.0, "welt"), language="de")})
    _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake, "--language", "de")

    assert code == 0
    assert {u["language"] for u in fake.uploads} == {"de"}
    transcriber = _result(events)["transcriber"]
    assert transcriber["language"] == "de"
    assert {t["language"] for t in transcriber["tracks"]} == {"de"}


def test_turns_are_built_from_the_word_timings_as_the_mac_builds_them(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    """The service's own turns are ignored: one that runs across a speaker change
    is split where the words change speaker, and --gap-threshold is honoured."""
    words = [("SPEAKER_00", 0.0, 0.4, "Hello"), ("SPEAKER_00", 0.5, 0.9, "there."),
             ("SPEAKER_01", 1.0, 1.4, "Hi."),
             ("SPEAKER_01", 2.4, 2.8, "Again.")]     # a 1.0 s pause before "Again."
    one_turn = diarised(("SPEAKER_00", 0.0, 2.8, "Hello there. Hi. Again."), words=words)
    fake = fake_stt({"mic": one_turn, "system": one_turn})
    _local_inference(monkeypatch)

    code, events = _whitebox(monkeypatch, tmp_path, fake)
    assert code == 0
    mic = [(t["speaker_id"], t["t0"], t["t1"], t["text"])
           for t in _result(events)["turns"] if t["stream"] == "mic"]
    assert mic == [("mic:SPEAKER_00", 0.0, 0.9, "Hello there."),
                   ("mic:SPEAKER_01", 1.0, 1.4, "Hi."),
                   ("mic:SPEAKER_01", 2.4, 2.8, "Again.")]

    code, events = _run(monkeypatch, tmp_path / "meeting", "--transcriber", "whitebox",
                        "--whitebox-url", fake.url, "--gap-threshold", "1.5")
    assert code == 0
    mic = [t["text"] for t in _result(events)["turns"] if t["stream"] == "mic"]
    assert mic == ["Hello there.", "Hi. Again."]


def test_engine_and_model_come_from_each_jobs_answer(tmp_path, monkeypatch, loopback_allowed, fake_stt):
    health = {**HEALTH, "default_engine": "parakeet"}
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a"), engine="parakeet",
                                     model="nvidia/parakeet-tdt-0.6b-v3", language=None),
                     "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"), engine=None, model=None,
                                        language=None)}, health=health)
    _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert {u["engine"] for u in fake.uploads} == {"parakeet"}
    transcriber = _result(events)["transcriber"]
    tracks = {t["stream"]: t for t in transcriber["tracks"]}
    assert (tracks["mic"]["engine"], tracks["mic"]["model"]) == ("parakeet", "nvidia/parakeet-tdt-0.6b-v3")
    assert (tracks["system"]["engine"], tracks["system"]["model"]) == ("unknown", "unknown")
    assert transcriber["engine"] == "mixed"          # never one engine assumed for both


def test_a_service_that_names_no_default_engine_is_recorded_as_unknown(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    """Nothing to name, so nothing is named: the service's own turns are used and
    the engine is "unknown", never assumed to be Whisper."""
    health = {k: v for k, v in HEALTH.items() if k != "default_engine"}
    plain = diarised(("SPEAKER_00", 0.0, 1.0, "plain turn"), engine=None, model=None)
    plain.pop("words")
    fake = fake_stt({"mic": plain, "system": plain}, health=health)
    _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert {u["engine"] for u in fake.uploads} == {None}
    result = _result(events)
    assert (result["transcriber"]["engine"], result["transcriber"]["model"]) == ("unknown", "unknown")
    assert {t["text"] for t in result["turns"]} == {"plain turn"}


def test_unreachable_whitebox_falls_back_to_the_mac_and_says_so(tmp_path, monkeypatch, loopback_allowed):
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                        "--whitebox-url", "http://localhost:9")   # nothing listens on port 9

    assert code == 0
    assert sorted(local) == ["mic", "system"]
    [fallback] = [e for e in events if e.get("stage") == "transcriber_fallback"]
    assert "unreachable" in fallback["reason"]
    transcriber = _result(events)["transcriber"]
    assert transcriber["machine"] == "local"
    assert transcriber["engine"] == "parakeet"
    assert transcriber["tracks"] == []
    assert "unreachable" in transcriber["fallback_reason"]
    assert {t["text"] for t in _result(events)["turns"]} == {"local words"}


def test_an_address_outside_the_tailnet_is_never_sent_audio(tmp_path, monkeypatch):
    monkeypatch.setattr(whitebox_stt.socket, "getaddrinfo",
                        lambda *a, **k: [(2, 1, 6, "", ("93.184.216.34", 8081))])
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "whitebox",
                        "--whitebox-url", "http://stt.example.com:8081")

    assert code == 0
    assert sorted(local) == ["mic", "system"]
    assert "not a Tailscale address" in _result(events)["transcriber"]["fallback_reason"]


@pytest.mark.parametrize("bad_system_reply, reason", [
    ({**diarised(), "segments": [{"start": 0.0, "end": 1.0, "text": "b"}],
      "diarize_error": "RuntimeError: no speakers detected"}, "no speakers detected"),
    ((500, {"detail": "transcription failed: boom"}), "HTTP 500"),
])
def test_an_unusable_answer_mid_run_redoes_the_whole_meeting_on_the_mac(
        tmp_path, monkeypatch, loopback_allowed, fake_stt, bad_system_reply, reason):
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")), "system": bad_system_reply})
    local = _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert sorted(local) == ["mic", "system"]          # both tracks, not just the bad one
    assert not [e for e in events if e.get("type") == "error"]
    transcriber = _result(events)["transcriber"]
    assert transcriber["machine"] == "local"
    assert transcriber["tracks"] == []                 # nothing carried over from the whitebox
    assert reason in transcriber["fallback_reason"]
    assert {t["text"] for t in _result(events)["turns"]} == {"local words"}


SILENT = {"text": "", "segments": [], "words": [], "engine": "whisper", "model": "large-v3",
          "error": "no speech detected - audio track is effectively silent",
          "audio_level": {"peak_db": -90.0}, "diarize_error": "RuntimeError: not diarised - no speech detected",
          "incomplete": True}
NO_WORDS = {"text": "", "segments": [], "words": [], "engine": "whisper", "model": "large-v3",
            "audio_seconds": 3.0, "incomplete": True,
            "diarize_error": "RuntimeError: whisper returned no word timestamps"}


@pytest.mark.parametrize("empty_reply", [SILENT, NO_WORDS], ids=["silent", "noise-without-words"])
def test_a_track_without_speech_is_an_empty_stream_not_a_failure(
        tmp_path, monkeypatch, loopback_allowed, fake_stt, empty_reply):
    fake = fake_stt({"mic": empty_reply, "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    local = _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0 and local == []
    result = _result(events)
    assert [t["speaker_id"] for t in result["turns"]] == ["system:SPEAKER_00"]
    statuses = {e["stream"]: e["status"] for e in result["processing"]["entries"]}
    assert statuses == {"mic": "processed_without_turns", "system": "processed"}


def test_a_track_that_goes_quiet_keeps_its_transcript_and_is_recorded_incomplete(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    coverage = {"reason": "the transcript ends at 1s of 300s of audio - it looks truncated",
                "end_ratio": 0.003}
    quiet_end = {**diarised(("SPEAKER_00", 0.0, 1.0, "b")), "incomplete": True, "coverage": coverage}
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")), "system": quiet_end})
    local = _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0 and local == []
    [warning] = [e for e in events if e.get("stage") == "coverage_warning"]
    assert warning["stream"] == "system" and "truncated" in warning["reason"]
    transcriber = _result(events)["transcriber"]
    assert transcriber["machine"] == "whitebox"
    assert _by_stream(transcriber["tracks"]) == [
        _track("mic"), _track("system", incomplete=True, coverage=coverage)]
    assert {t["text"] for t in _result(events)["turns"]} == {"a", "b"}


def test_a_track_past_the_upload_cap_goes_up_as_opus_and_says_so(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    monkeypatch.setattr(whitebox_stt, "UPLOAD_CAP_BYTES", 40_000)   # between Opus and FLAC sizes of 3 s of noise
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")),
                     "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path, noise=True), "--transcriber", "whitebox",
                        "--whitebox-url", fake.url)

    assert code == 0 and local == []
    assert all(u["ogg"] and not u["flac"] for u in fake.uploads)
    assert {t["upload_format"] for t in _result(events)["transcriber"]["tracks"]} == {"opus"}


def test_a_busy_service_is_waited_for_not_abandoned(tmp_path, monkeypatch, loopback_allowed, fake_stt):
    fake = fake_stt({"mic": [(503, {"detail": "busy"}, [("Retry-After", "5")]),
                             diarised(("SPEAKER_00", 0.0, 1.0, "a"))],
                     "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    local = _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0 and local == []
    assert _result(events)["transcriber"]["machine"] == "whitebox"
    assert len(fake.uploads) == 3
    assert loopback_allowed == [5.0]


def test_busy_waits_are_capped_at_five_minutes_for_the_whole_run(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    """Each track's wait is under the cap; together they are over it."""
    busy = (503, {"detail": "busy"}, [("Retry-After", "200")])
    fake = fake_stt({"mic": [busy, diarised(("SPEAKER_00", 0.0, 1.0, "a"))],
                     "system": [busy, diarised(("SPEAKER_00", 0.0, 1.0, "b"))]})
    local = _local_inference(monkeypatch)
    code, events = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert sorted(local) == ["mic", "system"]
    assert "busy" in _result(events)["transcriber"]["fallback_reason"]
    assert sum(loopback_allowed) <= 300


def test_the_read_timeout_is_the_track_length_plus_five_minutes(
        tmp_path, monkeypatch, loopback_allowed, fake_stt):
    timeouts = []
    real = whitebox_stt.http.client.HTTPConnection

    class Recording(real):
        def request(self, method, url, *args, **kwargs):
            timeouts.append((method, self.timeout))
            return super().request(method, url, *args, **kwargs)

    monkeypatch.setattr(whitebox_stt.http.client, "HTTPConnection", Recording)
    fake = fake_stt({"mic": diarised(("SPEAKER_00", 0.0, 1.0, "a")),
                     "system": diarised(("SPEAKER_00", 0.0, 1.0, "b"))})
    _local_inference(monkeypatch)
    code, _ = _whitebox(monkeypatch, tmp_path, fake)

    assert code == 0
    assert sorted(t for method, t in timeouts if method == "POST") == [302.0, 303.0]   # 2 s and 3 s tracks


def test_local_mode_records_the_mac_when_asked(tmp_path, monkeypatch):
    local = _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path), "--transcriber", "local")

    assert code == 0 and sorted(local) == ["mic", "system"]
    assert not [e for e in events if e.get("stage") == "transcriber_fallback"]
    assert _result(events)["transcriber"] == {
        "machine": "local", "engine": "parakeet", "model": "mlx-community/parakeet-tdt-0.6b-v3",
        "service": None, "language": "auto", "fallback_reason": None, "tracks": []}


def test_without_the_option_the_result_the_app_reads_is_unchanged(tmp_path, monkeypatch):
    _local_inference(monkeypatch)
    code, events = _run(monkeypatch, _meeting(tmp_path))

    assert code == 0
    assert "transcriber" not in _result(events)
