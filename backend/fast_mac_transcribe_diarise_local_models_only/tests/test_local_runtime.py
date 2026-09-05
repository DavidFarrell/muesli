import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from diarise_transcribe.local_assets import MissingLocalAssets, local_asr_directory, preflight


def test_missing_assets_fail_without_requesting_a_download(monkeypatch):
    import huggingface_hub
    calls = []
    def missing(model, file, **kwargs):
        calls.append(kwargs)
        raise FileNotFoundError(file)
    monkeypatch.setattr(huggingface_hub, "hf_hub_download", missing)
    with pytest.raises(MissingLocalAssets, match="no download was attempted"):
        local_asr_directory("test/missing-model")
    assert calls == [{"local_files_only": True}]


def test_local_preflight_records_exact_file_provenance(tmp_path):
    (tmp_path / "config.json").write_text('{"model_type":"test"}')
    (tmp_path / "model.safetensors").write_bytes(b"fixture")
    result = preflight(str(tmp_path), hashes=True)
    assert result["ready"]
    assert len(result["files"]) == 2
    assert all(len(file["sha256"]) == 64 for file in result["files"])
    assert result["asr_directory"] == str(tmp_path)


def test_invalid_local_config_is_not_ready(tmp_path):
    (tmp_path / "config.json").write_text("not JSON")
    (tmp_path / "model.safetensors").write_bytes(b"fixture")
    with pytest.raises(MissingLocalAssets, match="invalid"):
        preflight(str(tmp_path))


def test_runtime_blocks_python_network_before_hub_import_but_allows_local_ipc():
    code = '''
import json, os, socket
import diarise_transcribe
from diarise_transcribe.local_runtime import OfflineNetworkError
blocked = []
for operation in [lambda: socket.getaddrinfo("example.invalid", 443),
                  lambda: socket.socket().connect(("127.0.0.1", 9)),
                  lambda: socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"x", ("127.0.0.1", 9))]:
    try: operation()
    except OfflineNetworkError: blocked.append(True)
one, two = socket.socketpair()
one.send(b"local")
assert two.recv(5) == b"local"
one.close(); two.close()
from huggingface_hub import constants
print(json.dumps({"blocked": len(blocked), "hub_offline": constants.HF_HUB_OFFLINE}))
'''
    env = dict(os.environ, MUESLI_ALLOW_MODEL_DOWNLOADS="0", HF_HUB_OFFLINE="0")
    result = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"blocked": 3, "hub_offline": True}


def test_preflight_command_needs_no_model_runtime_import(tmp_path):
    code = '''
import sys
from diarise_transcribe.local_assets import local_asr_directory
assert "mlx.core" not in sys.modules
assert "coremltools" not in sys.modules
'''
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr


def test_exact_revision_preparation_is_used_by_default_app_model(tmp_path, monkeypatch):
    import runpy
    import huggingface_hub
    from diarise_transcribe import local_assets

    project = tmp_path / "backend"
    script = project / "scripts/prepare-local-models.py"
    script.parent.mkdir(parents=True)
    script.write_text((Path(__file__).parents[1] / "scripts/prepare-local-models.py").read_text())
    revision = "a" * 40
    snapshot = tmp_path / "cache/snapshots" / revision
    snapshot.mkdir(parents=True)
    (snapshot / "config.json").write_text('{}')
    (snapshot / "model.safetensors").write_bytes(b"test weights")
    calls = []
    def download(model, name, **kwargs):
        calls.append(kwargs)
        assert kwargs == {"revision": revision}
        return str(snapshot / name)
    monkeypatch.setattr(huggingface_hub, "hf_hub_download", download)
    monkeypatch.setattr(sys, "argv", [str(script), "--allow-download", "--revision", revision])
    monkeypatch.setattr(sys, "path", sys.path.copy())
    monkeypatch.setenv("MUESLI_ALLOW_MODEL_DOWNLOADS", "0")
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    monkeypatch.setenv("HF_HUB_DISABLE_TELEMETRY", "1")
    runpy.run_path(str(script), run_name="__main__")
    monkeypatch.setattr(local_assets, "ASSET_SELECTION", project / "local-models.json")
    monkeypatch.setattr(huggingface_hub, "hf_hub_download", lambda *a, **kw: pytest.fail("refs/main lookup"))
    assert local_assets.local_asr_directory() == snapshot
    assert local_assets.preflight()["asr_directory"] == str(snapshot)
    assert len(calls) == 2
    selection = json.loads(local_assets.ASSET_SELECTION.read_text())
    assert selection["asr"]["revision"] == revision
    assert len(selection["asr"]["files"][0]["sha256"]) == 64


@pytest.mark.parametrize("asset", [
    "libfbank_extractor.dylib", "libvad_coreml.dylib",
    "models/pyannote_segmentation.mlmodelc/weights/weight.bin",
    "models/camplusplus_batch16.mlpackage/Data/com.apple.CoreML/model.mlmodel",
    "cluster/conf/spectral.yaml", "cluster/conf/umap_hdbscan.yaml"])
def test_incomplete_senko_is_not_ready(tmp_path, monkeypatch, asset):
    from types import SimpleNamespace
    from diarise_transcribe import local_assets

    contents = {
        "libfbank_extractor.dylib": b"\xcf\xfa\xed\xfe" + b"native",
        "libvad_coreml.dylib": b"\xcf\xfa\xed\xfe" + b"native",
        "models/pyannote_segmentation.mlmodelc/Manifest.json": b"{}",
        "models/pyannote_segmentation.mlmodelc/coremldata.bin": b"data",
        "models/pyannote_segmentation.mlmodelc/model.mil": b"model",
        "models/pyannote_segmentation.mlmodelc/weights/weight.bin": b"weights",
        "models/camplusplus_batch16.mlpackage/Manifest.json": b"{}",
        "models/camplusplus_batch16.mlpackage/Data/com.apple.CoreML/model.mlmodel": b"model",
        "models/camplusplus_batch16.mlpackage/Data/com.apple.CoreML/weights/weight.bin": b"weights",
        "cluster/conf/spectral.yaml": b"cluster:\n  args: {}",
        "cluster/conf/umap_hdbscan.yaml": b"cluster:\n  args: {}",
    }
    for name, data in contents.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    monkeypatch.setattr(local_assets.importlib.util, "find_spec", lambda name: SimpleNamespace(origin=str(tmp_path / "__init__.py")))
    assert local_assets.senko_asset_paths()
    (tmp_path / asset).write_bytes(b"")
    with pytest.raises(MissingLocalAssets, match="missing or empty"):
        local_assets.senko_asset_paths()


def test_stale_pinned_selection_does_not_silently_use_another_cached_model(tmp_path, monkeypatch):
    from diarise_transcribe import local_assets
    selection = tmp_path / "local-models.json"
    selection.write_text(json.dumps({"schema_version": 1, "asr": {
        "model_id": local_assets.DEFAULT_ASR_MODEL, "revision": "b" * 40,
        "directory": str(tmp_path / "missing")}}))
    monkeypatch.setattr(local_assets, "ASSET_SELECTION", selection)
    with pytest.raises(MissingLocalAssets, match="selection is invalid"):
        local_assets.local_asr_directory()
