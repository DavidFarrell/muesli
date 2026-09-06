#!/usr/bin/env python3
"""Assemble a fresh development-signed local app from identified source.

The input service supplies previously qualified, sealed runtime/model bytes.
Native services are compiled from this checkout; Python modules must match it
exactly. This does not install, launch, notarize, or distribute the app.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def sha(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def source_identity(root):
    specification = importlib.util.spec_from_file_location('muesli_build_identity', root / 'scripts/write-build-identity.py')
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    value = module.identity(root, {})
    if value['source_dirty'] is not False or not value['source_commit'] or not value['source_tree_sha256']:
        raise ValueError('Local packaging requires a clean, identified checkout.')
    return value


def verify_manifest(resources, name, kind):
    path = resources / name
    if path.is_symlink() or path.stat().st_size > 8 * 1024**2:
        raise ValueError('Invalid payload manifest.')
    value = json.loads(path.read_bytes())
    if value.get('schema_version') != 1 or value.get('kind') != kind:
        raise ValueError('Unsupported payload manifest.')
    entries = value.get('entries')
    if not isinstance(entries, list) or not 0 < len(entries) <= 25000:
        raise ValueError('Invalid payload inventory.')
    seen = set()
    for item in entries:
        relative = item.get('path')
        if not isinstance(relative, str) or not relative or relative in seen:
            raise ValueError('Duplicate or missing payload path.')
        parts = PurePosixPath(relative)
        if parts.is_absolute() or '..' in parts.parts or str(parts) != relative:
            raise ValueError('Payload path escapes its resources.')
        candidate = resources / relative
        if not candidate.resolve(strict=True).is_relative_to(resources):
            raise ValueError('Payload link escapes its resources.')
        seen.add(relative)
        kind = item.get('kind')
        if kind == 'link':
            if not candidate.is_symlink() or os.readlink(candidate) != item.get('target'):
                raise ValueError('Payload link changed.')
        elif kind == 'directory':
            if candidate.is_symlink() or not candidate.is_dir():
                raise ValueError('Payload directory changed.')
        elif kind == 'file':
            info = candidate.lstat()
            if candidate.is_symlink() or not candidate.is_file() or info.st_nlink != 1:
                raise ValueError('Payload file is not an ordinary single-link file.')
            if info.st_size != item.get('bytes') or sha(candidate) != item.get('sha256'):
                raise ValueError('Payload bytes changed.')
        else:
            raise ValueError('Unsupported payload entry.')
    if name == 'runtime-manifest.json':
        runtime = resources / 'python'
        actual = {'python', *(p.relative_to(resources).as_posix() for p in runtime.rglob('*'))}
        if actual != seen:
            raise ValueError('Runtime contains missing or unrecorded entries.')
    return sha(path)


def verify_python(resources, root):
    source = root / 'backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe'
    installed = resources / 'python/lib/python3.12/site-packages/diarise_transcribe'
    expected = {p.name: sha(p) for p in source.glob('*.py')}
    actual = {p.name: sha(p) for p in installed.glob('*.py')}
    if expected != actual or not expected:
        raise ValueError('Qualified Python package differs from the current source checkout.')
    return expected


def signed_details(bundle, team, identifier, entitlements):
    run(['codesign', '--verify', '--deep', '--strict', bundle], capture_output=True)
    result = run(['codesign', '-d', '--entitlements', ':-', '--verbose=4', bundle], capture_output=True)
    actual = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    detail = result.stderr.decode()
    if actual != entitlements or f'TeamIdentifier={team}' not in detail or '(runtime)' not in detail:
        raise ValueError('Signed payload does not have the expected team, runtime, or entitlements.')
    if re.search(r'^Identifier=(.*)$', detail, re.M).group(1) != identifier:
        raise ValueError('Signed payload has an unexpected identifier.')


def bundle_info(identifier, executable, broker=False):
    xpc = {'ServiceType': 'Application'}
    if broker:
        xpc.update(RunLoopType='NSRunLoop', JoinExistingSession=True)
    return dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable, CFBundlePackageType='XPC!',
                CFBundleVersion='1', LSMinimumSystemVersion='26.2', LSUIElement=broker, XPCService=xpc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path, help='Clean-source optimized MuesliApp.app build.')
    parser.add_argument('--inference-payload', required=True, type=Path, help='Previously qualified signed InferenceService.xpc.')
    parser.add_argument('--output', required=True, type=Path, help='Fresh output directory; never the installed app.')
    parser.add_argument('--identity', required=True)
    parser.add_argument('--team', required=True)
    args = parser.parse_args()
    if not re.fullmatch('[A-Z0-9]{10}', args.team):
        parser.error('Invalid signing team.')
    root = Path(__file__).resolve().parent.parent
    app_input = args.app.resolve(strict=True)
    payload_input = args.inference_payload.resolve(strict=True)
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(app_input) or output.is_relative_to(payload_input):
        parser.error('Output must be a fresh directory outside both input bundles.')
    before = source_identity(root)
    app_identity = json.loads((app_input / 'Contents/Resources/build-identity.json').read_bytes())
    for key in ('source_commit', 'source_dirty', 'source_tree_sha256'):
        if app_identity.get(key) != before[key]:
            raise ValueError('The app build does not match this clean source checkout.')
    info = plistlib.loads((app_input / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'paidiaconsulting.MuesliApp' or info.get('CFBundleExecutable') != 'MuesliApp':
        raise ValueError('Input is not the expected Muesli application.')
    if app_identity.get('build_settings', {}).get('CONFIGURATION') != 'Release':
        raise ValueError('Local packaged testing requires the optimized Release configuration.')
    service_entitlements = {'com.apple.security.app-sandbox': True, 'com.apple.security.cs.allow-jit': True,
                            'com.apple.security.cs.allow-unsigned-executable-memory': True}
    broker_entitlements = {'com.apple.security.app-sandbox': True,
                           'com.apple.security.files.user-selected.read-only': True}
    signed_details(payload_input, args.team, 'paidiaconsulting.MuesliApp.InferenceService', service_entitlements)
    resources_input = payload_input / 'Contents/Resources'
    runtime_sha = verify_manifest(resources_input, 'runtime-manifest.json', 'actual_runtime_files')
    model_sha = verify_manifest(resources_input, 'model-manifest.json', 'validated_local_model_assets')
    python_sources = verify_python(resources_input, root)
    output.mkdir(parents=True)
    app = output / 'MuesliApp.app'
    run(['cp', '-cR', app_input, app])
    xpc_root = app / 'Contents/XPCServices'
    xpc_root.mkdir(exist_ok=True)
    service = xpc_root / 'paidiaconsulting.MuesliApp.InferenceService.xpc'
    broker = xpc_root / 'paidiaconsulting.MuesliApp.SourceAccessService.xpc'
    for bundle in (service, broker):
        if bundle.exists():
            raise ValueError('The input app already has an assembled local service; use a fresh Xcode build.')
        (bundle / 'Contents/MacOS').mkdir(parents=True)
    run(['cp', '-cR', resources_input, service / 'Contents/Resources'])
    (service / 'Contents/Info.plist').write_bytes(plistlib.dumps(bundle_info('paidiaconsulting.MuesliApp.InferenceService', 'InferenceService')))
    (broker / 'Contents/Info.plist').write_bytes(plistlib.dumps(bundle_info('paidiaconsulting.MuesliApp.SourceAccessService', 'SourceAccessService', True)))
    src = root / 'release/inference-service'
    broker_src = root / 'release/source-access-service'
    os.environ['DEVELOPER_DIR'] = os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    flags = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-O2', '-arch', 'arm64', '-mmacosx-version-min=26.2',
             f'-DMUESLI_SIGNING_TEAM="{args.team}"', '-I', src]
    run(flags + ['-I', service / 'Contents/Resources/python/include/python3.12', '-framework', 'Foundation',
                 '-framework', 'Security', *[src / name for name in ('ServiceV2.m', 'PythonBridgeV2.m', 'InferenceProtocolV2.m', 'SourceLeaseAdmission.m', 'VerifiedPayload.m')],
                 '-o', service / 'Contents/MacOS/InferenceService'])
    run(flags + ['-I', broker_src, '-framework', 'Foundation', '-framework', 'AppKit',
                 broker_src / 'SourceAccessService.m', src / 'InferenceProtocolV2.m', '-o', broker / 'Contents/MacOS/SourceAccessService'])
    for name, entitlements in [('Service', service_entitlements), ('Broker', broker_entitlements)]:
        (output / f'{name}.entitlements').write_bytes(plistlib.dumps(entitlements))
    for bundle, entitlements in ((service, output / 'Service.entitlements'), (broker, output / 'Broker.entitlements')):
        run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--entitlements', entitlements, bundle])
    archive = app / 'Contents/Helpers/muesli-archive'
    if not archive.is_file() or archive.is_symlink():
        raise ValueError('The app archive helper is missing or not an ordinary file.')
    run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', archive])
    copied_resources = service / 'Contents/Resources'
    if (verify_manifest(copied_resources, 'runtime-manifest.json', 'actual_runtime_files') != runtime_sha
            or verify_manifest(copied_resources, 'model-manifest.json', 'validated_local_model_assets') != model_sha
            or verify_python(copied_resources, root) != python_sources):
        raise ValueError('Payload changed during local packaging.')
    after = source_identity(root)
    if any(before[key] != after[key] for key in ('source_commit', 'source_dirty', 'source_tree_sha256')):
        raise ValueError('Source changed while assembling the native services.')
    record = dict(schema_version=1, scope='Local development-signed testing; distribution deferred',
                  app_build_id=app_identity['build_id'], source_commit=before['source_commit'],
                  source_tree_sha256=before['source_tree_sha256'], runtime_manifest_sha256=runtime_sha,
                  model_manifest_sha256=model_sha, python_source_sha256=python_sources,
                  inference_executable_sha256=sha(service / 'Contents/MacOS/InferenceService'),
                  source_broker_executable_sha256=sha(broker / 'Contents/MacOS/SourceAccessService'),
                  inference_client_identifier='paidiaconsulting.MuesliApp', source_broker_persistence=False,
                  signing_team=args.team, compiler_flags=['arm64', 'macOS26.2', 'O2', 'ARC', 'blocks'])
    (app / 'Contents/Resources/local-runtime-package.json').write_text(json.dumps(record, sort_keys=True, indent=2) + '\n')
    run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--entitlements',
         root / 'MuesliApp/MuesliApp/MuesliApp.entitlements', app])
    with (output / 'signed-app-audit.json').open('w') as report:
        run(['python3', src / 'audit-proof.py', app, '--team', args.team, '--application-host'], stdout=report)
    signed_details(app, args.team, 'paidiaconsulting.MuesliApp', {'com.apple.security.device.audio-input': True})
    signed_details(broker, args.team, 'paidiaconsulting.MuesliApp.SourceAccessService', broker_entitlements)
    signed_details(service, args.team, 'paidiaconsulting.MuesliApp.InferenceService', service_entitlements)
    print(json.dumps({'app': str(app), 'source_commit': before['source_commit'], 'app_build_id': app_identity['build_id'],
                      'audit': str(output / 'signed-app-audit.json'), 'installed': False, 'launched': False}))


if __name__ == '__main__':
    main()
