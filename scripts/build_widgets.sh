#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
python3 "$ROOT/scripts/require_build_lease.py"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex"
mkdir -p "$BUILD/PlugIns" "$BUILD/widget-cache"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")
cp "$ROOT/Sources/RhythmShared.swift" "$ROOT/WidgetExtension/RhythmShared.swift"
xcodebuild -quiet -project "$ROOT/WidgetExtension/GaoJieZouWidgets.xcodeproj" -target GaoJieZouWidgets -configuration Release CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$BUILD/widget-products" OBJROOT="$BUILD/widget-objects" CLANG_MODULE_CACHE_PATH="$BUILD/widget-cache" build
ditto "$BUILD/widget-products/Release/GaoJieZouWidgets.appex" "$BUILD/PlugIns/GaoJieZouWidgets.appex"
cp "$ROOT/WidgetExtension/Info.plist" "$BUILD/PlugIns/GaoJieZouWidgets.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUILD/PlugIns/GaoJieZouWidgets.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "$BUILD/PlugIns/GaoJieZouWidgets.appex/Contents/Info.plist"

# Each migrated widget keeps its own target, while the one host owns all three.
for source in Health Footprints; do
    if [[ "$source" == Health ]]; then target=GaoJianKangWidgets; else target=RhythmFootprintsWidgets; fi
    folder="$ROOT/Integrated/$source/Widgets"
    xcodebuild -quiet -project "$folder/$target.xcodeproj" -target "$target" -configuration Release CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$BUILD/integrated-$source-widget-products" OBJROOT="$BUILD/integrated-$source-widget-objects" CLANG_MODULE_CACHE_PATH="$BUILD/widget-cache" build
    product="$BUILD/PlugIns/Rhythm${source}Widgets.appex"
    ditto "$BUILD/integrated-$source-widget-products/Release/$target.appex" "$product"
    cp "$folder/Info.plist" "$product/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$product/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "$product/Contents/Info.plist"
done
