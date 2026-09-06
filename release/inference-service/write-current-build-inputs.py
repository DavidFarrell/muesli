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
source_files = ['ServiceV2.m', 'PythonBridgeV2.m', 'CurrentProofHost.m', 'InferenceProtocolV2.h',
                'InferenceProtocolV2.m', 'SourceLeaseAdmission.h', 'SourceLeaseAdmission.m',
                'VerifiedPayload.h', 'VerifiedPayload.m', 'OSVersion.m', 'Service.entitlements',
                'Child.entitlements', 'build-current-proof.sh', 'write-payload-manifests.py', 'write-current-build-inputs.py',
                'verify-current-build-inputs.py']
backend = root / 'backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe'
modules = sorted(path.stem for path in backend.glob('*.py'))
try:
    commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all'], text=True))
except (OSError, subprocess.CalledProcessError):
    commit, dirty = None, None
value = {'schema_version': 1, 'signing_team': sys.argv[3] if len(sys.argv)>3 else None,
         'diagnostic_picker_path_sha256': hashlib.sha256(sys.argv[4].encode()).hexdigest() if len(sys.argv)>4 and sys.argv[4] else None, 'source_commit': commit, 'source_dirty': dirty,
         'proof_sources_sha256': {name: hashlib.sha256((proof/name).read_bytes()).hexdigest() for name in source_files},
         'complete_backend_modules_sha256': {name: hashlib.sha256((backend/(name+'.py')).read_bytes()).hexdigest() for name in modules},
         'runtime_identity_scope': 'Actual shipped runtime/native/model identities require the separate payload audit and observed inference evidence.'}
with output.open('x') as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write('\n')
