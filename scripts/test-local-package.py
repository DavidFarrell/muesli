#!/usr/bin/env python3
"""Check the new local packager's rejection boundaries using tiny fixtures."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('local_package', Path(__file__).with_name('package-local-app.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class LocalPackageTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='muesli-local-package-test-')
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.resources = self.root / 'resources'
        self.runtime = self.resources / 'python'
        self.runtime.mkdir(parents=True)
        self.binary = self.runtime / 'fixture'
        self.binary.write_bytes(b'fixed runtime input')
        self.entries = [dict(kind='directory', path='python'),
                        dict(kind='file', path='python/fixture', bytes=self.binary.stat().st_size,
                             sha256=hashlib.sha256(self.binary.read_bytes()).hexdigest())]

    def manifest(self, entries=None):
        path = self.resources / 'runtime-manifest.json'
        path.write_text(json.dumps(dict(schema_version=1, kind='actual_runtime_files',
                                       entries=self.entries if entries is None else entries)))
        return path

    def verify(self):
        return package.verify_manifest(self.resources, 'runtime-manifest.json', 'actual_runtime_files')

    def test_exact_inventory_is_accepted(self):
        path = self.manifest()
        self.assertEqual(self.verify(), hashlib.sha256(path.read_bytes()).hexdigest())

    def test_changed_file_is_rejected(self):
        self.manifest()
        self.binary.write_bytes(b'changed runtime bytes')
        with self.assertRaises(ValueError): self.verify()

    def test_unrecorded_runtime_entry_is_rejected(self):
        self.manifest()
        (self.runtime / 'extra').write_bytes(b'not admitted')
        with self.assertRaises(ValueError): self.verify()

    def test_duplicate_entry_is_rejected(self):
        self.manifest([*self.entries, self.entries[-1]])
        with self.assertRaises(ValueError): self.verify()

    def test_parent_escape_is_rejected(self):
        self.manifest([*self.entries, dict(kind='file', path='../outside', bytes=1, sha256='a'*64)])
        with self.assertRaises(ValueError): self.verify()

    def test_absolute_path_is_rejected(self):
        self.manifest([*self.entries, dict(kind='file', path=str(self.binary), bytes=1, sha256='a'*64)])
        with self.assertRaises(ValueError): self.verify()

    def test_link_escape_is_rejected(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'outside')
        (self.runtime / 'escape').symlink_to(outside)
        self.manifest([*self.entries, dict(kind='link', path='python/escape', target=str(outside))])
        with self.assertRaises(ValueError): self.verify()

    def test_recorded_internal_link_is_accepted(self):
        (self.runtime / 'alias').symlink_to('fixture')
        self.manifest([*self.entries, dict(kind='link', path='python/alias', target='fixture')])
        self.verify()

    def test_ordinary_file_cannot_be_replaced_by_link(self):
        self.manifest()
        self.binary.rename(self.runtime / 'moved')
        self.binary.symlink_to('moved')
        with self.assertRaises(ValueError): self.verify()

    def test_python_source_mismatch_is_rejected(self):
        source = self.root / 'checkout/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe'
        installed = self.resources / 'python/lib/python3.12/site-packages/diarise_transcribe'
        source.mkdir(parents=True); installed.mkdir(parents=True)
        (source / '__init__.py').write_text('original = True\n')
        (installed / '__init__.py').write_text('original = True\n')
        package.verify_python(self.resources, self.root / 'checkout')
        (installed / '__init__.py').write_text('original = False\n')
        with self.assertRaises(ValueError): package.verify_python(self.resources, self.root / 'checkout')

    def test_wrong_manifest_kind_is_rejected(self):
        self.manifest()
        with self.assertRaises(ValueError):
            package.verify_manifest(self.resources, 'runtime-manifest.json', 'validated_local_model_assets')


if __name__ == '__main__':
    unittest.main()
