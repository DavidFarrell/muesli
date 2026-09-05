#!/usr/bin/env python3
"""Emit complete observed byte edits as JSON on stdout; never modify the notes.

This proves transformation fidelity only, not appropriate redaction, consent,
speaker identity, or permission to archive. The caller owns durable publication.
One changed span after the common Unicode prefix/suffix gives linear bounded
work. Unchanged text between separate changes can be inside that observed span;
it does not purport to identify the author's semantic redaction decisions.
"""
import argparse
import base64
import hashlib
import json
import os
import stat
import sys

MAX_NOTE_BYTES = 8 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024 * 1024


def read_note(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= MAX_NOTE_BYTES:
            raise ValueError("Note must be a bounded regular file")
        chunks, count = [], 0
        while True:
            chunk = os.read(fd, 64 * 1024)
            if not chunk:
                break
            count += len(chunk)
            if count > MAX_NOTE_BYTES:
                raise ValueError("Note grew beyond its size limit")
            chunks.append(chunk)
        after = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                or count != before.st_size
                or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)):
            raise ValueError("Note changed while being read")
        return b"".join(chunks)
    finally:
        os.close(fd)


def fingerprint(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def generate(raw, official):
    if len(raw) > MAX_NOTE_BYTES or len(official) > MAX_NOTE_BYTES:
        raise ValueError("Note exceeds its size limit")
    # Decode strictly: a byte-based common prefix could split a code point.
    left, right = raw.decode("utf-8"), official.decode("utf-8")
    prefix = 0
    while prefix < min(len(left), len(right)) and left[prefix] == right[prefix]:
        prefix += 1
    left_end, right_end = len(left), len(right)
    while left_end > prefix and right_end > prefix and left[left_end - 1] == right[right_end - 1]:
        left_end -= 1
        right_end -= 1
    edits = []
    if raw != official:
        start = len(left[:prefix].encode("utf-8"))
        end = start + len(left[prefix:left_end].encode("utf-8"))
        replacement = right[prefix:right_end].encode("utf-8")
        assert raw[:start] + replacement + raw[end:] == official
        edits.append({"start_byte": start, "end_byte": end,
                      "replacement_base64": base64.b64encode(replacement).decode("ascii")})
    return {"schema_version": 1, "evidence_kind": "observed_byte_transformation",
            "raw": fingerprint(raw), "official": fingerprint(official), "edits": edits}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--official", required=True)
    args = parser.parse_args()
    try:
        value = generate(read_note(args.raw), read_note(args.official))
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(encoded) > MAX_MANIFEST_BYTES:
            raise ValueError("Evidence exceeds its size limit")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Byte-edit evidence unavailable: {error}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
