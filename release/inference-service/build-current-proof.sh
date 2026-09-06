#!/bin/bash
set -euo pipefail
if [[ $# != 5 && $# != 6 ]]; then
  echo 'Usage: build-proof.sh fresh-output-directory python-runtime fixed-model-directory signing-identity team-id [generated-picker-folder]' >&2
  exit 64
fi
proof_output="$1"
proof_runtime="$2"
proof_models="$3"
proof_identity="$4"
proof_team="$5"
proof_picker="${6:-}"
proof_picker_flags=()
if [[ -n "$proof_picker" ]]; then
  [[ "$proof_picker" =~ ^/Users/david/muesli-current-inference-generated-[a-f0-9]{32}/admitted$ ]] || { echo 'Picker fixture must be a new dedicated generated directory.' >&2; exit 64; }
  [[ -f "$proof_picker/.generated-muesli-v2-fixture.json" ]] || { echo 'Generated fixture marker is missing.' >&2; exit 64; }
  proof_picker_flags=("-DMUESLI_GENERATED_SOURCE=\"$proof_picker\"")
fi
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
# Capture source identity BEFORE any compiler/copy reads, then require that
# same source snapshot and actual copied package before certifying the bundle.
python3 "$proof_sources/write-current-build-inputs.py" "$proof_repo" "$proof_app/Contents/Resources/proof-build-inputs.json" "$proof_team" "$proof_picker"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.2 -arch arm64 \
  "-DMUESLI_SIGNING_TEAM=\"$proof_team\"" -I "$proof_runtime/include/python3.12" \
  -framework Foundation -framework Security "$proof_sources/ServiceV2.m" "$proof_sources/PythonBridgeV2.m" \
  "$proof_sources/InferenceProtocolV2.m" "$proof_sources/SourceLeaseAdmission.m" "$proof_sources/VerifiedPayload.m" \
  -o "$proof_service/Contents/MacOS/InferenceService"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.2 -arch arm64 \
  "-DMUESLI_SIGNING_TEAM=\"$proof_team\"" "${proof_picker_flags[@]}" -framework Foundation -framework AppKit "$proof_sources/CurrentProofHost.m" "$proof_sources/InferenceProtocolV2.m" \
  -o "$proof_app/Contents/MacOS/InferenceProof"
# The proof owns its runtime copy; the shared staging payload is never resigned.
ditto "$proof_runtime" "$proof_service/Contents/Resources/python"
ditto "$(dirname "$proof_runtime")/tools" "$proof_service/Contents/Resources/python/tools"
xcrun clang -fobjc-arc -mmacosx-version-min=26.2 -arch arm64 -framework Foundation \
  "$proof_sources/OSVersion.m" -o "$proof_service/Contents/Resources/python/tools/sw_vers"
# Copy the complete current package, replacing only this fresh private copy.
proof_package="$proof_service/Contents/Resources/python/lib/python3.12/site-packages/diarise_transcribe"
rm -rf "$proof_package"
mkdir "$proof_package"
cp "$proof_repo"/backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/*.py "$proof_package/"
mkdir -p "$proof_service/Contents/Resources/models/parakeet-tdt-0.6b-v3"
for proof_asset in config.json model.safetensors; do
  cp "$proof_models/$proof_asset" "$proof_service/Contents/Resources/models/parakeet-tdt-0.6b-v3/$proof_asset"
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
# Validate current declared assets using the copied runtime, and hash the
# actual signed bytes before the service resource seal is created.
"$proof_service/Contents/Resources/python/bin/python3.12" -I -B "$proof_sources/write-payload-manifests.py" "$proof_service/Contents/Resources"
codesign --force --sign "$proof_identity" --options runtime --entitlements "$proof_sources/Service.entitlements" "$proof_service"
# Record exact copied source inputs, separate from the audited installed runtime.
# No source/model paths or contents enter this build record.
python3 "$proof_sources/write-current-build-inputs.py" "$proof_repo" "$proof_output/source-inputs-after.json" "$proof_team" "$proof_picker"
cmp "$proof_app/Contents/Resources/proof-build-inputs.json" "$proof_output/source-inputs-after.json"
python3 "$proof_sources/verify-current-build-inputs.py" "$proof_app/Contents/Resources/proof-build-inputs.json" "$proof_package"
codesign --force --sign "$proof_identity" --options runtime "$proof_app"
codesign --verify --deep --strict --verbose=2 "$proof_app"
echo "$proof_app/Contents/MacOS/InferenceProof"
