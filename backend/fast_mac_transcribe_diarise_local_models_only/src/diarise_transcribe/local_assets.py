"""Read-only local-model preflight without loading MLX or CoreML models."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

DEFAULT_ASR_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
ASR_FILES = ("config.json", "model.safetensors")
ASSET_SELECTION = Path(__file__).resolve().parents[2] / "local-models.json"


class MissingLocalAssets(RuntimeError):
    pass


def local_asr_directory(model_id: str = DEFAULT_ASR_MODEL) -> Path:
    if model_id == DEFAULT_ASR_MODEL and ASSET_SELECTION.exists():
        try:
            if ASSET_SELECTION.stat().st_size > 65536:
                raise ValueError("selection is too large")
            selection = json.loads(ASSET_SELECTION.read_text(encoding="utf-8"))
            asr = selection["asr"]
            revision = asr["revision"]
            if (selection["schema_version"] != 1 or asr["model_id"] != model_id
                    or not isinstance(revision, str) or len(revision) != 40
                    or any(c not in "0123456789abcdef" for c in revision)):
                raise ValueError("invalid model identity")
            selected = Path(asr["directory"])
            if not selected.is_absolute() or not selected.is_dir():
                raise ValueError("selected model directory is missing")
            model_id = str(selected)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise MissingLocalAssets("The pinned local model selection is invalid; prepare assets again.") from exc
    candidate = Path(model_id).expanduser()
    if candidate.is_dir():
        paths = [candidate / name for name in ASR_FILES]
    else:
        try:
            from huggingface_hub import hf_hub_download
            paths = [Path(hf_hub_download(model_id, name, local_files_only=True)) for name in ASR_FILES]
        except Exception as exc:
            raise MissingLocalAssets(
                f"Local ASR assets for {model_id!r} are missing. Prepare the model before recording; no download was attempted."
            ) from exc
        if paths[0].parent != paths[1].parent:
            raise MissingLocalAssets("ASR configuration and weights belong to different cached revisions.")
        candidate = paths[0].parent
    for path in paths:
        if not path.is_file() or path.stat().st_size == 0:
            raise MissingLocalAssets(f"Missing or empty local model asset: {path.name}")
    try:
        config = json.loads(paths[0].read_text(encoding="utf-8"))
        if not isinstance(config, dict):
            raise ValueError("configuration is not an object")
    except (OSError, ValueError) as exc:
        raise MissingLocalAssets("The local ASR configuration is unreadable or invalid.") from exc
    return candidate


def senko_asset_paths() -> list[Path]:
    spec = importlib.util.find_spec("senko")
    if spec is None or spec.origin is None:
        raise MissingLocalAssets("Senko is not installed in the selected local runtime.")
    package = Path(spec.origin).parent
    standard = (package / "libfbank_extractor.dylib").is_file()
    libraries = package if standard else package.parent / "build"
    models = package / "models" if standard else package.parent / "models"
    paths = [libraries / "libfbank_extractor.dylib", libraries / "libvad_coreml.dylib",
             models / "pyannote_segmentation.mlmodelc", models / "camplusplus_batch16.mlpackage",
             package / "cluster/conf/spectral.yaml", package / "cluster/conf/umap_hdbscan.yaml"]
    required = paths[:2] + paths[4:] + [
        paths[2] / "Manifest.json", paths[2] / "coremldata.bin",
        paths[2] / "model.mil", paths[2] / "weights/weight.bin",
        paths[3] / "Manifest.json", paths[3] / "Data/com.apple.CoreML/model.mlmodel",
        paths[3] / "Data/com.apple.CoreML/weights/weight.bin"]
    for path in required:
        if not path.is_file() or path.stat().st_size == 0:
            raise MissingLocalAssets(f"Local diarisation asset is missing or empty: {path}")
    import yaml
    try:
        for library in paths[:2]:
            with library.open("rb") as handle:
                if handle.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
                    raise ValueError(f"invalid native library: {library.name}")
        for manifest in (paths[2] / "Manifest.json", paths[3] / "Manifest.json"):
            if not isinstance(json.loads(manifest.read_text(encoding="utf-8")), dict):
                raise ValueError(f"invalid CoreML manifest: {manifest}")
        for config_path in paths[4:]:
            config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
            if not isinstance(config, dict) or not isinstance(config.get("cluster", {}).get("args"), dict):
                raise ValueError(f"invalid clustering configuration: {config_path.name}")
    except (OSError, ValueError, AttributeError, yaml.YAMLError) as exc:
        raise MissingLocalAssets(f"Invalid local diarisation assets: {exc}") from exc
    for path in paths:
        if not path.exists() or (path.is_dir() and not any(p.is_file() for p in path.rglob("*"))):
            raise MissingLocalAssets(f"Local diarisation asset is missing: {path.name}")
    return paths


def preflight(model_id: str = DEFAULT_ASR_MODEL, *, diarisation: bool = False, hashes: bool = False) -> dict:
    directory = local_asr_directory(model_id)
    paths = [directory / name for name in ASR_FILES]
    if diarisation:
        paths += senko_asset_paths()
    files = []
    for index, path in enumerate(paths):
        for file in sorted(path.rglob("*")) if path.is_dir() else [path]:
            if not file.is_file():
                continue
            logical_name = ("asr/" + file.name if index < len(ASR_FILES) else
                            "senko/" + path.name + ("/" + file.relative_to(path).as_posix() if path.is_dir() else ""))
            entry = {"path": str(file), "logical_name": logical_name, "bytes": file.stat().st_size}
            if hashes:
                digest = hashlib.sha256()
                with file.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(block)
                entry["sha256"] = digest.hexdigest()
            files.append(entry)
    return {"schema_version": 1, "ready": True, "asr_model": model_id,
            "asr_directory": str(directory), "diarisation": diarisation, "files": files}


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify local inference assets without downloads or model loading")
    parser.add_argument("--asr-model", default=DEFAULT_ASR_MODEL)
    parser.add_argument("--diarisation", action="store_true")
    parser.add_argument("--hashes", action="store_true", help="Include SHA-256 provenance for release manifests")
    args = parser.parse_args()
    try:
        result = preflight(args.asr_model, diarisation=args.diarisation, hashes=args.hashes)
    except MissingLocalAssets as exc:
        print(json.dumps({"schema_version": 1, "ready": False, "error": str(exc)}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
