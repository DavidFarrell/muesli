#!/usr/bin/env python3
"""Record exact proof source inputs, not a claim about installed model identity."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2])
proof = root / 'release/inference-service'
source_files = ['Service.m', 'PythonBridge.m', 'ProofHost.m', 'InferenceProtocol.h',
                'OSVersion.m', 'Service.entitlements', 'Child.entitlements', 'build-proof.sh',
                'write-build-inputs.py']
modules = ['xpc_entry', 'inference_workspace', 'muesli_backend', 'reprocess']
backend = root / 'backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe'
try:
    commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all'], text=True))
except (OSError, subprocess.CalledProcessError):
    commit, dirty = None, None
value = {'schema_version': 1, 'source_commit': commit, 'source_dirty': dirty,
         'proof_sources_sha256': {name: hashlib.sha256((proof/name).read_bytes()).hexdigest() for name in source_files},
         'overlaid_backend_modules_sha256': {name: hashlib.sha256((backend/(name+'.py')).read_bytes()).hexdigest() for name in modules},
         'runtime_identity_scope': 'Actual shipped runtime/native/model identities require the separate payload audit and observed inference evidence.'}
with output.open('x') as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write('\n')
