#!/usr/bin/env python3
"""Record build/runtime provenance without importing models or reading recordings."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--project', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
project = args.project.resolve()
lock = project / 'backend/fast_mac_transcribe_diarise_local_models_only/uv.lock'

def command(*values):
    return subprocess.check_output(values, cwd=project, text=True).strip()

packages = []
for distribution in sorted(importlib.metadata.distributions(), key=lambda item: item.metadata['Name'].lower()):
    entry = {'name': distribution.metadata['Name'], 'version': distribution.version}
    direct = distribution.read_text('direct_url.json')
    if direct:
        provenance = json.loads(direct)
        vcs = provenance.get('vcs_info')
        if vcs:
            entry['vcs_commit'] = vcs.get('commit_id')
            entry['vcs'] = vcs.get('vcs')
    license_expression = distribution.metadata.get('License-Expression')
    if license_expression:
        entry['declared_license_expression'] = license_expression
    packages.append(entry)
manifest = {
    'schema_version': 1, 'source_commit': command('git', 'rev-parse', 'HEAD'),
    'source_dirty': bool(command('git', 'status', '--porcelain')),
    'python': sys.version, 'architecture': platform.machine(), 'macos': platform.mac_ver()[0],
    'uv': command('uv', '--version'), 'xcode': command('xcodebuild', '-version'),
    'sdk': command('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
    'lock_sha256': hashlib.sha256(lock.read_bytes()).hexdigest(), 'packages': packages,
    'qualification': 'model-free tests and ad-hoc Release compilation only',
}
args.out.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
