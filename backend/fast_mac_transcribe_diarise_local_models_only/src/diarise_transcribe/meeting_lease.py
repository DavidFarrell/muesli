"""Retain an app-admitted meeting through the real Python process lifetime.

The parent supplies fixed file identities, not a command or import path. The
child opens existing files only. Pins deliberately have no close/atexit hook:
returning from main (or timing out a worker join) is not proof that all workers
have stopped. The kernel releases these non-inheritable descriptors at exit.
"""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import stat
import threading

ENVIRONMENT_KEY = "MUESLI_MEETING_LEASE"
LOCK_NAMES = (".meeting-access.lock", ".backend-owner.lock")
_PROCESS_PIN = None
_PIN_LOCK = threading.Lock()


class MeetingLeaseError(RuntimeError):
    pass


def _identity(value: object) -> tuple[int, int]:
    if not isinstance(value, dict) or set(value) != {"device", "inode"}:
        raise MeetingLeaseError("Invalid meeting lease identity")
    device, inode = value["device"], value["inode"]
    if any(type(item) is not int or not 0 <= item <= 2**64 - 1 for item in (device, inode)):
        raise MeetingLeaseError("Invalid meeting lease identity")
    return device, inode


def _matches(value: os.stat_result, expected: tuple[int, int]) -> bool:
    return (value.st_dev, value.st_ino) == expected


def _private_lock(value: os.stat_result) -> bool:
    return stat.S_ISREG(value.st_mode) and value.st_nlink == 1 and value.st_uid == os.geteuid()


class _ProcessPin:
    def __init__(self, encoded: str) -> None:
        if len(encoded.encode("utf-8")) > 4096:
            raise MeetingLeaseError("Meeting lease token exceeds its size limit")
        try:
            token = json.loads(encoded)
            if not isinstance(token, dict) or set(token) != {"version", "folder", "directory", "locks"}:
                raise MeetingLeaseError("Invalid meeting lease token")
            if type(token["version"]) is not int or token["version"] != 1:
                raise MeetingLeaseError("Unsupported meeting lease token")
            folder = token["folder"]
            if not isinstance(folder, str) or not os.path.isabs(folder) or "\0" in folder:
                raise MeetingLeaseError("Invalid meeting lease folder")
            if not isinstance(token["locks"], dict) or set(token["locks"]) != set(LOCK_NAMES):
                raise MeetingLeaseError("Invalid meeting lease lock set")
            self.directory_identity = _identity(token["directory"])
            self.lock_identities = {name: _identity(token["locks"][name]) for name in LOCK_NAMES}
        except (ValueError, KeyError, TypeError) as error:
            raise MeetingLeaseError("Invalid meeting lease token") from error
        self.encoded = encoded
        self.folder = Path(folder)
        opened: list[int] = []
        try:
            directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            opened.append(directory)
            state = os.fstat(directory)
            if not stat.S_ISDIR(state.st_mode) or not _matches(state, self.directory_identity):
                raise MeetingLeaseError("Meeting folder identity changed before child admission")
            self.directory = directory
            # The fixed order matches Swift: outer archive exclusion, then
            # the backend-specific lease. No transaction lock or lock upgrade.
            for name in LOCK_NAMES:
                fd = os.open(name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
                opened.append(fd)
                state = os.fstat(fd)
                if not _private_lock(state) or not _matches(state, self.lock_identities[name]):
                    raise MeetingLeaseError("Meeting lock identity changed before child admission")
                os.set_inheritable(fd, False)
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.descriptors = tuple(opened)
            self.validate()
        except BaseException as error:
            for fd in reversed(opened):
                os.close(fd)
            if isinstance(error, MeetingLeaseError):
                raise
            raise MeetingLeaseError("Meeting ownership unavailable; refusing child startup") from error

    def validate(self) -> None:
        try:
            current = os.stat(self.folder, follow_symlinks=False)
            if not stat.S_ISDIR(current.st_mode) or not _matches(current, self.directory_identity):
                raise MeetingLeaseError("Meeting folder moved or changed during child admission")
            for name in LOCK_NAMES:
                current = os.stat(name, dir_fd=self.directory, follow_symlinks=False)
                if not _private_lock(current) or not _matches(current, self.lock_identities[name]):
                    raise MeetingLeaseError("Meeting lock changed during child admission")
        except OSError as error:
            raise MeetingLeaseError("Meeting folder moved during child admission") from error


def pin_process_from_environment() -> None:
    """Run before model imports for every app-launched package entry mode.

    Standalone CLI use without an app admission token remains separate. An
    invalid supplied token never falls back to unpinned execution.
    """
    encoded = os.environ.get(ENVIRONMENT_KEY)
    if encoded is None:
        return
    global _PROCESS_PIN
    with _PIN_LOCK:
        if _PROCESS_PIN is None:
            _PROCESS_PIN = _ProcessPin(encoded)
        elif _PROCESS_PIN.encoded != encoded:
            raise MeetingLeaseError("This Python process already owns another meeting admission")
        else:
            _PROCESS_PIN.validate()


def validate_source_path(path: Path, *, meeting_root: bool = False) -> Path:
    """Bind fixed entry-point arguments to the pinned original meeting."""
    resolved = path.expanduser().resolve()
    pin = _PROCESS_PIN
    if pin is not None:
        pin.validate()
        root = pin.folder.resolve(strict=True)
        if resolved != root and (meeting_root or root not in resolved.parents):
            raise MeetingLeaseError("Source path is outside the admitted meeting")
    return resolved


def add_parser_argument(parser) -> None:
    import argparse
    parser.add_argument("--meeting-lease-required", action="store_true", help=argparse.SUPPRESS)


def require_app_admission(args) -> None:
    if getattr(args, "meeting_lease_required", False):
        if _PROCESS_PIN is None:
            raise MeetingLeaseError("App-launched transcription requires an independent meeting pin")
        _PROCESS_PIN.validate()
