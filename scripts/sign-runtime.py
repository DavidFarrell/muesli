#!/usr/bin/env python3
"""Sign native payload leaves and report post-sign hashes, without weakening library validation."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('runtime_audit', Path(__file__).with_name('audit-runtime.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--identity', required=True, help='Exact codesign identity; use - only for local qualification.')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.out.resolve().is_relative_to(root):
        parser.error('Signed payload manifest must be outside the payload to avoid self-reference.')
    before = audit.audit(root, args.executable)
    natives = [root / item['path'] for item in before['native']]
    for native in sorted(natives, key=lambda p: (p.resolve() == args.executable.resolve(), -len(p.parts), str(p))):
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', args.identity, str(native)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(native)], check=True)
    report = audit.audit(root, args.executable)
    report['hash_scope'] = 'payload after leaf signing, before containing-bundle signing; report outside payload'
    report['signing_identity_requested'] = args.identity
    report['qualification'] = 'leaf signatures and static closure only; enclosing bundle, notarization and runtime sandbox qualification are separate'
    args.out.write_text(json.dumps(report, indent=2) + '\n')
