import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
PACKAGE = ROOT / 'backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe'


def verify(record, package):
    return subprocess.run([sys.executable, str(HERE / 'verify-current-build-inputs.py'), str(record), str(package)], capture_output=True)


def test_actual_complete_package_matches_record_and_rejects_changed_or_extra_module(tmp_path):
    record, copy = tmp_path / 'record.json', tmp_path / 'package'
    subprocess.run([sys.executable, str(HERE / 'write-current-build-inputs.py'), str(ROOT), str(record)], check=True)
    copy.mkdir()
    for path in PACKAGE.glob('*.py'):
        shutil.copyfile(path, copy / path.name)
    assert verify(record, copy).returncode == 0
    module = copy / 'xpc_entry.py'
    original = module.read_bytes()
    module.write_bytes(original + b'\n# changed\n')
    assert verify(record, copy).returncode != 0
    module.write_bytes(original)
    (copy / 'unlisted.py').write_text('raise RuntimeError()')
    assert verify(record, copy).returncode != 0
    (copy / 'unlisted.py').unlink()
    (copy / '__pycache__').mkdir()
    assert verify(record, copy).returncode != 0


def test_native_sources_are_part_of_start_end_identity(tmp_path):
    record = tmp_path / 'record.json'
    subprocess.run([sys.executable, str(HERE / 'write-current-build-inputs.py'), str(ROOT), str(record)], check=True)
    value = json.loads(record.read_text())
    assert {'ServiceV2.m', 'PythonBridgeV2.m', 'InferenceProtocolV2.h', 'SourceLeaseAdmission.m',
            'VerifiedPayload.m', 'build-current-proof.sh', 'verify-current-build-inputs.py'} <= set(value['proof_sources_sha256'])
    assert set(value['complete_backend_modules_sha256']) == {p.stem for p in PACKAGE.glob('*.py')}
    script = (HERE / 'build-current-proof.sh').read_text()
    assert script.index('write-current-build-inputs.py') < script.index('xcrun clang')
    assert 'source-inputs-after.json' in script and '\ncmp ' in script
    assert ' -I -B ' in script
