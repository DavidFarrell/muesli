#!/usr/bin/env python3
"""Inspect the actual signed proof payload; emits hashes, never audio/model contents."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--team', required=True)
parser.add_argument('--picker-host', action='store_true', help='Require the separate diagnostic picker host entitlement set.')
parser.add_argument('--application-host', action='store_true', help='Audit the packaged Muesli app and production source broker.')
args = parser.parse_args()
if args.picker_host and args.application_host:
    parser.error('A production app is not the diagnostic picker host.')
app = args.app.resolve(strict=True)
service = 'Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc'
runtime = service + '/Contents/Resources/python'
expected_service = {'com.apple.security.app-sandbox': True, 'com.apple.security.cs.allow-jit': True,
                    'com.apple.security.cs.allow-unsigned-executable-memory': True}
expected_child = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
expected_host = {'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-only': True} if args.picker_host else {}
if args.application_host:
    expected_host = {'com.apple.security.device.audio-input': True}
host_executable = 'Contents/MacOS/MuesliApp' if args.application_host else 'Contents/MacOS/InferenceProof'
broker_executable = 'Contents/XPCServices/paidiaconsulting.MuesliApp.SourceAccessService.xpc/Contents/MacOS/SourceAccessService'
expected_broker = {'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-only': True}
expected_ids = {service + '/Contents/MacOS/InferenceService': 'paidiaconsulting.MuesliApp.InferenceService',
                host_executable: 'paidiaconsulting.MuesliApp' if args.application_host else 'paidiaconsulting.MuesliApp.InferenceProof',
                runtime + '/tools/ffmpeg': 'ffmpeg', runtime + '/tools/sw_vers': 'sw_vers'}
if args.application_host:
    expected_ids[broker_executable] = 'paidiaconsulting.MuesliApp.SourceAccessService'
    expected_ids['Contents/Helpers/muesli-archive'] = 'muesli-archive'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
native = []
backend = {}
magic = {bytes.fromhex(x) for x in ['cffaedfe', 'feedfacf', 'cefaedfe', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
for path in sorted(app.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    relative = path.relative_to(app).as_posix()
    with path.open('rb') as handle:
        header = handle.read(4)
    if relative.startswith(runtime + '/lib/python3.12/site-packages/diarise_transcribe/') and path.suffix == '.py':
        backend[relative.removeprefix(runtime + '/lib/python3.12/site-packages/')] = hashlib.sha256(path.read_bytes()).hexdigest()
    if header not in magic:
        continue
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', '--verbose=4', str(path)], capture_output=True, check=True)
    detail = result.stderr.decode()
    assert 'invalid entitlements' not in detail, (relative, detail)
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    expected = (expected_service if relative == service + '/Contents/MacOS/InferenceService' else
                expected_broker if args.application_host and relative == broker_executable else
                expected_child if relative in {runtime + '/tools/ffmpeg', runtime + '/tools/sw_vers'} else
                expected_host if relative == host_executable else {})
    assert entitlements == expected, (relative, entitlements, expected)
    assert '(runtime)' in detail and f'TeamIdentifier={args.team}' in detail, (relative, detail)
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    identifier = re.search(r'^Identifier=(.*)$', detail, re.M).group(1)
    if relative in expected_ids:
        assert identifier == expected_ids[relative], (relative, identifier)
    requirements = subprocess.run(['codesign', '-d', '-r-', str(path)], capture_output=True, check=True)
    native.append({'path': relative, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                   'entitlements': entitlements, 'hardened_runtime': True,
                   'identifier': identifier,
                   'requirements': requirements.stdout.decode().strip()})
assert {service + '/Contents/MacOS/InferenceService', runtime + '/tools/ffmpeg', runtime + '/tools/sw_vers'} <= {x['path'] for x in native}
assert set(expected_ids) <= {x['path'] for x in native}
build_record = app / ('Contents/Resources/local-runtime-package.json' if args.application_host else 'Contents/Resources/proof-build-inputs.json')
build_inputs = json.loads(build_record.read_text()) if build_record.is_file() else None
print(json.dumps({'build_inputs': build_inputs, 'team': args.team, 'native_count': len(native), 'native': native, 'backend_sha256': backend}, indent=2, sort_keys=True))
