#!/usr/bin/env python3
"""Materialize an isolated, pinned Python payload; never copy a developer venv."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

PYTHON_SHA256 = 'c33a34853ae48d54fbac15cbb84ad67ccd8a639ce2cef866ecf474ebd02f1286'
PYTHON_URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20260325/cpython-3.12.13%2B20260325-aarch64-apple-darwin-install_only_stripped.tar.gz'


def stage(archive, project, output):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PYTHON_SHA256:
        raise RuntimeError('Standalone Python archive does not match the pinned build.')
    output.mkdir(parents=True, exist_ok=False)
    payload = output / 'payload'
    payload.mkdir()
    with tarfile.open(archive) as source:
        source.extractall(payload, filter='data')
    backend = project / 'backend/fast_mac_transcribe_diarise_local_models_only'
    config = backend / 'uv.toml'
    uv = shutil.which('uv')
    if not uv or subprocess.check_output([uv, '--version'], text=True).split()[1] != '0.11.3':
        raise RuntimeError('Runtime staging requires uv 0.11.3.')
    python = payload / 'python/bin/python3.12'
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(output / 'build-home'),
           'TMPDIR': os.environ.get('TMPDIR', '/tmp'), 'LC_ALL': 'C',
           'UV_CACHE_DIR': str(output / 'cache'), 'PYTHONDONTWRITEBYTECODE': '1'}
    Path(env['HOME']).mkdir()
    if 'DEVELOPER_DIR' in os.environ:
        env['DEVELOPER_DIR'] = os.environ['DEVELOPER_DIR']
    lock_before = hashlib.sha256((backend / 'uv.lock').read_bytes()).hexdigest()
    requirements = output / 'runtime-requirements.txt'
    # Explicit build tooling is independent from the application dependency set.
    constraints = output / 'build-constraints.txt'
    constraints.write_text('setuptools==80.9.0\nwheel==0.45.1\nhatchling==1.27.0\n')
    commands = [
        [uv, '--config-file', str(config), 'export', '--project', str(backend), '--locked',
         '--no-dev', '--no-emit-project', '--output-file', str(requirements)],
        [uv, '--config-file', str(config), 'pip', 'install', '--python', str(python),
         '--break-system-packages', '--no-deps', '--build-constraints', str(constraints), '-r', str(requirements)],
        [uv, '--config-file', str(config), 'build', '--project', str(backend), '--wheel',
         '--build-constraints', str(constraints), '--out-dir', str(output / 'wheels')],
    ]
    with (output / 'stage.log').open('w') as log:
        for command in commands:
            subprocess.run(command, cwd=output, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        wheels = list((output / 'wheels').glob('*.whl'))
        if len(wheels) != 1:
            raise RuntimeError('Expected exactly one backend wheel.')
        subprocess.run([uv, '--config-file', str(config), 'pip', 'install', '--python', str(python),
                        '--break-system-packages', '--no-deps', str(wheels[0])],
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    if hashlib.sha256((backend / 'uv.lock').read_bytes()).hexdigest() != lock_before:
        raise RuntimeError('Staging changed the application lockfile.')
    # Python is launched through the fixed native helper. Remove generated
    # absolute-path console entry points; none is an admitted runtime command.
    for script in (payload / 'python/bin').iterdir():
        if script.name not in {'python', 'python3', 'python3.12'}:
            script.unlink()
    for cache in sorted(payload.rglob('__pycache__'), reverse=True):
        shutil.rmtree(cache)
    source_commit = subprocess.check_output(['git', '-C', str(project), 'rev-parse', 'HEAD'], text=True).strip()
    source_dirty = bool(subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'], text=True).strip())
    manifest = {'schema_version': 1, 'source_commit': source_commit, 'source_dirty': source_dirty, 'python_version': '3.12.13', 'standalone_build': '20260325',
                'python_source_url': PYTHON_URL, 'python_source_sha256': PYTHON_SHA256,
                'lock_sha256': lock_before, 'uv_configuration_sha256': hashlib.sha256(config.read_bytes()).hexdigest(),
                'build_constraints': constraints.read_text(),
                'backend_wheel_sha256': hashlib.sha256(wheels[0].read_bytes()).hexdigest(),
                'qualification': 'staged unsigned runtime; relocation, licenses, sandbox and signing gates remain'}
    (output / 'staging-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(payload)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python-archive', type=Path, required=True)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    stage(args.python_archive.resolve(), args.project.resolve(), args.output.resolve())
