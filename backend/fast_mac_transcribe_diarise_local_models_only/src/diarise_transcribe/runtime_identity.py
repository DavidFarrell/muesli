"""Allowlisted process provenance, separate from expected build/runtime locks.

This observes installed metadata and selected model bytes before inference. It
does not attest loaded weights, native code signing or lock equivalence. Paths,
model configuration contents, user input and exception text never leave here.
"""
from __future__ import annotations

import hashlib
from importlib import metadata
import json
from pathlib import Path
import re
import shutil
import sys
import sysconfig

PACKAGES = ("parakeet-mlx", "mlx", "mlx-metal", "senko", "coremltools", "numpy",
            "soundfile", "librosa", "numba", "llvmlite", "huggingface-hub")


def file_hash(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def observe_runtime(selected: dict | None) -> dict:
    packages = {}
    commits = {}
    for name in PACKAGES:
        try:
            version = metadata.version(name)
            if re.fullmatch(r"[0-9][A-Za-z0-9.+_-]{0,63}", version):
                packages[name] = version
        except metadata.PackageNotFoundError:
            pass
        try:
            direct = metadata.distribution(name).read_text("direct_url.json")
            commit = json.loads(direct or "{}").get("vcs_info", {}).get("commit_id")
            if isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
                commits[name] = commit
        except (metadata.PackageNotFoundError, OSError, ValueError, AttributeError):
            pass
    executable = backend = None
    try:
        executable = file_hash(Path(sys.executable))
        files = [(path.name, file_hash(path)) for path in sorted(Path(__file__).parent.glob("*.py"))]
        backend = hashlib.sha256(json.dumps(files, separators=(",", ":")).encode()).hexdigest()
    except OSError:
        pass
    tools = {}
    library = sysconfig.get_config_var("LDLIBRARY")
    prefix = sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX") or sysconfig.get_config_var("LIBDIR")
    candidates = {"ffmpeg": shutil.which("ffmpeg"),
                  "python_shared_library": str(Path(prefix) / library) if prefix and library else None}
    for name, candidate in candidates.items():
        try:
            if candidate:
                tools[name] = file_hash(Path(candidate))
        except OSError:
            pass
    assets = {}
    try:
        if selected is not None:
            directory = Path(selected["asr_directory"])
            assets["asr_config"] = file_hash(directory / "config.json")
            assets["asr_weights"] = file_hash(directory / "model.safetensors")
            # The preflight's validated Senko closure includes CoreML weights,
            # clustering configuration and native shims. No private path is an
            # output or part of the digest, so relocation preserves identity.
            extra = [entry for entry in selected["files"]
                     if entry.get("logical_name", "").startswith("senko/")]
            if extra:
                # Bind bytes to their role: swapping two valid clustering
                # configs changes behavior even when the byte multiset is equal.
                hashes = sorted((entry["logical_name"], file_hash(Path(entry["path"]))) for entry in extra)
                assets["senko_assets"] = hashlib.sha256(json.dumps(hashes, separators=(",", ":")).encode()).hexdigest()
    except (OSError, KeyError, TypeError):
        assets = {}
    return {"schema_version": 1, "observation": "process_preflight",
            "python_version": ".".join(str(part) for part in sys.version_info[:3]),
            "executable_sha256": executable, "backend_sha256": backend,
            "package_versions": packages, "model_assets_sha256": assets,
            "package_source_commits": commits, "selected_tools_sha256": tools,
            "model_observation": "selected_files_hashed" if assets else "unavailable"}


def prepare_observation(model_id: str, *, diarisation: bool) -> tuple[dict, str]:
    from .local_assets import MissingLocalAssets, preflight
    try:
        selected = preflight(model_id, diarisation=diarisation)
    except MissingLocalAssets:
        # An empty-source reprocess may legitimately never load any model.
        # Actual inference still enforces its own fail-closed local preflight.
        return observe_runtime(None), model_id
    return observe_runtime(selected), selected["asr_directory"]
