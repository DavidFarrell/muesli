import importlib.util
import json
from pathlib import Path
import subprocess

import pytest

script = Path(__file__).resolve().parents[3] / "scripts/write-build-identity.py"
spec = importlib.util.spec_from_file_location("build_identity", script)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def fixture(root):
    for path in build.INPUTS.values():
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text('{}' if file.suffix == '.json' else 'input')
    (root / build.INPUTS['schemas']).write_text('{"meeting_metadata":1}')


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), '-c', 'user.name=Fixture',
                                   '-c', 'user.email=fixture@example.invalid', *args], stderr=subprocess.DEVNULL)


def test_export_has_explicit_unknown_and_distribution_fails_closed(tmp_path):
    fixture(tmp_path)
    value = build.identity(tmp_path, {})
    assert value['source_commit'] is None and value['source_dirty'] is None
    assert len(value['source_tree_sha256']) == 64
    source = tmp_path / 'MuesliApp/MuesliApp/Exported.swift'
    source.write_text('let version = 1')
    changed = build.identity(tmp_path, {})
    assert changed['source_commit'] is None
    assert changed['build_id'] != value['build_id']
    assert value['expected_input_sha256']['runtime_lock'] is not None
    with pytest.raises(ValueError, match='clean, identified'):
        build.identity(tmp_path, {'ACTION': 'install'})


def test_clean_build_and_dirty_bytes_have_distinct_stable_identity(tmp_path):
    fixture(tmp_path)
    git(tmp_path, 'init')
    git(tmp_path, 'add', '.')
    git(tmp_path, 'commit', '-m', 'Fixture')
    first = build.identity(tmp_path, {'ACTION': 'install', 'CONFIGURATION': 'Release'})
    assert first['source_dirty'] is False and len(first['source_commit']) == 40
    assert first == build.identity(tmp_path, {'ACTION': 'install', 'CONFIGURATION': 'Release'})
    lock = tmp_path / build.INPUTS['runtime_lock']
    lock.write_text('changed lock')
    second = build.identity(tmp_path, {'CONFIGURATION': 'Release'})
    assert second['source_commit'] == first['source_commit']
    assert second['source_dirty'] is True
    assert second['build_id'] != first['build_id']
    assert second['source_tree_sha256'] != first['source_tree_sha256']
    with pytest.raises(ValueError):
        build.identity(tmp_path, {'MUESLI_REQUIRE_IDENTIFIED_BUILD': 'YES'})
    # Missing expected inputs cannot qualify even when their deletion is committed.
    lock.unlink()
    git(tmp_path, 'add', '.')
    git(tmp_path, 'commit', '-m', 'Missing input')
    with pytest.raises(ValueError):
        build.identity(tmp_path, {'ACTION': 'install'})


def test_generator_quotes_build_settings_without_executing_or_serializing_environment(tmp_path):
    import os
    fixture(tmp_path / 'source with spaces')
    env = dict(os.environ, PRODUCT_BUNDLE_IDENTIFIER='test."quoted"', PRIVATE_MEETING='secret words')
    subprocess.check_call(['/usr/bin/python3', str(script), '--root', str(tmp_path / 'source with spaces'),
                           '--output', str(tmp_path / 'derived files')], env=env)
    report = (tmp_path / 'derived files/build-identity.json').read_text()
    assert 'secret words' not in report and str(tmp_path) not in report
    assert json.loads(report)['build_settings']['PRODUCT_BUNDLE_IDENTIFIER'] == 'test."quoted"'
    import base64
    encoded = (tmp_path / 'derived files/EmbeddedBuildIdentity.swift').read_text().split('"')[1]
    assert json.loads(base64.b64decode(encoded)) == json.loads(report)


def test_ignored_compiler_input_cannot_qualify_as_clean_archive(tmp_path):
    fixture(tmp_path)
    (tmp_path / '.gitignore').write_text('Injected.swift\n')
    git(tmp_path, 'init'); git(tmp_path, 'add', '.'); git(tmp_path, 'commit', '-m', 'Fixture')
    code = tmp_path / 'MuesliApp/MuesliApp/Injected.swift'
    code.write_text('let injected = true')
    assert not git(tmp_path, 'status', '--porcelain').strip()
    value = build.identity(tmp_path, {})
    assert value['source_dirty'] is True
    with pytest.raises(ValueError):
        build.identity(tmp_path, {'ACTION': 'install'})


def test_effective_compiler_flags_change_identity_without_disclosing_paths(tmp_path):
    fixture(tmp_path)
    first = build.identity(tmp_path, {'OTHER_SWIFT_FLAGS': '-D NORMAL'})
    second = build.identity(tmp_path, {'OTHER_SWIFT_FLAGS': '-I /Users/private/include'})
    assert first['build_id'] != second['build_id']
    assert '/Users/' not in json.dumps(second)


def test_cache_named_swift_directory_cannot_hide_ignored_compiler_input(tmp_path):
    fixture(tmp_path)
    (tmp_path / '.gitignore').write_text('__pycache__/\n')
    git(tmp_path, 'init'); git(tmp_path, 'add', '.'); git(tmp_path, 'commit', '-m', 'Fixture')
    before = build.identity(tmp_path, {})
    code = tmp_path / 'MuesliApp/MuesliApp/__pycache__/Injected.swift'
    code.parent.mkdir(); code.write_text('let injected = true')
    assert not git(tmp_path, 'status', '--porcelain').strip()
    after = build.identity(tmp_path, {})
    assert after['source_dirty'] is True and after['build_id'] != before['build_id']
    with pytest.raises(ValueError):
        build.identity(tmp_path, {'ACTION': 'install'})


def test_generated_bytecode_in_python_roots_does_not_dirty_source(tmp_path):
    fixture(tmp_path)
    (tmp_path / '.gitignore').write_text('__pycache__/\n')
    git(tmp_path, 'init'); git(tmp_path, 'add', '.'); git(tmp_path, 'commit', '-m', 'Fixture')
    before = build.identity(tmp_path, {'ACTION': 'install'})
    for relative in ['scripts', build.BACKEND + '/src']:
        bytecode = tmp_path / relative / '__pycache__/module.cpython-312.pyc'
        bytecode.parent.mkdir(parents=True, exist_ok=True); bytecode.write_bytes(b'generated cache')
    after = build.identity(tmp_path, {'ACTION': 'install'})
    assert after['source_dirty'] is False and after['build_id'] == before['build_id']


def test_effective_coverage_setting_distinguishes_identified_release_builds(tmp_path):
    fixture(tmp_path)
    git(tmp_path, 'init'); git(tmp_path, 'add', '.'); git(tmp_path, 'commit', '-m', 'Fixture')
    common = {'ACTION': 'install', 'CONFIGURATION': 'Release'}
    enabled = build.identity(tmp_path, dict(common, ENABLE_CODE_COVERAGE='YES'))
    disabled = build.identity(tmp_path, dict(common, ENABLE_CODE_COVERAGE='NO'))
    absent = build.identity(tmp_path, common)
    assert enabled['source_commit'] == disabled['source_commit']
    assert enabled['source_tree_sha256'] == disabled['source_tree_sha256']
    assert enabled['source_dirty'] is disabled['source_dirty'] is False
    assert enabled['expected_input_sha256']['compiler_flags'] != disabled['expected_input_sha256']['compiler_flags']
    assert len({enabled['build_id'], disabled['build_id'], absent['build_id']}) == 3
    assert disabled == build.identity(tmp_path, dict(common, ENABLE_CODE_COVERAGE='NO'))
    assert 'ENABLE_CODE_COVERAGE' not in json.dumps(disabled)
