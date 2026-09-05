#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
backend_root="$project_root/backend/fast_mac_transcribe_diarise_local_models_only"
output_root="${1:-$(mktemp -d "${TMPDIR:-/tmp}/muesli-verify.XXXXXX")}"
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
if [[ "$(uname -m)" != arm64 || "$(uname -s)" != Darwin ]]; then
  echo 'Verification requires an Apple Silicon Mac.' >&2; exit 1
fi
if [[ "$(uv --version | cut -d ' ' -f 2)" != 0.11.3 ]]; then
  echo 'Verification requires uv 0.11.3.' >&2; exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode_26.6.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
  else
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
xcodebuild -version > "$output_root/xcode-version.txt"
if ! head -1 "$output_root/xcode-version.txt" | /usr/bin/grep -qx 'Xcode 26.6'; then
  echo 'Verification requires Xcode 26.6; set DEVELOPER_DIR explicitly.' >&2; exit 1
fi
shasum -a 256 "$backend_root/uv.lock" > "$output_root/lock-before.txt"
export UV_PROJECT_ENVIRONMENT="$output_root/runtime"
if [[ -e "$UV_PROJECT_ENVIRONMENT" ]]; then
  echo 'Choose a fresh output folder; its runtime must not already exist.' >&2; exit 1
fi
uv sync --project "$backend_root" --locked --extra dev --python 3.12.13 > "$output_root/bootstrap.log" 2>&1
shasum -a 256 "$backend_root/uv.lock" > "$output_root/lock-after.txt"
cmp "$output_root/lock-before.txt" "$output_root/lock-after.txt"
export PYTHONPATH="$backend_root/src"
export MUESLI_ALLOW_MODEL_DOWNLOADS=0 HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
"$UV_PROJECT_ENVIRONMENT/bin/python" -m pytest "$backend_root/tests" -q -p no:cacheprovider > "$output_root/python-tests.log" 2>&1
xcodebuild test -project "$project_root/MuesliApp/MuesliApp.xcodeproj" -scheme MuesliApp \
  -destination 'platform=macOS' -derivedDataPath "$output_root/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= > "$output_root/swift-tests.log" 2>&1
xcodebuild build -project "$project_root/MuesliApp/MuesliApp.xcodeproj" -scheme MuesliApp \
  -configuration Release -derivedDataPath "$output_root/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= > "$output_root/release-build.log" 2>&1
"$UV_PROJECT_ENVIRONMENT/bin/python" "$project_root/scripts/runtime-manifest.py" \
  --project "$project_root" --out "$output_root/runtime-manifest.json"
echo "Verification passed. Evidence: $output_root"
echo 'This verifies source/tests/ad-hoc compilation, not signed distribution or real hardware capture.'
