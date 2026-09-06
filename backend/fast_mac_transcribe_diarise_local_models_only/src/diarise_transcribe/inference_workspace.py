"""A single service-owned derived directory, retained until actual process exit.

A Python entry-point return does not establish that all native/worker threads
have returned. Do not delete or reassign this directory on that earlier event.
Standalone callers continue using their existing explicit output directory.
"""
from pathlib import Path
import tempfile

_directory: Path | None = None


def activate() -> Path:
    global _directory
    if _directory is not None:
        raise RuntimeError("The service already owns its inference workspace")
    _directory = Path(tempfile.mkdtemp(prefix="muesli-service-"))
    return _directory


def derived_directory(default: Path) -> Path:
    return _directory if _directory is not None else default
