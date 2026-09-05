"""Actual batch admission/snapshot/model seams; all audio and models synthetic."""
import hashlib
import json
import os
from pathlib import Path
import sys
import wave

import pytest

from diarise_transcribe import reprocess
from diarise_transcribe import processing_evidence as evidence
from diarise_transcribe.asr import TranscriptResult, Word
from diarise_transcribe.diarisation import DiarSegment
from diarise_transcribe.source_recording import committed_sources


def wav(path, frames=16000, rate=16000, channels=1, width=2):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(channels); out.setsampwidth(width); out.setframerate(rate)
        out.writeframes(b"\0" * frames * channels * width)


def pcm(folder, mic=32000, system=0):
    folder.mkdir(parents=True)
    streams = {}
    for name, size in (("mic", mic), ("system", system)):
        (folder / f"{name}.pcm").write_bytes(b"\x01\0" * (size // 2) + b"tail")
        streams[name] = {"sample_rate": 16000, "channels": 1, "committed_bytes": size}
    (folder / "source-recording.json").write_text(json.dumps({
        "schema_version": 1, "session_id": "fixture-source", "revision": 7,
        "timeline_offset_us": 30_000_000, "completed": False, "streams": streams}))


def models(monkeypatch, *, words=None, segments=None, asr_action=None, diar_action=None):
    seen = []
    class ASR:
        def __init__(self, *_): pass
        def transcribe(self, path, language=None):
            seen.append(("asr", Path(path), Path(path).read_bytes()))
            if asr_action: asr_action(Path(path))
            return TranscriptResult("fixture", [] if words is None else words)
    class Diar:
        def __init__(self, **_): pass
        def diarise(self, path):
            seen.append(("diar", Path(path), Path(path).read_bytes()))
            if diar_action: diar_action(Path(path))
            return [] if segments is None else segments
    monkeypatch.setattr(reprocess, "ASRModel", ASR)
    monkeypatch.setattr(reprocess, "SenkoDiarizer", Diar)
    return seen


def run(monkeypatch, meeting, selection="both", recovery=False):
    events = []
    monkeypatch.setattr(reprocess, "emit", events.append)
    monkeypatch.setattr(sys, "argv", ["reprocess", str(meeting), "--stream", selection] + ([] if recovery else ["--no-recovery"]))
    rc = reprocess.main()
    return rc, events[-1]


def test_pcm_exact_prefix_manifest_and_model_bytes_are_distinct_owned_evidence(tmp_path, monkeypatch):
    pcm(tmp_path / "audio")
    manifest = (tmp_path / "audio/source-recording.json").read_bytes()
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path)
    assert rc == 0
    payload = event["processing"]
    assert payload["schema_version"] == 1 and payload["complete"]
    assert payload["requested_streams"] == ["system", "mic"]
    system, mic = payload["entries"]
    assert system["status"] == "empty" and system["availability"] == "empty"
    assert system["model_input"] is None and system["asr_word_count"] is None
    assert mic["status"] == "processed_without_turns" and mic["availability"] == "present"
    assert mic["asr_word_count"] == mic["diarization_segment_count"] == mic["turn_count"] == 0
    raw = mic["source_input"]
    assert raw["manifest_sha256"] == hashlib.sha256(manifest).hexdigest()
    assert raw["manifest_revision"] == 7 and raw["completed"] is False
    assert raw["byte_count"] == raw["committed_bytes"] == 32000
    assert raw["sha256"] == hashlib.sha256(b"\x01\0" * 16000).hexdigest()
    assert seen[0][1] == seen[1][1] and seen[0][2] == seen[1][2]
    model = mic["model_input"]
    assert model["sha256"] == hashlib.sha256(seen[0][2]).hexdigest()
    assert model["byte_count"] == len(seen[0][2]) and model["frame_count"] == 16000
    assert not seen[0][1].exists()
    assert str(tmp_path) not in json.dumps(payload)
    assert "muesli-model-input" not in json.dumps(payload)


def test_manifest_replaced_after_frozen_parse_cannot_change_export_or_claimed_revision(tmp_path, monkeypatch):
    pcm(tmp_path / "audio")
    path = tmp_path / "audio/source-recording.json"
    original = path.read_bytes()
    real = reprocess.committed_sources
    def replaced(*args, **kwargs):
        value = real(*args, **kwargs)
        newer = json.loads(original)
        newer["revision"] = 99
        newer["streams"]["mic"]["committed_bytes"] = 2
        path.write_text(json.dumps(newer))
        return value
    monkeypatch.setattr(reprocess, "committed_sources", replaced)
    models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 0
    entry = event["processing"]["entries"][1]
    assert entry["source_input"]["manifest_revision"] == 7
    assert entry["source_input"]["manifest_sha256"] == hashlib.sha256(original).hexdigest()
    assert entry["model_input"]["frame_count"] == 16000


def test_legacy_original_can_change_after_snapshot_without_rebinding_model_evidence(tmp_path, monkeypatch):
    original = tmp_path / "audio/mic.wav"
    wav(original)
    old_bytes = original.read_bytes()
    seen = models(monkeypatch, asr_action=lambda _: original.write_bytes(b"changed external source"))
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 0
    system, mic = event["processing"]["entries"]
    assert system["status"] == "not_requested" and system["availability"] == "missing"
    assert system["source_input"] is None and system["model_input"] is None
    assert mic["source_input"]["sha256"] == hashlib.sha256(old_bytes).hexdigest()
    assert seen[0][2] == seen[1][2] == old_bytes
    assert all(path != original and not path.exists() for _, path, _ in seen)


@pytest.mark.parametrize("stage", ["asr", "diar"])
@pytest.mark.parametrize("kind", ["write", "replace"])
def test_changed_private_input_is_fatal_and_no_success_result(tmp_path, monkeypatch, stage, kind):
    wav(tmp_path / "audio/mic.wav")
    def mutate(path):
        if kind == "replace":
            data = path.read_bytes()
            path.unlink()
            path.write_bytes(data)  # identical bytes still have a different inode
        else:
            with path.open("r+b") as f:
                f.seek(45); f.write(b"x")
    seen = models(monkeypatch, **{stage + "_action": mutate})
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 1 and event["type"] == "error"
    assert event["processing"]["complete"] is False
    assert event["processing"]["entries"][1]["status"] == "failed"
    assert event["processing"]["entries"][1]["failure_code"] == "InputChanged"
    if stage == "asr": assert len(seen) == 1
    assert all(not path.exists() for _, path, _ in seen)


def test_model_failure_preserves_partial_counts_and_future_stream_not_processed(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav")
    wav(tmp_path / "audio/system.wav")
    def fail(_): raise RuntimeError("fixture")
    models(monkeypatch, words=[Word("one", 0, .1)], diar_action=fail)
    rc, event = run(monkeypatch, tmp_path)
    assert rc == 1
    system, mic = event["processing"]["entries"]
    assert system["status"] == "failed" and system["asr_word_count"] == 1
    assert system["diarization_segment_count"] is None and system["turn_count"] is None
    assert mic["status"] == "not_processed" and mic["model_input"] is None
    assert mic["source_input"] is not None


def test_missing_selected_is_not_empty(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav", frames=0)
    models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path)
    assert rc == 1
    entry = event["processing"]["entries"][0]
    assert entry["status"] == "failed" and entry["availability"] == "missing"
    assert entry["model_input"] is None


def test_not_requested_present_stream_keeps_source_evidence_without_model_claim(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav")
    wav(tmp_path / "audio/system.wav", frames=32000)
    seen = models(monkeypatch, words=[Word("one", 0, .1)], segments=[DiarSegment(0, 1, "one")])
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 0 and len(seen) == 2 and event["duration"] == 2
    system, mic = event["processing"]["entries"]
    assert system["status"] == "not_requested" and system["availability"] == "present"
    assert system["source_input"]["frame_count"] == 32000 and system["model_input"] is None
    assert mic["status"] == "processed" and mic["turn_count"] == 1


def test_empty_legacy_file_has_verified_zero_frames_no_models(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav", frames=0)
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 0 and seen == []
    mic = event["processing"]["entries"][1]
    assert mic["status"] == "empty" and mic["source_input"]["frame_count"] == 0
    assert mic["source_input"]["byte_count"] == 44 and mic["model_input"] is None


def test_24bit_mono_is_normalized_and_both_models_see_normalized_bytes(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav", width=3)
    if not reprocess.check_ffmpeg(): pytest.skip("local decoder unavailable")
    calls = []
    real_normalize = reprocess.normalise_audio
    def normalize(source, output_path, max_output_bytes, **kwargs):
        calls.append((Path(source).read_bytes(), max_output_bytes))
        return real_normalize(source, output_path, max_output_bytes=max_output_bytes, **kwargs)
    monkeypatch.setattr(reprocess, "normalise_audio", normalize)
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 0 and len(calls) == 1
    mic = event["processing"]["entries"][1]
    assert mic["source_input"]["encoding"] == "PCM_24"
    assert mic["model_input"]["format"] == "wav_pcm_s16le"
    assert mic["source_input"]["sha256"] != mic["model_input"]["sha256"]
    assert seen[0][2] == seen[1][2]


def test_copy_detects_actual_mutation_and_never_runs_models(tmp_path, monkeypatch):
    source = tmp_path / "audio/mic.wav"
    wav(source)
    real_read = os.read
    changed = False
    def read(fd, count):
        nonlocal changed
        result = real_read(fd, count)
        if not changed and count > 10000:
            changed = True
            with source.open("ab") as out: out.write(b"changed")
        return result
    monkeypatch.setattr(evidence.os, "read", read)
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 1 and seen == [] and changed
    assert event["processing"]["entries"][1]["failure_code"] == "InputChanged"


@pytest.mark.parametrize("target", ["meeting.json", "audio", "audio/mic.wav", "audio/source-recording.json"])
def test_source_symlinks_never_fall_back_or_read_foreign_inputs(tmp_path, monkeypatch, target):
    meeting = tmp_path / "meeting"
    wav(meeting / "audio/mic.wav")
    external = tmp_path / "external"
    if target == "audio":
        (meeting / "audio").rename(external)
        (meeting / "audio").symlink_to(external, target_is_directory=True)
    else:
        path = meeting / target
        path.unlink(missing_ok=True)
        path.symlink_to(external)  # dangling link must not count as absent
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, meeting, "mic")
    assert rc == 1 and seen == [] and not event["processing"]["complete"]


def test_snapshot_budget_counts_derived_copies_before_model_call(tmp_path, monkeypatch):
    pcm(tmp_path / "audio", mic=32000, system=0)
    monkeypatch.setattr(evidence, "MAX_SNAPSHOT_BYTES", 64090)  # raw+WAV fit; model copy does not
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 1 and seen == []
    assert "budget" in event["message"].lower()


def test_recovery_budget_failure_remains_visible_in_successful_main_result(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav", frames=160000)
    monkeypatch.setattr(evidence, "MAX_RECOVERY_WINDOWS", 0)
    seen = models(monkeypatch, segments=[DiarSegment(0, 5, "one")])
    rc, event = run(monkeypatch, tmp_path, "mic", recovery=True)
    assert rc == 0 and len(seen) == 2
    recovery = event["processing"]["entries"][1]["recovery"]
    assert recovery["outcome"] == "failed" and recovery["planned_window_count"] == 1
    assert recovery["attempted_window_count"] == 0 and recovery["failure_code"] == "ValueError"


def test_manifest_bool_numbers_rejected_and_frozen_bytes_hashed(tmp_path):
    pcm(tmp_path / "audio")
    path = tmp_path / "audio/source-recording.json"
    raw = path.read_bytes()
    parsed = committed_sources(path.parent, manifest_bytes=raw, validate_files=False)
    assert parsed["mic"].manifest_sha256 == hashlib.sha256(raw).hexdigest()
    for keys in [("schema_version",), ("streams", "mic", "channels")]:
        value = json.loads(raw)
        parent = value
        for key in keys[:-1]: parent = parent[key]
        parent[keys[-1]] = True
        with pytest.raises(ValueError):
            committed_sources(path.parent, manifest_bytes=json.dumps(value).encode(), validate_files=False)


def test_total_final_record_limit_is_checked_before_success_status(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav")
    words = [Word("x" * (4 * 1024 * 1024), 0, .1)]
    models(monkeypatch, words=words, segments=[DiarSegment(0, 1, "one")])
    events = []
    monkeypatch.setattr(reprocess, "emit", events.append)
    monkeypatch.setattr(sys, "argv", ["reprocess", str(tmp_path), "--stream", "mic", "--no-recovery"])
    assert reprocess.main() == 1
    assert events[-1]["type"] == "error"
    assert "4 MiB protocol" in events[-1]["message"]
    assert not events[-1]["processing"]["complete"]
    assert not any(e.get("stage") == "complete" or e["type"] == "result" for e in events)
    assert len(reprocess._encoded_event(events[-1]).encode()) < reprocess.MAX_PROTOCOL_BYTES


def test_bounded_real_decoder_rejects_output_before_writing_past_limit(tmp_path):
    from diarise_transcribe.audio import check_ffmpeg, normalise_audio
    if not check_ffmpeg(): pytest.skip("local ffmpeg unavailable")
    source = tmp_path / "input.wav"
    output = tmp_path / "owned.wav"
    wav(source, frames=16000, rate=8000, width=3)
    old = source.read_bytes()
    with pytest.raises(ValueError, match="size limit"):
        normalise_audio(str(source), str(output), max_output_bytes=1024)
    assert output.stat().st_size <= 1024
    assert source.read_bytes() == old
    normalise_audio(str(source), str(output), max_output_bytes=100000)
    with evidence.ModelInput(output) as model:
        assert model.frame_count == 32000


def test_directory_entry_budget_consumes_lazy_iterator_only_to_limit(tmp_path, monkeypatch):
    consumed = 0
    class Entry:
        name = "unrelated"
    class Scan:
        def __enter__(self): return self
        def __exit__(self, *_): pass
        def __iter__(self):
            nonlocal consumed
            for _ in range(100000):
                consumed += 1
                yield Entry()
    monkeypatch.setattr(evidence.os, "scandir", lambda _: Scan())
    with evidence.SourceDirectory(tmp_path) as directory:
        with pytest.raises(ValueError, match="entry limit"):
            directory.names()
    assert consumed == 4097


def fixture_result(monkeypatch, target):
    """Exercise the actual producer using only a checked-in synthetic source."""
    import shutil
    from diarise_transcribe import runtime_identity
    source = Path(__file__).parent / "fixtures/processing-v1/meeting"
    shutil.copytree(source, target)
    monkeypatch.setattr(runtime_identity, "prepare_observation", lambda *a, **kw: (
        {"fixture_only": True, "qualification": "synthetic models; no runtime claim"}, "fixture-model"))
    models(monkeypatch, words=[Word("fixture", 0, 1)], segments=[DiarSegment(0, 1, "one")])
    rc, event = run(monkeypatch, target, recovery=True)
    assert rc == 0
    return event


def test_checked_fixture_matches_actual_successful_producer(tmp_path, monkeypatch):
    expected = json.loads((Path(__file__).parent / "fixtures/processing-v1/result.json").read_text())
    assert fixture_result(monkeypatch, tmp_path / "fixture-meeting") == expected


def test_invalid_recovery_window_emits_finite_explicit_failure_evidence(tmp_path, monkeypatch):
    from diarise_transcribe.recovery import RecoveryWindow
    wav(tmp_path / "audio/mic.wav", frames=160000)
    models(monkeypatch, segments=[DiarSegment(0, 5, "one")])
    monkeypatch.setattr(reprocess, "cluster_recovery_windows", lambda *a, **kw: [
        RecoveryWindow(float("nan"), 5, 0, 5)])
    rc, event = run(monkeypatch, tmp_path, "mic", recovery=True)
    assert rc == 0
    recovery = event["processing"]["entries"][1]["recovery"]
    assert recovery["outcome"] == "failed" and recovery["windows"] == []
    assert recovery["attempted_window_count"] == 0
    json.dumps(event, allow_nan=False)


def test_model_guard_detects_mutation_during_final_hash_read(tmp_path, monkeypatch):
    path = tmp_path / "owned.wav"
    wav(path)
    with evidence.ModelInput(path) as owned:
        real_read = evidence.os.read
        changed = False
        def read(fd, count):
            nonlocal changed
            data = real_read(fd, count)
            if fd == owned.fd and not changed:
                changed = True
                with path.open("r+b") as output:
                    output.seek(45); output.write(b"x")
            return data
        monkeypatch.setattr(evidence.os, "read", read)
        with pytest.raises(evidence.InputChanged):
            owned.verify()


@pytest.mark.parametrize("storage", ["pcm", "legacy"])
def test_intermediate_owned_snapshot_cannot_be_rebound_before_model_admission(tmp_path, monkeypatch, storage):
    if storage == "pcm": pcm(tmp_path / "audio")
    else: wav(tmp_path / "audio/mic.wav")
    real_process = reprocess.reprocess_stream
    def alter_snapshot(path, *args, **kwargs):
        with path.open("r+b") as output:
            output.seek(45); output.write(b"x")
        return real_process(path, *args, **kwargs)
    monkeypatch.setattr(reprocess, "reprocess_stream", alter_snapshot)
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 1 and seen == []
    assert event["processing"]["entries"][1]["failure_code"] == "InputChanged"


def test_owned_pcm_edit_before_wrapping_cannot_rebind_source_hash(tmp_path, monkeypatch):
    pcm(tmp_path / "audio")
    real_wrap = reprocess._committed_wav
    def altered(source, path, *args, **kwargs):
        if source.size_bytes:
            with path.open("r+b") as output:
                output.write(b"xx")
        return real_wrap(source, path, *args, **kwargs)
    monkeypatch.setattr(reprocess, "_committed_wav", altered)
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 1 and seen == []
    assert event["processing"]["entries"][1]["failure_code"] == "InputChanged"


def test_normalization_cannot_rebind_a_changed_private_source(tmp_path, monkeypatch):
    wav(tmp_path / "audio/mic.wav", width=3)
    if not reprocess.check_ffmpeg(): pytest.skip("local decoder unavailable")
    real_normalize = reprocess.normalise_audio
    def normalize(source, **kwargs):
        produced = real_normalize(source, **kwargs)
        with Path(source).open("r+b") as output:
            output.seek(45); output.write(b"x")
        return produced
    monkeypatch.setattr(reprocess, "normalise_audio", normalize)
    seen = models(monkeypatch)
    rc, event = run(monkeypatch, tmp_path, "mic")
    assert rc == 1 and event["type"] == "error" and seen == []
    assert event["processing"]["entries"][1]["failure_code"] == "InputChanged"


def _alter_produced_wav(produced, mutation):
    """Preserve the independent review's exact post-production mutation point."""
    from dataclasses import replace
    path = Path(produced)
    before = path.read_bytes()
    if mutation == "sample":
        with path.open("r+b") as handle:
            handle.seek(44); handle.write(b"\x34\x12")
        assert len(path.read_bytes()) == len(before) and path.read_bytes() != before
    elif mutation == "inode":
        path.unlink()
        path.write_bytes(before)
        assert path.read_bytes() == before
    elif mutation == "missing":
        path.unlink()
    elif mutation == "frames":
        return replace(produced, frame_count=produced.frame_count + 1)
    else:
        raise AssertionError(mutation)
    return produced


@pytest.mark.parametrize("producer", ["recovery", "normalization"])
@pytest.mark.parametrize("mutation", ["sample", "inode", "missing", "frames", "hardlink"])
def test_actual_derived_output_handoff_must_match_producer_bytes_identity_and_frames(
        tmp_path, monkeypatch, producer, mutation):
    if producer == "normalization" and not reprocess.check_ffmpeg():
        pytest.skip("local decoder unavailable")
    wav(tmp_path / "audio/mic.wav", frames=16000 * 5, width=3 if producer == "normalization" else 2)
    original_source = (tmp_path / "audio/mic.wav").read_bytes()
    function = "slice_wav_to_temp" if producer == "recovery" else "normalise_audio"
    real_producer = getattr(reprocess, function)
    handed_off = []
    def mutate_after_production(*args, **kwargs):
        produced = real_producer(*args, **kwargs)
        handed_off.append(Path(produced))
        if mutation == "hardlink":
            os.link(os.fspath(produced), tmp_path / "fixture-derived-hardlink.wav")
            return produced
        return _alter_produced_wav(produced, mutation)
    monkeypatch.setattr(reprocess, function, mutate_after_production)
    seen = models(monkeypatch, words=[Word("word", .2, .4)],
                  segments=[DiarSegment(1, 4, "speaker")])
    rc, event = run(monkeypatch, tmp_path, "mic", recovery=producer == "recovery")
    assert handed_off
    assert rc == 1 and event["type"] == "error" and not event["processing"]["complete"]
    entry = event["processing"]["entries"][1]
    assert entry["status"] == "failed" and entry["failure_code"] == "InputChanged"
    assert len(seen) == (2 if producer == "recovery" else 0), "changed output must never reach a model"
    if producer == "recovery":
        recovery = entry["recovery"]
        assert recovery["outcome"] == "failed" and recovery["failed_window_count"] == 1
        window = recovery["windows"][0]
        assert window["failure_code"] == "InputChanged" and window["model_input"] is None
    assert (tmp_path / "audio/mic.wav").read_bytes() == original_source
    assert all(not path.exists() for path in handed_off)
    (tmp_path / "fixture-derived-hardlink.wav").unlink(missing_ok=True)


@pytest.mark.parametrize("producer", ["recovery", "normalization"])
def test_producer_digest_is_observed_during_derivation_not_rebased_at_finish(tmp_path, monkeypatch, producer):
    from diarise_transcribe.wav_derivation import WAVDerivation
    if producer == "normalization" and not reprocess.check_ffmpeg():
        pytest.skip("local decoder unavailable")
    wav(tmp_path / "audio/mic.wav", frames=16000 * 5, width=3 if producer == "normalization" else 2)
    original_finish = WAVDerivation.finish
    changed = []
    def mutate_before_finish(self, output, path):
        output.flush()
        output.seek(44); output.write(b"\x34\x12"); output.flush()
        changed.append(path)
        return original_finish(self, output, path)
    monkeypatch.setattr(WAVDerivation, "finish", mutate_before_finish)
    seen = models(monkeypatch, words=[Word("word", .2, .4)], segments=[DiarSegment(1, 4, "speaker")])
    rc, event = run(monkeypatch, tmp_path, "mic", recovery=producer == "recovery")
    assert changed and rc == 1 and event["type"] == "error"
    assert event["processing"]["entries"][1]["failure_code"] == "InputChanged"
    assert len(seen) == (2 if producer == "recovery" else 0)
    assert all(not Path(path).exists() for path in changed)


def test_actual_producer_handoff_is_frozen_and_matches_canonical_output(tmp_path):
    from dataclasses import FrozenInstanceError
    from diarise_transcribe.audio import slice_wav_to_temp
    wav(tmp_path / "input.wav", frames=16000 * 5)
    result = slice_wav_to_temp(str(tmp_path / "input.wav"), .125, 1.875, return_evidence=True)
    try:
        assert result.frame_count == 28000
        assert result.byte_count == 56044
        assert result.sha256 == hashlib.sha256(Path(result).read_bytes()).hexdigest()
        with pytest.raises(FrozenInstanceError):
            result.frame_count = 0
        with evidence.ModelInput(Path(result), expected=result) as admitted:
            assert admitted.frame_count == 28000
    finally:
        Path(result).unlink()


@pytest.mark.parametrize("producer", ["recovery", "normalization"])
@pytest.mark.parametrize("mutation", ["missing", "header"])
def test_format_read_race_after_producer_identity_check_is_fatal(tmp_path, monkeypatch, producer, mutation):
    if producer == "normalization" and not reprocess.check_ffmpeg():
        pytest.skip("local decoder unavailable")
    wav(tmp_path / "audio/mic.wav", frames=16000 * 5, width=3 if producer == "normalization" else 2)
    original_open = evidence.wave.open
    changed = []
    def mutate_at_format_read(file, mode=None):
        if isinstance(file, str) and mode == "rb" and (
                Path(file).name.startswith("recovery_slice_") if producer == "recovery"
                else isinstance(file, str) and mode == "rb" and Path(file).name == "normalized.wav"):
            changed.append(Path(file))
            if mutation == "missing":
                Path(file).unlink()
            else:
                with Path(file).open("r+b") as output:
                    output.write(b"BAD!")
        return original_open(file, mode)
    monkeypatch.setattr(evidence.wave, "open", mutate_at_format_read)
    seen = models(monkeypatch, words=[Word("word", .2, .4)], segments=[DiarSegment(1, 4, "speaker")])
    rc, event = run(monkeypatch, tmp_path, "mic", recovery=producer == "recovery")
    assert changed and rc == 1 and event["type"] == "error"
    assert not event["processing"]["complete"]
    entry = event["processing"]["entries"][1]
    assert entry["failure_code"] == "InputChanged"
    if producer == "recovery":
        assert entry["recovery"]["outcome"] == "failed"
        assert entry["recovery"]["windows"][0]["failure_code"] == "InputChanged"
    assert len(seen) == (2 if producer == "recovery" else 0)
    assert all(not path.exists() for path in changed)


@pytest.mark.parametrize("cancellation", [KeyboardInterrupt, __import__("asyncio").CancelledError])
def test_format_admission_preserves_cancellation_and_closes_original_descriptor(tmp_path, monkeypatch, cancellation):
    from diarise_transcribe.audio import slice_wav_to_temp
    wav(tmp_path / "input.wav")
    produced = slice_wav_to_temp(str(tmp_path / "input.wav"), 0, 1, return_evidence=True)
    opened = []
    real_open = evidence.os.open
    def capture_open(path, *args, **kwargs):
        fd = real_open(path, *args, **kwargs)
        if os.fspath(path) == os.fspath(produced): opened.append(fd)
        return fd
    def cancel_format(*_args, **_kwargs):
        raise cancellation()
    monkeypatch.setattr(evidence.os, "open", capture_open)
    monkeypatch.setattr(evidence.wave, "open", cancel_format)
    try:
        with pytest.raises(cancellation):
            evidence.ModelInput(Path(produced), expected=produced)
        assert len(opened) == 1
        with pytest.raises(OSError):
            os.fstat(opened[0])
    finally:
        Path(produced).unlink(missing_ok=True)
