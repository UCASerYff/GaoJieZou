#!/bin/zsh
set -euo pipefail
umask 077
ROOT=${0:A:h:h}
# Root must separately schedule this narrow regression. Having a free lease or
# executing another authorized test does not authorize this runner by itself.
[[ "${GAO_HOST_INTEGRATION_RESTORE_TEST_GO:-}" == "1" ]] || {
    print -u2 'Explicit Root GO required: GAO_HOST_INTEGRATION_RESTORE_TEST_GO=1'
    exit 1
}
python3 "$ROOT/scripts/require_build_lease.py"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -d "$DEVELOPER_DIR" ]] || { print -u2 'Full Xcode is required'; exit 1; }
OUT="$ROOT/build.noindex/host-integration-restore-regression"
mkdir -p "$OUT/cache"
FIXTURE=$(python3 - <<'PY'
import uuid
print('/private/tmp/rhythm-host-restore-' + str(uuid.uuid4()).upper() + '.noindex')
PY
)
[[ "$FIXTURE" == /private/tmp/rhythm-host-restore-*.noindex && ! -e "$FIXTURE" && ! -L "$FIXTURE" ]]
mkdir -m 700 "$FIXTURE"
trap '[[ "$FIXTURE" == /private/tmp/rhythm-host-restore-*.noindex && -d "$FIXTURE" && ! -L "$FIXTURE" ]] && rm -rf "$FIXTURE"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
# Compile only the real host recovery implementation and its pure dependencies.
# Host/Settings.swift and AppMain.swift are intentionally excluded: the test
# supplies AppDataLocations backed exclusively by our unique fixture directory.
xcrun swiftc -swift-version 5 -parse-as-library -D INTEGRATION_PATH_TEST \
    -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$OUT/cache" \
    -framework Foundation -framework AppKit -framework CryptoKit -lsqlite3 \
    "$ROOT/Integration/Shared/IntegrationAuthority.swift" \
    "$ROOT/Host/DailyBackup.swift" \
    "$ROOT/Host/BackupIntegrity.swift" \
    "$ROOT/Host/AppBackupRestore.swift" \
    "$ROOT/Tests/HostIntegrationRestoreRegression.swift" \
    -o "$OUT/host-integration-restore-regression"
# The binary supplies an in-memory UserDefaults shim and a different isolated
# prefix plus three fixture-path variables for each case. CFPreferences is never
# accessed; a production-domain lookup aborts instead of reaching real settings.
RHYTHM_HOST_RESTORE_FIXTURE_ROOT="$FIXTURE" "$OUT/host-integration-restore-regression"
