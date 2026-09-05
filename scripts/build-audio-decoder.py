#!/usr/bin/env python3
"""Build the app's file/pipe PCM decoder from a pinned upstream source archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import wave

VERSION = '9.0.1'
SOURCE_SHA256 = 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635'
SOURCE_URL = f'https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz'
SIGNING_FINGERPRINT = 'FCF986EA15E6E293A5644F10B4322F04D67658D8'


def build(archive: Path, output: Path):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This decoder build requires an Apple Silicon Mac.')
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise RuntimeError('FFmpeg source does not match the verified release archive.')
    output.mkdir(parents=True, exist_ok=False)
    archive_copy = output / archive.name
    shutil.copyfile(archive, archive_copy)
    source_root = output / 'source'
    source_root.mkdir()
    with tarfile.open(archive) as source:
        source.extractall(source_root, filter='data')
    source = source_root / f'ffmpeg-{VERSION}'
    prefix = output / 'decoder'
    flags = [
        f'--prefix={prefix}', '--disable-autodetect', '--disable-everything',
        '--disable-network', '--disable-gpl', '--disable-nonfree', '--disable-version3',
        '--disable-shared', '--enable-static', '--disable-doc', '--disable-debug',
        '--disable-ffplay', '--disable-ffprobe', '--enable-ffmpeg', '--enable-small',
        '--enable-protocol=file,pipe', '--enable-demuxer=wav,aiff',
        '--enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be,pcm_f64be,pcm_u8,pcm_s8',
        '--enable-encoder=pcm_s16le,pcm_f32le', '--enable-muxer=wav,pcm_s16le,pcm_f32le',
        '--enable-filter=aresample,aformat,anull',
        '--extra-cflags=-mmacosx-version-min=26.2', '--extra-ldflags=-mmacosx-version-min=26.2', '--cc=clang', '--arch=arm64', '--target-os=darwin',
    ]
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(output),
           'TMPDIR': os.environ.get('TMPDIR', '/tmp'), 'LC_ALL': 'C'}
    if 'DEVELOPER_DIR' in os.environ:
        env['DEVELOPER_DIR'] = os.environ['DEVELOPER_DIR']
    with (output / 'build.log').open('w') as log:
        for command in [['./configure', *flags], ['make', '-j', str(min(os.cpu_count() or 2, 8))], ['make', 'install']]:
            subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = prefix / 'bin/ffmpeg'
    dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True)
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError(f'Unpackaged decoder dependency: {dependency}')
    protocols = subprocess.check_output([str(binary), '-hide_banner', '-protocols'], text=True, stderr=subprocess.DEVNULL)
    names = {line.strip() for line in protocols.splitlines() if line.startswith('  ')}
    if names != {'file', 'pipe'}:
        raise RuntimeError(f'Unexpected decoder protocols: {names}')
    fixture = output / 'decoder-probe.wav'
    with wave.open(str(fixture), 'wb') as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(48_000)
        audio.writeframes(b'\0\0' * 48_000)
    for format_name, codec, expected in [('s16le', 'pcm_s16le', 32_000), ('f32le', 'pcm_f32le', 64_000)]:
        result = subprocess.check_output([str(binary), '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-i', str(fixture), '-threads', '0', '-f', format_name, '-ac', '1', '-acodec', codec, '-ar', '16000', '-'])
        if len(result) != expected:
            raise RuntimeError(f'Decoder probe returned {len(result)} bytes, expected {expected}')
    notices = output / 'notices'
    notices.mkdir()
    for name in ['LICENSE.md', 'COPYING.LGPLv2.1']:
        shutil.copyfile(source / name, notices / name)
    manifest = {'schema_version': 1, 'version': VERSION, 'source_url': SOURCE_URL,
                'source_sha256': SOURCE_SHA256, 'verified_release_signing_fingerprint': SIGNING_FINGERPRINT,
                'configuration': flags, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'dependencies': dependencies, 'protocols': sorted(names),
                'qualification': 'decoder build only; packaged signing and sandbox qualification still required'}
    (output / 'decoder-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(binary)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    build(args.source_archive.resolve(), args.output.resolve())
