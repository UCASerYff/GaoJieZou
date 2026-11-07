#!/usr/bin/env python3
"""Whitelist export and isolated restore for the Rhythm receiver.

This tool copies an explicit whitelist into a new private package and can
expand that package only into a directory whose name ends with ``.noindex``.
It does not write the live App Group, Application Support, preferences, or
keychain, and it does not apply, activate, roll back, or delete source trees.

Synthetic fixtures and unit tests are the supported callers in this phase.
A successful run is not a completed recovery of a real install: the receipt
keeps ``realRecoveryCompleted`` false and ``rootMaintenanceEvidence`` at
``NOT_EXECUTED`` because the Root writer-pause interface is not in this repo.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote

SCHEMA = 1
KIND = "ReceiverWhitelistRecovery"
GROUP_ID = "5G96498KGJ.com.gaojiezou.rhythm"
DOMAINS = (
    "com.gaojiezou.rhythm",
    "com.gaojiezou.rhythm.Rhythm",
    "com.gaojiezou.rhythm.integrated.health",
    "com.gaojiezou.rhythm.integrated.footprints",
)
CANONICAL = {
    "Integration/Modules/Health/health.sqlite": "health",
    "Integration/Modules/Footprints/footprints.sqlite": "footprints",
    "Integration/SharedSleep/sleep-records.sqlite": "sharedSleep",
}
SIDECARS = ("-wal", "-shm", "-journal")
GROUP_FILES = {
    "library.json": "rhythm_widget_mirror",
    "widget-snapshot.json": "rhythm_widget_snapshot",
    "widget-snapshot.previous.json": "rhythm_widget_snapshot_previous",
}
REQUIRED_GROUP_FILES = ("library.json",)
APP_SUPPORT_EXACT = {
    "library.json": "rhythm_library",
    "library.json.read-only": "rhythm_library_read_only_marker",
    "library.json.widget-pending": "rhythm_widget_pending",
    "library.json.tmp": "rhythm_library_temporary",
}
CORRUPTED_LIBRARY = re.compile(r"library\.corrupted-\d{8}-\d{6}\.json\Z")
TX_RE = re.compile(r"[a-zA-Z0-9_-]{1,128}\Z")
PAYLOAD_RE = re.compile(r"Payload-[0-9a-f]{16}\Z")
MOVE_RE = re.compile(
    r"(Modules-Health|Modules-Footprints|SharedSleep|SourceArchives)\.(intent|observed)\.json\Z")
MOVE_RAW = re.compile(r"^/rootProvenance/rawBase64\Z|^/changes/\d+/(source|native)/rawBase64\Z")
META_RAW = re.compile(
    r"^/changes/\d+/(source|native)/rawBase64\Z|^/quarantinePreservation/(source|before|after)/rawBase64\Z")
JSON_LIMIT = 32 * 1024 * 1024
MOVE_OWNERS = {
    "Modules-Health": "source_health",
    "Modules-Footprints": "source_footprints",
    "SharedSleep": "mixed_shared_sleep",
    "SourceArchives": "mixed_source_archives",
}
# Specification copied from the 2026-11-05 preparation note. Not an execution proof.
PRODUCTION_PLAN_FILE_SHA256 = "333685220a4be4e773f9b10f8c1c6e904b363d10799a79489b413758346599e6"
PRODUCTION_TRANSACTION_ID = "RootRhythm41011-20261104-03"
# Bundle IDs visible in this repository. Listing them is not a process check.
EXTERNAL_GATE_WRITERS = frozenset({
    "com.gaoseries.GaoJianKang",
    "com.gaoseries.GaoJianKang.widgets",
    "com.gaoseries.GaoZuJi",
    "com.gaoseries.GaoZuJi.widgets",
    "com.gaojiezou.rhythm",
    "com.gaojiezou.rhythm.widgets",
    "com.gaojiezou.rhythm.health.widgets",
    "com.gaojiezou.rhythm.footprints.widgets",
})
GATE_FIELDS = frozenset({
    "schemaVersion", "kind", "role", "rootLockIntegrated", "method", "scope",
    "assertedPausedBundleIDs", "assertedAt", "validUntil",
})
ROOT_FIELD_ORDER = (
    "status",
    "captureAt",
    "restoreCheckAt",
    "rootMaintenanceEvidence",
    "freshCurrentBackup",
    "whitelistAndExclusionManifestSHA256",
    "authoritySHA256",
    "sameActiveTransactionVerified",
    "productionPlanByteHashVerified",
    "originalTransactionReceiptSHA256",
    "payloadMetadataPolicy",
    "actualArchiveTreeSHA256",
    "isolatedRestoreTargetIdentity",
    "actualArchiveToRestoreMetadataExact",
    "fourPreferenceDomainsPresenceAndValuesVerified",
    "threeCurrentDatabasesConsistent",
    "attachmentsAndGameProgressVerified",
    "sharedSleepSeedTombstoneRequestRewardDedupVerified",
    "receiverSourceArchivesRhythmAndAbsencesPreservedOrPreciselyRecoverable",
    "currentReadersCompatible",
    "runtimeOnlyCompatibleWithUnchangedRootPlanAndReceipt",
    "pureSourceRawExcludedFromRecoverablePackage",
    "reMigrationPerformed",
    "reActivationPerformed",
    "activeBusinessRolledBack",
)


class RecoveryError(Exception):
    def __init__(self, code, detail=None):
        self.code = code
        self.detail = detail
        super().__init__(code if detail is None else code + ":" + str(detail))


def fail(code, detail=None):
    raise RecoveryError(code, detail)


def load_sibling(name):
    path = Path(__file__).resolve().parent / name
    spec = importlib.util.spec_from_file_location(name.replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def parse_json(data):
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                fail("duplicate_json_key")
            result[key] = value
        return result

    def invalid(_):
        fail("nonfinite_json_number")

    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)
    except RecoveryError:
        raise
    except (ValueError, UnicodeError, TypeError):
        fail("invalid_json")


def now():
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc).isoformat()


def root_actual_current_recovery_fields():
    """Initial values from the preparation note. This phase cannot advance them."""
    fields = {name: None for name in ROOT_FIELD_ORDER}
    fields["status"] = "NOT_EXECUTED"
    fields["reMigrationPerformed"] = False
    fields["reActivationPerformed"] = False
    fields["activeBusinessRolledBack"] = False
    return fields


def seal_root_fields(fields):
    if not isinstance(fields, dict) or tuple(fields) != ROOT_FIELD_ORDER and set(fields) != set(ROOT_FIELD_ORDER):
        fail("root_receipt_fields_incomplete")
    if len(fields) != 25:
        fail("root_receipt_fields_incomplete")
    expected = root_actual_current_recovery_fields()
    for name in ROOT_FIELD_ORDER:
        if fields.get(name) is True:
            fail("root_field_prefilled_true", name)
        if fields.get(name) != expected[name]:
            fail("root_field_not_at_preparation_value", name)
    return {name: fields[name] for name in ROOT_FIELD_ORDER}


def preparation_contract():
    return {
        "schemaVersion": 1,
        "kind": "ControlledCurrentReceiverRecoveryPreparation",
        "app": "搞节奏",
        "role": "specification_not_execution_proof",
        "transactionID": PRODUCTION_TRANSACTION_ID,
        "productionPlanRelative": "RootCutover-20261104-03.noindex/migration-plan.json",
        "productionPlanFileSHA256": PRODUCTION_PLAN_FILE_SHA256,
        "runtimeVerifyEntry": "scripts/integrate_sources.py verify --plan <unchanged actual production plan> --runtime-only",
        "hostRestoreEntry": "Host/AppBackupRestore.swift prepare -> schedule -> next-launch applyPending",
        "executeAllowed": False,
        "sourceRetirementAuthorizedByThisNote": False,
        "existingCurrentWhitelistExecutorFound": False,
        "actualCurrentRestoreExecuted": False,
        "citedIdentityEvidence": {
            "programZIP_SHA256": "fda4f5d9…5b41e3",
            "hostMachO_SHA256": "532af63f…7a81e",
            "sourceCommit": "8c839144fe0a58a62f70bcaf3a04f1982aae8dff",
            "sourceZIP_SHA256": "91ad6747…8c190b0",
            "rootRouteReceipt_SHA256": "6f1b5d75…1736",
            "truncatedHashesAreNotFullValues": True,
            "routePassIsNotCurrentRestorePass": True,
        },
        "readOnlyCapture": {
            "implemented": True,
            "defaultEnabled": False,
            "entry": "capture",
            "productionReady": False,
            "rootLockIntegrated": False,
            "activeWriteProtection": "remains_closed",
            "liveSourceRead": "only_explicit_capture_paths_plus_external_maintenance_gate",
            "historicalNoteFoundAnExecutor": False,
        },
    }


def load_maintenance_gate(path, group, app_support, preferences_dir, output):
    """Caller attestation only. A confirmed string is not a writer pause."""
    import datetime as dt
    data = read_file(path)
    value = parse_json(data)
    if not isinstance(value, dict) or set(value) != GATE_FIELDS:
        fail("unknown_maintenance_gate_field")
    if value.get("schemaVersion") != 1 or value.get("kind") != "ExternalMaintenanceGate":
        fail("maintenance_gate_kind_rejected")
    if value.get("role") != "caller_attestation_pending_root_integration":
        fail("maintenance_gate_role_rejected")
    if value.get("method") != "external_attestation_not_a_process_check":
        fail("maintenance_gate_method_rejected")
    if value.get("rootLockIntegrated") is not False:
        fail("root_lock_claim_rejected")
    writers = value.get("assertedPausedBundleIDs")
    if not isinstance(writers, list) or set(writers) != EXTERNAL_GATE_WRITERS or len(writers) != len(set(writers)):
        fail("maintenance_writer_set_rejected")
    scope = value.get("scope")
    expected = {"group": str(logical_path(group)), "appSupport": str(logical_path(app_support)),
                "preferencesDir": str(logical_path(preferences_dir)), "output": str(logical_path(output))}
    if not isinstance(scope, dict) or set(scope) != set(expected) or any(scope.get(key) != item for key, item in expected.items()):
        fail("maintenance_scope_mismatch")

    def parsed(text):
        if not isinstance(text, str):
            fail("maintenance_gate_time_invalid")
        try:
            moment = dt.datetime.fromisoformat(text)
        except ValueError:
            fail("maintenance_gate_time_invalid")
        if moment.tzinfo is None:
            fail("maintenance_gate_time_invalid")
        return moment

    start, end = parsed(value.get("assertedAt")), parsed(value.get("validUntil"))
    current = dt.datetime.now(dt.timezone.utc)
    if not start <= current <= end or end <= start:
        fail("maintenance_gate_expired")
    return {"sha256": sha(data), "bytes": data, "value": value}


def production_plan_was_verified(path):
    """None when the caller did not pass a file. Mismatch fails closed."""
    if path is None:
        return None
    if sha(read_file(path)) != PRODUCTION_PLAN_FILE_SHA256:
        fail("production_plan_sha_mismatch")
    return True


def seal_preparation(value):
    expected = preparation_contract()
    if value.get("productionPlanFileSHA256") != PRODUCTION_PLAN_FILE_SHA256:
        fail("production_plan_specification_changed")
    if value.get("transactionID") != PRODUCTION_TRANSACTION_ID:
        fail("production_transaction_specification_changed")
    for key in ("executeAllowed", "sourceRetirementAuthorizedByThisNote",
                "existingCurrentWhitelistExecutorFound", "actualCurrentRestoreExecuted"):
        if value.get(key) is not False:
            fail("preparation_gate_flipped", key)
    capture = value.get("readOnlyCapture") or {}
    if capture.get("implemented") is not True or capture.get("defaultEnabled") is not False:
        fail("read_only_capture_contract_changed")
    if capture.get("productionReady") is not False or capture.get("rootLockIntegrated") is not False:
        fail("read_only_capture_contract_changed")
    if capture.get("activeWriteProtection") != "remains_closed":
        fail("read_only_capture_contract_changed")
    if value.get("role") != expected["role"]:
        fail("preparation_role_changed")
    return value


def live_roots(home):
    return (
        home / "Library/Group Containers" / GROUP_ID,
        home / "Library/Application Support/GaoSeries",
        home / "Library/Preferences",
        Path("/Applications"),
    )


def logical_path(path):
    """Absolute path without resolving symlinks. resolve() would hide a swap."""
    text = os.path.abspath(os.fspath(path))
    return Path(text)


def within(path, parent):
    try:
        logical_path(path).relative_to(logical_path(parent))
        return True
    except ValueError:
        return False


def lstat_existing(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def assert_no_symlink_chain(path):
    current = Path(path.anchor)
    saw_missing = False
    for part in logical_path(path).parts[1:]:
        if part in ("", ".", "..") or "\0" in part:
            fail("invalid_path")
        current = current / part
        info = lstat_existing(current)
        if info is None:
            saw_missing = True
            continue
        if saw_missing:
            fail("path_component_reappeared", part)
        if stat.S_ISLNK(info.st_mode):
            fail("symlink_path_refused", part)
    return current


def open_directory_nofollow(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        fail("directory_open_refused")
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        os.close(fd)
        fail("required_directory_missing")
    return fd, (info.st_dev, info.st_ino)


def mkdir_at(parent_fd, name):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mkdirat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.mkdirat.restype = ctypes.c_int
    if libc.mkdirat(parent_fd, os.fsencode(name), 0o700) != 0:
        err = ctypes.get_errno()
        if err == errno.EEXIST:
            fail("partial_output_exists")
        fail("staging_mkdir_failed", errno.errorcode.get(err, "errno"))


def identity_of(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        fail("symlink_refused", path.name)
    kind = "directory" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else None
    if kind is None:
        fail("unsupported_file_type")
    return (kind, info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, stat.S_IMODE(info.st_mode))


def directory_names(path):
    names = []
    try:
        iterator = os.scandir(path)
    except OSError:
        fail("unreadable_directory")
    with iterator as listing:
        for entry in listing:
            info = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                fail("symlink_refused", entry.name)
            names.append(entry.name)
    return tuple(sorted(names))


def refuse_live(path, home=None):
    home = Path.home() if home is None else home
    for root in live_roots(home):
        if within(path, root):
            fail("live_data_root_refused", root.name)


def guard_path(value, exists, directory):
    if not isinstance(value, (str, Path)):
        fail("invalid_path")
    text = os.fspath(value)
    if not text or "\0" in text or ".." in Path(text).parts or "." in Path(text).parts:
        fail("invalid_path")
    path = Path(text)
    if not path.is_absolute():
        fail("absolute_path_required")
    assert_no_symlink_chain(path)
    info = lstat_existing(path)
    if exists:
        if info is None:
            fail("required_path_missing")
        if stat.S_ISLNK(info.st_mode):
            fail("symlink_path_refused")
        if directory and not stat.S_ISDIR(info.st_mode):
            fail("required_directory_missing")
        if not directory and not stat.S_ISREG(info.st_mode):
            fail("required_file_missing")
    elif info is not None:
        fail("output_exists")
    return logical_path(path)


def read_file(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags), "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            fail("unsupported_file_type")
        data = handle.read()
        after = os.fstat(handle.fileno())
        if (info.st_ino, info.st_size, info.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            fail("source_changed_during_read")
    return data


def file_sha(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    digest = hashlib.sha256()
    with os.fdopen(os.open(path, flags), "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            fail("unsupported_file_type")
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
        after = os.fstat(handle.fileno())
        if (info.st_ino, info.st_size, info.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            fail("source_changed_during_read")
    return digest.hexdigest()


def lstat_kind(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        fail("symlink_refused", path.name)
    if stat.S_ISDIR(info.st_mode):
        return "directory", info
    if stat.S_ISREG(info.st_mode):
        if info.st_nlink != 1:
            fail("hardlink_refused")
        return "file", info
    fail("unsupported_file_type")


def check_relative(rel):
    if rel == "":
        return
    parts = rel.split("/")
    if any(part in ("", ".", "..") or "\0" in part for part in parts):
        fail("unsafe_relative_path", rel)


def walk(root):
    directories, files = [], []

    def visit(base):
        try:
            iterator = os.scandir(base)
        except OSError:
            fail("unreadable_directory")
        with iterator as listing:
            entries = sorted(listing, key=lambda item: item.name)
        for entry in entries:
            path = Path(entry.path)
            rel = path.relative_to(root).as_posix()
            check_relative(rel)
            info = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                fail("symlink_refused", rel)
            if stat.S_ISDIR(info.st_mode):
                directories.append(rel)
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    fail("hardlink_refused", rel)
                files.append(rel)
            else:
                fail("unsupported_file_type", rel)

    kind, _ = lstat_kind(root)
    if kind != "directory":
        fail("required_directory_missing")
    visit(root)
    return directories, files


def raw_pointers(value, prefix=""):
    found = []
    if isinstance(value, dict):
        for key, child in value.items():
            pointer = prefix + "/" + key
            if key == "rawBase64":
                found.append(pointer)
            else:
                found.extend(raw_pointers(child, pointer))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(raw_pointers(child, prefix + "/" + str(index)))
    return found


def load_json_file(path):
    data = read_file(path)
    if len(data) > JSON_LIMIT:
        fail("json_too_large_to_classify")
    return data, parse_json(data)


_CAPTURE_MODE = False
_FORCE_XATTR_BACKEND = None
_XATTR_NOFOLLOW = 0x0001


def xattr_backend_name():
    """Darwin uses the 6-argument libSystem calls. os.setxattr is not required."""
    if _FORCE_XATTR_BACKEND:
        return _FORCE_XATTR_BACKEND
    if sys.platform == "darwin":
        return "darwin-ctypes"
    if hasattr(os, "listxattr") and hasattr(os, "getxattr") and hasattr(os, "setxattr"):
        return "os"
    return "missing"


def _darwin_xattr_lib():
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    lib.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    lib.listxattr.restype = ctypes.c_ssize_t
    lib.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    lib.getxattr.restype = ctypes.c_ssize_t
    lib.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    lib.setxattr.restype = ctypes.c_int
    return lib


def list_xattr_bytes(path):
    """Return {name: bytes} or None when the backend cannot read them."""
    kind = xattr_backend_name()
    if kind == "missing":
        return None
    if kind == "os":
        try:
            return {name: os.getxattr(path, name, follow_symlinks=False)
                    for name in os.listxattr(path, follow_symlinks=False)}
        except OSError:
            fail("xattr_read_failed")
    try:
        lib = _darwin_xattr_lib()
    except OSError:
        return None
    encoded = os.fsencode(path)
    size = lib.listxattr(encoded, None, 0, _XATTR_NOFOLLOW)
    if size < 0:
        return None
    buf = ctypes.create_string_buffer(max(size, 1))
    if lib.listxattr(encoded, buf, size, _XATTR_NOFOLLOW) != size:
        fail("xattr_read_failed")
    found = {}
    for name in [item for item in buf.raw[:size].split(b"\0") if item]:
        length = lib.getxattr(encoded, name, None, 0, 0, _XATTR_NOFOLLOW)
        if length < 0:
            fail("xattr_read_failed")
        value = ctypes.create_string_buffer(max(length, 1))
        if lib.getxattr(encoded, name, value, length, 0, _XATTR_NOFOLLOW) != length:
            fail("xattr_read_failed")
        found[os.fsdecode(name)] = value.raw[:length]
    return found


def set_xattr_bytes(path, name, value):
    kind = xattr_backend_name()
    if kind == "os":
        os.setxattr(path, name, value, follow_symlinks=False)
        return
    if kind != "darwin-ctypes":
        raise OSError("xattr backend missing")
    lib = _darwin_xattr_lib()
    raw = ctypes.create_string_buffer(value)
    if lib.setxattr(os.fsencode(path), os.fsencode(name), raw, len(value), 0, _XATTR_NOFOLLOW) != 0:
        raise OSError(ctypes.get_errno(), "setxattr")


def metadata_of(path):
    kind, info = lstat_kind(path)
    xattr_names = {}
    found = list_xattr_bytes(path)
    xattr_status = "UNVERIFIED" if found is None else "READ"
    if found is not None:
        xattr_names = {name: sha(value) for name, value in found.items()}
    flags = getattr(info, "st_flags", None)
    return {
        "type": "file" if kind == "file" else "directory",
        "mode": stat.S_IMODE(info.st_mode),
        "mtimeNs": info.st_mtime_ns,
        "size": info.st_size if kind == "file" else None,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "sha256": file_sha(path) if kind == "file" else None,
        "xattrs": xattr_names,
        "xattrStatus": xattr_status,
        "bsdFlags": flags if flags is not None else "UNVERIFIED",
        "acl": "UNVERIFIED" if sys.platform != "darwin" else "UNVERIFIED_NOT_CAPTURED",
    }


def annotate_quarantine(policy, notes):
    preserved = any("com.apple.quarantine" in note.get("xattrsPreserved", []) for note in notes)
    skipped = any("com.apple.quarantine" in note.get("xattrsSkipped", []) for note in notes)
    policy = dict(policy)
    policy["quarantineAttributesObserved"] = bool(preserved or skipped)
    if preserved and not skipped and sys.platform == "darwin":
        policy["macosQuarantineFidelity"] = "VERIFIED"
    else:
        policy["macosQuarantineFidelity"] = "UNVERIFIED"
        if sys.platform != "darwin":
            policy["appleMetadata"] = "SKIP"
    return policy


def platform_policy():
    darwin = sys.platform == "darwin"
    return {
        "schemaVersion": SCHEMA,
        "kind": "ReceiverPayloadMetadataPolicy",
        "platform": "darwin" if darwin else "non_darwin",
        "compared": ["type", "mode", "mtimeNs", "size", "sha256", "preservedXattrs"],
        "macosQuarantineFidelity": "VERIFIED" if darwin else "UNVERIFIED",
        "appleMetadata": "CAPTURED" if darwin else "SKIP",
        # This phase records st_flags when the platform exposes them, but it does
        # not call chflags or restore ACLs. Matching package-to-sandbox flags
        # are not macOS quarantine-flag fidelity.
        "bsdFlags": "UNVERIFIED",
        "acl": "UNVERIFIED",
        "allowedDifferences": [{
            "id": "sqlite_wal_folded_into_snapshot",
            "appliesTo": "source_to_package_only",
            "paths": sorted(CANONICAL),
            "effect": "The three current databases are checkpointed with the SQLite backup API. "
                      "Existing -wal/-shm/-journal sidecars stay out of the package; logical row "
                      "digests must match. Package-to-isolated-restore remains byte-exact.",
        }],
        "rejectedDifferences": [
            "symlink_umask_exemption", "quarantine_removal", "bsd_flag_downgrade",
            "uid_gid_rewrite", "mtime_drift", "copy_whole_tree_then_delete",
        ],
        "note": "Linux or other non-macOS runs must not be cited as macOS quarantine, ACL, or BSD-flag fidelity.",
    }


def copy_xattrs(source, target):
    """Copy source xattrs onto the destination only. The source is not modified."""
    found = list_xattr_bytes(source)
    if found is None:
        if _CAPTURE_MODE:
            fail("metadata_backend_unavailable")
        return {}, [], "UNVERIFIED"
    preserved, skipped = {}, []
    for name, raw in sorted(found.items()):
        try:
            set_xattr_bytes(target, name, raw)
            readback = (list_xattr_bytes(target) or {}).get(name)
        except OSError:
            skipped.append(name)
            continue
        if readback != raw:
            fail("xattr_readback_mismatch", name)
        preserved[name] = sha(raw)
    return preserved, skipped, "READ"


def copy_bsd_flags(source, target):
    """Set destination flags to the source value. Never changes the source."""
    info = source.lstat()
    flags = getattr(info, "st_flags", None)
    if not hasattr(os, "chflags") or flags is None:
        return "UNVERIFIED"
    try:
        os.chflags(target, flags, follow_symlinks=False)
        readback = getattr(os.lstat(target), "st_flags", None)
    except (AttributeError, OSError, NotImplementedError):
        return "UNVERIFIED"
    if readback is None or (readback & flags) != flags:
        fail("flags_lowered_or_not_preserved")
    return "PRESERVED" if readback == flags else "UNVERIFIED"


def acl_structure_equal(left, right):
    """Exact ACE equality. This does not special-case the everyone sample."""
    if not isinstance(left, list) or not isinstance(right, list) or len(left) != len(right):
        return False
    for first, second in zip(left, right):
        if first.get("tag") != second.get("tag"):
            return False
        if first.get("qualifier") != second.get("qualifier"):
            return False
        if tuple(first.get("perms") or ()) != tuple(second.get("perms") or ()):
            return False
    return True


def copy_acl(source, target):
    """Copy an existing ACL byte-for-structure. Absence is not a fidelity pass."""
    if sys.platform != "darwin":
        return "UNVERIFIED"
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        lib.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
        lib.acl_get_file.restype = ctypes.c_void_p
        lib.acl_set_file.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
        lib.acl_set_file.restype = ctypes.c_int
        lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
        lib.acl_get_entry.restype = ctypes.c_int
        lib.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
        lib.acl_get_tag_type.restype = ctypes.c_int
        lib.acl_get_qualifier.argtypes = [ctypes.c_void_p]
        lib.acl_get_qualifier.restype = ctypes.c_void_p
        lib.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        lib.acl_get_permset.restype = ctypes.c_int
        lib.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        lib.acl_get_perm_np.restype = ctypes.c_int
        lib.acl_free.argtypes = [ctypes.c_void_p]
        lib.acl_free.restype = ctypes.c_int
    except OSError:
        return "UNVERIFIED"
    if not hasattr(lib, "acl_get_entry"):
        return "UNVERIFIED"

    def entries_of(path):
        handle = lib.acl_get_file(os.fsencode(path), 0x80)
        if not handle:
            return None if ctypes.get_errno() not in (getattr(errno, "ENOENT", 2), getattr(errno, "ENOATTR", 93)) else []
        found = []
        entry = ctypes.c_void_p()
        entry_id = 0
        try:
            while len(found) < 64:
                if lib.acl_get_entry(handle, entry_id, ctypes.byref(entry)) != 0:
                    break
                tag = ctypes.c_uint()
                lib.acl_get_tag_type(entry, ctypes.byref(tag))
                qualifier = lib.acl_get_qualifier(entry)
                raw = b""
                if qualifier:
                    try:
                        raw = ctypes.string_at(qualifier, 16)
                    finally:
                        lib.acl_free(qualifier)
                permset = ctypes.c_void_p()
                bits = []
                if lib.acl_get_permset(entry, ctypes.byref(permset)) == 0:
                    for bit in range(1, 15):
                        if lib.acl_get_perm_np(permset, 1 << bit) == 1:
                            bits.append(1 << bit)
                found.append({"tag": tag.value, "qualifier": raw, "perms": tuple(bits)})
                entry_id = -1
        finally:
            lib.acl_free(handle)
        return found

    source_entries = entries_of(source)
    if source_entries is None:
        return "UNVERIFIED"
    if not source_entries:
        return "ABSENT"
    handle = lib.acl_get_file(os.fsencode(source), 0x80)
    if not handle or lib.acl_set_file(os.fsencode(target), 0x80, handle) != 0:
        fail("metadata_not_preserved", "acl")
    lib.acl_free(handle)
    if not acl_structure_equal(source_entries, entries_of(target)):
        fail("metadata_not_preserved", "acl")
    return "PRESERVED"


def apply_destination_metadata(source, target):
    preserved, skipped, status = copy_xattrs(source, target)
    require_preserved_xattrs(skipped)
    return {"xattrsPreserved": sorted(preserved), "xattrDigests": preserved, "xattrsSkipped": skipped,
            "xattrStatus": status, "bsdFlags": copy_bsd_flags(source, target), "acl": copy_acl(source, target)}


def require_preserved_xattrs(skipped):
    """A present attribute that cannot be copied fails. It is not recorded as preserved."""
    for name in skipped:
        if name.startswith("com.apple.") and sys.platform != "darwin" and not _CAPTURE_MODE:
            continue
        fail("metadata_not_preserved", name)


def write_bytes(path, data, mode):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, mode), "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def snapshot_database(source, dest, scratch_dir):
    snapshot_database.opened = getattr(snapshot_database, "opened", [])
    scratch = scratch_dir / source.name
    sidecars = []
    for suffix in ("", *SIDECARS):
        item = Path(str(source) + suffix)
        if not item.exists() and not item.is_symlink():
            continue
        if item.is_symlink() or not item.is_file():
            fail("unsafe_database_sidecar", suffix or "main")
        before_identity = identity_of(item)
        target = Path(str(scratch) + suffix)
        write_bytes(target, read_file(item), 0o600)
        if identity_of(item) != before_identity:
            fail("source_database_changed_during_snapshot")
        if suffix:
            sidecars.append(suffix)
    before = file_sha(source)
    uri = "file:" + quote(str(scratch), safe="/") + "?mode=ro"
    if str(source) in uri or scratch.resolve() == source.resolve():
        fail("sqlite_opened_source")
    snapshot_database.opened.append(uri)
    with contextlib.closing(sqlite3.connect(uri, uri=True, timeout=10)) as reader:
        reader.execute("BEGIN")
        if reader.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            fail("sqlite_integrity_failed")
        if reader.execute("PRAGMA quick_check").fetchone() != ("ok",):
            fail("sqlite_integrity_failed")
        summary = sql_summary(reader)
        dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with contextlib.closing(sqlite3.connect(dest)) as writer:
            reader.backup(writer)
            if writer.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
                fail("sqlite_snapshot_not_self_contained")
            writer.commit()
    if file_sha(source) != before:
        fail("source_database_changed_during_snapshot")
    for suffix in SIDECARS:
        extra = Path(str(dest) + suffix)
        if extra.exists() or extra.is_symlink():
            if extra.is_symlink() or not within(extra, dest.parent):
                fail("unexpected_snapshot_sidecar")
            extra.unlink()
    with contextlib.closing(sqlite3.connect("file:" + quote(str(dest), safe="/") + "?mode=ro&immutable=1",
                                            uri=True)) as check:
        if check.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            fail("sqlite_snapshot_integrity_failed")
        if sql_summary(check) != summary:
            fail("sqlite_snapshot_logical_mismatch")
    return summary, sidecars


def sql_summary(connection):
    objects = connection.execute(
        "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    tables = {}
    for kind, name, _, _ in objects:
        if kind != "table":
            continue
        quoted = '"' + name.replace('"', '""') + '"'
        rows = []
        for row in connection.execute("SELECT * FROM " + quoted):
            rows.append(canonical([_cell(value) for value in row]).decode("utf-8"))
        tables[name] = {"count": len(rows), "rowsSHA256": sha(canonical(sorted(rows)))}
    return {"userVersion": connection.execute("PRAGMA user_version").fetchone()[0],
            "schemaSHA256": sha(canonical(objects)), "tables": tables}


def _cell(value):
    if isinstance(value, bytes):
        return {"blobSHA256": sha(value), "bytes": len(value)}
    if isinstance(value, float) and not (value == value and value not in (float("inf"), float("-inf"))):
        fail("nonfinite_database_value")
    return value


def decision(rel, active):
    check_relative(rel)
    if rel == ".rhythm-integration-maintenance.json":
        fail("source_maintenance_in_progress", rel)
    if rel in ("Integration/health-restore-in-progress.json",
               "Integration/footprints-restore-in-progress.json"):
        fail("module_restore_in_progress", rel)
    if rel == ".rhythm-integration-writers.lock":
        return "exclude", "coordination_lock_not_acquired"
    if rel in GROUP_FILES:
        return "include", GROUP_FILES[rel]
    if rel == "Integration":
        return "include", "integration_root"
    if rel == "Integration/authority.json":
        return "include", "authority"
    if rel == "Integration/.migration.lock":
        return "exclude", "migration_lock_not_acquired"
    if rel == "Integration/Modules" or rel.startswith("Integration/Modules/"):
        return business_decision(rel, "current_module_business")
    if rel == "Integration/SharedSleep" or rel.startswith("Integration/SharedSleep/"):
        return business_decision(rel, "current_shared_sleep")
    if rel in ("Integration/SourceArchives", "Integration/SourceArchives/Rhythm",
               "Integration/SourceArchives/Rhythm/library.json",
               "Integration/SourceArchives/explicit-absences.json"):
        return "include", "receiver_archive"
    if rel.startswith("Integration/SourceArchives/Rhythm/"):
        fail("unclassified_rhythm_archive_entry", rel)
    if rel == "Integration/SourceArchives/Health" or rel.startswith("Integration/SourceArchives/Health/"):
        return "exclude", "pure_source_archive_health"
    if rel == "Integration/SourceArchives/Footprints" or rel.startswith("Integration/SourceArchives/Footprints/"):
        return "exclude", "pure_source_archive_footprints"
    if rel.startswith("Integration/SourceArchives/"):
        fail("unclassified_source_archive_entry", rel)
    if rel == "Integration/Transactions.noindex":
        return "include", "transaction_parent"
    if rel.startswith("Integration/Transactions.noindex/"):
        return transaction_decision(rel, active)
    if rel.startswith("Integration/"):
        fail("unclassified_integration_entry", rel)
    fail("unclassified_group_entry", rel)


def business_decision(rel, reason):
    parts = rel.split("/")
    if "NativeMetadata.noindex" in parts:
        fail("source_metadata_escrow_inside_business_tree", rel)
    for database in CANONICAL:
        if any(rel == database + suffix for suffix in SIDECARS):
            return "exclude", "sqlite_wal_folded_into_snapshot"
    return "include", reason


def transaction_decision(rel, active):
    rest = rel[len("Integration/Transactions.noindex/"):]
    parts = rest.split("/")
    tx = parts[0]
    if TX_RE.fullmatch(tx) is None:
        fail("invalid_transaction_directory", tx)
    sub = parts[1:]
    active_tx = tx == active
    if not sub:
        return ("include", "active_transaction_directory") if active_tx else ("exclude", "foreign_transaction")
    if len(sub) == 1 and sub[0] in ("owner.json", "receipt.json"):
        if active_tx:
            return "include", "active_" + sub[0]
        return "exclude", "foreign_transaction_record"
    if PAYLOAD_RE.fullmatch(sub[0]):
        return "exclude", "staged_payload"
    if sub[0] == "NativeMoves.noindex":
        if len(sub) == 1 or (len(sub) == 2 and MOVE_RE.fullmatch(sub[1])):
            return "exclude", "native_move_escrow"
        fail("unclassified_native_move", rel)
    fail("unclassified_transaction_entry", rel)


def support_decision(rel):
    check_relative(rel)
    if rel in APP_SUPPORT_EXACT:
        return "include", APP_SUPPORT_EXACT[rel]
    if CORRUPTED_LIBRARY.fullmatch(rel):
        return "include", "rhythm_library_quarantine_copy"
    parts = rel.split("/")
    # Host quarantine of imported module restore jobs lives in the Rhythm
    # support tree. It is current receiver state, not a source archive.
    if parts[0] == "IntegratedRecovery" and (len(parts) == 1 or parts[1] in ("Health", "Footprints")):
        return "include", "receiver_integrated_recovery_quarantine"
    if parts[0] == "IntegratedRecovery":
        fail("unclassified_application_support_entry", rel)
    fail("unclassified_application_support_entry", rel)


def payload_leaf_reason(inside, data, live_rhythm, live_absence):
    check_relative(inside)
    if inside == "SourceArchives/Health" or inside.startswith("SourceArchives/Health/"):
        return "payload_pure_source_health"
    if inside == "SourceArchives/Footprints" or inside.startswith("SourceArchives/Footprints/"):
        return "payload_pure_source_footprints"
    if inside == "SourceArchives/Rhythm/library.json":
        if data != live_rhythm:
            fail("staged_rhythm_archive_diverges_from_live")
        return "payload_rhythm_archive_duplicate_of_live"
    if inside == "SourceArchives/explicit-absences.json":
        if data != live_absence:
            fail("staged_absence_file_diverges_from_live")
        return "payload_absence_duplicate_of_live"
    if inside.startswith("SourceArchives/Rhythm/"):
        fail("unclassified_payload_rhythm_entry", inside)
    if (inside in ("Modules", "SharedSleep", "SourceArchives", "SourceArchives/Rhythm")
            or inside.startswith("Modules/") or inside.startswith("SharedSleep/")
            or inside.startswith("SourceArchives/")):
        if "NativeMetadata.noindex" in inside.split("/"):
            fail("unclassified_payload_leaf", inside)
        return "payload_staged_component_not_current_business"
    fail("unclassified_payload_leaf", inside)


def classify_escrow_json(path, pattern, owner):
    data, parsed = load_json_file(path)
    pointers = raw_pointers(parsed)
    for pointer in pointers:
        if pattern.fullmatch(pointer) is None:
            fail("rawbase64_ownership_unresolved", pointer)
    return {"sha256": sha(data), "bytes": len(data), "owner": owner,
            "rawBase64Pointers": pointers, "rawValuesStored": False}


def business_raw_count(path, reason):
    if path.suffix != ".json":
        return 0
    data, parsed = load_json_file(path)
    pointers = raw_pointers(parsed)
    if not pointers:
        return 0
    if path.name == "receipt.json":
        fail("immutable_receipt_contains_rawbase64")
    if path.name == "explicit-absences.json":
        fail("absence_file_contains_rawbase64")
    if reason == "receiver_integrated_recovery_quarantine":
        fail("rawbase64_ownership_unresolved", path.name)
    blocked = {"authority", "active_owner.json", "receiver_archive"}
    if reason in blocked and path.name != "library.json":
        fail("immutable_record_contains_rawbase64", path.name)
    return len(pointers)


def require_bytes_stable(path, previous):
    if file_sha(path) != previous:
        fail("source_changed_during_read")


def read_authority(group, migration):
    path = group / "Integration/authority.json"
    if not path.is_file() or path.is_symlink():
        fail("required_authority_missing")
    data = read_file(path)
    if len(data) > 1_048_576:
        fail("authority_too_large")
    value = parse_json(data)
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 or value.get("state") != "active":
        fail("authority_not_active")
    tx = value.get("transactionID")
    if not isinstance(tx, str) or TX_RE.fullmatch(tx) is None:
        fail("invalid_transaction_id")
    if value.get("modulePaths") != {"health": "Modules/Health", "footprints": "Modules/Footprints"}:
        fail("authority_layout_mismatch")
    if value.get("sharedSleepPath") != "SharedSleep":
        fail("authority_layout_mismatch")
    revisions = value.get("sourceRevisions")
    if not isinstance(revisions, dict) or not revisions:
        fail("authority_revisions_missing")
    if any(not isinstance(item, str) or migration.HEX_RE.fullmatch(item) is None for item in revisions.values()):
        fail("authority_revisions_invalid")
    plan_sha = value.get("planSHA256")
    if not isinstance(plan_sha, str) or migration.HEX_RE.fullmatch(plan_sha) is None:
        fail("authority_plan_hash_missing")
    return data, value


def preference_map(directory):
    directories, files = walk(directory)
    if directories:
        fail("unclassified_preference_entry", directories[0])
    expected = {domain + ".plist" for domain in DOMAINS}
    found = set(files)
    missing = sorted(expected - found)
    extra = sorted(found - expected)
    if missing:
        fail("preference_domain_missing", missing[0])
    if extra:
        fail("unknown_preference_domain", extra[0])
    result = {}
    for domain in DOMAINS:
        path = directory / (domain + ".plist")
        data = read_file(path)
        try:
            value = plistlib.loads(data)
        except (ValueError, plistlib.InvalidFileException):
            fail("preference_unreadable", domain)
        if not isinstance(value, dict):
            fail("preference_unreadable", domain)
        result[domain] = {"bytes": data, "sha256": sha(data)}
    return result


def assert_no_overlap(paths):
    resolved = [path.resolve(strict=False) for path in paths]
    for left in resolved:
        for right in resolved:
            if left != right and within(left, right):
                fail("overlapping_paths")


def staging_for(final):
    if not final.name.endswith(".noindex"):
        fail("output_not_noindex")
    return final.with_name(final.name[:-len(".noindex")] + ".partial.noindex")


def discard_staging(staging):
    if not staging.exists() and not staging.is_symlink():
        return
    if staging.is_symlink() or not staging.name.endswith(".partial.noindex"):
        fail("foreign_partial_refused")
    marker = staging / "STAGING.json"
    if not marker.is_file() or marker.is_symlink():
        fail("foreign_partial_refused")
    body = parse_json(read_file(marker))
    if body.get("kind") != "ReceiverWhitelistRecoveryStaging" or body.get("pid") != os.getpid():
        fail("foreign_partial_refused")
    shutil.rmtree(staging)


def fsync_tree(root):
    files, dirs = [], [root]
    for current, names, filenames in os.walk(root, followlinks=False):
        dirs.append(Path(current))
        files.extend(Path(current) / name for name in filenames)
    for file in files:
        if file.is_symlink() or not file.is_file():
            fail("unsafe_staged_file")
        fd = os.open(file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    for directory in reversed(dirs):
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def export_package(group, app_support, preferences_dir, plan_path, output,
                   expect_plan_sha=None, failpoint=None, home=None, pre_commit_hook=None,
                   allow_live_sources=False, maintenance_gate=None, production_plan_verified=None):
    migration = load_sibling("integrate_sources.py")
    upgrade = load_sibling("upgrade_data.py")
    global _CAPTURE_MODE
    _CAPTURE_MODE = bool(allow_live_sources)
    snapshot_database.opened = []
    group = guard_path(group, True, True)
    app_support = guard_path(app_support, True, True)
    preferences_dir = guard_path(preferences_dir, True, True)
    plan_path = guard_path(plan_path, True, False)
    output = guard_path(output, False, False)
    if not output.name.endswith(".noindex"):
        fail("output_not_noindex")
    if allow_live_sources and maintenance_gate is None:
        fail("maintenance_gate_required")
    refused = [output, output.parent]
    if not allow_live_sources:
        refused = [group, app_support, preferences_dir, plan_path, *refused]
    for path in refused:
        refuse_live(path, home)
    assert_no_overlap([group, app_support, preferences_dir, output])
    if within(plan_path, output) or within(output, plan_path.parent) and output.parent == plan_path.parent and output.name == plan_path.name:
        fail("overlapping_paths")
    staging = staging_for(output)
    if staging.exists() or staging.is_symlink():
        fail("partial_output_exists")
    plan = migration.load_plan(plan_path)
    plan_bytes = read_file(plan_path)
    plan_file_sha = sha(plan_bytes)
    plan_canonical = migration.sha(migration.canonical(plan))
    if expect_plan_sha is not None and expect_plan_sha != plan_file_sha:
        fail("expected_plan_sha_mismatch")
    authority_bytes, authority = read_authority(group, migration)
    if authority["transactionID"] != plan["transactionID"]:
        fail("authority_transaction_mismatch")
    if authority["sourceRevisions"] != plan["sourceRevisions"]:
        fail("authority_revision_mismatch")
    if authority["planSHA256"] != plan_canonical:
        fail("authority_plan_mismatch")
    active = authority["transactionID"]
    included, excluded, business_raw, snapshot_notes = collect_sources(
        group, app_support, active, authority_bytes, plan_canonical)
    preferences = preference_map(preferences_dir)
    if "library.json.read-only" in included["support"]:
        fail("library_read_only_marker_present")
    if "library.json" not in included["support"]:
        fail("required_library_missing")
    if "library.json.tmp" in included["support"] and "library.json" not in included["support"]:
        fail("library_missing_temporary_not_promoted")
    mirror = included["group_files"].get("library.json")
    library = included["support"]["library.json"]
    if mirror is None:
        fail("rhythm_widget_mirror_missing")
    if mirror["sha256"] != library["sha256"] and "library.json.widget-pending" not in included["support"]:
        fail("widget_mirror_diverges")
    required = [
        "Integration/authority.json",
        "Integration/Modules/Health/health.sqlite",
        "Integration/Modules/Footprints/footprints.sqlite",
        "Integration/SharedSleep/sleep-records.sqlite",
        "Integration/SourceArchives/Rhythm/library.json",
        "Integration/SourceArchives/explicit-absences.json",
        "Integration/Transactions.noindex/" + active + "/owner.json",
        "Integration/Transactions.noindex/" + active + "/receipt.json",
    ]
    for rel in required:
        if rel not in included["group"]:
            fail("required_receiver_path_missing", rel)
    owner_path = group / "Integration/Transactions.noindex" / active / "owner.json"
    receipt_path = group / "Integration/Transactions.noindex" / active / "receipt.json"
    owner = parse_json(read_file(owner_path))
    if owner != {"transactionID": active, "planSHA256": plan_canonical}:
        fail("owner_json_not_bound")
    receipt_bytes = read_file(receipt_path)
    if b'"rawBase64"' in receipt_bytes:
        fail("immutable_receipt_contains_rawbase64")
    receipt = parse_json(receipt_bytes)
    if receipt.get("schemaVersion") != 1 or receipt.get("transactionID") != active:
        fail("transaction_receipt_mismatch")
    if receipt.get("planSHA256") != plan_canonical:
        fail("transaction_receipt_mismatch")
    if set(receipt.get("components", {})) != {"Modules/Health", "Modules/Footprints", "SharedSleep", "SourceArchives"}:
        fail("transaction_components_incomplete")
    absence = parse_json(read_file(group / "Integration/SourceArchives/explicit-absences.json"))
    if absence.get("schemaVersion") != 1 or absence.get("transactionID") != active:
        fail("absence_file_not_bound")
    lock_fd = os.open(output.parent / ".receiver-whitelist-recovery.lock",
                      os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        import fcntl
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("recovery_staging_lock_busy")
        source_hashes, listings = capture_source_snapshot(
            group, app_support, preferences_dir, included, preferences, excluded)
        parent_fd, parent_identity = open_directory_nofollow(output.parent)
        try:
            mkdir_at(parent_fd, staging.name)
            write_bytes(staging / "STAGING.json", canonical({
                "kind": "ReceiverWhitelistRecoveryStaging", "pid": os.getpid(), "createdAt": now()}), 0o600)
            payload = staging / "payload"
            payload.mkdir(mode=0o700)
            notes = materialize(group, app_support, preferences, included, payload)
            archive = sealed_archive(payload)
            runtime = runtime_report(payload, upgrade, migration)
            bind_shipped_hashes(included, preferences, payload)
            policy = annotate_quarantine(platform_policy(), notes)
            exclusion_body = {"schemaVersion": SCHEMA, "entries": excluded}
            whitelist_body = {"schemaVersion": SCHEMA, "entries": whitelist_entries(included, preferences)}
            manifests = staging / "manifests"
            manifests.mkdir(mode=0o700)
            write_bytes(manifests / "whitelist.json", canonical(whitelist_body), 0o600)
            write_bytes(manifests / "exclusions.json", canonical(exclusion_body), 0o600)
            write_bytes(manifests / "metadata-policy.json", canonical(policy), 0o600)
            write_bytes(manifests / "archive-tree.json", canonical(archive), 0o600)
            receipt_kwargs = dict(
                authority_bytes=authority_bytes, plan_file_sha=plan_file_sha,
                plan_canonical=plan_canonical, receipt_bytes=receipt_bytes,
                whitelist_sha=sha(canonical(whitelist_body)),
                exclusion_sha=sha(canonical(exclusion_body)),
                archive_sha=sha(canonical(archive)), policy=policy,
                business_raw=business_raw, runtime=runtime, notes=notes,
                widget_pending="library.json.widget-pending" in included["support"],
                expect_plan_sha=expect_plan_sha)
            if allow_live_sources:
                receipt_body = build_capture_receipt(
                    maintenance_gate=maintenance_gate, production_plan_verified=production_plan_verified,
                    transaction_id=active, **receipt_kwargs)
            else:
                receipt_body = build_receipt(**receipt_kwargs)
            write_bytes(manifests / "receipt.json", canonical(receipt_body), 0o600)
            write_bytes(staging / "PACKAGE-COMPLETE", b"isolated-package\n", 0o600)
            fsync_tree(staging)
            if pre_commit_hook is not None:
                pre_commit_hook()
            recheck_source_snapshot(source_hashes, listings)
            if failpoint == "before_commit":
                fail("failpoint_before_commit")
            if os.fstat(parent_fd).st_ino != parent_identity[1] or os.fstat(parent_fd).st_dev != parent_identity[0]:
                fail("path_identity_changed")
            try:
                probe = os.open(output.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
            except FileNotFoundError:
                probe = -1
            except OSError:
                fail("symlink_path_refused")
            if probe >= 0:
                os.close(probe)
                fail("output_exists")
            os.rename(staging.name, output.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        except BaseException:
            discard_staging(staging)
            raise
        finally:
            os.close(parent_fd)
    finally:
        os.close(lock_fd)
        _CAPTURE_MODE = False
    require_bytes_stable(plan_path, plan_file_sha)
    require_bytes_stable(group / "Integration/authority.json", sha(authority_bytes))
    require_bytes_stable(receipt_path, sha(receipt_bytes))
    if allow_live_sources:
        return public_capture_summary(output, production_plan_verified, policy, metadata_fidelity(notes))
    return public_summary("exported", output, policy)


def capture_source_snapshot(group, app_support, preferences_dir, included, preferences, excluded):
    hashes = {}
    listings = {str(group): directory_names(group), str(app_support): directory_names(app_support),
                str(preferences_dir): directory_names(preferences_dir)}
    for rel, item in included["group"].items():
        path = group / rel
        if item.get("directory"):
            listings[str(path)] = directory_names(path)
        else:
            hashes[str(path)] = item["sha256"]
    for rel, item in included["support"].items():
        path = app_support / rel
        if item.get("directory"):
            listings[str(path)] = directory_names(path)
        else:
            hashes[str(path)] = item["sha256"]
    for domain, item in preferences.items():
        hashes[str(preferences_dir / (domain + ".plist"))] = item["sha256"]
    for record in excluded:
        if record.get("type") != "file" or "sha256" not in record:
            continue
        if not record["path"].startswith("GroupContainer/"):
            continue
        hashes[str(group / record["path"][len("GroupContainer/"):])] = record["sha256"]
    return hashes, listings


def recheck_source_snapshot(hashes, listings):
    for text, digest in hashes.items():
        path = Path(text)
        if lstat_existing(path) is None or path.is_symlink():
            fail("source_changed_during_read")
        if file_sha(path) != digest:
            fail("source_changed_during_read")
    for text, names in listings.items():
        path = Path(text)
        if lstat_existing(path) is None or path.is_symlink():
            fail("source_tree_changed")
        if directory_names(path) != names:
            fail("source_tree_changed")


def collect_sources(group, app_support, active, authority_bytes, plan_canonical):
    directories, files = walk(group)
    included_group, excluded = {}, []
    business_raw = 0
    snapshot_notes = {}
    live_rhythm = read_required(group / "Integration/SourceArchives/Rhythm/library.json",
                                "required_receiver_archive_missing")
    live_absence = read_required(group / "Integration/SourceArchives/explicit-absences.json",
                                 "required_absence_file_missing")
    for rel in directories + files:
        path = group / rel
        kind, _ = lstat_kind(path)
        action, reason = decision(rel, active)
        if action == "include":
            if kind == "file":
                business_raw += business_raw_count(path, reason)
                included_group[rel] = {"reason": reason, "sha256": file_sha(path), "bytes": path.stat().st_size}
            else:
                included_group[rel] = {"reason": reason, "directory": True}
        else:
            record = {"path": "GroupContainer/" + rel, "reason": reason, "type": kind}
            if kind == "file":
                record["sha256"] = file_sha(path)
                record["bytes"] = path.stat().st_size
                record.update(refine_exclusion(group, rel, reason, live_rhythm, live_absence))
            excluded.append(record)
            if reason == "sqlite_wal_folded_into_snapshot":
                snapshot_notes.setdefault(database_of_sidecar(rel), []).append(rel)
            if reason == "foreign_transaction_record" and path.suffix == ".json" and b'"rawBase64"' in read_file(path):
                fail("rawbase64_ownership_unresolved", rel)
    support_dirs, support_files = walk(app_support)
    included_support = {}
    for rel in support_dirs + support_files:
        action, reason = support_decision(rel)
        path = app_support / rel
        kind, _ = lstat_kind(path)
        if action != "include":
            fail("unclassified_application_support_entry", rel)
        if kind == "file":
            business_raw += business_raw_count(path, reason)
            included_support[rel] = {"reason": reason, "sha256": file_sha(path), "bytes": path.stat().st_size}
        else:
            included_support[rel] = {"reason": reason, "directory": True}
    if sha(read_file(group / "Integration/authority.json")) != sha(authority_bytes):
        fail("source_changed_during_read")
    if parse_json(authority_bytes).get("planSHA256") != plan_canonical:
        fail("authority_plan_mismatch")
    included = {"group": included_group, "support": included_support,
                "group_files": {name: included_group.get(name) for name in GROUP_FILES}}
    return included, excluded, business_raw, snapshot_notes


def read_required(path, code):
    if path.is_symlink() or not path.is_file():
        fail(code)
    return read_file(path)


def database_of_sidecar(rel):
    for database in CANONICAL:
        if any(rel == database + suffix for suffix in SIDECARS):
            return database
    fail("unclassified_database_sidecar", rel)


def refine_exclusion(group, rel, reason, live_rhythm, live_absence):
    path = group / rel
    extra = {"rawValuesStored": False}
    if reason == "native_move_escrow" and path.is_file():
        owner = MOVE_OWNERS[path.name.split(".", 1)[0]]
        pattern = MOVE_RAW
        extra.update(classify_escrow_json(path, pattern, owner))
        extra["classification"] = "metadata_escrow_raw_not_business"
    elif reason in ("pure_source_archive_health", "pure_source_archive_footprints") and path.is_file():
        if "NativeMetadata.noindex" in rel.split("/"):
            if path.suffix != ".json":
                fail("unclassified_native_metadata_entry", rel)
            owner = "source_health" if "/Health/" in ("/" + rel + "/") else "source_footprints"
            if "/SourceArchives/Health/" in ("/" + rel):
                owner = "source_health"
            elif "/SourceArchives/Footprints/" in ("/" + rel):
                owner = "source_footprints"
            else:
                fail("rawbase64_ownership_unresolved", rel)
            extra.update(classify_escrow_json(path, META_RAW, owner))
            extra["classification"] = "pure_source_metadata_escrow"
    elif reason == "staged_payload" and path.is_file():
        parts = rel.split("/")
        payload_at = next(i for i, part in enumerate(parts) if PAYLOAD_RE.fullmatch(part))
        inside = "/".join(parts[payload_at + 1:])
        if not inside:
            fail("unclassified_payload_leaf", rel)
        data = read_file(path)
        extra["leafReason"] = payload_leaf_reason(inside, data, live_rhythm, live_absence)
        extra["classification"] = "payload_leaf_not_whole_tree"
    return extra


def whitelist_entries(included, preferences):
    rows = []
    for rel, item in sorted(included["group"].items()):
        rows.append({"path": "GroupContainer/" + rel, **item})
    for rel, item in sorted(included["support"].items()):
        rows.append({"path": "ApplicationSupport/GaoSeries/Rhythm/" + rel, **item})
    for domain, item in preferences.items():
        rows.append({"path": "Preferences/" + domain + ".plist", "reason": "preference_domain",
                     "sha256": item["sha256"], "bytes": len(item["bytes"])})
    for name, reason in GROUP_FILES.items():
        if name not in included["group"]:
            rows.append({"path": "GroupContainer/" + name, "absent": True, "reason": reason,
                         "absenceIsExplicit": True})
    if not any(rel == "IntegratedRecovery" or rel.startswith("IntegratedRecovery/")
               for rel in included["support"]):
        rows.append({"path": "ApplicationSupport/GaoSeries/Rhythm/IntegratedRecovery",
                     "absent": True, "reason": "receiver_integrated_recovery_quarantine",
                     "absenceIsExplicit": True})
    return rows


def materialize(group, app_support, preferences, included, payload):
    notes = []
    materialize.meta = []
    mapping = []
    for rel, item in included["group"].items():
        if item.get("directory"):
            continue
        mapping.append((group / rel, payload / "GroupContainer" / rel, False))
    for rel, item in included["support"].items():
        if item.get("directory"):
            continue
        mapping.append((app_support / rel, payload / "ApplicationSupport/GaoSeries/Rhythm" / rel, False))
    directories = [payload / "GroupContainer" / rel for rel, item in included["group"].items() if item.get("directory")]
    directories.extend(payload / "ApplicationSupport/GaoSeries/Rhythm" / rel
                       for rel, item in included["support"].items() if item.get("directory"))
    directories.extend([
        payload / "ApplicationSupport", payload / "ApplicationSupport/GaoSeries",
        payload / "ApplicationSupport/GaoSeries/Rhythm", payload / "Preferences",
        payload / "GroupContainer"])
    for directory in directories:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(suffix=".partial.noindex") as scratch:
        scratch_dir = Path(scratch)
        for source, target, _ in mapping:
            rel = source.relative_to(group).as_posix() if within(source, group) else None
            meta = metadata_of(source)
            if rel in CANONICAL:
                summary, sidecars = snapshot_database(source, target, scratch_dir)
                os.chmod(target, meta["mode"], follow_symlinks=False)
                applied = apply_destination_metadata(source, target)
                os.utime(target, ns=(meta["mtimeNs"], meta["mtimeNs"]), follow_symlinks=False)
                notes.append({"source": rel, "logical": summary, "sidecarsFolded": sidecars,
                              "sourceSHA256": meta["sha256"], "snapshotSHA256": file_sha(target), **applied})
                materialize.meta.append(applied)
            else:
                write_bytes(target, read_file(source), 0o600)
                os.chmod(target, meta["mode"], follow_symlinks=False)
                applied = apply_destination_metadata(source, target)
                os.utime(target, ns=(meta["mtimeNs"], meta["mtimeNs"]), follow_symlinks=False)
                materialize.meta.append(applied)
                if file_sha(target) != meta["sha256"]:
                    fail("copy_checksum_mismatch")
        for domain, item in preferences.items():
            target = payload / "Preferences" / (domain + ".plist")
            write_bytes(target, item["bytes"], 0o600)
    for directory in sorted((item for item in directories), key=lambda item: len(item.parts), reverse=True):
        source = directory_source(directory, payload, group, app_support)
        if source is not None:
            meta = metadata_of(source)
            os.chmod(directory, meta["mode"], follow_symlinks=False)
            materialize.meta.append(apply_destination_metadata(source, directory))
            os.utime(directory, ns=(meta["mtimeNs"], meta["mtimeNs"]), follow_symlinks=False)
        else:
            os.chmod(directory, 0o700, follow_symlinks=False)
    return notes


def directory_source(directory, payload, group, app_support):
    rel = directory.relative_to(payload).as_posix()
    if rel == "GroupContainer":
        return group
    if rel.startswith("GroupContainer/"):
        return group / rel[len("GroupContainer/"):]
    if rel == "ApplicationSupport/GaoSeries/Rhythm":
        return app_support
    prefix = "ApplicationSupport/GaoSeries/Rhythm/"
    if rel.startswith(prefix):
        return app_support / rel[len(prefix):]
    return None


def bind_shipped_hashes(included, preferences, payload):
    """Whitelist digests are the bytes that ship. Canonical databases keep the
    pre-snapshot source digest beside the checkpointed package digest."""
    for rel, item in included["group"].items():
        if item.get("directory"):
            continue
        shipped = payload / "GroupContainer" / rel
        actual = file_sha(shipped)
        if rel in CANONICAL:
            item["sourceSHA256"] = item["sha256"]
            item["sha256"] = actual
            item["bytes"] = shipped.stat().st_size
        elif actual != item["sha256"]:
            fail("copy_checksum_mismatch", rel)
    for rel, item in included["support"].items():
        if item.get("directory"):
            continue
        actual = file_sha(payload / "ApplicationSupport/GaoSeries/Rhythm" / rel)
        if actual != item["sha256"]:
            fail("copy_checksum_mismatch", rel)
    for domain, item in preferences.items():
        actual = file_sha(payload / "Preferences" / (domain + ".plist"))
        if actual != item["sha256"]:
            fail("copy_checksum_mismatch", domain)


def sealed_archive(root):
    """Inventory the three payload roots that an isolated restore materializes."""
    nodes = []
    for name in ("ApplicationSupport", "GroupContainer", "Preferences"):
        tree = inventory_tree(root / name)
        for node in tree["nodes"]:
            node["path"] = name if node["path"] == "." else name + "/" + node["path"]
            nodes.append(node)
    return {"schemaVersion": SCHEMA, "nodes": sorted(nodes, key=lambda item: item["path"])}


def inventory_tree(root):
    nodes = []
    directories, files = walk(root)
    for rel in [""] + directories:
        path = root if rel == "" else root / rel
        meta = metadata_of(path)
        meta["path"] = rel or "."
        meta["origin"] = "payload"
        nodes.append(meta)
    for rel in files:
        meta = metadata_of(root / rel)
        meta["path"] = rel
        meta["origin"] = "payload"
        nodes.append(meta)
    return {"schemaVersion": SCHEMA, "nodes": nodes}


def runtime_report(payload, upgrade, migration):
    try:
        return _runtime_report(payload, upgrade, migration)
    except upgrade.SafetyError as error:
        fail("rhythm_library_rejected", str(error))
    except migration.MigrationError as error:
        fail("runtime_reader_rejected", str(error))


def _runtime_report(payload, upgrade, migration):
    group = payload / "GroupContainer/Integration"
    health = group / "Modules/Health/health.sqlite"
    footprints = group / "Modules/Footprints/footprints.sqlite"
    sleep = group / "SharedSleep/sleep-records.sqlite"
    library_path = payload / "ApplicationSupport/GaoSeries/Rhythm/library.json"
    library = parse_json(read_file(library_path))
    with contextlib.closing(sqlite3.connect("file:" + quote(str(health), safe="/") + "?mode=ro&immutable=1", uri=True)) as connection:
        migration.validate_health(connection)
        state = json.loads(connection.execute("SELECT json FROM state").fetchone()[0])
    requests = state.get("requests")
    rewarded = state.get("island", {}).get("rewardedSleepIDs", [])
    if not isinstance(requests, list) or any(not isinstance(item, str) or not item for item in requests):
        fail("health_request_ids_invalid")
    if len(set(requests)) != len(requests):
        fail("duplicate_health_request_id")
    if not isinstance(rewarded, list) or any(not isinstance(item, str) or not item for item in rewarded):
        fail("health_reward_ids_invalid")
    if len(set(rewarded)) != len(rewarded):
        fail("duplicate_health_reward_id")
    with contextlib.closing(sqlite3.connect("file:" + quote(str(footprints), safe="/") + "?mode=ro&immutable=1", uri=True)) as connection:
        foot = migration.validate_footprints(connection, group / "Modules/Footprints/Photos")
        meta = json.loads(connection.execute("SELECT payload FROM items WHERE kind='meta' AND id='main'").fetchone()[0])
    train = meta.get("train")
    visits = train.get("rewardedVisits") if isinstance(train, dict) else None
    if visits is not None:
        if not isinstance(visits, list) or len(set(visits)) != len(visits):
            fail("duplicate_footprint_reward_id")
    with contextlib.closing(sqlite3.connect("file:" + quote(str(sleep), safe="/") + "?mode=ro&immutable=1", uri=True)) as connection:
        sleep_report = migration.validate_sleep(connection, library)
    support = payload / "ApplicationSupport/GaoSeries/Rhythm"
    summary = upgrade.library_summary(support, upgrade.inventory(support))
    pref_digests = {}
    for domain in DOMAINS:
        data = read_file(payload / "Preferences" / (domain + ".plist"))
        pref_digests[domain] = {"present": True, "sha256": sha(data)}
    return {
        "health": {"requestCount": len(requests), "rewardedSleepIDCount": len(rewarded),
                   "duplicateRewardIDs": 0},
        "footprints": {"photoCount": foot["photoCount"],
                       "trainStateSHA256": sha(canonical(train)) if train is not None else None},
        "sleep": sleep_report,
        "rhythmLibrary": {"schema": summary["schema"], "gameStateSHA256": summary["game_state_sha256"],
                          "collectionCounts": {key: value["count"] for key, value in summary["collections"].items()}},
        "preferences": pref_digests,
        "attachmentFiles": sum(Path(name).suffix.lower() in upgrade.ATTACHMENT_EXTENSIONS
                               for name in upgrade.inventory(payload)["files"]),
        "valuesEmitted": False,
    }


def _collapse_status(values, preserved_token):
    values = {value for value in values if value is not None}
    if not values or "UNVERIFIED" in values:
        return "UNVERIFIED"
    if preserved_token in values and values <= {preserved_token, "ABSENT"}:
        return preserved_token
    if values == {"ABSENT"}:
        return "ABSENT"
    return "UNVERIFIED"


def metadata_fidelity(notes):
    rows = list(getattr(materialize, "meta", []) or []) + list(notes)
    fidelity = {
        "mode": "COMPARED",
        "preservedUserXattrs": "COMPARED",
        "appleQuarantine": "PRESERVED" if any(
            "com.apple.quarantine" in row.get("xattrsPreserved", []) for row in rows) else "UNVERIFIED",
        "bsdFlags": _collapse_status((row.get("bsdFlags") for row in rows), "PRESERVED"),
        "acl": _collapse_status((row.get("acl") for row in rows), "PRESERVED"),
        "archiveToRestoreMetadataExact": None,
        "productionReady": False,
    }
    for key in ("appleQuarantine", "bsdFlags", "acl"):
        if fidelity[key] == "PASS":
            fail("metadata_fidelity_pass_forged")
    return fidelity


def capture_blockers(fidelity):
    blockers = ["root_lock_not_integrated"]
    if fidelity["appleQuarantine"] != "PRESERVED":
        blockers.append("apple_quarantine_unverified")
    if fidelity["bsdFlags"] != "PRESERVED":
        blockers.append("bsd_flags_unverified")
    if fidelity["acl"] != "PRESERVED":
        blockers.append("acl_unverified")
    return blockers


def build_capture_receipt(authority_bytes, plan_file_sha, plan_canonical, receipt_bytes,
                          whitelist_sha, exclusion_sha, archive_sha, policy, business_raw, runtime,
                          notes, widget_pending, expect_plan_sha, maintenance_gate,
                          production_plan_verified, transaction_id):
    fields = root_actual_current_recovery_fields()
    fields["captureAt"] = now()
    fields["freshCurrentBackup"] = {"nameSuffix": ".noindex", "archiveTreeSHA256": archive_sha}
    fields["whitelistAndExclusionManifestSHA256"] = sha(canonical({"whitelist": whitelist_sha, "exclusion": exclusion_sha}))
    fields["authoritySHA256"] = sha(authority_bytes)
    fields["productionPlanByteHashVerified"] = True if production_plan_verified is True else None
    fields["originalTransactionReceiptSHA256"] = sha(receipt_bytes)
    fields["payloadMetadataPolicy"] = policy
    fields["actualArchiveTreeSHA256"] = archive_sha
    fields["fourPreferenceDomainsPresenceAndValuesVerified"] = True
    if len(notes) != 3:
        fail("sqlite_snapshot_incomplete")
    fields["threeCurrentDatabasesConsistent"] = True
    fields["receiverSourceArchivesRhythmAndAbsencesPreservedOrPreciselyRecoverable"] = True
    fields["pureSourceRawExcludedFromRecoverablePackage"] = True
    if transaction_id == PRODUCTION_TRANSACTION_ID and production_plan_verified is True:
        fields["sameActiveTransactionVerified"] = True
    fidelity = metadata_fidelity(notes)
    fields = seal_capture_fields(fields)
    return {
        "schemaVersion": SCHEMA,
        "kind": "ReadOnlyWhitelistCaptureRecord",
        "notRootEvidence": True,
        "realRecoveryCompleted": False,
        "activeWrite": False,
        "productionReady": False,
        "productionReadyBlockers": capture_blockers(fidelity),
        "metadataFidelity": fidelity,
        "preparationContract": seal_preparation(preparation_contract()),
        "rootActualCurrentRecoveryFields": fields,
        "externalMaintenanceGate": {
            "sha256": maintenance_gate["sha256"],
            "role": "caller_attestation_pending_root_integration",
            "rootLockIntegrated": False,
            "writersCheckedByThisTool": False,
            "rootMaintenanceEvidence": None,
        },
        "captureObservation": {
            "syntheticOnly": False,
            "notRootEvidence": True,
            "semanticVerification": "UNVERIFIED",
            "currentReaders": "UNVERIFIED",
            "gameProgress": "UNVERIFIED",
            "dedup": "UNVERIFIED",
            "runtimeOnlyAgainstProductionPlan": "UNVERIFIED",
            "macQuarantineFlagsAcl": "UNVERIFIED",
            "structuralArchiveTreeSHA256": archive_sha,
            "structuralWhitelistSHA256": whitelist_sha,
            "structuralExclusionSHA256": exclusion_sha,
            "suppliedPlanFileSHA256": plan_file_sha,
            "suppliedPlanCanonicalSHA256": plan_canonical,
            "suppliedPlanMatchesFixtureAuthority": True,
            "callerExpectedPlanSHA256": expect_plan_sha,
            "callerExpectationIsNotProductionProof": True,
            "originalTransactionReceiptSHA256": sha(receipt_bytes),
            "authoritySHA256": sha(authority_bytes),
            "businessRawBase64PointerCount": business_raw,
            "pureSourceRawExcludedFromThisSyntheticPackage": True,
            "sqliteSnapshotNotes": notes,
            "widgetPublicationPending": widget_pending,
            "preferenceSHA256": runtime["preferences"],
            "libraryGameStateSHA256": runtime["rhythmLibrary"]["gameStateSHA256"],
            "structuralReadersGate": "passed_on_these_bytes_not_root_evidence",
            "payloadMetadataPolicy": policy,
            "isolatedRestoreCheckedAt": None,
            "syntheticArchiveToRestoreStructuralMatch": None,
            "sourceSqliteOpened": False,
            "sourceMetadataMutated": False,
            "packageStagingLock": "acquired_not_root_maintenance",
            "locksNotAcquired": [
                ".rhythm-integration-writers.lock", ".rhythm-integration-maintenance.json",
                "build_lease", "foreground_lease"],
        },
    }


def seal_capture_fields(fields):
    if set(fields) != set(ROOT_FIELD_ORDER) or len(fields) != 25:
        fail("root_receipt_fields_incomplete")
    if fields.get("status") != "NOT_EXECUTED":
        fail("root_status_not_execution")
    for name in ("reMigrationPerformed", "reActivationPerformed", "activeBusinessRolledBack"):
        if fields.get(name) is not False:
            fail("root_field_prefilled_true", name)
    if fields.get("rootMaintenanceEvidence") is not None:
        fail("root_maintenance_claim_rejected")
    if fields.get("productionPlanByteHashVerified") not in (None, True):
        fail("production_plan_verification_invalid")
    for name in ("restoreCheckAt", "isolatedRestoreTargetIdentity", "actualArchiveToRestoreMetadataExact",
                 "attachmentsAndGameProgressVerified", "sharedSleepSeedTombstoneRequestRewardDedupVerified",
                 "currentReadersCompatible", "runtimeOnlyCompatibleWithUnchangedRootPlanAndReceipt"):
        if fields.get(name) is not None:
            fail("semantic_field_not_evidence", name)
    return {name: fields[name] for name in ROOT_FIELD_ORDER}


def public_capture_summary(path, production_plan_verified, policy, fidelity):
    return {
        "status": "captured_not_production_ready",
        "package": path.name,
        "notRootEvidence": True,
        "realRecoveryCompleted": False,
        "activeWrite": False,
        "productionReady": False,
        "productionPlanByteHashVerified": True if production_plan_verified is True else None,
        "rootMaintenanceEvidence": None,
        "rootLockIntegrated": False,
        "semanticVerification": "UNVERIFIED",
        "macosQuarantineFidelity": policy["macosQuarantineFidelity"],
        "appleMetadata": policy["appleMetadata"],
        "appleQuarantine": fidelity["appleQuarantine"],
        "bsdFlags": fidelity["bsdFlags"],
        "acl": fidelity["acl"],
        "scope": "external_noindex_capture",
    }


def capture_package(group, app_support, preferences_dir, plan_path, output, maintenance_gate,
                    production_plan=None, expect_plan_sha=None, failpoint=None, home=None,
                    pre_commit_hook=None):
    gate = load_maintenance_gate(maintenance_gate, group, app_support, preferences_dir, output)
    verified = production_plan_was_verified(production_plan)
    return export_package(group, app_support, preferences_dir, plan_path, output,
                          expect_plan_sha=expect_plan_sha, failpoint=failpoint, home=home,
                          pre_commit_hook=pre_commit_hook, allow_live_sources=True,
                          maintenance_gate=gate, production_plan_verified=verified)


def build_receipt(authority_bytes, plan_file_sha, plan_canonical, receipt_bytes,
                  whitelist_sha, exclusion_sha, archive_sha, policy, business_raw, runtime,
                  notes, widget_pending, expect_plan_sha):
    root_fields = seal_root_fields(root_actual_current_recovery_fields())
    preparation = seal_preparation(preparation_contract())
    return {
        "schemaVersion": SCHEMA,
        "kind": "SyntheticReceiverWhitelistPackageRecord",
        "notRootEvidence": True,
        "realRecoveryCompleted": False,
        "activeWrite": False,
        "preparationContract": preparation,
        "rootActualCurrentRecoveryFields": root_fields,
        "syntheticObservation": {
            "syntheticOnly": True,
            "notRootEvidence": True,
            "semanticVerification": "UNVERIFIED",
            "currentReaders": "UNVERIFIED",
            "gameProgress": "UNVERIFIED",
            "dedup": "UNVERIFIED",
            "fourPreferenceValues": "UNVERIFIED",
            "runtimeOnlyAgainstProductionPlan": "UNVERIFIED",
            "macQuarantineFlagsAcl": "UNVERIFIED",
            "reason": "synthetic_fixture_or_file_presence_is_not_real_evidence",
            "structuralArchiveTreeSHA256": archive_sha,
            "structuralWhitelistSHA256": whitelist_sha,
            "structuralExclusionSHA256": exclusion_sha,
            "suppliedPlanFileSHA256": plan_file_sha,
            "suppliedPlanCanonicalSHA256": plan_canonical,
            "suppliedPlanMatchesFixtureAuthority": True,
            "callerExpectedPlanSHA256": expect_plan_sha,
            "callerExpectationIsNotProductionProof": True,
            "originalTransactionReceiptSHA256": sha(receipt_bytes),
            "authoritySHA256": sha(authority_bytes),
            "businessRawBase64PointerCount": business_raw,
            "pureSourceRawExcludedFromThisSyntheticPackage": True,
            "sqliteSnapshotNotes": notes,
            "widgetPublicationPending": widget_pending,
            "preferenceSHA256": runtime["preferences"],
            "libraryGameStateSHA256": runtime["rhythmLibrary"]["gameStateSHA256"],
            "structuralReadersGate": "passed_on_these_bytes_not_root_evidence",
            "payloadMetadataPolicy": policy,
            "isolatedRestoreCheckedAt": None,
            "syntheticArchiveToRestoreStructuralMatch": None,
            "packageStagingLock": "acquired_not_root_maintenance",
            "locksNotAcquired": [
                ".rhythm-integration-writers.lock", ".rhythm-integration-maintenance.json",
                "build_lease", "foreground_lease"],
        },
    }


def public_summary(status, path, policy):
    return {
        "status": status,
        "package": path.name,
        "notRootEvidence": True,
        "realRecoveryCompleted": False,
        "activeWrite": False,
        "liveRootReadImplemented": False,
        "productionPlanByteHashVerified": None,
        "productionPlanFileSHA256": PRODUCTION_PLAN_FILE_SHA256,
        "rootActualCurrentRecoveryFieldsStatus": "NOT_EXECUTED",
        "semanticVerification": "UNVERIFIED",
        "macosQuarantineFidelity": policy["macosQuarantineFidelity"],
        "appleMetadata": policy["appleMetadata"],
        "scope": "isolated_noindex_only",
    }


def load_package(package):
    package = guard_path(package, True, True)
    if not package.name.endswith(".noindex"):
        fail("package_not_noindex")
    refuse_live(package)
    marker = package / "PACKAGE-COMPLETE"
    if not marker.is_file() or marker.is_symlink():
        fail("package_incomplete")
    manifests = package / "manifests"
    archive = parse_json(read_file(manifests / "archive-tree.json"))
    receipt = parse_json(read_file(manifests / "receipt.json"))
    whitelist = parse_json(read_file(manifests / "whitelist.json"))
    exclusions = parse_json(read_file(manifests / "exclusions.json"))
    policy = parse_json(read_file(manifests / "metadata-policy.json"))
    if receipt.get("notRootEvidence") is not True or receipt.get("realRecoveryCompleted") is not False:
        fail("receipt_missing_synthetic_boundary")
    if receipt.get("activeWrite") is not False:
        fail("receipt_claims_forbidden_action")
    kind = receipt.get("kind")
    if kind == "SyntheticReceiverWhitelistPackageRecord":
        seal_root_fields(receipt.get("rootActualCurrentRecoveryFields"))
        observation = receipt.get("syntheticObservation")
    elif kind == "ReadOnlyWhitelistCaptureRecord":
        if receipt.get("productionReady") is not False:
            fail("production_ready_not_allowed")
        fidelity = receipt.get("metadataFidelity") or {}
        if fidelity.get("bsdFlags") == "PASS" or fidelity.get("acl") == "PASS":
            fail("metadata_fidelity_pass_forged")
        if fidelity.get("archiveToRestoreMetadataExact") is not None:
            fail("metadata_exactness_not_proven")
        seal_capture_fields(receipt.get("rootActualCurrentRecoveryFields"))
        observation = receipt.get("captureObservation")
    else:
        fail("receipt_kind_unknown")
    seal_preparation(receipt.get("preparationContract"))
    if not isinstance(observation, dict) or observation.get("notRootEvidence") is not True:
        fail("receipt_missing_synthetic_boundary")
    if observation.get("semanticVerification") != "UNVERIFIED":
        fail("synthetic_observation_claims_real_verification")
    if sha(canonical(archive)) != observation.get("structuralArchiveTreeSHA256"):
        fail("archive_tree_hash_mismatch")
    if sha(canonical(whitelist)) != observation.get("structuralWhitelistSHA256"):
        fail("forged_whitelist_manifest")
    if sha(canonical(exclusions)) != observation.get("structuralExclusionSHA256"):
        fail("forged_exclusion_manifest")
    payload = package / "payload"
    actual = sealed_archive(payload)
    if actual["nodes"] != archive["nodes"]:
        fail("package_tree_changed")
    excluded_paths = {item["path"] for item in exclusions["entries"]}
    for node in actual["nodes"]:
        if node["path"] in excluded_paths:
            fail("excluded_path_present_in_package", node["path"])
        if node["type"] == "file" and node["path"].startswith("GroupContainer/Integration/SourceArchives/Health"):
            fail("pure_source_present_in_package")
        if node["type"] == "file" and node["path"].startswith("GroupContainer/Integration/SourceArchives/Footprints"):
            fail("pure_source_present_in_package")
    for entry in whitelist["entries"]:
        if "sha256" not in entry:
            continue
        file_path = payload / entry["path"]
        if file_sha(file_path) != entry["sha256"]:
            fail("whitelist_checksum_mismatch", entry["path"])
    return {"package": package, "archive": archive, "receipt": receipt, "whitelist": whitelist,
            "exclusions": exclusions, "policy": policy, "payload": payload}


def verify_package(package, plan_path, restored=None, source_group=None, home=None):
    migration = load_sibling("integrate_sources.py")
    upgrade = load_sibling("upgrade_data.py")
    loaded = load_package(package)
    plan_path = guard_path(plan_path, True, False)
    refuse_live(plan_path, home)
    plan = migration.load_plan(plan_path)
    plan_canonical = migration.sha(migration.canonical(plan))
    observation = loaded["receipt"].get("syntheticObservation") or loaded["receipt"].get("captureObservation")
    if observation.get("suppliedPlanCanonicalSHA256") != plan_canonical:
        fail("package_plan_mismatch")
    payload_group = loaded["payload"] / "GroupContainer"
    authority_bytes, authority = read_authority(payload_group, migration)
    if sha(authority_bytes) != observation["authoritySHA256"]:
        fail("authority_hash_mismatch")
    if authority["planSHA256"] != plan_canonical or authority["transactionID"] != plan["transactionID"]:
        fail("authority_plan_mismatch")
    if authority["sourceRevisions"] != plan["sourceRevisions"]:
        fail("authority_revision_mismatch")
    active = authority["transactionID"]
    receipt_path = payload_group / "Integration/Transactions.noindex" / active / "receipt.json"
    owner_path = payload_group / "Integration/Transactions.noindex" / active / "owner.json"
    receipt_bytes = read_file(receipt_path)
    if sha(receipt_bytes) != observation["originalTransactionReceiptSHA256"]:
        fail("transaction_receipt_byte_mismatch")
    if b'"rawBase64"' in receipt_bytes:
        fail("immutable_receipt_contains_rawbase64")
    owner = parse_json(read_file(owner_path))
    if owner != {"transactionID": active, "planSHA256": plan_canonical}:
        fail("owner_json_not_bound")
    runtime = runtime_report(loaded["payload"], upgrade, migration)
    if runtime["preferences"] != observation["preferenceSHA256"]:
        fail("preference_digest_mismatch")
    if runtime["rhythmLibrary"]["gameStateSHA256"] != observation["libraryGameStateSHA256"]:
        fail("synthetic_library_digest_mismatch")
    scan_package_raw(loaded["payload"])
    runtime_only = "NOT_EXECUTED"
    if source_group is not None:
        source_group = guard_path(source_group, True, True)
        refuse_live(source_group, home)
        if Path(plan["targetGroup"]).resolve() != source_group.resolve():
            fail("runtime_only_group_not_plan_target")
        runtime_only = run_runtime_only(plan_path)
    restored_identity = None
    if restored is not None:
        restored = guard_path(restored, True, True)
        if not restored.name.endswith(".noindex"):
            fail("restore_target_not_noindex")
        refuse_live(restored, home)
        compare_trees(loaded["archive"], sealed_archive(restored / "payload") if (restored / "payload").is_dir()
                      else sealed_archive(restored))
        info = restored.lstat()
        restored_identity = {"device": info.st_dev, "inode": info.st_ino}
        check = parse_json(read_file(restored / "recovery-receipt.json"))
        if check.get("realRecoveryCompleted") is not False or check.get("activeWrite") is not False:
            fail("restore_receipt_claims_active_write")
        seal_root_fields(check.get("rootActualCurrentRecoveryFields"))
        if check.get("syntheticObservation", {}).get("macQuarantineFlagsAcl") != "UNVERIFIED":
            fail("restore_claims_mac_metadata_fidelity")
        if check.get("syntheticObservation", {}).get("syntheticArchiveToRestoreStructuralMatch") is not True:
            fail("restore_structural_match_missing")
    return {
        "status": "verified",
        "notRootEvidence": True,
        "realRecoveryCompleted": False,
        "liveRootReadImplemented": False,
        "productionPlanByteHashVerified": None,
        "semanticVerification": "UNVERIFIED",
        "currentReadersCompatible": None,
        "fourPreferenceDomainsPresenceAndValuesVerified": None,
        "attachmentsAndGameProgressVerified": None,
        "sharedSleepSeedTombstoneRequestRewardDedupVerified": None,
        "runtimeOnlyCompatibleWithUnchangedRootPlanAndReceipt": None,
        "syntheticFixtureRuntimeOnly": runtime_only,
        "isolatedRestoreTargetIdentity": restored_identity,
        "preferenceValuesEmitted": False,
    }


def compare_trees(expected, actual):
    left = {node["path"]: node for node in expected["nodes"]}
    right = {node["path"]: node for node in actual["nodes"]}
    if set(left) != set(right):
        fail("restore_tree_membership_mismatch")
    for path, source in left.items():
        target = right[path]
        for key in ("type", "mode", "mtimeNs", "size", "sha256"):
            if source.get(key) != target.get(key):
                fail("restore_metadata_mismatch", path + ":" + key)
        if source.get("xattrStatus") != target.get("xattrStatus") or source.get("xattrs") != target.get("xattrs"):
            fail("restore_xattr_mismatch", path)
        if source.get("bsdFlags") != target.get("bsdFlags"):
            fail("restore_flags_mismatch", path)
        if source.get("uid") != target.get("uid") or source.get("gid") != target.get("gid"):
            fail("uid_gid_mismatch", path)


def scan_package_raw(payload):
    directories, files = walk(payload)
    for rel in files:
        path = payload / rel
        if path.suffix != ".json":
            continue
        _data, parsed = load_json_file(path)
        pointers = raw_pointers(parsed)
        if not pointers:
            continue
        if rel.startswith("GroupContainer/Integration/SourceArchives/Health") or rel.startswith(
                "GroupContainer/Integration/SourceArchives/Footprints"):
            fail("pure_source_raw_present", rel)
        if "/NativeMetadata.noindex/" in rel or "/NativeMoves.noindex/" in rel or "/Payload-" in rel:
            fail("source_escrow_present", rel)
        if rel.endswith("authority.json") or rel.endswith("receipt.json") or rel.endswith("owner.json") or rel.endswith(
                "explicit-absences.json"):
            fail("immutable_record_contains_rawbase64", rel)


def run_runtime_only(plan_path):
    script = Path(__file__).resolve().parent / "integrate_sources.py"
    completed = subprocess.run([sys.executable, str(script), "verify", "--plan", str(plan_path), "--runtime-only"],
                               check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        fail("runtime_only_incompatible")
    try:
        body = json.loads(completed.stdout)
    except ValueError:
        fail("runtime_only_incompatible")
    if body.get("status") != "active" or body.get("sourceArchivesChecked") is not False:
        fail("runtime_only_incompatible")
    return {"status": body["status"], "sourceArchivesChecked": False,
            "boundary": "read_only_plan_target_not_an_isolated_restore"}


def restore_package(package, target, failpoint=None, home=None):
    loaded = load_package(package)
    if Path(target).exists() or Path(target).is_symlink():
        fail("restore_target_exists")
    target = guard_path(target, False, False)
    if not target.name.endswith(".noindex"):
        fail("restore_target_not_noindex")
    refuse_live(target, home)
    refuse_live(loaded["package"], home)
    if within(target, loaded["package"]) or within(loaded["package"], target):
        fail("overlapping_paths")
    staging = staging_for(target)
    if staging.exists() or staging.is_symlink():
        fail("partial_output_exists")
    try:
        staging.mkdir(mode=0o700)
        write_bytes(staging / "STAGING.json", canonical({
            "kind": "ReceiverWhitelistRecoveryStaging", "pid": os.getpid(), "createdAt": now()}), 0o600)
        for name in ("ApplicationSupport", "GroupContainer", "Preferences"):
            source = loaded["payload"] / name
            place_tree(source, staging / name, staging)
        expected = sealed_archive(staging)
        compare_trees(loaded["archive"], expected)
        info_parent = staging.lstat()
        receipt = dict(loaded["receipt"])
        seal_root_fields(receipt["rootActualCurrentRecoveryFields"])
        observation = dict(receipt["syntheticObservation"])
        observation["isolatedRestoreCheckedAt"] = now()
        observation["syntheticArchiveToRestoreStructuralMatch"] = True
        observation["macQuarantineFlagsAcl"] = "UNVERIFIED"
        observation["isolatedRestoreTargetDevice"] = info_parent.st_dev
        observation["isolatedRestoreTargetInode"] = info_parent.st_ino
        observation["preexistingGroupRequired"] = False
        receipt["syntheticObservation"] = observation
        receipt["realRecoveryCompleted"] = False
        receipt["activeWrite"] = False
        write_bytes(staging / "recovery-receipt.json", canonical(receipt), 0o600)
        write_bytes(staging / "RESTORE-COMPLETE", b"isolated-restore\n", 0o600)
        fsync_tree(staging)
        if failpoint == "before_commit":
            fail("failpoint_before_commit")
        os.rename(staging, target)
    except BaseException:
        discard_staging(staging)
        raise
    final = target.lstat()
    return {"status": "restored", "target": target.name, "realRecoveryCompleted": False,
            "activeWrite": False, "preexistingGroupRequired": False,
            "isolatedRestoreTargetIdentity": {"device": final.st_dev, "inode": final.st_ino},
            "macosQuarantineFidelity": loaded["policy"].get("macosQuarantineFidelity"),
            "appleMetadata": loaded["policy"].get("appleMetadata")}


def place_tree(source, dest, staging):
    if not within(dest, staging):
        fail("restore_write_outside_staging")
    meta = metadata_of(source)
    dest.mkdir(mode=0o700)
    entries = sorted(Path(source).iterdir(), key=lambda item: item.name)
    for entry in entries:
        target = dest / entry.name
        if entry.is_symlink():
            fail("symlink_refused", entry.name)
        if entry.is_dir():
            place_tree(entry, target, staging)
        elif entry.is_file():
            file_meta = metadata_of(entry)
            write_bytes(target, read_file(entry), 0o600)
            os.chmod(target, file_meta["mode"], follow_symlinks=False)
            applied = apply_destination_metadata(entry, target)
            if applied["xattrDigests"] != file_meta["xattrs"] or applied["xattrsSkipped"]:
                fail("restore_xattr_mismatch", entry.name)
            os.utime(target, ns=(file_meta["mtimeNs"], file_meta["mtimeNs"]), follow_symlinks=False)
        else:
            fail("unsupported_file_type")
    os.chmod(dest, meta["mode"], follow_symlinks=False)
    applied = apply_destination_metadata(source, dest)
    if applied["xattrDigests"] != meta["xattrs"] or applied["xattrsSkipped"]:
        fail("restore_xattr_mismatch", dest.name)
    os.utime(dest, ns=(meta["mtimeNs"], meta["mtimeNs"]), follow_symlinks=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Isolated whitelist recovery for the Rhythm receiver. "
                                      "Does not write live data, apply, activate, or delete sources.")
    sub = parser.add_subparsers(dest="command", required=True)
    export = sub.add_parser("export")
    export.add_argument("--group", type=Path, required=True)
    export.add_argument("--app-support", type=Path, required=True)
    export.add_argument("--preferences-dir", type=Path, required=True)
    export.add_argument("--plan", type=Path, required=True)
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--expect-plan-sha")
    capture = sub.add_parser("capture")
    capture.add_argument("--group", type=Path, required=True)
    capture.add_argument("--app-support", type=Path, required=True)
    capture.add_argument("--preferences-dir", type=Path, required=True)
    capture.add_argument("--plan", type=Path, required=True)
    capture.add_argument("--output", type=Path, required=True)
    capture.add_argument("--maintenance-gate", type=Path, required=True)
    capture.add_argument("--production-plan", type=Path)
    restore = sub.add_parser("restore")
    restore.add_argument("--package", type=Path, required=True)
    restore.add_argument("--target", type=Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--package", type=Path, required=True)
    verify.add_argument("--plan", type=Path, required=True)
    verify.add_argument("--restored", type=Path)
    verify.add_argument("--source-group", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "export":
            result = export_package(args.group, args.app_support, args.preferences_dir, args.plan,
                                    args.output, args.expect_plan_sha)
        elif args.command == "capture":
            result = capture_package(args.group, args.app_support, args.preferences_dir, args.plan,
                                     args.output, args.maintenance_gate, args.production_plan)
        elif args.command == "restore":
            result = restore_package(args.package, args.target)
        else:
            result = verify_package(args.package, args.plan, args.restored, args.source_group)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except RecoveryError as error:
        print(json.dumps({"status": "refused", "code": error.code, "detail": error.detail,
                          "realRecoveryCompleted": False}, ensure_ascii=False, sort_keys=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())
