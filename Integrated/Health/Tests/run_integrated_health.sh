#!/bin/zsh
set -euo pipefail
# Caller must already hold its assigned Master/build_lease.py lease. No auto acquire.
[[ "${RHYTHM_HEALTH_TEST_COMPILE_GO:-}" == "1" ]] || { print -u2 "需要根协调明确编译GO及已持有本轮build lease"; exit 2; }
HERE=${0:A:h:h}
TARGET=${HERE:h:h}
python3 "$TARGET/scripts/require_build_lease.py"
BUILD="$TARGET/build.noindex/health-integration-regression.noindex"
mkdir -p "$BUILD/cache"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -swift-version 5 -parse-as-library -D INTEGRATION_PATH_TEST \
  -sdk "$SDK" -target arm64-apple-macosx14.0 -module-cache-path "$BUILD/cache" \
  -framework AppKit -framework WidgetKit -framework CryptoKit -lsqlite3 \
  "$TARGET/Integration/Shared/IntegrationAuthority.swift" \
  "$HERE"/Shared/*.swift "$HERE/Sources/SharedSleepStore.swift" \
  "$HERE/Sources/HealthSleepImport.swift" \
  "$HERE/HostSupport/BackupIntegrity.swift" "$HERE/HostSupport/DailyBackup.swift" \
  "$HERE/HostSupport/RestorePreferences.swift" "$HERE/HostSupport/DataLocations.swift" \
  "$HERE/HostSupport/AppBackupExport.swift" "$HERE/HostSupport/AppBackupRestore.swift" \
  "$HERE/Tests/IntegratedHealthRegression.swift" -o "$BUILD/IntegratedHealthRegression"
"$BUILD/IntegratedHealthRegression"
