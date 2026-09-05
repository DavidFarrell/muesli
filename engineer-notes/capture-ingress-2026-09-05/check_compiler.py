"""Compile actual production sources and assert the ingress has no UI executor dependency."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
dev = Path('/Applications/Xcode.app/Contents/Developer')
swiftc = dev / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env={'DEVELOPER_DIR':str(dev), 'PATH':'/usr/bin:/bin'}, text=True).strip()
features = ['DisableOutwardActorInference', 'InferSendableFromCaptures', 'GlobalActorIsolatedTypesUsability', 'MemberImportVisibility', 'InferIsolatedConformances', 'NonisolatedNonsendingByDefault']
with tempfile.TemporaryDirectory(prefix='muesli-ingress-sil-') as cache:
 command = [str(swiftc), '-emit-silgen', '-whole-module-optimization', '-module-name', 'MuesliApp', '-parse-as-library', '-swift-version', '5', '-default-isolation','MainActor','-sdk',sdk,'-target','arm64-apple-macos26.2','-module-cache-path',cache,'-import-objc-header',str(root/'MuesliApp/MuesliApp/MuesliApp-Bridging-Header.h')]
 for f in features: command.extend(['-enable-upcoming-feature',f])
 command.extend(str(p) for p in sorted((root/'MuesliApp/MuesliApp').glob('*.swift')))
 output = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
 if output.returncode: raise SystemExit(output.stdout)
 result=[]
 for marker in ['// closure #1 in MicAudioIngress.callback()', '// closure #1 in static MicAudioIngress.forwarding(to:display:onRejected:)']:
  start=output.stdout.index(marker)
  end=output.stdout.index('\n',output.stdout.index('// end sil function',start))
  function=output.stdout[start:end]
  assert 'MainActor' not in function, function
  result.append(function)
 Path('/private/tmp/muesli-ingress-callback.sil.txt').write_text('\n\n'.join(result))
 print('Production callback + forwarding closure compiled without MainActor reference. Evidence: /private/tmp/muesli-ingress-callback.sil.txt')

