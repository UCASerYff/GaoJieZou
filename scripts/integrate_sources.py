#!/usr/bin/env python3
"""Explicit, fail-closed Health/Footprints integration. No live-path defaults.

plan is read-only except its explicitly requested plan output. apply stages exact
source archives and coherent SQLite backups; activate is the sole authority
commit. Source hosts/widgets must already be stopped by the coordinator.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import ctypes
import datetime as dt
import errno
import fcntl
import hashlib
import json
import math
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
from types import SimpleNamespace
from urllib.parse import quote

SCHEMA = 1
ROOT_KEYS = {"healthGroup", "healthSupport", "healthRestore", "healthPreferences",
             "footprintsSupport", "footprintsGroup", "footprintsRestore",
             "footprintsPreferences", "rhythmLibrary"}
OPTIONAL_ROOTS = {"healthSupport", "healthRestore", "footprintsRestore"}
FILE_ROOTS = {"healthPreferences", "footprintsPreferences", "rhythmLibrary"}
WRITERS = {"com.gaoseries.GaoJianKang", "com.gaoseries.GaoJianKang.widgets",
           "com.gaoseries.GaoZuJi", "com.gaoseries.GaoZuJi.widgets",
           "com.gaojiezou.rhythm", "com.gaojiezou.rhythm.widgets"}
MODULE_PATHS = {"health": "Modules/Health", "footprints": "Modules/Footprints"}
COMPONENTS = ("Modules/Health", "Modules/Footprints", "SharedSleep", "SourceArchives")
TX_RE = re.compile(r"[a-zA-Z0-9_-]{1,128}\Z")
HEX_RE = re.compile(r"[0-9a-f]{64}\Z")


class MigrationError(Exception):
    """Public code only; do not print private rows or paths on failure."""


def require(condition, code):
    if not condition:
        raise MigrationError(code)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parse_json(data):
    def pairs(rows):
        result = {}
        for key, value in rows:
            require(key not in result, "duplicate_json_key")
            result[key] = value
        return result
    def invalid(_):
        raise MigrationError("nonfinite_json_number")
    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)
    except (ValueError, UnicodeError, TypeError):
        raise MigrationError("invalid_json")


def safe_path(value, exists=True):
    require(isinstance(value, str) and value and "\0" not in value, "invalid_path")
    p = Path(value)
    require(p.is_absolute() and ".." not in p.parts, "absolute_path_required")
    for part in reversed([p, *p.parents]):
        if part.exists() or part.is_symlink():
            require(not part.is_symlink(), "symlink_path_refused")
    if exists:
        require(p.exists(), "required_source_missing")
    return p


def read_file(path):
    with os.fdopen(os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)), "rb") as f:
        s = os.fstat(f.fileno())
        require(stat.S_ISREG(s.st_mode) and s.st_mode & 0o444, "unreadable_or_nonregular_file")
        data = f.read()
        after = os.fstat(f.fileno())
        require((s.st_ino, s.st_size, s.st_mtime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns), "source_changed_during_read")
        return data


def file_hash(path):
    h = hashlib.sha256()
    with os.fdopen(os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)), "rb") as f:
        s = os.fstat(f.fileno())
        require(stat.S_ISREG(s.st_mode) and s.st_mode & 0o444, "unreadable_or_nonregular_file")
        while True:
            data = f.read(1024 * 1024)
            if not data:
                break
            h.update(data)
        after = os.fstat(f.fileno())
        require((s.st_ino, s.st_size, s.st_mtime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns), "source_changed_during_read")
    return h.hexdigest()


def xattrs(path):
    """System Python on macOS may omit os xattr functions; never assume empty."""
    if hasattr(os, "listxattr") and hasattr(os, "getxattr"):
        return {name: sha(os.getxattr(path, name, follow_symlinks=False))
                for name in sorted(os.listxattr(path, follow_symlinks=False))}
    require(sys.platform == "darwin", "xattr_api_unavailable")
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    n = libc.listxattr(encoded, None, 0, 1)
    require(n >= 0, "xattr_read_failed")
    buf = ctypes.create_string_buffer(max(n, 1))
    require(libc.listxattr(encoded, buf, n, 1) == n, "xattr_changed_during_read")
    result = {}
    for name in sorted(x for x in buf.raw[:n].split(b"\0") if x):
        size = libc.getxattr(encoded, name, None, 0, 0, 1)
        require(size >= 0, "xattr_read_failed")
        value = ctypes.create_string_buffer(max(size, 1))
        require(libc.getxattr(encoded, name, value, size, 0, 1) == size, "xattr_changed_during_read")
        result[os.fsdecode(name)] = sha(value.raw[:size])
    return result


def acl_digest(path):
    if sys.platform != "darwin":
        return None  # Synthetic tests on other OS; production target is macOS.
    p = subprocess.run(["/bin/ls", "-lde", str(path)], capture_output=True, check=False)
    require(p.returncode == 0, "acl_read_failed")
    entries = [line.strip() for line in p.stdout.splitlines()
               if re.match(rb"^\s*\d+:", line)]
    return sha(b"\n".join(entries))


def metadata(path):
    s = path.lstat()
    require(not stat.S_ISLNK(s.st_mode), "symlink_entry_refused")
    require(stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode), "unsupported_file_type")
    return {"mode": stat.S_IMODE(s.st_mode), "mtimeNs": s.st_mtime_ns,
            "uid": s.st_uid, "gid": s.st_gid, "bsdFlags": getattr(s, "st_flags", 0),
            "xattrs": xattrs(path), "aclSHA256": acl_digest(path)}


def inventory(path):
    safe_path(str(path))
    s = path.lstat()
    if stat.S_ISREG(s.st_mode):
        return {"type": "file", "sha256": file_hash(path), "bytes": s.st_size,
                "metadata": metadata(path)}
    require(stat.S_ISDIR(s.st_mode) and s.st_mode & 0o500 == 0o500, "unreadable_source_directory")
    entries = {}
    def walk(base):
        with os.scandir(base) as listing:
            rows = sorted(listing, key=lambda x: x.name)
        for entry in rows:
            p = Path(entry.path)
            rel = p.relative_to(path).as_posix()
            require(not entry.is_symlink(), "symlink_entry_refused")
            m = metadata(p)
            if entry.is_dir(follow_symlinks=False):
                entries[rel] = {"type": "directory", "metadata": m}
                walk(p)
            else:
                require(entry.is_file(follow_symlinks=False), "unsupported_file_type")
                entries[rel] = {"type": "file", "sha256": file_hash(p),
                                "bytes": p.stat().st_size, "metadata": m}
    walk(path)
    return {"type": "directory", "metadata": metadata(path), "entries": entries}


def atomic_new(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    safe_path(str(path.parent))
    tmp = path.parent / (".write-" + os.urandom(8).hex())
    try:
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                               getattr(os, "O_NOFOLLOW", 0), 0o600), "wb") as f:
            f.write(canonical(value)); f.flush(); os.fsync(f.fileno())
        os.link(tmp, path, follow_symlinks=False)  # no replacing foreign/current data
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if tmp.exists():
            tmp.unlink()


def confirmed_absent(value):
    path = safe_path(value, exists=False)
    try:
        path.lstat()
    except FileNotFoundError:
        parent = path.parent
        while not parent.exists():
            parent = parent.parent
        require(parent.is_dir(), "absence_parent_not_directory")
        with os.scandir(parent) as listing:
            list(listing)  # permission/I/O errors must not become absence
        return
    raise MigrationError("explicitly_absent_source_now_exists")


def load_config(path):
    cfg = parse_json(read_file(safe_path(str(path))))
    require(isinstance(cfg, dict) and cfg.get("schemaVersion") == 1, "invalid_source_config")
    roots = cfg.get("roots")
    require(isinstance(roots, dict) and set(roots) == ROOT_KEYS, "source_roots_incomplete")
    absent = cfg.get("explicitAbsences", [])
    require(isinstance(absent, list) and len(absent) == len(set(absent)) and
            set(absent) <= OPTIONAL_ROOTS, "invalid_explicit_absence")
    require({k for k, v in roots.items() if v is None} == set(absent), "absence_not_explicit")
    absent_paths = cfg.get("absentPaths", {})
    require(isinstance(absent_paths, dict) and set(absent_paths) == set(absent), "absence_paths_missing")
    for value in absent_paths.values():
        confirmed_absent(value)
    resolved = {}
    for name, value in roots.items():
        if value is None:
            require(name in OPTIONAL_ROOTS, "required_source_missing")
            resolved[name] = None
        else:
            p = safe_path(value)
            require(p.is_file() if name in FILE_ROOTS else p.is_dir(), "wrong_source_root_type")
            resolved[name] = str(p)
    return {"schemaVersion": 1, "roots": resolved, "explicitAbsences": sorted(absent),
            "absentPaths": absent_paths}


def collect_sources(cfg):
    result = {}
    for name, value in sorted(cfg["roots"].items()):
        result[name] = {"path": value, "explicitlyAbsent": value is None}
        if value is None:
            expected_path = cfg["absentPaths"][name]
            confirmed_absent(expected_path)
            result[name]["absentPath"] = expected_path
        if value is not None:
            p = Path(value); s = p.lstat()
            result[name].update(identity={"device": s.st_dev, "inode": s.st_ino}, tree=inventory(p))
    return result


def revisions(sources):
    return {name: sha(canonical(value)) for name, value in sources.items()}


def qi(name):
    return '"' + name.replace('"', '""') + '"'


def sqlite_clone(source, directory):
    """Copy main+sidecars before SQLite opens, so no source read-mark writes."""
    directory.mkdir(mode=0o700)
    target = directory / source.name
    for suffix in ("", "-wal", "-shm", "-journal"):
        p = Path(str(source) + suffix)
        if p.exists():
            require(not p.is_symlink() and p.is_file(), "unsafe_database_sidecar")
            shutil.copyfile(p, Path(str(target) + suffix), follow_symlinks=False)
    require(target.is_file() and target.stat().st_size > 0, "database_missing_or_empty")
    return target


def open_ro(path):
    return sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=ro", uri=True, timeout=10)


def cell(value):
    if isinstance(value, bytes):
        return {"blob": base64.b64encode(value).decode("ascii")}
    require(not isinstance(value, float) or math.isfinite(value), "nonfinite_database_value")
    return value


def sql_summary(connection):
    require(connection.execute("PRAGMA quick_check").fetchall() == [("ok",)], "sqlite_integrity_failed")
    objects = connection.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    tables = {}
    for kind, name, _, _ in objects:
        if kind != "table":
            continue
        rows = [canonical([cell(v) for v in row]).decode("utf-8")
                for row in connection.execute("SELECT * FROM " + qi(name))]
        tables[name] = {"count": len(rows), "rowsSHA256": sha(canonical(sorted(rows))),
                        "columns": [list(x) for x in connection.execute("PRAGMA table_info(" + qi(name) + ")").fetchall()]}
    return {"userVersion": connection.execute("PRAGMA user_version").fetchone()[0],
            "schemaSHA256": sha(canonical(objects)), "tables": tables}


def payload_object(value):
    require(isinstance(value, (str, bytes)), "missing_json_payload")
    result = parse_json(value)
    require(isinstance(result, dict), "invalid_json_payload")
    return result


def require_table(c, name, columns, primary_key):
    rows = c.execute("PRAGMA table_info(" + qi(name) + ")").fetchall()
    require({r[1]: r[2].upper() for r in rows} == columns and
            [r[1] for r in sorted(rows, key=lambda r: r[5]) if r[5] > 0] == primary_key,
            "unsupported_database_table_shape")


def validate_health(c):
    version = c.execute("PRAGMA user_version").fetchone()[0]
    require(version in (0, 1), "unsupported_health_database_schema")
    require_table(c, "state", {"id":"INTEGER", "json":"BLOB"}, ["id"])
    if version == 1:
        require_table(c, "records", {"id":"TEXT", "kind":"TEXT", "occurred_at":"REAL", "json":"BLOB"}, ["id"])
        require_table(c, "events", {"id":"TEXT", "type_id":"TEXT", "occurred_at":"REAL", "json":"BLOB"}, ["id"])
    rows = c.execute("SELECT id,json FROM state").fetchall()
    require(len(rows) == 1 and rows[0][0] == 1, "health_state_missing_or_duplicated")
    state = payload_object(rows[0][1])
    require(type(state.get("schemaVersion")) is int and state["schemaVersion"] in (1, 2),
            "unsupported_health_payload_schema")
    for key, kind in (("preferences", dict), ("island", dict), ("ledgers", dict), ("requests", list)):
        require(isinstance(state.get(key), kind), "incomplete_health_payload")
    if version == 1:
        for table in ("records", "events"):
            for row_id, blob in c.execute("SELECT id,json FROM " + table):
                obj = payload_object(blob)
                require(isinstance(row_id, str) and obj.get("id") == row_id, "health_row_identity_mismatch")
    return {"stateSchema": state["schemaVersion"], "identityPolicy": "preserve_all_rows_and_reward_keys"}


def validate_footprints(c, photos):
    require(c.execute("PRAGMA user_version").fetchone()[0] == 0,
            "unsupported_footprint_database_schema")
    require_table(c, "items", {"kind":"TEXT", "id":"TEXT", "payload":"BLOB"}, ["kind", "id"])
    meta = None
    attachments = {}
    visits = []
    for kind, row_id, blob in c.execute("SELECT kind,id,payload FROM items"):
        require(kind in ("visit", "trip", "city", "photo", "meta"), "unknown_footprint_row_kind")
        obj = payload_object(blob)
        if kind == "meta":
            require(row_id == "main" and meta is None and type(obj.get("schema")) is int and obj["schema"] == 1,
                    "unsupported_or_duplicate_footprint_metadata")
            meta = obj
        else:
            require(isinstance(row_id, str) and row_id and obj.get("id") == row_id,
                    "footprint_row_identity_mismatch")
            if kind == "photo":
                filename = obj.get("filename")
                require(filename == row_id + ".jpg" and re.fullmatch(r"[A-Fa-f0-9-]{36}\.jpg", filename),
                        "unsafe_photo_filename")
                p = photos / filename
                require(p.is_file() and not p.is_symlink() and p.stat().st_size == obj.get("size")
                        and file_hash(p) == obj.get("sha256"), "photo_missing_or_changed")
                attachments[row_id] = obj
            if kind == "visit":
                visits.append(obj)
    require(meta is not None, "footprint_metadata_missing")
    for visit in visits:
        require(isinstance(visit.get("photoIDs", []), list) and
                set(visit.get("photoIDs", [])) <= set(attachments), "footprint_photo_reference_missing")
    return {"schema": 1, "photoCount": len(attachments), "identityPolicy": "preserve_all_rows_and_train_state"}


def validate_sleep(c, rhythm=None):
    require(c.execute("PRAGMA user_version").fetchone()[0] == 1, "unsupported_shared_sleep_schema")
    require_table(c, "sleep_metadata", {"id":"INTEGER", "version":"INTEGER"}, ["id"])
    require_table(c, "sleep_records", {"id":"TEXT", "payload":"BLOB", "deleted":"INTEGER"}, ["id"])
    require_table(c, "sleep_migrations", {"key":"TEXT"}, ["key"])
    require(c.execute("SELECT id,version FROM sleep_metadata").fetchall() == [(1, 1)], "invalid_sleep_metadata")
    migrations = [x[0] for x in c.execute("SELECT key FROM sleep_migrations")]
    require("rhythm-library-v1" in migrations, "legacy_sleep_seed_not_complete")
    require(all(isinstance(x, str) and x and "\0" not in x for x in migrations), "invalid_sleep_migration_key")
    records = {}
    for row_id, blob, deleted in c.execute("SELECT id,payload,deleted FROM sleep_records"):
        require(isinstance(row_id, str) and row_id and "\0" not in row_id and type(deleted) is int and deleted in (0, 1),
                "invalid_sleep_identity_or_tombstone")
        obj = None if deleted else payload_object(blob)
        if obj is not None:
            require(obj.get("id") == row_id, "sleep_payload_identity_mismatch")
            require(all(isinstance(obj.get(k), (float, int)) and not isinstance(obj.get(k), bool)
                        and math.isfinite(obj[k]) for k in ("startedAt", "endedAt", "durationSeconds")),
                    "invalid_sleep_time")
            require(obj["endedAt"] >= obj["startedAt"] and obj["durationSeconds"] >= 0,
                    "invalid_sleep_interval")
        records[row_id] = obj
    if rhythm is None:
        return {"schema": 1, "legacySeedComplete": True,
                "tombstones": sum(v is None for v in records.values())}
    require(type(rhythm.get("version")) is int and rhythm["version"] == 11 and isinstance(rhythm.get("sleepRecords"), list),
            "unsupported_rhythm_library_schema")
    require(rhythm.get("activeSleep") is None and rhythm.get("activeFocus") is None,
            "active_rhythm_session_requires_coordinated_freeze")
    ids = set()
    for record in rhythm["sleepRecords"]:
        require(isinstance(record, dict) and isinstance(record.get("id"), str) and record["id"] not in ids,
                "invalid_or_duplicate_rhythm_sleep_identity")
        row_id = record["id"]; ids.add(row_id)
        require(row_id in records, "pending_rhythm_sleep_not_in_canonical_journal")
        stored = records[row_id]
        if stored is None:  # explicit canonical deletion always wins
            continue
        for key in ("startedAt", "endedAt", "durationSeconds", "score"):
            require(stored.get(key) == record.get(key), "rhythm_sleep_pending_content_mismatch")
        for key in ("pastureYield", "healthGrowthCreditedSeconds", "healthProductionCreditedCycles",
                    "manualGrowthCreditedSeconds", "manualProductionCreditedCycles"):
            require((stored.get(key) or 0) >= (record.get(key) or 0), "rhythm_sleep_pending_settlement_mismatch")
    return {"schema": 1, "legacySeedComplete": True, "rhythmSleepIDsAccountedFor": len(ids),
            "tombstones": sum(v is None for v in records.values()), "noImportOrRewardReplay": True}


def preferences(path):
    try:
        value = plistlib.loads(read_file(path))
    except (ValueError, plistlib.InvalidFileException):
        raise MigrationError("invalid_preference_export")
    require(isinstance(value, dict) and isinstance(value.get("standard"), dict)
            and isinstance(value.get("module"), dict), "preference_domains_not_explicit")
    module = value["module"]
    for key, typ in (("animationEnabled", bool), ("soundEnabled", bool), ("ownerName", str)):
        if key in module:
            require(type(module[key]) is typ, "invalid_mapped_preference_type")
    if "gqns.language" in value["standard"]:
        require(value["standard"]["gqns.language"] in ("system", "zh-Hans", "en"), "invalid_source_language")
    return value


def inspect_databases(cfg):
    roots = cfg["roots"]
    paths = {"health": Path(roots["healthGroup"]) / "Health/health.sqlite",
             "footprints": Path(roots["footprintsSupport"]) / "footprints.sqlite",
             "sharedSleep": Path(roots["healthGroup"]) / "SharedSleep/sleep-records.sqlite"}
    if roots["healthSupport"] is not None:
        collision = Path(roots["healthGroup"]) / "Health/ImportedSupport"
        require(not collision.exists() and not collision.is_symlink(), "imported_support_name_conflict")
    rhythm = parse_json(read_file(Path(roots["rhythmLibrary"])))
    require(isinstance(rhythm, dict), "invalid_rhythm_library")
    result = {}
    with tempfile.TemporaryDirectory(suffix=".noindex") as directory:
        tmp = Path(directory).resolve()
        for name, source in paths.items():
            staged = sqlite_clone(source, tmp / name)
            with contextlib.closing(open_ro(staged)) as c:
                c.execute("BEGIN")
                summary = sql_summary(c)
                if name == "health":
                    validation = validate_health(c)
                elif name == "footprints":
                    validation = validate_footprints(c, Path(roots["footprintsSupport"]) / "Photos")
                else:
                    validation = validate_sleep(c, rhythm)
                result[name] = {"summary": summary, "validation": validation}
    preferences(Path(roots["healthPreferences"])); preferences(Path(roots["footprintsPreferences"]))
    return result


def make_plan(config_path, target_group, transaction):
    require(TX_RE.fullmatch(transaction) is not None, "invalid_transaction_id")
    cfg = load_config(config_path)
    target = safe_path(str(target_group))
    require(target.is_dir(), "target_group_missing")
    for value in list(cfg["roots"].values()) + list(cfg["absentPaths"].values()):
        if value is not None:
            p = Path(value)
            require(target != p and target not in p.parents and p not in target.parents,
                    "source_target_overlap")
    sources = collect_sources(cfg)
    databases = inspect_databases(cfg)
    require(sources == collect_sources(cfg), "source_changed_during_plan")
    return {"schemaVersion": 1, "kind": "RhythmSourceIntegrationPlan", "transactionID": transaction,
            "createdAt": now(), "targetGroup": str(target), "sourceConfig": cfg,
            "sources": sources, "sourceRevisions": revisions(sources), "databases": databases,
            "modulePaths": dict(MODULE_PATHS), "sharedSleepPath": "SharedSleep",
            "noBusinessRewardReplay": True, "permissionsNotTransferred": True}


def load_plan(path):
    plan = parse_json(read_file(safe_path(str(path))))
    require(isinstance(plan, dict) and plan.get("schemaVersion") == 1 and
            plan.get("kind") == "RhythmSourceIntegrationPlan" and
            TX_RE.fullmatch(plan.get("transactionID", "")) is not None, "invalid_plan")
    require(plan.get("modulePaths") == MODULE_PATHS and plan.get("sharedSleepPath") == "SharedSleep",
            "invalid_runtime_layout")
    require(set(plan.get("sourceRevisions", {})) == ROOT_KEYS and
            all(HEX_RE.fullmatch(x or "") for x in plan["sourceRevisions"].values()), "invalid_source_revisions")
    require(revisions(plan["sources"]) == plan["sourceRevisions"], "plan_revision_mismatch")
    return plan


def validate_freeze(plan, path):
    receipt = parse_json(read_file(safe_path(str(path))))
    require(isinstance(receipt, dict) and receipt.get("schemaVersion") == 1 and
            receipt.get("transactionID") == plan["transactionID"] and
            receipt.get("planSHA256") == sha(canonical(plan)) and
            receipt.get("sourceRevisions") == plan["sourceRevisions"] and
            receipt.get("sourcesFrozen") is True, "freeze_receipt_mismatch")
    require(isinstance(receipt.get("stoppedWriterBundleIDs"), list) and
            WRITERS <= set(receipt["stoppedWriterBundleIDs"]), "not_all_source_and_target_writers_frozen")
    require(receipt.get("footprintsPublisherStopped") is True and
            receipt.get("oldWidgetsCannotWrite") is True, "independent_writers_not_frozen")
    require(receipt.get("backupsVerified") is True and receipt.get("rollbackVerified") is True,
            "restorable_backups_not_verified")
    require(isinstance(receipt.get("verifiedAt"), str) and receipt["verifiedAt"] and
            isinstance(receipt.get("evidence"), list) and receipt["evidence"], "freeze_evidence_missing")
    return receipt


def source_cas(plan):
    require(collect_sources(plan["sourceConfig"]) == plan["sources"], "source_changed_since_plan")
    require(inspect_databases(plan["sourceConfig"]) == plan["databases"], "source_database_changed_since_plan")
    require(collect_sources(plan["sourceConfig"]) == plan["sources"], "source_changed_during_database_check")


def copy_exact(source, target):
    safe_path(str(source)); require(not target.exists() and not target.is_symlink(), "copy_target_exists")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if sys.platform == "darwin":
        p = subprocess.run(["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", str(source), str(target)],
                           capture_output=True, check=False)
        require(p.returncode == 0, "metadata_preserving_copy_failed")
    elif source.is_dir():
        shutil.copytree(source, target, copy_function=shutil.copy2)
    else:
        shutil.copy2(source, target, follow_symlinks=False)
    require(inventory(source) == inventory(target), "copied_tree_verification_failed")


def native_copy_api():
    return SimpleNamespace(require=require, canonical=canonical, sha=sha,
                           safe_path=safe_path, inventory=inventory, metadata=metadata,
                           read_file=read_file, file_hash=file_hash, atomic_new=atomic_new)


def coherent_database(path, expected, native=None, source_key=None, source_relative=None):
    """Operate only on private copies; archive preserves original physical WAL."""
    source_metadata = metadata(path)
    tmp = path.parent / (path.name + ".coherent-" + os.urandom(6).hex())
    temporary = (native.create_database_temporary(path, tmp, source_key, source_relative)
                 if native is not None else None)
    try:
        with contextlib.closing(open_ro(path)) as reader, contextlib.closing(sqlite3.connect(tmp)) as writer:
            require(sql_summary(reader) == expected, "staged_database_mismatch")
            reader.backup(writer)
            # Prepared files are self-contained, so a read-only inspection cannot
            # create WAL/SHM files before activation. Runtime may re-enable WAL.
            require(writer.execute("PRAGMA journal_mode=DELETE").fetchone()[0] == "delete",
                    "sqlite_snapshot_not_self_contained")
        with contextlib.closing(open_ro(tmp)) as check:
            require(sql_summary(check) == expected, "sqlite_backup_logical_mismatch")
        if sys.platform == "darwin":
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            libc.copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
            libc.copyfile.restype = ctypes.c_int
            require(libc.copyfile(os.fsencode(path), os.fsencode(tmp), None, 7) == 0,
                    "sqlite_metadata_copy_failed")  # ACL | STAT | XATTR, never DATA
        else:
            shutil.copystat(path, tmp, follow_symlinks=False)
        if native is not None:
            native.check_database_metadata(path, tmp, source_key, source_relative, source_metadata)
        else:
            require(metadata(path) == metadata(tmp), "sqlite_metadata_copy_mismatch")
        os.replace(tmp, path)
        if native is not None:
            native.finalize_database_metadata(path, source_key, source_relative)
        for suffix in ("-wal", "-shm", "-journal"):
            sidecar = Path(str(path) + suffix)
            if sidecar.exists():
                require(sidecar.is_file() and not sidecar.is_symlink(), "unsafe_staged_sidecar")
                sidecar.unlink()
    finally:
        if temporary is not None:
            temporary.close()


def sync_tree(path):
    files = []
    directories = []
    for current, names, filenames in os.walk(path, followlinks=False):
        directories.append(Path(current))
        files.extend(Path(current) / name for name in filenames)
    for file in files:
        require(file.is_file() and not file.is_symlink(), "unsafe_durable_payload")
        fd = os.open(file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    for directory in reversed(directories):
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def build_payload(plan, payload, native_policy=None, native_result=None):
    roots = plan["sourceConfig"]["roots"]
    payload.mkdir(mode=0o700)
    native = None
    if native_policy is not None:
        from native_copy import NativeCopySession
        native = NativeCopySession(api=native_copy_api(), plan=plan,
                                   policy_path=native_policy, payload=payload)

    def clone(source, target, key, relative="."):
        if native is None:
            copy_exact(source, target)
        else:
            native.copy(source, target, key, relative)

    mappings = {"healthGroup": "SourceArchives/Health/AppGroup",
                "healthSupport": "SourceArchives/Health/ApplicationSupport",
                "healthRestore": "SourceArchives/Health/PendingRestore",
                "healthPreferences": "SourceArchives/Health/Preferences.plist",
                "footprintsSupport": "SourceArchives/Footprints/ApplicationSupport",
                "footprintsGroup": "SourceArchives/Footprints/AppGroup",
                "footprintsRestore": "SourceArchives/Footprints/PendingRestore",
                "footprintsPreferences": "SourceArchives/Footprints/Preferences.plist",
                "rhythmLibrary": "SourceArchives/Rhythm/library.json"}
    for name, relative in mappings.items():
        if roots[name] is not None:
            clone(Path(roots[name]), payload / relative, name)
    clone(Path(roots["healthGroup"]) / "Health", payload / "Modules/Health", "healthGroup", "Health")
    if roots["healthSupport"] is not None:
        imported = payload / "Modules/Health/ImportedSupport"
        require(not imported.exists() and not imported.is_symlink(), "imported_support_name_conflict")
        # This is a user-file tree, not a known business database root. Keep
        # documents, empty directories, metadata and arbitrary DB/WAL bytes raw.
        clone(Path(roots["healthSupport"]), imported, "healthSupport")
    clone(Path(roots["footprintsSupport"]), payload / "Modules/Footprints", "footprintsSupport")
    require(not (payload / "Modules/Footprints/WidgetData").exists(), "widget_data_name_conflict")
    clone(Path(roots["footprintsGroup"]), payload / "Modules/Footprints/WidgetData", "footprintsGroup")
    clone(Path(roots["healthGroup"]) / "SharedSleep", payload / "SharedSleep", "healthGroup", "SharedSleep")
    for name, relative, key, source_relative in (
            ("health", "Modules/Health/health.sqlite", "healthGroup", "Health/health.sqlite"),
            ("footprints", "Modules/Footprints/footprints.sqlite", "footprintsSupport", "footprints.sqlite"),
            ("sharedSleep", "SharedSleep/sleep-records.sqlite", "healthGroup", "SharedSleep/sleep-records.sqlite")):
        if native is None:
            coherent_database(payload / relative, plan["databases"][name]["summary"])
        else:
            coherent_database(payload / relative, plan["databases"][name]["summary"],
                              native, key, source_relative)
    for name, key in (("Health", "healthPreferences"), ("Footprints", "footprintsPreferences")):
        prefs = preferences(Path(roots[key]))
        data = {"schema": 1, "transactionID": plan["transactionID"],
                "standard": prefs["standard"], "module": prefs["module"]}
        target = payload / ("Modules/" + name + "/Preferences.plist")
        require(not target.exists(), "migration_preferences_name_conflict")
        with target.open("xb") as f:
            os.chmod(target, 0o600); plistlib.dump(data, f, fmt=plistlib.FMT_BINARY, sort_keys=True)
    atomic_new(payload / "SourceArchives/explicit-absences.json",
               {"schemaVersion": 1, "transactionID": plan["transactionID"],
                "explicitAbsences": plan["sourceConfig"]["explicitAbsences"],
                "absentPaths": plan["sourceConfig"]["absentPaths"]})
    sync_tree(payload)
    components = {relative: inventory(payload / relative) for relative in COMPONENTS}
    if native is not None:
        manifest = native.manifest(components)
        if native_result is not None:
            native_result.update(manifest)
    return components


@contextlib.contextmanager
def target_lock(plan):
    root = safe_path(plan["targetGroup"]) / "Integration"
    require(not root.is_symlink(), "unsafe_integration_root")
    root.mkdir(mode=0o700, exist_ok=True)
    safe_path(str(root))
    fd = os.open(root / ".migration.lock", os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), "unsafe_migration_lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise MigrationError("another_migration_is_running")
        yield root
    finally:
        os.close(fd)


def transaction_root(root, plan):
    parent = root / "Transactions.noindex"
    require(not parent.is_symlink(), "unsafe_transaction_parent")
    parent.mkdir(mode=0o700, exist_ok=True)
    tx = parent / plan["transactionID"]
    require(not tx.is_symlink(), "unsafe_transaction_directory")
    return tx


def read_receipt(root, plan):
    tx = transaction_root(root, plan)
    receipt = parse_json(read_file(tx / "receipt.json"))
    require(receipt.get("schemaVersion") == 1 and receipt.get("transactionID") == plan["transactionID"]
            and receipt.get("planSHA256") == sha(canonical(plan)), "transaction_receipt_mismatch")
    require(set(receipt.get("components", {})) == set(COMPONENTS), "transaction_components_incomplete")
    return tx, receipt


def active_for(root, plan):
    path = root / "authority.json"
    if not path.exists() and not path.is_symlink():
        return None
    authority = parse_json(read_file(path))
    require(authority.get("schemaVersion") == 1 and authority.get("state") == "active" and
            authority.get("transactionID") == plan["transactionID"] and
            authority.get("sourceRevisions") == plan["sourceRevisions"] and
            authority.get("modulePaths") == MODULE_PATHS and
            authority.get("sharedSleepPath") == "SharedSleep" and
            authority.get("planSHA256") == sha(canonical(plan)), "authority_conflict")
    return authority


def verify_current_runtime(root):
    paths = {"health": root / "Modules/Health/health.sqlite",
             "footprints": root / "Modules/Footprints/footprints.sqlite",
             "sharedSleep": root / "SharedSleep/sleep-records.sqlite"}
    with tempfile.TemporaryDirectory(suffix=".noindex") as directory:
        for name, path in paths.items():
            before = {suffix: file_hash(Path(str(path) + suffix))
                      for suffix in ("", "-wal", "-shm", "-journal")
                      if Path(str(path) + suffix).exists()}
            clone = sqlite_clone(path, Path(directory).resolve() / name)
            after = {suffix: file_hash(Path(str(path) + suffix))
                     for suffix in ("", "-wal", "-shm", "-journal")
                     if Path(str(path) + suffix).exists()}
            require(before == after, "current_database_busy_retry_without_writes")
            with contextlib.closing(open_ro(clone)) as c:
                c.execute("BEGIN")
                sql_summary(c)
                if name == "health":
                    validate_health(c)
                elif name == "footprints":
                    validate_footprints(c, root / "Modules/Footprints/Photos")
                else:
                    validate_sleep(c)


def verify_prepared(root, plan, strict=True, runtime_only=False):
    require(not runtime_only or (not strict and active_for(root, plan) is not None),
            "runtime_only_requires_active_authority")
    tx, receipt = read_receipt(root, plan)
    archive_tree = None
    for relative in COMPONENTS:
        if runtime_only and relative == "SourceArchives":
            continue  # accepted source recovery copies are not current business data
        destination = root / relative
        require(destination.exists() and not destination.is_symlink(), "prepared_component_missing")
        if strict or relative == "SourceArchives":
            current = inventory(destination)
            if relative == "SourceArchives":
                archive_tree = current
            if "nativeCopyMetadata" in receipt:
                import native_copy
                matches = native_copy.component_matches(native_copy_api(), plan, root, receipt, relative, current)
            else:
                matches = current == receipt["components"][relative]
            require(matches, "prepared_or_archived_data_changed")
    if "nativeCopyMetadata" in receipt and not runtime_only:
        import native_copy
        native_copy.verify_native_receipt(native_copy_api(), plan, root, receipt, archive_tree=archive_tree)
    if not strict:
        verify_current_runtime(root)
    return receipt


def apply(plan, freeze_path, native_policy=None):
    with target_lock(plan) as root:
        if active_for(root, plan):
            verify_prepared(root, plan, strict=False)
            return {"status": "already_active", "transactionID": plan["transactionID"], "wroteBusinessData": False}
        freeze = validate_freeze(plan, freeze_path)
        source_cas(plan)
        tx = transaction_root(root, plan)
        if not tx.exists():
            tx.mkdir(mode=0o700)
            atomic_new(tx / "owner.json", {"transactionID": plan["transactionID"], "planSHA256": sha(canonical(plan))})
        owner = parse_json(read_file(tx / "owner.json"))
        require(owner == {"transactionID": plan["transactionID"], "planSHA256": sha(canonical(plan))}, "foreign_transaction")
        receipt_path = tx / "receipt.json"
        if not receipt_path.exists():
            require(not any((root / c).exists() for c in COMPONENTS), "unowned_runtime_component_exists")
            # An interrupted private preparation is retained, never overlaid or
            # deleted. A new attempt is recorded; no authority points to either.
            attempt = tx / ("Payload-" + os.urandom(8).hex())
            native_result = {}
            if native_policy is None:
                components = build_payload(plan, attempt)
            else:
                components = build_payload(plan, attempt, native_policy, native_result)
            source_cas(plan)
            receipt = {"schemaVersion": 1, "transactionID": plan["transactionID"],
                       "planSHA256": sha(canonical(plan)), "preparedAt": now(),
                       "payload": attempt.name, "components": components,
                       "sourceRevisions": plan["sourceRevisions"], "freezeReceipt": freeze,
                       "freezeReceiptSHA256": sha(canonical(freeze)), "noRewardReplay": True}
            if native_result:
                receipt["nativeCopyMetadata"] = native_result
            atomic_new(receipt_path, receipt)
        tx, receipt = read_receipt(root, plan)
        payload_name = receipt.get("payload", "")
        require(re.fullmatch(r"Payload-[0-9a-f]{16}", payload_name) is not None, "unsafe_payload_path")
        payload = tx / payload_name
        for relative in COMPONENTS:
            destination = root / relative
            if destination.exists() or destination.is_symlink():
                current = inventory(destination)
                if "nativeCopyMetadata" in receipt:
                    import native_copy
                    matches = native_copy.component_matches(native_copy_api(), plan, root, receipt, relative, current)
                else:
                    matches = current == receipt["components"][relative]
                require(matches, "runtime_component_conflict")
                continue
            source = payload / relative
            require(inventory(source) == receipt["components"][relative], "staged_component_changed")
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            safe_path(str(destination.parent))
            if "nativeCopyMetadata" in receipt:
                import native_copy
                native_copy.move_component(native_copy_api(), plan, root, receipt, relative, source, destination)
            else:
                os.rename(source, destination)
            for directory in (source.parent, destination.parent):
                fd = os.open(directory, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
        verify_prepared(root, plan)
        source_cas(plan)
        return {"status": "prepared_not_active", "transactionID": plan["transactionID"],
                "authorityCommitted": False, "noRewardReplay": True}


def activate(plan, freeze_path):
    with target_lock(plan) as root:
        if active_for(root, plan):
            verify_prepared(root, plan, strict=False)
            return {"status": "already_active", "transactionID": plan["transactionID"], "wroteBusinessData": False}
        freeze = validate_freeze(plan, freeze_path)
        verify_prepared(root, plan)
        source_cas(plan)
        authority = {"schemaVersion": 1, "state": "active", "transactionID": plan["transactionID"],
                     "modulePaths": dict(MODULE_PATHS), "sharedSleepPath": "SharedSleep",
                     "sourceRevisions": plan["sourceRevisions"], "planSHA256": sha(canonical(plan)),
                     "activatedAt": now(), "freezeReceiptSHA256": sha(canonical(freeze)),
                     "permissionsTransferred": False, "noRewardReplay": True}
        atomic_new(root / "authority.json", authority)
        return {"status": "active", "transactionID": plan["transactionID"], "authorityCommitted": True,
                "sourceFilesModified": False}


def verify(plan, strict=False, runtime_only=False):
    root = safe_path(plan["targetGroup"]) / "Integration"
    require(root.is_dir(), "integration_not_prepared")
    authority = active_for(root, plan)
    verify_prepared(root, plan, strict=strict or authority is None, runtime_only=runtime_only)
    return {"status": "active" if authority else "prepared_not_active", "transactionID": plan["transactionID"],
            "strictImportedState": strict or authority is None,
            "sourceArchivesChecked": not runtime_only,
            "boundary": "Runtime-only checks active business data; ordinary/strict verification still checks source recovery copies."}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    a = sub.add_parser("plan")
    a.add_argument("--source-config", type=Path, required=True)
    a.add_argument("--target-group", type=Path, required=True)
    a.add_argument("--transaction", required=True)
    a.add_argument("--output", type=Path, required=True)
    for name in ("apply", "activate", "verify"):
        a = sub.add_parser(name); a.add_argument("--plan", type=Path, required=True)
        if name != "verify":
            a.add_argument("--freeze-receipt", type=Path, required=True)
            if name == "apply":
                a.add_argument("--native-metadata-policy", type=Path)
        else:
            a.add_argument("--strict-import", action="store_true")
            a.add_argument("--runtime-only", action="store_true")
    args = p.parse_args(argv)
    try:
        if args.command == "plan":
            plan = make_plan(args.source_config, args.target_group, args.transaction)
            out = safe_path(str(args.output.absolute()), exists=False)
            for value in list(plan["sourceConfig"]["roots"].values()) + list(plan["sourceConfig"]["absentPaths"].values()):
                if value is not None:
                    require(Path(value) != out and Path(value) not in out.parents, "plan_output_overlaps_source")
            target = Path(plan["targetGroup"])
            require(target != out and target not in out.parents, "plan_output_overlaps_target")
            atomic_new(out, plan)
            result = {"status": "planned_read_only", "transactionID": args.transaction,
                      "planSHA256": sha(canonical(plan)), "sourceRevisions": plan["sourceRevisions"],
                      "targetTouched": False}
        else:
            plan = load_plan(args.plan)
            if args.command == "verify":
                result = verify(plan, args.strict_import, args.runtime_only)
            elif args.command == "apply":
                result = apply(plan, args.freeze_receipt, args.native_metadata_policy)
            else:
                result = activate(plan, args.freeze_receipt)
        print(json.dumps(result, ensure_ascii=False)); return 0
    except (MigrationError, OSError, sqlite3.Error, ValueError, KeyError, TypeError) as e:
        code = str(e) if isinstance(e, MigrationError) else type(e).__name__
        print(json.dumps({"ok": False, "error": code, "sourceDataRetained": True}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
