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


def live_roots(home):
    return (
        home / "Library/Group Containers" / GROUP_ID,
        home / "Library/Application Support/GaoSeries",
        home / "Library/Preferences",
        Path("/Applications"),
    )


def within(path, parent):
    try:
        path.resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except ValueError:
        return False


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
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            if part.is_symlink():
                fail("symlink_path_refused")
            break
    if exists:
        if not path.exists():
            fail("required_path_missing")
        if directory and not path.is_dir():
            fail("required_directory_missing")
        if not directory and not path.is_file():
            fail("required_file_missing")
    elif path.exists() or path.is_symlink():
        fail("output_exists")
    return path


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
            if entry.is_symlink():
                fail("symlink_refused", rel)
            if entry.is_dir(follow_symlinks=False):
                directories.append(rel)
                visit(path)
            elif entry.is_file(follow_symlinks=False):
                info = path.lstat()
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


def metadata_of(path):
    kind, info = lstat_kind(path)
    xattr_names = {}
    xattr_status = "UNVERIFIED"
    if hasattr(os, "listxattr") and hasattr(os, "getxattr"):
        try:
            names = sorted(os.listxattr(path, follow_symlinks=False))
            xattr_names = {name: sha(os.getxattr(path, name, follow_symlinks=False)) for name in names}
            xattr_status = "READ"
        except OSError:
            fail("xattr_read_failed")
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
    """Copy xattrs the running platform can round-trip. Apple names that the
    platform refuses are reported as SKIP, never as preserved."""
    preserved, skipped = {}, []
    if not (hasattr(os, "listxattr") and hasattr(os, "getxattr") and hasattr(os, "setxattr")):
        return preserved, skipped, "UNVERIFIED"
    for name in sorted(os.listxattr(source, follow_symlinks=False)):
        raw = os.getxattr(source, name, follow_symlinks=False)
        try:
            os.setxattr(target, name, raw, follow_symlinks=False)
            readback = os.getxattr(target, name, follow_symlinks=False)
        except OSError:
            if sys.platform == "darwin":
                fail("xattr_not_preserved", name)
            skipped.append(name)
            continue
        if readback != raw:
            fail("xattr_readback_mismatch", name)
        preserved[name] = sha(raw)
    return preserved, skipped, "READ"


def write_bytes(path, data, mode):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, mode), "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def snapshot_database(source, dest, scratch_dir):
    scratch = scratch_dir / source.name
    sidecars = []
    for suffix in ("", *SIDECARS):
        item = Path(str(source) + suffix)
        if not item.exists() and not item.is_symlink():
            continue
        if item.is_symlink() or not item.is_file():
            fail("unsafe_database_sidecar", suffix or "main")
        target = Path(str(scratch) + suffix)
        write_bytes(target, read_file(item), 0o600)
        if suffix:
            sidecars.append(suffix)
    before = file_sha(source)
    uri = "file:" + quote(str(scratch), safe="/") + "?mode=ro"
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
                   expect_plan_sha=None, failpoint=None, home=None):
    migration = load_sibling("integrate_sources.py")
    upgrade = load_sibling("upgrade_data.py")
    group = guard_path(group, True, True)
    app_support = guard_path(app_support, True, True)
    preferences_dir = guard_path(preferences_dir, True, True)
    plan_path = guard_path(plan_path, True, False)
    output = guard_path(output, False, False)
    if not output.name.endswith(".noindex"):
        fail("output_not_noindex")
    for path in (group, app_support, preferences_dir, plan_path, output, output.parent):
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
        try:
            staging.mkdir(mode=0o700)
            write_bytes(staging / "STAGING.json", canonical({
                "kind": "ReceiverWhitelistRecoveryStaging", "pid": os.getpid(), "createdAt": now()}), 0o600)
            payload = staging / "payload"
            payload.mkdir(mode=0o700)
            notes = materialize(group, app_support, preferences, included, payload)
            archive = sealed_archive(payload)
            bind_shipped_hashes(included, preferences, payload)
            runtime = runtime_report(payload, upgrade, migration)
            policy = annotate_quarantine(platform_policy(), notes)
            exclusion_body = {"schemaVersion": SCHEMA, "entries": excluded}
            whitelist_body = {"schemaVersion": SCHEMA, "entries": whitelist_entries(included, preferences)}
            manifests = staging / "manifests"
            manifests.mkdir(mode=0o700)
            write_bytes(manifests / "whitelist.json", canonical(whitelist_body), 0o600)
            write_bytes(manifests / "exclusions.json", canonical(exclusion_body), 0o600)
            write_bytes(manifests / "metadata-policy.json", canonical(policy), 0o600)
            write_bytes(manifests / "archive-tree.json", canonical(archive), 0o600)
            receipt_body = build_receipt(
                phase="export", authority_bytes=authority_bytes, plan_file_sha=plan_file_sha,
                plan_canonical=plan_canonical, receipt_bytes=receipt_bytes,
                whitelist_sha=sha(canonical(whitelist_body)),
                exclusion_sha=sha(canonical(exclusion_body)),
                archive_sha=sha(canonical(archive)), policy=policy,
                business_raw=business_raw, runtime=runtime, notes=notes,
                widget_pending="library.json.widget-pending" in included["support"])
            write_bytes(manifests / "receipt.json", canonical(receipt_body), 0o600)
            write_bytes(staging / "PACKAGE-COMPLETE", b"isolated-package\n", 0o600)
            fsync_tree(staging)
            if failpoint == "before_commit":
                fail("failpoint_before_commit")
            os.rename(staging, output)
        except BaseException:
            discard_staging(staging)
            raise
    finally:
        os.close(lock_fd)
    require_bytes_stable(plan_path, plan_file_sha)
    require_bytes_stable(group / "Integration/authority.json", sha(authority_bytes))
    require_bytes_stable(receipt_path, sha(receipt_bytes))
    return public_summary("exported", output, business_raw, policy, plan_canonical,
                          sha(authority_bytes), sha(receipt_bytes))


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
    if support_dirs:
        fail("unclassified_application_support_entry", support_dirs[0])
    included_support = {}
    for rel in support_files:
        action, reason = support_decision(rel)
        path = app_support / rel
        business_raw += business_raw_count(path, reason)
        included_support[rel] = {"reason": reason, "sha256": file_sha(path), "bytes": path.stat().st_size}
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
    return rows


def materialize(group, app_support, preferences, included, payload):
    notes = []
    mapping = []
    for rel, item in included["group"].items():
        if item.get("directory"):
            continue
        mapping.append((group / rel, payload / "GroupContainer" / rel, False))
    for rel in included["support"]:
        mapping.append((app_support / rel, payload / "ApplicationSupport/GaoSeries/Rhythm" / rel, False))
    directories = [payload / "GroupContainer" / rel for rel, item in included["group"].items() if item.get("directory")]
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
                preserved, skipped, status = copy_xattrs(source, target)
                os.chmod(target, meta["mode"], follow_symlinks=False)
                os.utime(target, ns=(meta["mtimeNs"], meta["mtimeNs"]), follow_symlinks=False)
                notes.append({"source": rel, "logical": summary, "sidecarsFolded": sidecars,
                              "sourceSHA256": meta["sha256"], "snapshotSHA256": file_sha(target),
                              "xattrsPreserved": sorted(preserved), "xattrsSkipped": skipped,
                              "xattrStatus": status})
            else:
                write_bytes(target, read_file(source), 0o600)
                os.chmod(target, meta["mode"], follow_symlinks=False)
                preserved, skipped, status = copy_xattrs(source, target)
                if skipped and sys.platform == "darwin":
                    fail("xattr_not_preserved")
                os.utime(target, ns=(meta["mtimeNs"], meta["mtimeNs"]), follow_symlinks=False)
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
            copy_xattrs(source, directory)
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


def build_receipt(phase, authority_bytes, plan_file_sha, plan_canonical, receipt_bytes,
                  whitelist_sha, exclusion_sha, archive_sha, policy, business_raw, runtime,
                  notes, widget_pending):
    return {
        "schemaVersion": SCHEMA,
        "kind": KIND + "Receipt",
        "phase": phase,
        "captureAt": now(),
        "restoreCheckAt": "NOT_EXECUTED",
        "rootMaintenanceEvidence": "NOT_EXECUTED",
        "rootMaintenanceInterface": "unknown",
        "locksNotAcquired": [
            ".rhythm-integration-writers.lock", ".rhythm-integration-maintenance.json",
            "build_lease", "foreground_lease"],
        "packageStagingLock": "acquired_not_root_maintenance",
        "whitelistAndExclusionManifestSHA256": sha(canonical({"whitelist": whitelist_sha, "exclusion": exclusion_sha})),
        "authoritySHA256": sha(authority_bytes),
        "suppliedPlanFileSHA256": plan_file_sha,
        "suppliedPlanCanonicalSHA256": plan_canonical,
        "suppliedPlanMatchesAuthorityPlanSHA256": True,
        "productionPlanByteHashVerified": "NOT_EXECUTED",
        "productionPlanIdentityDocument": "missing_reports_rootcutover_migration_plan",
        "originalTransactionReceiptSHA256": sha(receipt_bytes),
        "payloadMetadataPolicy": policy,
        "actualArchiveTreeSHA256": archive_sha,
        "isolatedRestoreTargetIdentity": None,
        "pureSourceRawExcludedFromRecoverablePackage": True,
        "businessRawBase64Preserved": business_raw,
        "sqliteSnapshotNotes": notes,
        "widgetPublicationPending": widget_pending,
        "runtime": runtime,
        "reMigration": False,
        "reActivation": False,
        "activeBusinessRolledBack": False,
        "activeWrite": False,
        "realUserDataTouched": False,
        "realRecoveryCompleted": False,
        "scope": "isolated_noindex_only",
        "receiptSchemaAlignment": "partial_names_from_20261105_brief_ellipsis_not_loaded",
        "unseenRootActualCurrentRecoveryFields": "REQUIRED_DOCUMENT",
    }


def public_summary(status, path, business_raw, policy, plan_canonical, authority_sha, receipt_sha):
    return {
        "status": status,
        "package": path.name,
        "businessRawBase64Preserved": business_raw,
        "pureSourceRawExcludedFromRecoverablePackage": True,
        "reMigration": False,
        "reActivation": False,
        "activeBusinessRolledBack": False,
        "activeWrite": False,
        "rootMaintenanceEvidence": "NOT_EXECUTED",
        "productionPlanByteHashVerified": "NOT_EXECUTED",
        "macosQuarantineFidelity": policy["macosQuarantineFidelity"],
        "appleMetadata": policy["appleMetadata"],
        "planCanonicalSHA256": plan_canonical,
        "authoritySHA256": authority_sha,
        "originalTransactionReceiptSHA256": receipt_sha,
        "realRecoveryCompleted": False,
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
    if sha(canonical(archive)) != receipt.get("actualArchiveTreeSHA256"):
        fail("archive_tree_hash_mismatch")
    if receipt.get("realRecoveryCompleted") is not False or receipt.get("reMigration") is not False:
        fail("receipt_claims_forbidden_action")
    if receipt.get("reActivation") is not False or receipt.get("activeBusinessRolledBack") is not False:
        fail("receipt_claims_forbidden_action")
    if receipt.get("productionPlanByteHashVerified") not in ("NOT_EXECUTED", None, False):
        fail("receipt_claims_unexecuted_proof")
    if receipt.get("rootMaintenanceEvidence") != "NOT_EXECUTED":
        fail("receipt_claims_root_maintenance")
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
    if loaded["receipt"].get("suppliedPlanCanonicalSHA256") != plan_canonical:
        fail("package_plan_mismatch")
    payload_group = loaded["payload"] / "GroupContainer"
    authority_bytes, authority = read_authority(payload_group, migration)
    if sha(authority_bytes) != loaded["receipt"]["authoritySHA256"]:
        fail("authority_hash_mismatch")
    if authority["planSHA256"] != plan_canonical or authority["transactionID"] != plan["transactionID"]:
        fail("authority_plan_mismatch")
    if authority["sourceRevisions"] != plan["sourceRevisions"]:
        fail("authority_revision_mismatch")
    active = authority["transactionID"]
    receipt_path = payload_group / "Integration/Transactions.noindex" / active / "receipt.json"
    owner_path = payload_group / "Integration/Transactions.noindex" / active / "owner.json"
    receipt_bytes = read_file(receipt_path)
    if sha(receipt_bytes) != loaded["receipt"]["originalTransactionReceiptSHA256"]:
        fail("transaction_receipt_byte_mismatch")
    if b'"rawBase64"' in receipt_bytes:
        fail("immutable_receipt_contains_rawbase64")
    owner = parse_json(read_file(owner_path))
    if owner != {"transactionID": active, "planSHA256": plan_canonical}:
        fail("owner_json_not_bound")
    runtime = runtime_report(loaded["payload"], upgrade, migration)
    if runtime["preferences"] != loaded["receipt"]["runtime"]["preferences"]:
        fail("preference_digest_mismatch")
    if runtime["rhythmLibrary"]["gameStateSHA256"] != loaded["receipt"]["runtime"]["rhythmLibrary"]["gameStateSHA256"]:
        fail("game_progress_mismatch")
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
    return {
        "status": "verified",
        "realRecoveryCompleted": False,
        "integrateSourcesRuntimeOnly": runtime_only,
        "equivalentReadersApplied": True,
        "isolatedRestoreTargetIdentity": restored_identity,
        "businessRawBase64Preserved": loaded["receipt"]["businessRawBase64Preserved"],
        "pureSourceRawExcludedFromRecoverablePackage": True,
        "productionPlanByteHashVerified": "NOT_EXECUTED",
        "rootMaintenanceEvidence": "NOT_EXECUTED",
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
        receipt["phase"] = "restore-check"
        receipt["restoreCheckAt"] = now()
        receipt["isolatedRestoreTargetIdentity"] = {"device": info_parent.st_dev, "inode": info_parent.st_ino,
                                                     "nameEndsWithNoindex": True, "preexistingGroupRequired": False}
        receipt["realRecoveryCompleted"] = False
        receipt["activeWrite"] = False
        receipt["reMigration"] = False
        receipt["reActivation"] = False
        receipt["activeBusinessRolledBack"] = False
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
            preserved, skipped, _ = copy_xattrs(entry, target)
            if file_meta["xattrs"] != preserved or skipped:
                fail("restore_xattr_mismatch", entry.name)
            os.utime(target, ns=(file_meta["mtimeNs"], file_meta["mtimeNs"]), follow_symlinks=False)
        else:
            fail("unsupported_file_type")
    os.chmod(dest, meta["mode"], follow_symlinks=False)
    preserved, skipped, _ = copy_xattrs(source, dest)
    if meta["xattrs"] != preserved or skipped:
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
