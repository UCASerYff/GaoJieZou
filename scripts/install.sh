#!/bin/zsh
set -euo pipefail
umask 077
ROOT=${0:A:h:h}
TARGET="/Applications/搞节奏.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TEAM=5G96498KGJ
SOURCE="$ROOT/build.noindex/搞节奏.app"
UNPACKED=0
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")

# This integration candidate must never be installed ahead of the explicit,
# verified authority cutover. A fixture plan cannot authorize a live install.
if [[ "$VERSION" == 4.10 ]]; then
    [[ -n "${GAO_RHYTHM_INTEGRATION_PLAN:-}" && -f "$GAO_RHYTHM_INTEGRATION_PLAN" ]] || { print -u2 '需要本轮真实迁移计划与active权威，拒绝提前安装'; exit 1; }
    python3 "$ROOT/scripts/integrate_sources.py" verify --plan "$GAO_RHYTHM_INTEGRATION_PLAN" --runtime-only
    python3 - "$GAO_RHYTHM_INTEGRATION_PLAN" <<'PYGATE'
import json,sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text())
expected=Path.home()/'Library/Group Containers/5G96498KGJ.com.gaojiezou.rhythm'
assert Path(p['targetGroup']).resolve()==expected.resolve(),'Fixture or foreign target group cannot authorize live installation'
a=json.loads((expected/'Integration/authority.json').read_text())
assert a['schemaVersion']==1 and a['state']=='active' and a['transactionID']==p['transactionID']
assert a['sourceRevisions']==p['sourceRevisions'] and a.get('freezeReceiptSHA256'),'Missing actual cutover receipt'
assert not (expected/'.rhythm-integration-maintenance.json').exists(),'Recovery is incomplete'
PYGATE
fi

# Every expanded staging app has a .noindex ancestor before creation.
ordinary_container() {
    [[ ! -L "$1" ]] || { print -u2 -- "拒绝符号链接容器：$1"; return 1; }
    mkdir -p "$1"
    [[ -d "$1" && ! -L "$1" ]]
}
if [[ -f "$ROOT/dist/GaoJieZou-$VERSION.zip" && -f "$ROOT/dist/GaoJieZou-$VERSION.zip.sha256" ]] || [[ ! -d "$SOURCE" ]]; then
    ordinary_container "$ROOT/.install.noindex"
    SOURCE="$ROOT/.install.noindex/搞节奏.app"
    [[ ! -e "$SOURCE" && ! -L "$SOURCE" ]] || { print -u2 '解包暂存已存在，请先核对其来源'; exit 1; }
    (cd "$ROOT/dist"; shasum -a 256 -c "GaoJieZou-$VERSION.zip.sha256")
    UNPACKED=1
    ditto -x -k "$ROOT/dist/GaoJieZou-$VERSION.zip" "$ROOT/.install.noindex"
fi

verify_bundle() {
    local app="$1" widget="$1/Contents/PlugIns/GaoJieZouWidgets.appex" part
    [[ -d "$app" && ! -L "$app" && -d "$widget" && ! -L "$widget" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.gaojiezou.rhythm ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget/Contents/Info.plist")" == com.gaojiezou.rhythm.widgets ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget/Contents/Info.plist")" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget/Contents/Info.plist")" ]] || return 1
    local source extra expected version number
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
    for source in Health Footprints; do
        extra="$app/Contents/PlugIns/Rhythm${source}Widgets.appex"
        expected="com.gaojiezou.rhythm.${source:l}.widgets"
        [[ -d "$extra" && ! -L "$extra" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extra/Contents/Info.plist")" == "$expected" ]] || return 1
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extra/Contents/Info.plist")" == "$version" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extra/Contents/Info.plist")" == "$number" ]] || return 1
        [[ "$(codesign -dv "$extra" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM" ]] || return 1
        codesign --verify --strict "$extra" || return 1
        [[ -d "$app/Contents/Frameworks/Rhythm${source}.framework" ]] || return 1
        codesign --verify --strict "$app/Contents/Frameworks/Rhythm${source}.framework" || return 1
    done
    codesign --verify --deep --strict "$app" || return 1
    for part in "$app" "$widget"; do
        codesign --verify --strict "$part" || return 1
        [[ "$(codesign -dv "$part" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM" ]] || return 1
    done
}
requirement() {
    local value
    value=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p')
    [[ -n "$value" ]] || return 1
    print -r -- "$value"
}
register_formal() {
    local extension bid
    "$LSREGISTER" -f -R "$TARGET" || return 1
    for extension in "$TARGET"/Contents/PlugIns/*.appex(N); do
        bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension/Contents/Info.plist")
        [[ "$bid" == com.gaojiezou.rhythm.* ]] || return 1
        pluginkit -a "$extension" || return 1
    done
}
unregister_formal_widgets() {
    local extension bid version registration
    for extension in "$TARGET"/Contents/PlugIns/*.appex(N); do
        [[ ! -L "$extension" ]] || return 1
        bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension/Contents/Info.plist") || return 1
        version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension/Contents/Info.plist") || return 1
        case "$bid:${extension:t}" in
            com.gaojiezou.rhythm.widgets:GaoJieZouWidgets.appex|\
            com.gaojiezou.rhythm.health.widgets:RhythmHealthWidgets.appex|\
            com.gaojiezou.rhythm.footprints.widgets:RhythmFootprintsWidgets.appex) ;;
            *) print -u2 '拒绝处理非本应用固定小组件'; return 1 ;;
        esac
        registration=$(formal_widget_registration "$extension" "$bid" "$version") || return 1
        if [[ "$registration" == absent ]]; then
            print -r -- "Already unregistered: $bid"
            continue
        fi
        pluginkit -r "$extension" || return 1
        [[ "$(formal_widget_registration "$extension" "$bid" "$version")" == absent ]] || return 1
    done
}
formal_widget_registration() {
    python3 - "$1" "$2" "$3" <<'PYWIDGETREG'
import pathlib,re,subprocess,sys,uuid
extension,bid,version=sys.argv[1:]
allowed={'com.gaojiezou.rhythm.widgets':'GaoJieZouWidgets.appex',
         'com.gaojiezou.rhythm.health.widgets':'RhythmHealthWidgets.appex',
         'com.gaojiezou.rhythm.footprints.widgets':'RhythmFootprintsWidgets.appex'}
def require(ok):
    if not ok:raise RuntimeError('Formal widget registration is unreadable or changed')
p=pathlib.Path(extension)
require(bid in allowed and p.name==allowed[bid] and version and p.is_absolute() and
        p.is_dir() and all(not q.is_symlink() for q in [p,*p.parents]))
result=subprocess.run(['/usr/bin/pluginkit','-m','-A','-D','-vv','-i',bid],capture_output=True,text=True)
require(result.returncode==0 and not result.stderr.strip())
output=result.stdout
headers=list(re.finditer(r'^\s*([+\-=!?]?)\s*'+re.escape(bid)+r'\(([^)\n]+)\)\s*$',output,re.M))
if not headers:
    require(output.strip() in ('', '(no matches)') or
            re.fullmatch(r'0\s+plug-in(?:\(s\)|s)?',output.strip()) is not None)
    print('absent')
else:
    blocks=[]
    for index,header in enumerate(headers):
        end=headers[index+1].start() if index+1<len(headers) else len(output)
        blocks.append((header,output[header.start():end]))
    matches=[(header,block) for header,block in blocks
             if re.findall(r'^\s*Path = (.+)$',block,re.M)==[extension]]
    require(len(matches)<=1)
    if not matches:
        print('absent')
    else:
        header,block=matches[0]
        identifiers=re.findall(r'^\s*UUID = (.+)$',block,re.M)
        require(header.group(2)==version and len(identifiers)==1 and
                re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',identifiers[0]) is not None and
                uuid.UUID(identifiers[0]).int!=0)
        print('present')
PYWIDGETREG
}
no_main_process() {
    local query_status
    if pgrep -x GaoJieZou >/dev/null; then
        print -u2 '请先正常退出搞节奏'
        return 1
    else
        query_status=$?
        [[ "$query_status" == 1 ]] || { print -u2 '无法可靠读取搞节奏进程状态，拒绝替换'; return 1; }
    fi
}

[[ "${SOURCE:A}" == "$SOURCE" ]] || { print -u2 '拒绝暂存路径中的符号链接'; exit 1; }
verify_bundle "$SOURCE"
SOURCE_HOST_DR=$(requirement "$SOURCE")
SOURCE_WIDGET_DR=$(requirement "$SOURCE/Contents/PlugIns/GaoJieZouWidgets.appex")
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")" ]] || { print -u2 '源码与待安装版本不一致'; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")" ]] || { print -u2 '源码与待安装构建号不一致'; exit 1; }
no_main_process
[[ ! -L "$TARGET" ]] || { print -u2 '拒绝符号链接正式入口'; exit 1; }
HAD_OLD=0
finish_install() {
    local code="$1"
    trap - EXIT INT TERM
    set +e
    if (( code != 0 )); then
        print -u2 '安装未完成；未创建旧程序副本或自动恢复内容，请保留错误信息并停止后续清理'
    fi
    if (( UNPACKED )); then
        if ! rm -rf "$ROOT/.install.noindex/搞节奏.app"; then
            print -u2 '本次解包暂存清理未完成'
            (( code == 0 )) && code=1
        fi
        rmdir "$ROOT/.install.noindex" 2>/dev/null
    fi
    return "$code"
}
trap 'finish_install $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$TARGET" ]]; then
    [[ -d "$TARGET" ]] || { print -u2 '正式入口不是应用目录'; exit 1; }
    verify_bundle "$TARGET"
    HAD_OLD=1
    OLD_HOST_DR=$(requirement "$TARGET")
    OLD_WIDGET_DR=$(requirement "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex")
    [[ "$SOURCE_HOST_DR" == "$OLD_HOST_DR" && "$SOURCE_WIDGET_DR" == "$OLD_WIDGET_DR" ]] || { print -u2 '新旧完整 designated requirement 不一致，拒绝替换'; exit 1; }
fi

# Only the formal application path is registered; user data is never copied.
no_main_process
if (( HAD_OLD )); then
    unregister_formal_widgets
    "$LSREGISTER" -u "$TARGET"
    rm -rf "$TARGET"
fi
ditto "$SOURCE" "$TARGET"
verify_bundle "$TARGET"
[[ "$(requirement "$TARGET")" == "$SOURCE_HOST_DR" && "$(requirement "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex")" == "$SOURCE_WIDGET_DR" ]]
register_formal

# Stop only this app's three installed extension processes; WidgetKit owns restarts.
for widget_name in GaoJieZouWidgets RhythmHealthWidgets RhythmFootprintsWidgets; do
    for widget_pid in ${(f)"$(pgrep -f "^/Applications/搞节奏.app/Contents/PlugIns/${widget_name}.appex/Contents/MacOS/${widget_name}( |$)" || true)"}; do
        [[ "$widget_pid" == <-> ]] && kill -TERM "$widget_pid" 2>/dev/null || true
    done
done
print -r -- "Installed $TARGET; no old-program copy created; user data untouched"
