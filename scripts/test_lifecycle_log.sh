#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp/}rhythm-lifecycle-log-build.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT INT TERM
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -swift-version 5 -parse-as-library -Onone \
    -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$TEST_BUILD/cache" \
    "$ROOT/Host/AppLifecycleLog.swift" "$ROOT/Tests/AppLifecycleLogRegression.swift" \
    -o "$TEST_BUILD/lifecycle-log-regression"
"$TEST_BUILD/lifecycle-log-regression"
