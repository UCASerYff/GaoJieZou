#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
python3 "$ROOT/scripts/require_build_lease.py"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex"
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
mkdir -p "$BUILD/cache"
integrated_targets=(Health Footprints)
if (( $# )); then
    [[ $# == 1 && ( "$1" == Health || "$1" == Footprints ) ]] || { print -u2 'Expected Health or Footprints'; exit 2; }
    integrated_targets=("$1")
fi
for source in "${integrated_targets[@]}"; do
    NAME="Rhythm$source"
    SOURCE="$ROOT/Integrated/$source"
    FRAMEWORK="$BUILD/Frameworks/$NAME.framework"
    VERSION="$FRAMEWORK/Versions/A"
    [[ -f "$SOURCE/Module.swift" && -f "$ROOT/Integration/Shared/IntegrationAuthority.swift" ]]
    rm -rf "$FRAMEWORK"
    mkdir -p "$VERSION/Modules/$NAME.swiftmodule" "$VERSION/Resources"
    SOURCES=("$SOURCE"/Sources/*.swift "$SOURCE"/Shared/*.swift(N) "$SOURCE"/GameWorld/*.swift(N) "$SOURCE"/HostSupport/*.swift(N) "$SOURCE/Module.swift" "$ROOT/Integration/Shared/IntegrationAuthority.swift")
    swiftc -swift-version 5 -parse-as-library -O -emit-library -emit-module \
      -module-name "$NAME" -sdk "$SDK" -target arm64-apple-macosx14.0 \
      -module-cache-path "$BUILD/cache" -load-plugin-library "$MACROS" \
      -framework SwiftUI -framework AppKit -framework WidgetKit -framework Charts \
      -framework CryptoKit -framework AppIntents -framework SceneKit -framework WebKit \
      -framework UniformTypeIdentifiers -framework Security -framework PDFKit \
      -framework QuickLookUI -framework UserNotifications -framework Combine \
      -framework CoreText -framework ImageIO -lsqlite3 \
      -Xlinker -install_name -Xlinker "@rpath/$NAME.framework/Versions/A/$NAME" \
      $SOURCES -emit-module-path "$VERSION/Modules/$NAME.swiftmodule/arm64-apple-macos.swiftmodule" -o "$VERSION/$NAME"
    ditto "$SOURCE/Resources" "$VERSION/Resources"
    if [[ -d "$SOURCE/GameWorld/Resources" ]]; then ditto "$SOURCE/GameWorld/Resources" "$VERSION/Resources"; fi
    python3 - "$ROOT/Info.plist" "$NAME" "$VERSION/Resources/Info.plist" <<'PY'
import plistlib,sys
app=plistlib.load(open(sys.argv[1],'rb'))
d={'CFBundleIdentifier':app['CFBundleIdentifier']+'.integrated.'+sys.argv[2][6:].lower()+'.framework','CFBundleName':sys.argv[2],'CFBundleExecutable':sys.argv[2],'CFBundlePackageType':'FMWK','CFBundleShortVersionString':app['CFBundleShortVersionString'],'CFBundleVersion':app['CFBundleVersion']}
plistlib.dump(d,open(sys.argv[3],'wb'))
PY
    ln -s A "$FRAMEWORK/Versions/Current"
    ln -s "Versions/Current/$NAME" "$FRAMEWORK/$NAME"
    ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
    ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
    codesign --force --sign - "$FRAMEWORK"
done
