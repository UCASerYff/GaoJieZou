#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
python3 "$ROOT/scripts/require_build_lease.py"
[[ "${RHYTHM_INTEGRATION_TEST_COMPILE_GO:-}" == 1 ]] || { print -u2 'Requires explicit integration fixture compile GO'; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT="$ROOT/build.noindex/integration-authority-tests.noindex"
mkdir -p "$OUT/cache"
xcrun swiftc -swift-version 5 -parse-as-library -D INTEGRATION_PATH_TEST -module-cache-path "$OUT/cache" -lsqlite3 \
  "$ROOT/Integration/Shared/IntegrationAuthority.swift" "$ROOT/Sources/SharedSleepStore.swift" \
  "$ROOT/Tests/IntegrationAuthorityRegression.swift" -o "$OUT/authority-tests"
"$OUT/authority-tests"
