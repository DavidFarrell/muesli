#!/bin/bash
set -euo pipefail
if [[ $# != 6 ]]; then
  echo 'Usage: bash build-picker-proof.sh fresh-output original-proof-app generated-source-folder unselected-control-file signing-identity team-id' >&2
  exit 64
fi
picker_output="$1"
picker_original="$2"
picker_source="$3"
picker_control="$4"
picker_identity="$5"
picker_team="$6"
picker_sources="$(cd "$(dirname "$0")" && pwd)"
[[ ! -e "$picker_output" && -d "$picker_original" && -d "$picker_source" && "$picker_source" == /* && -f "$picker_control" && "$picker_control" == /* ]] || exit 64
[[ "$picker_team" =~ ^[A-Z0-9]{10}$ ]] || exit 64
for picker_value in "$picker_source" "$picker_control"; do
  [[ "$picker_value" != *'"'* && "$picker_value" != *'\'* && "$picker_value" != *$'\n'* ]] || exit 64
done
mkdir "$picker_output"
picker_app="$picker_output/InferenceProof.app"
/bin/cp -cR "$picker_original" "$picker_app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.2 -arch arm64 -framework Foundation -framework AppKit \
  -DMUESLI_PICKER_HOST "-DMUESLI_SIGNING_TEAM=\"$picker_team\"" \
  "-DMUESLI_GENERATED_SOURCE=\"$picker_source\"" "-DMUESLI_GENERATED_CONTROL=\"$picker_control\"" \
  "$picker_sources/ProofHost.m" -o "$picker_app/Contents/MacOS/InferenceProof"
codesign --force --sign "$picker_identity" --options runtime --entitlements "$picker_sources/PickerHost.entitlements" "$picker_app"
codesign --verify --deep --strict "$picker_app"
echo "$picker_app/Contents/MacOS/InferenceProof"
