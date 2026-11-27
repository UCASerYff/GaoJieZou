#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/rhythm-focus-status.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_BUILD/cache" \
    "$ROOT/Host/FocusStatusPresentation.swift" "$ROOT/Tests/FocusStatusPresentationRegression.swift" \
    -o "$TEST_BUILD/focus-status-regression"
"$TEST_BUILD/focus-status-regression"
