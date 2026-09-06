#!/usr/bin/env python3
"""Validate actual copied assets and record sealed bytes without private paths.

Run with the copied Python after signing its native libraries. No model import,
network access, expected == installed assumption, or model binaries in Git.
"""
import hashlib
import json
import os
from pathlib import Path
import sys

resources = Path(sys.argv[1]).resolve(strict=True)
runtime = resources / 'python'
model = resources / 'models/parakeet-tdt-0.6b-v3'
sys.path.insert(0, str(runtime / 'lib/python3.12/site-packages'))
from diarise_transcribe.local_assets import preflight


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def entry(path):
    relative = path.relative_to(resources).as_posix()
    if path.is_symlink():
        target = os.readlink(path)
        if Path(target).is_absolute() or not path.resolve(strict=True).is_relative_to(runtime):
            raise ValueError('Runtime link escapes the sealed tree')
        return {'path': relative, 'kind': 'link', 'target': target}
    if path.is_dir():
        return {'path': relative, 'kind': 'directory'}
    if not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError('Only ordinary single-link payload files are supported')
    size = path.stat().st_size
    if size > 4 * 1024**3:
        raise ValueError('Payload file is oversized')
    return {'path': relative, 'kind': 'file', 'bytes': size, 'sha256': digest(path)}

selected = preflight(str(model), diarisation=True, hashes=True)
assets = []
for value in selected['files']:
    path = Path(value['path'])
    if not path.resolve(strict=True).is_relative_to(resources) or path.is_symlink():
        raise ValueError('Model asset is outside the sealed resources')
    actual = entry(path)
    if actual['bytes'] != value['bytes'] or actual['sha256'] != value['sha256']:
        raise ValueError('Model changed during validation')
    assets.append(dict(actual, role=value['logical_name']))
paths = [runtime, *runtime.rglob('*')]
if len(paths) > 25000:
    raise ValueError('Runtime inventory is oversized')
entries = [entry(path) for path in sorted(paths)]
if sum(item.get('bytes', 0) for item in entries + assets) > 8 * 1024**3:
    raise ValueError('Payload byte budget exceeded')
for name, value in [
    ('runtime-manifest.json', {'schema_version': 1, 'kind': 'actual_runtime_files', 'entries': entries}),
    ('model-manifest.json', {'schema_version': 1, 'kind': 'validated_local_model_assets',
        'asr_directory': 'models/parakeet-tdt-0.6b-v3', 'entries': sorted(assets, key=lambda x: x['role'])}),
]:
    data = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if len(data) > 8 * 1024**2:
        raise ValueError('Manifest is oversized')
    with (resources / name).open('xb') as handle:
        handle.write(data)
    print(name, hashlib.sha256(data).hexdigest())
