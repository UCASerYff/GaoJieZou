#!/usr/bin/env python3
"""Standalone synthetic macOS metadata probe. Python standard library only.

This file does not import the repository, does not scan the working directory,
and does not run recovery tests. It is not a restore tool.

Default (no flag): print not_run and create nothing.
Confirmed run: only with --confirm-standalone-metadata-probe, only when TMPDIR
and HOME are explicit, absolute, non-symlink paths and TMPDIR is outside HOME.
It then creates one new $TMPDIR/rhythm-macos-probe-*.noindex directory and, inside
it only, sets and compares synthetic quarantine, mode, BSD flags, and ACL.
Unsupported or unconfirmed results are SKIP or UNVERIFIED, never PASS.
The directory is not deleted. Nothing under /Applications, Group Containers,
Application Support, Preferences, or the home directory is read.
"""

from __future__ import annotations

import ctypes
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

CONFIRM = "--confirm-standalone-metadata-probe"
PROBE_KIND = "StandaloneSyntheticMacOSMetadataProbe"
SYNTHETIC_QUARANTINE = b"0083;00000000;RhythmSyntheticProbe;00000000"
CAPABILITIES = ("quarantine", "mode", "bsdFlags", "acl")


def emit(payload, code=0):
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return code


def chain_has_symlink(path):
    current = Path(path.anchor)
    for part in Path(path).parts[1:]:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            return "missing"
        if stat.S_ISLNK(info.st_mode):
            return "symlink"
    return None


def validate_roots(tmpdir, home):
    if not isinstance(tmpdir, str) or not tmpdir or not isinstance(home, str) or not home:
        return "tmpdir_or_home_unknown"
    tmp = Path(tmpdir)
    house = Path(home)
    if not tmp.is_absolute() or not house.is_absolute():
        return "tmpdir_or_home_not_absolute"
    for path in (tmp, house):
        problem = chain_has_symlink(path)
        if problem == "symlink":
            return "symlink_path_refused"
        if problem == "missing":
            return "tmpdir_or_home_missing"
    try:
        if not stat.S_ISDIR(tmp.lstat().st_mode) or not stat.S_ISDIR(house.lstat().st_mode):
            return "tmpdir_or_home_not_directory"
    except FileNotFoundError:
        return "tmpdir_or_home_missing"
    if tmp == house or house in tmp.parents or tmp in house.parents:
        return "tmpdir_inside_or_over_home"
    forbidden = ("Applications", "Group Containers", "Application Support", "Preferences", "Library")
    if any(part in forbidden for part in tmp.parts):
        return "tmpdir_in_forbidden_scope"
    return None


def copy_bytes(source, dest):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(source, flags), "rb") as reader:
        data = reader.read()
    out = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(dest, out, 0o600), "wb") as writer:
        writer.write(data)


def probe_mode(archive, restore):
    os.chmod(archive, 0o640, follow_symlinks=False)
    copy_bytes(archive, restore)
    os.chmod(restore, 0o640, follow_symlinks=False)
    left = stat.S_IMODE(os.lstat(archive).st_mode)
    right = stat.S_IMODE(os.lstat(restore).st_mode)
    return "PASS" if left == right == 0o640 else "UNVERIFIED"


def probe_quarantine(archive, restore):
    if not hasattr(os, "setxattr") or not hasattr(os, "getxattr"):
        return "SKIP"
    name = "com.apple.quarantine"
    try:
        os.setxattr(archive, name, SYNTHETIC_QUARANTINE, follow_symlinks=False)
        os.setxattr(restore, name, SYNTHETIC_QUARANTINE, follow_symlinks=False)
        left = os.getxattr(archive, name, follow_symlinks=False)
        right = os.getxattr(restore, name, follow_symlinks=False)
    except OSError:
        return "UNVERIFIED"
    return "PASS" if left == right == SYNTHETIC_QUARANTINE else "UNVERIFIED"


def probe_flags(archive, restore):
    flag = getattr(stat, "UF_NODUMP", None)
    if not hasattr(os, "chflags") or flag is None or not hasattr(os.lstat(archive), "st_flags"):
        return "SKIP"
    try:
        os.chflags(archive, flag, follow_symlinks=False)
        os.chflags(restore, flag, follow_symlinks=False)
        left = os.lstat(archive).st_flags & flag
        right = os.lstat(restore).st_flags & flag
    except (AttributeError, OSError, NotImplementedError):
        return "UNVERIFIED"
    return "PASS" if left == right == flag else "UNVERIFIED"


def probe_acl(archive, restore):
    if sys.platform != "darwin":
        return "SKIP"
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    except OSError:
        return "SKIP"
    for symbol in ("acl_init", "acl_set_file", "acl_get_file", "acl_to_text", "acl_free"):
        if not hasattr(lib, symbol):
            return "SKIP"
    try:
        lib.acl_init.restype = ctypes.c_void_p
        lib.acl_set_file.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
        lib.acl_get_file.restype = ctypes.c_void_p
        lib.acl_to_text.restype = ctypes.c_void_p
        created = lib.acl_init(1)
        if not created:
            return "UNVERIFIED"
        # ACL_TYPE_EXTENDED on Darwin is 0x80. A failed call is not a pass.
        for path in (archive, restore):
            if lib.acl_set_file(os.fsencode(path), 0x80, created) != 0:
                return "UNVERIFIED"
        texts = []
        for path in (archive, restore):
            handle = lib.acl_get_file(os.fsencode(path), 0x80)
            if not handle:
                return "UNVERIFIED"
            texts.append(ctypes.cast(lib.acl_to_text(handle, None), ctypes.c_char_p).value)
        return "PASS" if texts[0] == texts[1] and texts[0] is not None else "UNVERIFIED"
    except (OSError, AttributeError):
        return "UNVERIFIED"


def run_in(created):
    """Compare synthetic archive and restore metadata. Never upgrades a gap to PASS."""
    archive_dir = created / "archive"
    restore_dir = created / "restore"
    archive_dir.mkdir(mode=0o700)
    restore_dir.mkdir(mode=0o700)
    archive = archive_dir / "sample.bin"
    restore = restore_dir / "sample.bin"
    archive.write_bytes(b"synthetic-metadata-not-user-data")
    results = {
        "mode": probe_mode(archive, restore),
        "quarantine": probe_quarantine(archive, restore),
        "bsdFlags": probe_flags(archive, restore),
        "acl": probe_acl(archive, restore),
    }
    for name in CAPABILITIES:
        if results[name] not in ("PASS", "SKIP", "UNVERIFIED"):
            results[name] = "UNVERIFIED"
    results["metadataOverall"] = "PASS" if all(results[name] == "PASS" for name in CAPABILITIES) else "UNVERIFIED"
    return results


def confirm(environ):
    if sys.platform != "darwin":
        return emit({"status": "refused", "code": "macos_probe_requires_darwin", "created": None,
                     "metadataOverall": "NOT_RUN", "realRecoveryCompleted": False,
                     "dependencies": ["python-stdlib"]}, 2)
    reason = validate_roots(environ.get("TMPDIR"), environ.get("HOME"))
    if reason:
        return emit({"status": "refused", "code": reason, "created": None,
                     "metadataOverall": "NOT_RUN", "realRecoveryCompleted": False}, 2)
    parent = Path(environ["TMPDIR"])
    before = parent.lstat()
    created = Path(tempfile.mkdtemp(prefix="rhythm-macos-probe-", suffix=".noindex", dir=parent))
    if parent.lstat().st_ino != before.st_ino or created.is_symlink() or not created.name.startswith(
            "rhythm-macos-probe-") or not created.name.endswith(".noindex"):
        return emit({"status": "refused", "code": "probe_directory_not_isolated", "created": str(created),
                     "deleted": False, "metadataOverall": "NOT_RUN", "realRecoveryCompleted": False}, 2)
    try:
        measured = run_in(created)
    except OSError as error:
        measured = {name: "UNVERIFIED" for name in CAPABILITIES}
        measured["metadataOverall"] = "UNVERIFIED"
        measured["error"] = type(error).__name__
    result = {"status": "probe_finished_directory_retained", "kind": PROBE_KIND, "created": str(created),
              "deleted": False, "appLaunched": False, "locksAcquired": [], "repositoryImports": [],
              "dependencies": ["python-stdlib"], "scannedCwd": False, "recoveryTestRan": False,
              "realRecoveryCompleted": False, "productionReady": False, **measured}
    (created / "RESULT.json").write_text(json.dumps(result, ensure_ascii=False, sort_keys=True) + "\n")
    return emit(result, 0 if measured.get("metadataOverall") in ("PASS", "UNVERIFIED") else 1)


def main(argv, environ=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    environ = os.environ if environ is None else environ
    if argv != [CONFIRM]:
        if CONFIRM not in argv:
            return emit({"status": "not_run", "created": None, "reason": "confirmation_required",
                         "kind": PROBE_KIND, "metadataOverall": "NOT_RUN", "realRecoveryCompleted": False,
                         "dependencies": ["python-stdlib"]})
        return emit({"status": "refused", "code": "probe_arguments_refused", "created": None,
                     "metadataOverall": "NOT_RUN", "realRecoveryCompleted": False}, 2)
    return confirm(environ)


if __name__ == "__main__":
    sys.exit(main(None))
