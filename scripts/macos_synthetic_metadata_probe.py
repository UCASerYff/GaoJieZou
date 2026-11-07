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


# Darwin getxattr/setxattr take a position argument. The os module helpers are a different ABI.
XATTR_NOFOLLOW = 0x0001
# Apple's well-known everyone UUID. It is not a user account.
EVERYONE_UUID_TEXT = "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C"
EVERYONE_UUID = bytes((
    0xAB, 0xCD, 0xEF, 0xAB, 0xCD, 0xEF, 0xAB, 0xCD,
    0xEF, 0xAB, 0xCD, 0xEF, 0x00, 0x00, 0x00, 0x0C,
))
ACL_TYPE_EXTENDED = 0x80
ACL_EXTENDED_ALLOW = 1
ACL_READ_DATA = 1 << 1


def acl_text_is_synthetic_everyone_read(text):
    """True only for a non-empty everyone-allow-read entry without write or delete."""
    if not isinstance(text, (bytes, str)) or not text:
        return False
    lowered = text.decode("utf-8", "replace").lower() if isinstance(text, bytes) else text.lower()
    if EVERYONE_UUID_TEXT.lower() not in lowered and "everyone" not in lowered:
        return False
    if "allow" not in lowered or "read" not in lowered:
        return False
    for forbidden in ("write", "delete", "append", "chown"):
        if forbidden in lowered:
            return False
    return True


def _darwin_xattr():
    if sys.platform != "darwin":
        return None
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    except OSError:
        return None
    lib.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    lib.setxattr.restype = ctypes.c_int
    lib.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    lib.getxattr.restype = ctypes.c_ssize_t
    return lib


def _xattr_roundtrip(lib, path, name, value):
    raw = ctypes.create_string_buffer(value)
    if lib.setxattr(os.fsencode(path), name.encode(), raw, len(value), 0, XATTR_NOFOLLOW) != 0:
        return None
    size = lib.getxattr(os.fsencode(path), name.encode(), None, 0, 0, XATTR_NOFOLLOW)
    if size < 0 or size != len(value):
        return None
    buf = ctypes.create_string_buffer(size)
    if lib.getxattr(os.fsencode(path), name.encode(), buf, size, 0, XATTR_NOFOLLOW) != size:
        return None
    return buf.raw[:size]


def probe_quarantine(archive, restore):
    """Capability check only. The os module xattr helpers are not used."""
    lib = _darwin_xattr()
    if lib is None:
        return "SKIP"
    try:
        left = _xattr_roundtrip(lib, archive, "com.apple.quarantine", SYNTHETIC_QUARANTINE)
        right = _xattr_roundtrip(lib, restore, "com.apple.quarantine", SYNTHETIC_QUARANTINE)
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


def _bind_acl(lib):
    names = ("acl_init", "acl_create_entry", "acl_set_tag_type", "acl_set_qualifier",
             "acl_get_permset", "acl_add_perm", "acl_set_file", "acl_get_file",
             "acl_to_text", "acl_free")
    if any(not hasattr(lib, name) for name in names):
        return False
    lib.acl_init.argtypes = [ctypes.c_int]
    lib.acl_init.restype = ctypes.c_void_p
    lib.acl_create_entry.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_create_entry.restype = ctypes.c_int
    lib.acl_set_tag_type.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    lib.acl_set_tag_type.restype = ctypes.c_int
    lib.acl_set_qualifier.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.acl_set_qualifier.restype = ctypes.c_int
    lib.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_get_permset.restype = ctypes.c_int
    lib.acl_add_perm.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    lib.acl_add_perm.restype = ctypes.c_int
    lib.acl_set_file.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
    lib.acl_set_file.restype = ctypes.c_int
    lib.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
    lib.acl_get_file.restype = ctypes.c_void_p
    lib.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.acl_to_text.restype = ctypes.c_void_p
    lib.acl_free.argtypes = [ctypes.c_void_p]
    lib.acl_free.restype = ctypes.c_int
    return True


def _synthetic_everyone_read_acl(lib):
    """everyone allow read. No write, delete, append, or owner change."""
    acl = lib.acl_init(1)
    if not acl:
        return None
    slot = ctypes.c_void_p(acl)
    entry = ctypes.c_void_p()
    if lib.acl_create_entry(ctypes.byref(slot), ctypes.byref(entry)) != 0:
        return None
    if lib.acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) != 0:
        return None
    qualifier = ctypes.create_string_buffer(EVERYONE_UUID)
    if lib.acl_set_qualifier(entry, qualifier) != 0:
        return None
    permset = ctypes.c_void_p()
    if lib.acl_get_permset(entry, ctypes.byref(permset)) != 0:
        return None
    if lib.acl_add_perm(permset, ACL_READ_DATA) != 0:
        return None
    return slot.value


def _acl_text(lib, path):
    handle = lib.acl_get_file(os.fsencode(path), ACL_TYPE_EXTENDED)
    if not handle:
        return None
    raw = lib.acl_to_text(handle, None)
    if not raw:
        lib.acl_free(handle)
        return None
    try:
        return ctypes.cast(raw, ctypes.c_char_p).value
    finally:
        lib.acl_free(raw)
        lib.acl_free(handle)


def probe_acl(archive, restore):
    """Non-empty everyone-read sample. An empty acl_init is not a pass."""
    if sys.platform != "darwin":
        return "SKIP"
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    except OSError:
        return "SKIP"
    if not _bind_acl(lib):
        return "SKIP"
    try:
        acl = _synthetic_everyone_read_acl(lib)
        if acl is None:
            return "UNVERIFIED"
        for path in (archive, restore):
            if lib.acl_set_file(os.fsencode(path), ACL_TYPE_EXTENDED, acl) != 0:
                return "UNVERIFIED"
        left, right = _acl_text(lib, archive), _acl_text(lib, restore)
    except (OSError, AttributeError):
        return "UNVERIFIED"
    if not acl_text_is_synthetic_everyone_read(left) or left != right:
        return "UNVERIFIED"
    return "PASS"


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
