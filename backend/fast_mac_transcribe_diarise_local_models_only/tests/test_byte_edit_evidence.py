import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

script = Path(__file__).resolve().parents[3] / "scripts/generate-byte-edit-evidence.py"
spec = importlib.util.spec_from_file_location("byte_edit_evidence", script)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def replay(raw, value):
    result, cursor = b"", 0
    for edit in value["edits"]:
        start, end = edit["start_byte"], edit["end_byte"]
        raw[:start].decode("utf-8")
        raw[:end].decode("utf-8")
        result += raw[cursor:start] + base64.b64decode(edit["replacement_base64"], validate=True)
        cursor = end
    return result + raw[cursor:]


@pytest.mark.parametrize("raw,official", [
    ("", ""), ("", "é"), ("é", ""), ("same", "same"),
    ("A 😀 café 秘密 Z", "A 😁 cafe\u0301 [redacted] Z"),
    ("Before consent.\r\nA: secret.\r\n", "[Record begins at consent]\r\nA: [redacted].\r\n"),
    ("abc", "!abc!"), ("abc", "ab"), ("a" * 100_000, "b" * 100_000),
])
def test_complete_observed_edits_are_exact_without_semantic_claim(raw, official):
    left, right = raw.encode(), official.encode()
    result = evidence.generate(left, right)
    assert result["evidence_kind"] == "observed_byte_transformation"
    assert result["raw"] == evidence.fingerprint(left)
    assert result["official"] == evidence.fingerprint(right)
    assert replay(left, result) == right
    assert len(result["edits"]) == (0 if left == right else 1)


def test_generator_rejects_invalid_utf8_and_limits():
    with pytest.raises(UnicodeError):
        evidence.generate(b"\xff", b"")
    with pytest.raises(UnicodeError):
        evidence.generate(b"", b"\xff")
    with pytest.raises(ValueError, match="size limit"):
        evidence.generate(b"x" * (evidence.MAX_NOTE_BYTES + 1), b"")


def test_cli_does_not_write_inputs_and_emits_no_partial_evidence_on_failure(tmp_path):
    raw, official = tmp_path / "raw.md", tmp_path / "official.md"
    raw.write_bytes("😀 confidential".encode())
    official.write_bytes("😀 [redacted]".encode())
    command = [sys.executable, "-B", str(script), "--raw", str(raw), "--official", str(official)]
    result = subprocess.run(command, capture_output=True, timeout=5)
    assert result.returncode == 0, result.stderr
    assert replay(raw.read_bytes(), json.loads(result.stdout)) == official.read_bytes()
    assert raw.read_bytes() == "😀 confidential".encode()
    assert official.read_bytes() == "😀 [redacted]".encode()
    official.write_bytes(b"\xff")
    failed = subprocess.run(command, capture_output=True, timeout=5)
    assert failed.returncode != 0 and failed.stdout == b""


def test_reader_refuses_symlinks_fifo_and_oversized_source_without_waiting(tmp_path):
    raw = tmp_path / "raw.md"
    raw.write_bytes(b"text")
    alias = tmp_path / "alias"
    alias.symlink_to(raw)
    with pytest.raises(OSError):
        evidence.read_note(alias)
    fifo = tmp_path / "fifo"
    os.mkfifo(fifo)
    with pytest.raises(ValueError, match="regular file"):
        evidence.read_note(fifo)
    with raw.open("wb") as handle:
        handle.truncate(evidence.MAX_NOTE_BYTES + 1)
    with pytest.raises(ValueError, match="bounded"):
        evidence.read_note(raw)


def test_reader_rejects_same_size_mutation_during_read(tmp_path, monkeypatch):
    raw = tmp_path / "raw.md"
    raw.write_bytes(b"original")
    real_read = os.read
    changed = False
    def mutate(fd, size):
        nonlocal changed
        chunk = real_read(fd, size)
        if not changed:
            changed = True
            raw.write_bytes(b"modified")
        return chunk
    monkeypatch.setattr(evidence.os, "read", mutate)
    with pytest.raises(ValueError, match="changed"):
        evidence.read_note(raw)
