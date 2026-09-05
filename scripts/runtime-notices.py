#!/usr/bin/env python3
"""Inventory shipped dependency notices without importing runtime packages."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path


def inventory(root):
    root = root.resolve()
    site = root / 'python/lib/python3.12/site-packages'
    packages = []
    for dist in sorted(importlib.metadata.distributions(path=[str(site)]), key=lambda d: d.metadata['Name'].lower()):
        notices = []
        for entry in dist.files or []:
            if not any(word in entry.name.lower() for word in ['license', 'licence', 'copying', 'notice', 'copyright']):
                continue
            path = Path(dist.locate_file(entry)).resolve()
            if not path.is_relative_to(root):
                raise ValueError('Dependency notice escapes the staged runtime.')
            if path.is_file():
                notices.append({'path': str(path.relative_to(root)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
        packages.append({'name': dist.metadata['Name'], 'version': dist.version,
                         'declared_license_expression': dist.metadata.get('License-Expression'),
                         'declared_license': dist.metadata.get('License'),
                         'notice_files': notices, 'notice_review_required': not bool(notices)})
    python_license = root / 'python/lib/python3.12/LICENSE.txt'
    if not python_license.is_file():
        raise ValueError('Standalone Python license text is missing.')
    return {'schema_version': 1, 'packages': packages,
            'python_license': {'path': str(python_license.relative_to(root)),
                               'sha256': hashlib.sha256(python_license.read_bytes()).hexdigest()},
            'qualification': 'inventory of declared and shipped notices; model and redistribution review remains separate'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.write_text(json.dumps(inventory(args.root), indent=2) + '\n')
