import hashlib
import json
from pathlib import Path

from diarise_transcribe import runtime_identity


def test_observation_hashes_actual_selected_bytes_without_private_paths(tmp_path, monkeypatch):
    directory = tmp_path / 'Private client meeting'
    directory.mkdir()
    config = directory / 'config.json'; config.write_text('{"private model metadata":true}')
    weights = directory / 'model.safetensors'; weights.write_bytes(b'weights')
    monkeypatch.setattr(runtime_identity.metadata, 'version', lambda _: '9.8.7')
    selected = {'asr_directory': str(directory), 'files': [{'path': str(config)}, {'path': str(weights)}]}
    value = runtime_identity.observe_runtime(selected)
    assert value['model_assets_sha256']['asr_weights'] == hashlib.sha256(b'weights').hexdigest()
    assert value['package_versions']['mlx'] == '9.8.7'
    assert value['observation'] == 'process_preflight'
    serialized = json.dumps(value)
    assert str(tmp_path) not in serialized and 'Private client' not in serialized and 'private model metadata' not in serialized
    weights.write_bytes(b'actual new weights')
    assert value['model_assets_sha256'] != runtime_identity.observe_runtime(selected)['model_assets_sha256']


def test_missing_assets_remain_unknown_and_untrusted_package_versions_are_omitted(monkeypatch):
    monkeypatch.setattr(runtime_identity.metadata, 'version', lambda _: '/Users/person/Private report')
    value = runtime_identity.observe_runtime(None)
    assert value['model_observation'] == 'unavailable'
    assert value['model_assets_sha256'] == {} and value['package_versions'] == {}


def test_preparation_pins_observed_model_directory(tmp_path, monkeypatch):
    from diarise_transcribe import local_assets
    (tmp_path / 'config.json').write_text('{}')
    (tmp_path / 'model.safetensors').write_bytes(b'fixture')
    monkeypatch.setattr(local_assets, 'preflight', lambda *a, **kw: {
        'asr_directory': str(tmp_path), 'files': []})
    observed, selected = runtime_identity.prepare_observation('mutable/model-reference', diarisation=False)
    assert selected == str(tmp_path)
    assert observed['model_observation'] == 'selected_files_hashed'


def test_vcs_and_selected_native_tools_are_observed_without_direct_urls(tmp_path, monkeypatch):
    class Distribution:
        def read_text(self, name):
            assert name == 'direct_url.json'
            return json.dumps({'url': '/Users/Private checkout', 'vcs_info': {'commit_id': 'a' * 40}})
    monkeypatch.setattr(runtime_identity.metadata, 'distribution', lambda _: Distribution())
    monkeypatch.setattr(runtime_identity.metadata, 'version', lambda _: '1.2.3')
    executable = tmp_path / 'ffmpeg'; executable.write_bytes(b'actual selected executable')
    monkeypatch.setattr(runtime_identity.shutil, 'which', lambda _: str(executable))
    value = runtime_identity.observe_runtime(None)
    assert value['package_source_commits']['senko'] == 'a' * 40
    assert value['selected_tools_sha256']['ffmpeg'] == hashlib.sha256(executable.read_bytes()).hexdigest()
    assert 'Private checkout' not in json.dumps(value) and str(tmp_path) not in json.dumps(value)
