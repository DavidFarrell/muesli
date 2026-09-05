#!/usr/bin/env python3
"""Reject runtime payloads with escaping links or unresolved native dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
SYSTEM = ('/usr/lib/', '/System/Library/')


def inside(path, root):
    return path.resolve().is_relative_to(root)


def load_commands(path):
    text = subprocess.check_output(['/usr/bin/otool', '-arch', 'arm64', '-l', str(path)], text=True)
    commands = []
    for block in text.split('Load command ')[1:]:
        match = re.search(r'\n\s*cmd (\S+)', block)
        if match:
            commands.append((match.group(1), block))
    return commands


def audit(root, executable, minimum=(26, 2)):
    root = root.resolve()
    executable = executable.resolve()
    if not inside(executable, root):
        raise ValueError('Entry executable escapes the runtime.')
    files, native, symlinks = {}, {}, {}
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if path.is_symlink():
            if not inside(path, root) or not path.exists():
                raise ValueError(f'Escaping or broken runtime symlink: {name}')
            symlinks[name] = str(path.readlink())
        elif path.is_file():
            with path.open('rb') as handle:
                magic = handle.read(4)
                handle.seek(0)
                files[name] = hashlib.file_digest(handle, 'sha256').hexdigest()
            if magic in MAGIC:
                native[path] = load_commands(path)
    if executable not in native:
        raise ValueError('Entry executable is not an arm64 Mach-O binary.')

    def expand(value, owner, entry):
        if value == '@loader_path':
            return owner.parent.resolve()
        if value == '@executable_path':
            return entry.parent.resolve()
        if value.startswith('@loader_path/'):
            return (owner.parent / value[len('@loader_path/'):]).resolve()
        if value.startswith('@executable_path/'):
            return (entry.parent / value[len('@executable_path/'):]).resolve()
        if value.startswith('/'):
            return Path(value).resolve()
        raise ValueError(f'Unsupported native path {value} in {owner.relative_to(root)}')

    def rpaths(owner, entry):
        result = []
        for kind, block in native[owner]:
            if kind == 'LC_RPATH':
                value = re.search(r'\n\s*path (.+?) \(offset', block).group(1)
                if value.startswith('/'):
                    raise ValueError(f'Non-relocatable absolute rpath in {owner.relative_to(root)}: {value}')
                resolved = expand(value, owner, entry)
                if not inside(resolved, root):
                    raise ValueError(f'Escaping rpath in {owner.relative_to(root)}: {value}')
                result.append(resolved)
        return result

    details = []
    for owner, commands in native.items():
        # Standalone binaries have their own executable directory. Extension
        # modules and dylibs use the sole admitted Python host's directory.
        filetype = subprocess.check_output(['/usr/bin/otool', '-arch', 'arm64', '-hv', str(owner)], text=True)
        entry = owner if 'EXECUTE' in filetype else executable
        search = rpaths(owner, entry) + ([] if owner == entry else rpaths(entry, entry))
        dependencies = []
        for kind, block in commands:
            if kind == 'LC_BUILD_VERSION':
                version = re.search(r'\n\s*minos ([0-9.]+)', block).group(1)
                parts = tuple(int(x) for x in version.split('.'))
                if (parts + (0, 0))[:2] > minimum:
                    raise ValueError(f'{owner.relative_to(root)} requires macOS {version}')
            if kind not in {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB'}:
                continue
            value = re.search(r'\n\s*name (.+?) \(offset', block).group(1)
            if value.startswith(SYSTEM):
                dependencies.append(value)
                continue
            if value.startswith('/'):
                raise ValueError(f'Non-relocatable absolute dependency in {owner.relative_to(root)}: {value}')
            if value.startswith('@rpath/'):
                matches = [base / value[len('@rpath/'):] for base in search]
            else:
                matches = [expand(value, owner, entry)]
            candidates = [p.resolve() for p in matches if p.exists() and inside(p, root)]
            if not candidates or not any(p in native for p in candidates):
                raise ValueError(f'Unresolved native dependency in {owner.relative_to(root)}: {value}')
            dependencies.append(str(candidates[0].relative_to(root)))
        details.append({'path': str(owner.relative_to(root)), 'dependencies': dependencies})
    return {'schema_version': 1, 'hash_scope': 'unsigned payload files before signing; audit report stored outside payload',
            'files': files, 'symlinks': symlinks, 'native': details, 'minimum_macos': '.'.join(map(str, minimum)),
            'qualification': 'static closure inspection; dynamic loads and signed runtime still require actual execution'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--executable', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    if args.out.resolve().is_relative_to(args.root.resolve()):
        parser.error('Audit report must be outside the hashed payload.')
    args.out.write_text(json.dumps(audit(args.root, args.executable), indent=2) + '\n')
