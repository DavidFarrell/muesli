#!/usr/bin/env python3
"""Exercise relocation and rejection boundaries against real Mach-O fixtures."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


runtime = module('audit', 'audit-runtime.py')
staging = module('staging', 'stage-python-runtime.py')
decoder = module('decoder', 'build-audio-decoder.py')


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='muesli-package-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'payload'
        (self.root / 'bin').mkdir(parents=True)
        (self.root / 'lib').mkdir()
        self.host = self.root / 'bin/host'
        self.library = self.root / 'lib/libprobe.dylib'
        (self.base / 'library.c').write_text('int probe(void) { return 0; }\n')
        (self.base / 'host.c').write_text('extern int probe(void); int main(void) { return probe(); }\n')
        self.run_command('clang', '-dynamiclib', '-mmacosx-version-min=26.2', str(self.base / 'library.c'),
                         '-Wl,-install_name,@rpath/libprobe.dylib', '-Wl,-headerpad_max_install_names', '-o', str(self.library))
        self.run_command('clang', '-mmacosx-version-min=26.2', str(self.base / 'host.c'),
                         '-L' + str(self.root / 'lib'), '-lprobe', '-Wl,-rpath,@executable_path/../lib', '-Wl,-headerpad_max_install_names', '-o', str(self.host))

    def run_command(self, *args):
        subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_relative_native_closure_survives_original_directory_removal(self):
        moved = self.base / 'relocated'
        self.root.rename(moved)
        report = runtime.audit(moved, moved / 'bin/host')
        self.assertEqual(len(report['native']), 2)
        self.run_command(str(moved / 'bin/host'))

    def test_escaping_symlink_is_rejected(self):
        (self.root / 'escape').symlink_to(self.base)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            runtime.audit(self.root, self.host)

    def test_rpath_escape_and_absolute_internal_path_are_rejected(self):
        self.run_command('install_name_tool', '-add_rpath', '@loader_path/../../outside', str(self.host))
        with self.assertRaisesRegex(ValueError, 'rpath'):
            runtime.audit(self.root, self.host)
        self.run_command('install_name_tool', '-delete_rpath', '@loader_path/../../outside',
                         '-add_rpath', str(self.root / 'lib'), str(self.host))
        with self.assertRaisesRegex(ValueError, 'absolute rpath'):
            runtime.audit(self.root, self.host)

    def test_unbundled_library_is_rejected(self):
        self.library.unlink()
        with self.assertRaisesRegex(ValueError, 'Unresolved native dependency'):
            runtime.audit(self.root, self.host)

    def test_binary_newer_than_supported_macos_is_rejected(self):
        self.run_command('clang', '-dynamiclib', '-mmacosx-version-min=26.3', str(self.base / 'library.c'),
                         '-Wl,-install_name,@rpath/libprobe.dylib', '-Wl,-headerpad_max_install_names', '-o', str(self.library))
        with self.assertRaisesRegex(ValueError, 'requires macOS'):
            runtime.audit(self.root, self.host)

    def test_system_prefix_cannot_hide_path_traversal(self):
        self.run_command('install_name_tool', '-change', '@rpath/libprobe.dylib',
                         '/usr/lib/../../private/tmp/unbundled-library.dylib', str(self.host))
        with self.assertRaisesRegex(ValueError, 'absolute dependency'):
            runtime.audit(self.root, self.host)

    def test_intel_only_host_and_dependency_are_rejected(self):
        self.run_command('clang', '-arch', 'x86_64', '-mmacosx-version-min=26.2',
                         str(self.base / 'library.c'), '-dynamiclib', '-o', str(self.library))
        with self.assertRaisesRegex(ValueError, 'arm64 slice'):
            runtime.audit(self.root, self.host)
        self.library.unlink()
        (self.base / 'intel.c').write_text('int main(void) { return 0; }\n')
        self.run_command('clang', '-arch', 'x86_64', '-mmacosx-version-min=26.2',
                         str(self.base / 'intel.c'), '-o', str(self.host))
        with self.assertRaisesRegex(ValueError, 'arm64 slice'):
            runtime.audit(self.root, self.host)

    def test_unsupported_fat64_container_is_not_silently_treated_as_data(self):
        bad = self.root / 'lib/bad.dylib'
        bad.write_bytes(b'\xca\xfe\xba\xbf' + b'\0' * 40)
        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
            runtime.audit(self.root, self.host)

    def test_wrong_download_hash_fails_before_output_creation(self):
        archive = self.base / 'wrong-archive'
        archive.write_bytes(b'wrong archive')
        for operation in [lambda target: staging.stage(archive, self.base, target),
                          lambda target: decoder.build(archive, target)]:
            target = self.base / 'must-not-exist'
            with self.assertRaises(RuntimeError):
                operation(target)
            self.assertFalse(target.exists())


if __name__ == '__main__':
    unittest.main()
