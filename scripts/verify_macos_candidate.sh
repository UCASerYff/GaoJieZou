#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 || "$(sw_vers -productVersion)" != 15.* ]]; then
    echo 'This verification requires an arm64 macOS 15 host with full Xcode.' >&2
    exit 2
fi

repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 "$repo/scripts/require_build_lease.py"
revision=$(git -C "$repo" rev-parse HEAD)
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
xcodebuild -version
xcrun swiftc --version
printf 'Verifying %s on macOS %s (%s)\n' "$revision" "$(sw_vers -productVersion)" "$(uname -m)"

temporary_base=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
scratch=$(mktemp -d "${temporary_base%/}/rhythm-candidate.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
source_root="$scratch/source.noindex"
mkdir -p -- "$source_root" "$scratch/tmp" "$scratch/data"
git -C "$repo" archive "$revision" | tar -xf - -C "$source_root"
export TMPDIR="$scratch/tmp/"
export GAOJIEZOU_DATA_DIR="$scratch/data"

for regression in workspace_navigation background_focus focus_status; do
    printf '\nRunning %s regression\n' "$regression"
    zsh "$source_root/scripts/test_$regression.sh"
done
printf '\nRunning weekly_review regression\n'
bash "$source_root/scripts/test_weekly_review.sh"

zsh "$source_root/scripts/build.sh" --verify-unsigned
python3 -I - "$source_root/build.verify.noindex/搞节奏.app" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys


def verify_bundle(plist_path, executable_dir, identifier, kind, executable_name):
    with plist_path.open('rb') as plist:
        metadata = plistlib.load(plist)
    assert (metadata['CFBundleIdentifier'], metadata['CFBundlePackageType'], metadata['CFBundleExecutable']) == (
        identifier, kind, executable_name
    ), (plist_path, metadata)
    assert (metadata['CFBundleShortVersionString'], metadata['CFBundleVersion']) == ('4.13', '15'), plist_path
    executable = executable_dir / executable_name
    archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).split()
    assert archs == ['arm64'], (executable, archs)
    bundle_contents = executable_dir if kind == 'FMWK' else executable_dir.parent
    assert not (bundle_contents / '_CodeSignature' / 'CodeResources').exists(), executable
    if kind == 'XPC!':
        assert metadata['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension', plist_path
        links = subprocess.check_output(['xcrun', 'otool', '-L', str(executable)], text=True)
        assert '/WidgetKit.framework/' in links, executable
    print(f'PASS {identifier} {metadata["CFBundleShortVersionString"]} ({metadata["CFBundleVersion"]}) arm64')


contents = Path(sys.argv[1]) / 'Contents'
prefix = 'com.gaojiezou.rhythm'
verify_bundle(contents / 'Info.plist', contents / 'MacOS', prefix, 'APPL', 'GaoJieZou')
frameworks = {
    'Rhythm': '.framework',
    'RhythmHealth': '.integrated.health.framework',
    'RhythmFootprints': '.integrated.footprints.framework',
}
for name, identifier_suffix in frameworks.items():
    version_dir = contents / 'Frameworks' / f'{name}.framework' / 'Versions' / 'A'
    verify_bundle(version_dir / 'Resources' / 'Info.plist', version_dir, prefix + identifier_suffix, 'FMWK', name)

widgets = (
    ('GaoJieZouWidgets', '.widgets', 'GaoJieZouWidgets'),
    ('RhythmHealthWidgets', '.health.widgets', 'GaoJianKangWidgets'),
    ('RhythmFootprintsWidgets', '.footprints.widgets', 'RhythmFootprintsWidgets'),
)
for bundle_name, identifier_suffix, executable_name in widgets:
    widget = contents / 'PlugIns' / f'{bundle_name}.appex' / 'Contents'
    verify_bundle(widget / 'Info.plist', widget / 'MacOS', prefix + identifier_suffix, 'XPC!', executable_name)
PY
