"""Regenerate evidence for the actual app callback's executor dependency.

Uses the installed Xcode toolchain and the audited project's concurrency
settings. Does not launch the app. Full temporary compiler output is discarded;
the relevant generated function is printed for review. A changed source or
toolchain may change the function's name or generated instructions.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEVELOPER = Path('/Applications/Xcode.app/Contents/Developer')
SWIFTC = DEVELOPER / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
sdk = subprocess.check_output(
    ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
    env={'DEVELOPER_DIR': str(DEVELOPER), 'PATH': '/usr/bin:/bin'}, text=True
).strip()
features = ['DisableOutwardActorInference', 'InferSendableFromCaptures',
            'GlobalActorIsolatedTypesUsability', 'MemberImportVisibility',
            'InferIsolatedConformances', 'NonisolatedNonsendingByDefault']
with tempfile.TemporaryDirectory(prefix='muesli-compiler-audit-') as scratch:
    command = [str(SWIFTC), '-emit-silgen', '-whole-module-optimization',
               '-module-name', 'MuesliApp', '-parse-as-library', '-swift-version', '5',
               '-default-isolation', 'MainActor', '-sdk', sdk,
               '-target', 'arm64-apple-macos26.2', '-module-cache-path', scratch,
               '-import-objc-header', str(ROOT / 'MuesliApp/MuesliApp/MuesliApp-Bridging-Header.h')]
    for feature in features:
        command.extend(['-enable-upcoming-feature', feature])
    command.extend(str(p) for p in sorted((ROOT / 'MuesliApp/MuesliApp').glob('*.swift')))
    with tempfile.TemporaryFile(mode='w+') as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=120)
        output.seek(0)
        generated = output.read()
    if result.returncode:
        raise SystemExit(generated[-12000:])
    marker = '// closure #1 in closure #2 in AppModel.attemptMeetingMicEngineStart('
    start = generated.index(marker)
    end = generated.index('\n', generated.index('// end sil function', start))
    print(generated[start:end])
