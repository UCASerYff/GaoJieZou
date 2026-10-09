#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp/}rhythm-habit-backfill-build.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
SOURCES=(
    AppLanguage AppTheme Models RhythmCatalog RhythmShared RhythmLog
    RhythmPersistence RhythmRealtimeEngine RhythmEstateEngine RhythmNotifications RhythmStore
    SharedSleepStore RhythmSleepSync RhythmCSVExport
)
FILES=()
for SOURCE in $SOURCES; do FILES+=("$ROOT/Sources/$SOURCE.swift"); done
swiftc -swift-version 5 -parse-as-library -D SMOKE_TEST \
    -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$TEST_BUILD/cache" \
    -framework AppKit -framework SwiftUI -framework Combine -framework WidgetKit \
    -framework UserNotifications -lsqlite3 \
    $FILES "$ROOT/Tests/HabitBackfillRegression.swift" \
    -o "$TEST_BUILD/habit-backfill-regression"
"$TEST_BUILD/habit-backfill-regression"
