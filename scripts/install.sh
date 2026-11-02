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

# Every expanded staging/rollback app has a .noindex ancestor before creation.
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
    "$LSREGISTER" -f -R "$TARGET" && pluginkit -a "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex"
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
ordinary_container "$ROOT/rollback.noindex"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)-$$
WORK="$ROOT/rollback.noindex/verify-$STAMP.noindex"
mkdir -m 700 "$WORK"
VERIFIED="$WORK/搞节奏.app"
ARCHIVE=""
RECEIPT=""
HAD_OLD=0
ARCHIVE_READY=0
REPLACEMENT_STARTED=0
INSTALL_OK=0

receipt_status() {
    [[ -n "$RECEIPT" && -f "$RECEIPT" ]] || return 0
    python3 - "$RECEIPT" "$1" <<'PY'
import datetime,json,os,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text());d['lastStatus']=sys.argv[2];d['lastStatusAtUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat()
tmp=p.with_name(p.name+'.status.tmp')
with tmp.open('x') as f:json.dump(d,f,ensure_ascii=False,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
os.replace(tmp,p)
PY
}
finish_install() {
    local code="$1" recovered=0
    trap - EXIT INT TERM
    set +e
    if (( code != 0 && REPLACEMENT_STARTED )); then
        "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1
        pluginkit -r "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex" >/dev/null 2>&1
        if [[ -L "$TARGET" ]]; then
            print -u2 '正式路径意外变为符号链接，停止自动恢复；压缩回滚备份保留'
        elif (( HAD_OLD && ARCHIVE_READY )); then
            # The verified expansion remains under .noindex; never register it.
            if (cd "${ARCHIVE:h}" && shasum -a 256 -c "${ARCHIVE:t}.sha256") && verify_bundle "$VERIFIED" \
                && [[ "$(requirement "$VERIFIED")" == "$OLD_HOST_DR" ]] \
                && [[ "$(requirement "$VERIFIED/Contents/PlugIns/GaoJieZouWidgets.appex")" == "$OLD_WIDGET_DR" ]]; then
                rm -rf "$TARGET"
                if ditto "$VERIFIED" "$TARGET" && verify_bundle "$TARGET" \
                    && [[ "$(requirement "$TARGET")" == "$OLD_HOST_DR" ]] \
                    && [[ "$(requirement "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex")" == "$OLD_WIDGET_DR" ]] \
                    && register_formal; then
                    recovered=1
                    receipt_status rolled-back-after-install-failure
                    print -u2 '安装未完成，旧正式程序已从核验过的回滚内容恢复；用户资料未改动'
                fi
            fi
            if (( ! recovered )); then receipt_status partial-install-manual-recovery-required; print -u2 -- "自动恢复未完成，保留归档、收据和 $WORK"; fi
        elif (( ! HAD_OLD )); then
            rm -rf "$TARGET"
            recovered=1
        fi
    fi
    if (( INSTALL_OK || ! REPLACEMENT_STARTED || recovered )); then
        if ! rm -rf "$WORK"; then
            print -u2 -- "核验暂存清理未完成：$WORK"
            (( code == 0 )) && code=1
        fi
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
    OLD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")
    OLD_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist")
    ARCHIVE="$ROOT/rollback.noindex/GaoJieZou-$OLD_VERSION-build$OLD_BUILD-$STAMP.app.zip"
    RECEIPT="$ARCHIVE.restore.json"
    [[ ! -e "$ARCHIVE" && ! -e "$ARCHIVE.sha256" && ! -e "$RECEIPT" ]] || exit 1
    ditto -c -k --keepParent --norsrc --noextattr "$TARGET" "$ARCHIVE"
    python3 - "$ARCHIVE" <<'PY'
import hashlib,sys,zipfile
from pathlib import Path,PurePosixPath
p=Path(sys.argv[1])
with zipfile.ZipFile(p) as z:
    if not z.infolist() or z.testzip() is not None:raise RuntimeError('Rollback ZIP integrity failed')
    for item in z.infolist():
        # ditto may store UTF-8 filename bytes without ZIP's UTF-8 flag.
        name=item.filename if item.flag_bits & 0x800 else item.filename.encode('cp437').decode('utf-8')
        q=PurePosixPath(name)
        if q.is_absolute() or '..' in q.parts or q.parts[0]!='搞节奏.app':raise RuntimeError('Unexpected rollback member path')
h=hashlib.sha256(p.read_bytes()).hexdigest()
with Path(str(p)+'.sha256').open('x') as f:f.write(h+'  '+p.name+'\n')
PY
    ditto -x -k "$ARCHIVE" "$WORK"
    verify_bundle "$VERIFIED"
    [[ "$(requirement "$VERIFIED")" == "$OLD_HOST_DR" && "$(requirement "$VERIFIED/Contents/PlugIns/GaoJieZouWidgets.appex")" == "$OLD_WIDGET_DR" ]] || exit 1
    # Do not follow framework aliases: diff -r can skip them as directory loops.
    python3 - "$TARGET" "$VERIFIED" <<'PY'
import hashlib,os,stat,sys
from pathlib import Path
def inventory(root):
    result={}
    for parent,dirs,files in os.walk(root,followlinks=False):
        for name in dirs+files:
            p=Path(parent)/name; s=p.lstat(); key=str(p.relative_to(root))
            if stat.S_ISLNK(s.st_mode):result[key]=('link',os.readlink(p))
            elif stat.S_ISDIR(s.st_mode):result[key]=('directory',)
            elif stat.S_ISREG(s.st_mode):result[key]=('file',hashlib.sha256(p.read_bytes()).hexdigest(),s.st_mode&0o111)
            else:raise RuntimeError('Unexpected bundle file type')
    return result
if inventory(Path(sys.argv[1]))!=inventory(Path(sys.argv[2])):raise RuntimeError('Rollback file/symlink content mismatch')
PY
    python3 - "$TARGET" "$VERIFIED" "$ARCHIVE" "$RECEIPT" "$SOURCE" "$OLD_HOST_DR" "$OLD_WIDGET_DR" "$SOURCE_HOST_DR" "$SOURCE_WIDGET_DR" <<'PY'
import datetime,hashlib,json,os,plistlib,sys
from pathlib import Path
old,expanded,archive,receipt,source=map(Path,sys.argv[1:6])
info=lambda app:plistlib.loads((app/'Contents/Info.plist').read_bytes())
i,j=info(old),info(source)
d={'format':1,'createdAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'formalPath':str(old),'bundleID':i['CFBundleIdentifier'],'team':'5G96498KGJ','oldVersion':i['CFBundleShortVersionString'],'oldBuild':i['CFBundleVersion'],'oldHostDesignatedRequirement':sys.argv[6],'oldWidgetDesignatedRequirement':sys.argv[7],'newVersion':j['CFBundleShortVersionString'],'newBuild':j['CFBundleVersion'],'newHostDesignatedRequirement':sys.argv[8],'newWidgetDesignatedRequirement':sys.argv[9],'archive':str(archive),'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'archiveCRCVerified':True,'temporaryVerifiedExpansion':str(expanded),'roundTripFilesSymlinksAndExecutableBitsEqual':True,'lastStatus':'rollback-verified-before-replacement','noUserDataTouched':True,'recovery':'Verify archive SHA; expand only inside an existing .noindex container; deep/strict verify host and appex plus both full designated requirements; restore only formalPath and register only that host/appex. Never launch or rewrite user data.'}
with receipt.open('x') as f:json.dump(d,f,ensure_ascii=False,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
PY
    ARCHIVE_READY=1
fi

# No backup, temporary app or restored app is registered outside the formal path.
no_main_process
REPLACEMENT_STARTED=1
if (( HAD_OLD )); then
    pluginkit -r "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex"
    "$LSREGISTER" -u "$TARGET"
    rm -rf "$TARGET"
fi
ditto "$SOURCE" "$TARGET"
verify_bundle "$TARGET"
[[ "$(requirement "$TARGET")" == "$SOURCE_HOST_DR" && "$(requirement "$TARGET/Contents/PlugIns/GaoJieZouWidgets.appex")" == "$SOURCE_WIDGET_DR" ]]
register_formal
receipt_status installed-new-version-without-launch
INSTALL_OK=1
# Only this installed extension's process is stopped; WidgetKit owns any restart.
for widget_pid in ${(f)"$(pgrep -f '^/Applications/搞节奏.app/Contents/PlugIns/GaoJieZouWidgets.appex/Contents/MacOS/GaoJieZouWidgets( |$)' || true)"}; do
    [[ "$widget_pid" == <-> ]] && kill -TERM "$widget_pid" 2>/dev/null || true
done
print -r -- "Installed $TARGET; rollback archive retained: ${ARCHIVE:-none (first install)}"
