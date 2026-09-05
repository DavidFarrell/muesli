#!/usr/bin/env python3
"""Explicit online provisioning. Never called automatically by a recording."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--allow-download", action="store_true", required=True,
                    help="Explicitly permit downloading model assets from Hugging Face")
parser.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3",
                    choices=["mlx-community/parakeet-tdt-0.6b-v3"])
parser.add_argument("--revision", required=True, help="Exact 40-character upstream model commit")
args = parser.parse_args()
if len(args.revision) != 40 or any(c not in "0123456789abcdef" for c in args.revision):
    parser.error("--revision must be an exact lowercase 40-character model commit")

# This standalone process establishes its explicit provisioning policy before
# either the package or Hub library is imported. It never reads meeting data.
os.environ["MUESLI_ALLOW_MODEL_DOWNLOADS"] = "1"
os.environ["HF_HUB_OFFLINE"] = "0"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
from huggingface_hub import hf_hub_download

paths = [Path(hf_hub_download(args.model, name, revision=args.revision))
         for name in ("config.json", "model.safetensors")]
if paths[0].parent != paths[1].parent:
    raise RuntimeError("Downloaded assets did not resolve to one model revision")
project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project / "src"))
from diarise_transcribe.local_assets import preflight
assets = preflight(str(paths[0].parent), hashes=True)
selection = {"schema_version": 1, "asr": {"model_id": args.model,
             "revision": args.revision, "directory": str(paths[0].parent.resolve()),
             "files": assets["files"]}}
# The app and batch worker resolve the same selection without depending on a
# mutable Hub refs/main entry. Publish only after the whole snapshot validates.
with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=project,
                                 prefix=".local-models-", delete=False) as handle:
    temporary = Path(handle.name)
    try:
        json.dump(selection, handle, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
        os.replace(temporary, project / "local-models.json")
        directory_fd = os.open(project, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)
print(f"Prepared local model revision {args.revision} at {paths[0].parent}")
print(f"App and reprocessing selection saved to {project / 'local-models.json'}")
print("Run python -m diarise_transcribe.local_assets --diarisation --hashes to verify the local runtime.")
