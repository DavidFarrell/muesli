#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="${1:-$(mktemp -d /private/tmp/muesli-native-observer-tests.XXXXXX)}"
mkdir -p "$output_directory"
clang -fobjc-arc -fmodules -fmodules-cache-path="$output_directory/modules" -Wall -Wextra -Werror \
  -Dkqueue=MuesliTestKqueue -c "$task_root/MuesliNativeProcessObserver.m" -o "$output_directory/observer.o"
clang -fobjc-arc -fmodules -fmodules-cache-path="$output_directory/modules" -Wall -Wextra -Werror \
  -framework Foundation -framework Security "$output_directory/observer.o" \
  "$task_root/tests/NativeProcessObserverTests.m" -o "$output_directory/NativeProcessObserverTests"
codesign --force --sign - --identifier com.paidiaconsulting.muesli.native-observer-tests \
  "$output_directory/NativeProcessObserverTests"
swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors \
  -typecheck -module-cache-path "$output_directory/swift-modules" \
  -import-objc-header "$task_root/MuesliNativeProcessObserver.h" "$task_root/tests/NativeProcessObserverImport.swift"
test_status=0
"$output_directory/NativeProcessObserverTests" > "$output_directory/result.json" || test_status=$?
cat "$output_directory/result.json"
exit "$test_status"
