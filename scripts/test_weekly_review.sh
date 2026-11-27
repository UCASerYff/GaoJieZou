#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp/}/rhythm-weekly-review-build.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
SOURCES=(
    AppLanguage AppTheme Models RhythmCatalog RhythmShared RhythmLog
    RhythmPersistence RhythmRealtimeEngine RhythmEstateEngine RhythmNotifications RhythmStore
    SharedSleepStore RhythmSleepSync WeeklyReview
)
FILES=()
for source in "${SOURCES[@]}"; do FILES+=("$ROOT/Sources/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library -D SMOKE_TEST \
    -sdk "$SDK" -target arm64-apple-macosx14.0 -module-cache-path "$TEST_BUILD/cache" \
    -framework AppKit -framework SwiftUI -framework Combine -framework WidgetKit \
    -framework UserNotifications -lsqlite3 \
    "${FILES[@]}" "$ROOT/Tests/WeeklyReviewRegression.swift" -o "$TEST_BUILD/weekly-review-regression"
"$TEST_BUILD/weekly-review-regression"
