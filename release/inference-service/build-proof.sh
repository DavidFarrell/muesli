#!/bin/bash
set -euo pipefail
if [[ $# != 4 ]]; then
  echo 'Usage: build-proof.sh fresh-output-directory python-runtime signing-identity team-id' >&2
  exit 64
fi
proof_output="$1"
proof_runtime="$2"
proof_identity="$3"
proof_team="$4"
proof_sources="$(cd "$(dirname "$0")" && pwd)"
proof_repo="$(cd "$proof_sources/../.." && pwd)"
[[ ! -e "$proof_output" ]] || { echo 'Output must not exist.' >&2; exit 1; }
[[ "$proof_team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid signing Team ID.' >&2; exit 1; }
proof_app="$proof_output/InferenceProof.app"
proof_service="$proof_app/Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc"
mkdir -p "$proof_app/Contents/Resources" "$proof_app/Contents/MacOS" "$proof_service/Contents/MacOS" "$proof_service/Contents/Resources"
cat > "$proof_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>paidiaconsulting.MuesliApp.InferenceProof</string>
<key>CFBundleExecutable</key><string>InferenceProof</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>26.2</string><key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$proof_service/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>paidiaconsulting.MuesliApp.InferenceService</string>
<key>CFBundleExecutable</key><string>InferenceService</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>26.2</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.2 -arch arm64 \
  "-DMUESLI_SIGNING_TEAM=\"$proof_team\"" -I "$proof_runtime/include/python3.12" \
  -framework Foundation -framework Security "$proof_sources/Service.m" "$proof_sources/PythonBridge.m" \
  -o "$proof_service/Contents/MacOS/InferenceService"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.2 -arch arm64 \
  "-DMUESLI_SIGNING_TEAM=\"$proof_team\"" -framework Foundation "$proof_sources/ProofHost.m" \
  -o "$proof_app/Contents/MacOS/InferenceProof"
# The proof owns its runtime copy; the shared staging payload is never resigned.
ditto "$proof_runtime" "$proof_service/Contents/Resources/python"
ditto "$(dirname "$proof_runtime")/tools" "$proof_service/Contents/Resources/python/tools"
xcrun clang -fobjc-arc -mmacosx-version-min=26.2 -arch arm64 -framework Foundation \
  "$proof_sources/OSVersion.m" -o "$proof_service/Contents/Resources/python/tools/sw_vers"
for proof_module in xpc_entry inference_workspace muesli_backend reprocess; do
  cp "$proof_repo/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/$proof_module.py" \
     "$proof_service/Contents/Resources/python/lib/python3.12/site-packages/diarise_transcribe/$proof_module.py"
done
while IFS= read -r -d '' proof_file; do
  if file -b "$proof_file" | /usr/bin/grep -q 'Mach-O'; then
    if [[ "$proof_file" == */tools/ffmpeg || "$proof_file" == */tools/sw_vers ]]; then
      codesign --force --sign "$proof_identity" --options runtime --entitlements "$proof_sources/Child.entitlements" "$proof_file"
    else
      codesign --force --sign "$proof_identity" --options runtime "$proof_file"
    fi
  fi
done < <(find "$proof_service/Contents/Resources/python" -type f -print0)
codesign --force --sign "$proof_identity" --options runtime --entitlements "$proof_sources/Service.entitlements" "$proof_service"
# Record exact copied source inputs, separate from the audited installed runtime.
# No source/model paths or contents enter this build record.
python3 "$proof_sources/write-build-inputs.py" "$proof_repo" "$proof_app/Contents/Resources/proof-build-inputs.json"
codesign --force --sign "$proof_identity" --options runtime "$proof_app"
codesign --verify --deep --strict --verbose=2 "$proof_app"
echo "$proof_app/Contents/MacOS/InferenceProof"
