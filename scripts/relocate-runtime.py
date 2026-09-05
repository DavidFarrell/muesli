#!/usr/bin/env python3
"""Remove build-machine rpaths/IDs; reject unresolved loads in the subsequent audit."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess

spec = importlib.util.spec_from_file_location('runtime_audit', Path(__file__).with_name('audit-runtime.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def relocate(root):
    root = root.resolve()
    changes = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as handle:
            if handle.read(4) not in audit.MAGIC:
                continue
        operations = []
        relative = str(path.relative_to(root))
        for kind, block in audit.load_commands(path):
            if kind == 'LC_RPATH':
                value = re.search(r'\n\s*path (.+?) \(offset', block).group(1)
                if value.startswith('/') or (value.startswith('@loader_path/') and not audit.inside(path.parent / value[len('@loader_path/'):], root)):
                    operations.extend(['-delete_rpath', value])
            if kind == 'LC_LOAD_DYLIB' and relative == 'python/lib/python3.12/site-packages/numba/np/ufunc/omppool.cpython-312-darwin.so':
                value = re.search(r'\n\s*name (.+?) \(offset', block).group(1)
                if value == '@rpath/libomp.dylib':
                    target = root / 'python/lib/python3.12/site-packages/sklearn/.dylibs/libomp.dylib'
                    if not target.is_file():
                        raise ValueError('Pinned sklearn OpenMP runtime is absent.')
                    operations.extend(['-change', value, '@loader_path/../../../sklearn/.dylibs/libomp.dylib'])
            if kind == 'LC_ID_DYLIB':
                value = re.search(r'\n\s*name (.+?) \(offset', block).group(1)
                if value.startswith('/'):
                    operations.extend(['-id', '@rpath/' + path.name])
        if operations:
            before = hashlib.sha256(path.read_bytes()).hexdigest()
            subprocess.run(['/usr/bin/install_name_tool', *operations, str(path)], check=True)
            changes.append({'path': str(path.relative_to(root)), 'original_sha256': before,
                            'transformed_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                            'operations': operations})
    return {'schema_version': 1, 'changes': changes,
            'qualification': 'transformed unsigned code; requires closure audit, runtime testing and fresh signing'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.resolve().is_relative_to(args.root.resolve()):
        parser.error('Transformation report must be outside the payload.')
    args.out.write_text(json.dumps(relocate(args.root), indent=2) + '\n')
