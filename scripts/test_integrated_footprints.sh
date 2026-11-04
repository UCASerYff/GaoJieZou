#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
python3 "$ROOT/scripts/require_build_lease.py"
[[ "${RHYTHM_INTEGRATION_TEST_COMPILE_GO:-}" == 1 ]] || { print -u2 'Requires explicit integration fixture compile GO'; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SOURCE="$ROOT/Integrated/Footprints"
OUT="$ROOT/build.noindex/footprints-integration-tests.noindex"
mkdir -p "$OUT/cache"
xcrun swiftc -D INTEGRATION_PATH_TEST -swift-version 5 -parse-as-library -module-cache-path "$OUT/cache" -framework AppKit -framework CryptoKit -lsqlite3 \
 "$ROOT/Integration/Shared/IntegrationAuthority.swift" "$SOURCE/Shared/Models.swift" "$SOURCE/Shared/TrainEngine.swift" \
 "$SOURCE/Shared/Repository.swift" "$SOURCE/Shared/IntegratedStorage.swift" "$SOURCE/Sources/IntegratedPreferences.swift" \
 "$SOURCE/HostSupport/BackupIntegrity.swift" "$SOURCE/HostSupport/DailyBackup.swift" "$SOURCE/HostSupport/AppBackupExport.swift" \
 "$SOURCE/HostSupport/AppBackupRestore.swift" "$SOURCE/Tests/IntegrationCoreRegression.swift" -o "$OUT/footprints-core-regression"
FIXTURE=$(mktemp -d /private/tmp/rhythm-footprints-integration-XXXXXXXX.noindex)
trap 'rm -rf "$FIXTURE"' EXIT
RHYTHM_INTEGRATION_TEST_GROUP="$FIXTURE/group" "$OUT/footprints-core-regression"
