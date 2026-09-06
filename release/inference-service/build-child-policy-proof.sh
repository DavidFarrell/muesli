#!/bin/bash
set -euo pipefail
if [[ $# != 5 ]]; then
  echo 'Usage: bash build-child-policy-proof.sh fresh-output real-proof-app generated-source-file unbookmarked-control-file signing-identity' >&2
  exit 64
fi
probe_output="$1"
probe_original="$2"
probe_source="$3"
probe_control="$4"
probe_identity="$5"
probe_sources="$(cd "$(dirname "$0")" && pwd)"
[[ ! -e "$probe_output" && -d "$probe_original" && -f "$probe_source" && "$probe_source" == /* ]] || exit 64
[[ -f "$probe_control" && "$probe_control" == /* ]] || exit 64
# A compiler string literal must not interpret arbitrary source-path syntax.
[[ "$probe_source" != *'"'* && "$probe_source" != *'\'* && "$probe_source" != *$'\n'* ]] || exit 64
[[ "$probe_control" != *'"'* && "$probe_control" != *'\'* && "$probe_control" != *$'\n'* ]] || exit 64
mkdir "$probe_output"
probe_app="$probe_output/InferenceProof.app"
/bin/cp -cR "$probe_original" "$probe_app"
probe_service="$probe_app/Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=26.2 -arch arm64 -framework Foundation \
  "-DMUESLI_PROBE_SOURCE_FILE=\"$probe_source\"" "-DMUESLI_PROBE_CONTROL_FILE=\"$probe_control\"" "$probe_sources/ChildPolicyProbe.m" \
  -o "$probe_service/Contents/Resources/python/tools/ffmpeg"
codesign --force --sign "$probe_identity" --identifier ffmpeg --options runtime \
  --entitlements "$probe_sources/Child.entitlements" "$probe_service/Contents/Resources/python/tools/ffmpeg"
codesign --force --sign "$probe_identity" --options runtime --entitlements "$probe_sources/Service.entitlements" "$probe_service"
codesign --force --sign "$probe_identity" --options runtime "$probe_app"
codesign --verify --deep --strict "$probe_app"
echo "$probe_app/Contents/MacOS/InferenceProof"
