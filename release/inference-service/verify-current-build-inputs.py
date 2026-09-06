#!/usr/bin/env python3
"""Reject an incomplete or changed copied backend before signing the proof host."""
import hashlib
import json
from pathlib import Path
import sys

record = json.loads(Path(sys.argv[1]).read_text())
package = Path(sys.argv[2])
expected = record['complete_backend_modules_sha256']
actual = {p.stem: hashlib.sha256(p.read_bytes()).hexdigest() for p in package.glob('*.py')}
if expected != actual or any(p.is_symlink() or not p.is_file() or p.suffix != '.py' for p in package.iterdir()):
    raise SystemExit('Copied backend differs from the captured source inputs')
print('Complete copied backend matches the original build source snapshot')
