#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp/}rhythm-widget-sync-build.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
SOURCES=(
    AppLanguage AppTheme Models RhythmCatalog RhythmShared RhythmLog
    RhythmPersistence RhythmRealtimeEngine RhythmEstateEngine RhythmNotifications RhythmStore
    SharedSleepStore RhythmSleepSync
)
FILES=()
for SOURCE in $SOURCES; do FILES+=("$ROOT/Sources/$SOURCE.swift"); done
swiftc -swift-version 5 -parse-as-library -D WIDGET_SYNC_TEST -D INTEGRATION_PATH_TEST \
    -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$TEST_BUILD/cache" \
    -framework AppKit -framework SwiftUI -framework Combine -framework WidgetKit \
    -framework UserNotifications -framework CryptoKit -lsqlite3 \
    "$ROOT/Integration/Shared/IntegrationAuthority.swift" $FILES "$ROOT/WidgetExtension/WidgetData.swift" "$ROOT/WidgetExtension/WidgetTimeline.swift" \
    "$ROOT/Tests/WidgetSyncRegression.swift" -o "$TEST_BUILD/widget-sync-regression"
"$TEST_BUILD/widget-sync-regression"
