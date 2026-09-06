#!/bin/bash
set -euo pipefail
source_test_dir="$(cd "$(dirname "$0")" && pwd)"
source_repo_dir="$(cd "$source_test_dir/../../.." && pwd)"
source_build_dir="${1:-$(mktemp -d /private/tmp/muesli-source-access-tests.XXXXXX)}"
mkdir -p "$source_build_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
source_native_flags=(-fobjc-arc -fblocks -fmodules -arch arm64 -mmacosx-version-min=26.2 -Wall -Wextra -Werror "-fmodules-cache-path=$source_build_dir/clang-cache")
xcrun clang "${source_native_flags[@]}" "$source_test_dir/SourceAccessAdmissionTests.m" "$source_repo_dir/release/inference-service/InferenceProtocolV2.m" -framework Foundation -framework AppKit -o "$source_build_dir/source-admission-tests"
"$source_build_dir/source-admission-tests" > "$source_build_dir/native-results.json"
xcrun clang -arch arm64 -mmacosx-version-min=26.2 -Wall -Wextra -Werror "$source_test_dir/SourceOwnerExitFixture.c" -o "$source_build_dir/source-owner-exit-fixture"
codesign --force --sign - --identifier com.paidiaconsulting.MuesliSourceOwnerExitFixture "$source_build_dir/source-owner-exit-fixture"
xcrun clang "${source_native_flags[@]}" -c "$source_test_dir/SourceOwnerEvidence.m" -o "$source_build_dir/SourceOwnerEvidence.o"
xcrun clang "${source_native_flags[@]}" -c "$source_repo_dir/release/inference-service/MuesliNativeProcessObserver.m" -o "$source_build_dir/MuesliNativeProcessObserver.o"
xcrun clang "${source_native_flags[@]}" -c "$source_repo_dir/release/inference-service/InferenceProtocolV2.m" -o "$source_build_dir/InferenceProtocolV2.o"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -default-isolation MainActor -warnings-as-errors -target arm64-apple-macosx26.2 -parse-as-library -D MUESLI_SOURCE_OWNER_TESTING \
    -import-objc-header "$source_test_dir/SourceOwnerTests-Bridging.h" -module-cache-path "$source_build_dir/swift-cache" \
    "$source_repo_dir/release/inference-service/SourceCapabilityOwner.swift" "$source_test_dir/SourceCapabilityOwnerTests.swift" \
    "$source_build_dir/SourceOwnerEvidence.o" "$source_build_dir/MuesliNativeProcessObserver.o" "$source_build_dir/InferenceProtocolV2.o" \
    -framework Foundation -framework Security -o "$source_build_dir/source-owner-tests"
"$source_build_dir/source-owner-tests" "$source_build_dir/source-owner-exit-fixture" > "$source_build_dir/owner-results.json"
python3 - "$source_build_dir" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])
for name in ['native-results.json','owner-results.json']:
 result=json.loads((p/name).read_text())
 print(f'{name}: {sum(x["passed"] for x in result["checks"])}/{len(result["checks"])} passed')
 assert result['passed'], result
print(p)
PY
