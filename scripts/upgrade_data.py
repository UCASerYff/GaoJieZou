#!/usr/bin/env python3
"""Privately snapshot and verify Rhythm data without modifying live files.

Quit the app before each check so its 30-second save cannot race the copy:
  python3 scripts/upgrade_data.py snapshot --version 4.01
  python3 scripts/upgrade_data.py verify-live /path/returned/as/backup

All data-root and App Group files, including attachments and database sidecars,
are copied and SHA-256 checked. Preferences are exported read-only. Keychain
credentials stay in the existing system Keychain and are never exported.
The current data format/path is preserved; no restoration, migration or deletion
of live data is performed. Missing/unreadable required data fails closed.

Verification is strict: advancing focus, sleep or game state is reported as a
separate difference, never silently accepted. JSON whitespace and Swift Set
ordering are immaterial. Only aggregate counts and public error codes are printed.
Fixture roots can be supplied without accessing real user data or preferences.
"""

from __future__ import annotations

import argparse
import copy
from contextlib import closing
import datetime as dt
import hashlib
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
from xml.parsers.expat import ExpatError

FORMAT = 1
APP_ID = "com.gaojiezou.rhythm"
DOMAINS = (APP_ID, APP_ID + ".Rhythm")
LIBRARY_REL = "library.json"
MANIFEST = "manifest.json"
MAX_SCHEMA = 11
COLLECTIONS = ("habits", "chores", "focusRecords", "sleepRecords", "longGoals",
               "shortActions", "rewardEvents")
OPTIONAL_COLLECTIONS = {"chores"}
GAME_COLLECTIONS = ("farmPlots", "ownedAnimals", "pastureAnimals", "aquariumFish", "decorations")
OPTIONAL_GAME_COLLECTIONS = {"ownedAnimals", "pastureAnimals", "aquariumFish", "decorations"}
GAME_FIELDS = (*GAME_COLLECTIONS, "coins", "bait", "animalShelterCapacity",
               "fishInventory", "fishCaught", "harvestedCrops")
SET_FIELDS = ("habitCompletionKeys", "habitRewardKeys")
SESSIONS = ("activeFocus", "activeSleep")
ATTACHMENT_EXTENSIONS = {".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
                         ".jpg", ".jpeg", ".png", ".heic", ".gif", ".webp", ".tiff",
                         ".mov", ".mp4", ".mp3", ".m4a", ".wav", ".zip"}
# Codable fields in Sources/Models.swift. Optional compatibility fields are
# retained and hashed even when they are not present in an older archive.
REQUIRED_STRINGS = {
    "habits": "id title symbol", "chores": "id title",
    "focusRecords": "id title", "sleepRecords": "id",
    "longGoals": "id title reason outcome unit status",
    "shortActions": "id title notes", "rewardEvents": "id title detail symbol",
    "farmPlots": "id", "ownedAnimals": "id animalID",
    "pastureAnimals": "id animalID", "aquariumFish": "id fishID",
    "decorations": "id definitionID", "activeFocus": "id title", "activeSleep": "id",
}
REQUIRED_NUMBERS = {
    "habits": "rewardCoins createdAt", "chores": "startDate endDate",
    "focusRecords": "startedAt endedAt durationSeconds earnedCoins",
    "sleepRecords": "startedAt endedAt durationSeconds score pastureYield",
    "longGoals": "targetValue currentValue startDate targetDate createdAt",
    "shortActions": "dueDate estimatedMinutes focusedSeconds createdAt",
    "rewardEvents": "date coins", "farmPlots": "growthMinutes nextFocusBoost",
    "ownedAnimals": "count pendingProducts",
    "pastureAnimals": "growthHours pendingProducts acquiredAt",
    "aquariumFish": "addedAt lastIncomeDate", "decorations": "level placedAt",
    "activeFocus": "startedAt accumulatedSeconds", "activeSleep": "startedAt",
}
REQUIRED_BOOLEANS = {
    "chores": "isCompleted rewardClaimed", "longGoals": "rewardClaimed",
    "shortActions": "isCompleted rewardClaimed", "activeFocus": "pausedForSystem",
}


class SafetyError(Exception):
    """The message is a public, non-sensitive error code."""


def fail(code: str) -> None:
    raise SafetyError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def parse_json(data: bytes) -> object:
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail("duplicate_json_key")
            result[key] = value
        return result

    def reject_constant(_):
        fail("nonfinite_json_number")

    try:
        return json.loads(data, object_pairs_hook=unique_keys, parse_constant=reject_constant)
    except (ValueError, UnicodeError):
        fail("invalid_json")


def file_hash(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    checksum = hashlib.sha256()
    with os.fdopen(os.open(path, flags), "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            fail("unsupported_file_type")
        while data := source.read(1024 * 1024):
            checksum.update(data)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ino) != (
                after.st_size, after.st_mtime_ns, after.st_ino):
            fail("source_changed_during_read")
    return checksum.hexdigest()


def read_file(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags), "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            fail("unsupported_file_type")
        return source.read()


def inventory(root: Path) -> dict:
    if root.is_symlink() or not root.is_dir():
        fail("required_data_root_missing_or_unsafe")
    files, directories = {}, []
    def traversal_error(error):
        raise error

    for current, names, filenames in os.walk(root, followlinks=False, onerror=traversal_error):
        names.sort()
        filenames.sort()
        base = Path(current)
        for name in names:
            entry = base / name
            if entry.is_symlink() or not entry.is_dir():
                fail("unsafe_directory_entry")
            directories.append(entry.relative_to(root).as_posix())
        for name in filenames:
            entry = base / name
            metadata = entry.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                fail("unsupported_file_type")
            relative = entry.relative_to(root).as_posix()
            files[relative] = {"sha256": file_hash(entry), "bytes": metadata.st_size}
    return {"files": files, "directories": sorted(directories)}


def private_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, 0o600), "wb") as target:
        target.write(data)
        target.flush()
        os.fsync(target.fileno())


def mirror(source: Path, target: Path, listing: dict) -> None:
    target.mkdir(mode=0o700, parents=True)
    for relative in listing["directories"]:
        (target / relative).mkdir(mode=0o700, parents=True, exist_ok=True)
    for relative, expected in listing["files"].items():
        original, destination = source / relative, target / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(original, flags), "rb") as reader:
            if not stat.S_ISREG(os.fstat(reader.fileno()).st_mode):
                fail("unsupported_file_type")
            with destination.open("xb") as writer:
                os.chmod(destination, 0o600)
                shutil.copyfileobj(reader, writer, 1024 * 1024)
                writer.flush()
                os.fsync(writer.fileno())
        if file_hash(destination) != expected["sha256"]:
            fail("snapshot_copy_checksum_failed")


def number(value: object) -> bool:
    return type(value) in (int, float)


def validate_record(record: dict, kind: str) -> None:
    if not isinstance(record, dict):
        fail("business_record_invalid")
    for key in REQUIRED_STRINGS[kind].split():
        if not isinstance(record.get(key), str):
            fail("business_string_missing_or_invalid")
    if not record["id"]:
        fail("business_record_id_invalid")
    for key in REQUIRED_NUMBERS[kind].split():
        if not number(record.get(key)):
            fail("business_number_missing_or_invalid")
    for key in REQUIRED_BOOLEANS.get(kind, "").split():
        if type(record.get(key)) is not bool:
            fail("business_boolean_missing_or_invalid")
    if kind == "habits":
        normalize_set(record.get("weekdays"), int)
    if kind == "longGoals" and record["status"] not in ("planned", "active", "paused", "completed"):
        fail("goal_status_invalid")


def normalize_set(values: object, element: type) -> list:
    if not isinstance(values, list) or any(type(value) is not element for value in values):
        fail("business_set_invalid")
    if len(set(values)) != len(values):
        fail("duplicate_business_set_value")
    return sorted(values)


def normalized_library(root: Path, listing: dict) -> dict:
    if LIBRARY_REL not in listing["files"]:
        fail("existing_library_missing")
    if "library.json.read-only" in listing["files"]:
        fail("library_has_read_only_failure_marker")
    library = parse_json(read_file(root / LIBRARY_REL))
    if not isinstance(library, dict) or type(library.get("version")) is not int:
        fail("invalid_library_schema")
    if not 1 <= library["version"] <= MAX_SCHEMA:
        fail("unsupported_library_schema")
    normalized = copy.deepcopy(library)
    for name in (*COLLECTIONS, *GAME_COLLECTIONS):
        records = library.get(name)
        optional = name in OPTIONAL_COLLECTIONS | OPTIONAL_GAME_COLLECTIONS
        if records is None and optional:
            continue
        if not isinstance(records, list):
            fail("business_collection_missing_or_invalid")
        ids = []
        for record in records:
            validate_record(record, name)
            ids.append(record["id"])
        if len(set(ids)) != len(ids):
            fail("duplicate_business_record_id")
    for habit in normalized["habits"]:
        habit["weekdays"] = normalize_set(habit["weekdays"], int)
    for name in SET_FIELDS:
        normalized[name] = normalize_set(library.get(name), str)
    for name in SESSIONS:
        if library.get(name) is not None:
            validate_record(library[name], name)
    for name in ("coins", "bait"):
        if type(library.get(name)) is not int:
            fail("game_balance_missing_or_invalid")
    if library.get("animalShelterCapacity") is not None and type(library["animalShelterCapacity"]) is not int:
        fail("animal_capacity_invalid")
    for name in ("fishInventory", "fishCaught", "harvestedCrops"):
        values = library.get(name)
        if not isinstance(values, dict) or any(type(value) is not int for value in values.values()):
            fail("game_inventory_missing_or_invalid")
    # RhythmStore.load sorts these histories by date. Preserve every record
    # while ignoring only the storage order of these two chronology lists.
    for name in ("focusRecords", "sleepRecords"):
        normalized[name] = sorted(normalized[name], key=lambda record: record["id"])
    return normalized


def library_summary(root: Path, listing: dict) -> dict:
    library = normalized_library(root, listing)
    collections = {}
    for name in COLLECTIONS:
        records = library.get(name)
        collections[name] = {"present": records is not None,
                             "count": len(records or []),
                             "ids_sha256": digest(canonical(sorted(item["id"] for item in records or []))),
                             "records_sha256": digest(canonical(records))}
    sessions = {}
    for name in SESSIONS:
        value = library.get(name)
        identity = {key: value.get(key) for key in ("id", "startedAt", "linkedActionID")} if value else None
        sessions[name] = {"present": value is not None,
                          "identity_sha256": digest(canonical(identity)),
                          "state_sha256": digest(canonical(value))}
    fields = set(COLLECTIONS) | set(GAME_FIELDS) | set(SET_FIELDS) | set(SESSIONS)
    game = {key: library[key] for key in GAME_FIELDS if key in library}
    other = {key: value for key, value in library.items() if key not in fields}
    return {"schema": library["version"], "collections": collections, "sessions": sessions,
            "game_state_sha256": digest(canonical(game)),
            "habit_sets_sha256": digest(canonical({key: library[key] for key in SET_FIELDS})),
            "other_fields_sha256": digest(canonical(other)),
            "library_sha256": digest(canonical(library))}


def library_differences(previous: dict, current: dict) -> dict:
    result = {"business_collections": 0, "record_ids_or_counts": 0, "active_session_identity": 0,
              "active_session_progress": 0, "game_progress": 0, "habit_sets": 0, "other_fields": 0}
    for name in COLLECTIONS:
        before, after = previous["collections"][name], current["collections"][name]
        result["business_collections"] += int(before["records_sha256"] != after["records_sha256"])
        result["record_ids_or_counts"] += int((before["present"], before["count"], before["ids_sha256"]) !=
                                             (after["present"], after["count"], after["ids_sha256"]))
    for name in SESSIONS:
        before, after = previous["sessions"][name], current["sessions"][name]
        result["active_session_identity"] += int(before["identity_sha256"] != after["identity_sha256"])
        result["active_session_progress"] += int(before["state_sha256"] != after["state_sha256"])
    result["game_progress"] = int(previous["game_state_sha256"] != current["game_state_sha256"])
    result["habit_sets"] = int(previous["habit_sets_sha256"] != current["habit_sets_sha256"])
    result["other_fields"] = int(previous["other_fields_sha256"] != current["other_fields_sha256"])
    return result


def parse_preferences(data: bytes) -> dict:
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException, ExpatError):
        fail("invalid_preferences")
    if not isinstance(value, dict):
        fail("invalid_preferences")
    return value


def preference_digest(value: dict) -> str:
    return digest(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True))


def preferences(preferences_dir: Path | None) -> dict:
    if preferences_dir is not None and not preferences_dir.is_dir():
        fail("fixture_preferences_directory_missing")
    result = {}
    for domain in DOMAINS:
        if preferences_dir is not None:
            path = preferences_dir / (domain + ".plist")
            if not path.exists() and not path.is_symlink():
                result[domain] = None
                continue
            result[domain] = parse_preferences(read_file(path))
        else:
            command = subprocess.run(["/usr/bin/defaults", "export", domain, "-"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env={**os.environ, "LC_ALL": "C"}, check=False)
            if command.returncode:
                # Absence is explicit. Authorization, I/O and export errors
                # never become an empty preferences dictionary.
                error = command.stderr.decode("utf-8", "replace")
                if "does not exist" in error:
                    result[domain] = None
                    continue
                fail("preferences_export_failed")
            result[domain] = parse_preferences(command.stdout)
    return result


def sqlite_snapshots(roots: dict[str, Path], listings: dict, target: Path) -> dict:
    databases = {}
    for namespace, root in roots.items():
        files = listings[namespace]["files"]
        for relative, metadata in files.items():
            source = root / relative
            with source.open("rb") as handle:
                sqlite_header = handle.read(16) == b"SQLite format 3\0"
            if not sqlite_header:
                if source.suffix.lower() in (".sqlite", ".sqlite3"):
                    fail("invalid_sqlite_header")
                continue
            # Preserve raw db/WAL/SHM in the payload. Open a disposable copy so
            # SQLite can update its shared-memory files without touching live
            # data or changing the byte-for-byte archive.
            with tempfile.TemporaryDirectory(prefix="gao-rhythm-sqlite-") as scratch:
                scratch_path = Path(scratch)
                copied = scratch_path / "database"
                shutil.copyfile(source, copied)
                for suffix in ("-wal", "-shm", "-journal"):
                    sidecar = relative + suffix
                    if sidecar in files:
                        shutil.copyfile(root / sidecar, Path(str(copied) + suffix))
                uri = "file:" + quote(str(copied), safe="/") + "?mode=ro"
                destination = target / namespace / relative
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with closing(sqlite3.connect(uri, uri=True, timeout=10)) as reader:
                    if reader.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                        fail("sqlite_source_integrity_failed")
                    with closing(sqlite3.connect(destination)) as writer:
                        reader.backup(writer)
                        writer.commit()
                os.chmod(destination, 0o600)
                check_sqlite(destination)
                databases[namespace + "/" + relative] = {
                    "sha256": file_hash(destination), "bytes": destination.stat().st_size,
                }
    return databases


def check_sqlite(path: Path) -> None:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True, timeout=10)) as connection:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            fail("sqlite_snapshot_integrity_failed")


def resolve_roots(args, saved: dict | None = None) -> dict[str, Path]:
    home = Path.home()
    defaults = {"rhythm": home / "Library/Application Support/GaoSeries/Rhythm",
                "app_group": home / "Library/Group Containers/5G96498KGJ.com.gaojiezou.rhythm"}
    result = {}
    for name, argument in (("rhythm", args.rhythm_root), ("app_group", args.group_root)):
        path = Path(argument or (saved[name] if saved else defaults[name])).expanduser().absolute()
        if path.is_symlink():
            fail("unsafe_data_root_symlink")
        # Resolve macOS /var -> /private/var for test fixtures. Symlinks inside
        # each data tree remain forbidden by inventory().
        result[name] = path.resolve()
    if result["rhythm"] == result["app_group"] or any(
            a in b.parents for a in result.values() for b in result.values() if a != b):
        fail("overlapping_data_roots")
    return result


def public_counts(listings: dict, summaries: dict, sqlite_count: int) -> dict:
    summary = summaries["rhythm"]
    return {"files": sum(len(v["files"]) for v in listings.values()),
            "bytes": sum(f["bytes"] for v in listings.values() for f in v["files"].values()),
            "business_records": {key: value["count"] for key, value in summary["collections"].items()},
            "active_sessions": {key: value["present"] for key, value in summary["sessions"].items()},
            "attachment_files": sum(Path(name).suffix.lower() in ATTACHMENT_EXTENSIONS
                                    for listing in listings.values() for name in listing["files"]),
            "sqlite_databases": sqlite_count,
            "widget_library_matches_main": summary["library_sha256"] == summaries["app_group"]["library_sha256"]}


def verify_backup(backup: Path) -> dict:
    if backup.is_symlink() or not backup.is_dir():
        fail("invalid_backup_directory")
    data = read_file(backup / MANIFEST)
    if read_file(backup / "manifest.sha256").decode("ascii").strip() != digest(data):
        fail("backup_manifest_checksum_failed")
    manifest = parse_json(data)
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT or manifest.get("app_id") != APP_ID:
        fail("unsupported_backup_format")
    if set(manifest["roots"]) != {"rhythm", "app_group"}:
        fail("invalid_backup_roots")
    actual = inventory(backup)
    actual["files"].pop(MANIFEST, None)
    actual["files"].pop("manifest.sha256", None)
    if actual != manifest["archive"]:
        fail("backup_file_checksum_failed")
    roots = {name: backup / "payload" / name for name in manifest["roots"]}
    listings = {name: inventory(root) for name, root in roots.items()}
    if listings != manifest["sources"]:
        fail("backup_source_inventory_failed")
    if {name: library_summary(root, listings[name]) for name, root in roots.items()} != manifest["libraries"]:
        fail("backup_business_integrity_failed")
    for key in manifest["sqlite"]:
        check_sqlite(backup / "sqlite-consistent" / key)
    return manifest


def snapshot(args) -> dict:
    if not re.fullmatch(r"V?[0-9]+(?:\.[0-9]+){1,2}", args.version):
        fail("invalid_version")
    roots = resolve_roots(args)
    preferences_dir = Path(args.preferences_dir).expanduser().resolve() if args.preferences_dir else None
    backup_root = Path(args.backup_root).expanduser().resolve() if args.backup_root else (
        Path.home() / "Library/Application Support/GaoSeries/UpgradeBackups/Rhythm")
    project = Path(__file__).resolve().parents[1]
    if backup_root == project or project in backup_root.parents:
        fail("backup_must_not_enter_source_repository")
    if any(backup_root == root or root in backup_root.parents or backup_root in root.parents for root in roots.values()):
        fail("backup_must_not_overlap_live_data")
    listings = {name: inventory(root) for name, root in roots.items()}
    summaries = {name: library_summary(root, listings[name]) for name, root in roots.items()}
    settings = preferences(preferences_dir)
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_root, 0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    final = backup_root / (stamp + "-V" + args.version.lstrip("V"))
    stage = Path(tempfile.mkdtemp(prefix=".incomplete-", dir=backup_root))
    try:
        copied_roots = {}
        for name, root in roots.items():
            copied_roots[name] = stage / "payload" / name
            mirror(root, copied_roots[name], listings[name])
        for domain, value in settings.items():
            if value is not None:
                private_write(stage / "preferences" / (domain + ".plist"),
                              plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True))
        databases = sqlite_snapshots(copied_roots, listings, stage / "sqlite-consistent")
        if {name: inventory(root) for name, root in roots.items()} != listings:
            fail("live_data_changed_during_snapshot")
        if preferences(preferences_dir) != settings:
            fail("preferences_changed_during_snapshot")
        manifest = {"format": FORMAT, "app_id": APP_ID, "target_version": args.version,
                    "created_at": stamp, "roots": {name: str(root) for name, root in roots.items()},
                    "preferences_dir": str(preferences_dir) if preferences_dir else None,
                    "preferences_present": {domain: value is not None for domain, value in settings.items()},
                    "sources": listings, "libraries": summaries, "sqlite": databases,
                    "archive": inventory(stage)}
        encoded = canonical(manifest)
        private_write(stage / MANIFEST, encoded)
        private_write(stage / "manifest.sha256", (digest(encoded) + "\n").encode("ascii"))
        verify_backup(stage)
        os.rename(stage, final)
        return {"ok": True, "command": "snapshot", "backup": str(final),
                "counts": public_counts(listings, summaries, len(databases))}
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def verify_live(args) -> dict:
    backup = Path(args.backup).expanduser().resolve()
    manifest = verify_backup(backup)
    roots = resolve_roots(args, manifest["roots"])
    preferences_dir = (Path(args.preferences_dir).expanduser().resolve() if args.preferences_dir else
                       Path(manifest["preferences_dir"]) if manifest.get("preferences_dir") else None)
    listings = {name: inventory(root) for name, root in roots.items()}
    summaries = {name: library_summary(root, listings[name]) for name, root in roots.items()}
    library_changes = {name: library_differences(manifest["libraries"][name], summaries[name]) for name in roots}
    differences = {"files_added": 0, "files_missing": 0, "files_changed": 0,
                   "directories": 0, "preferences": 0}
    for name, root in roots.items():
        old, new = manifest["sources"][name], listings[name]
        old_files, new_files = old["files"], new["files"]
        differences["files_added"] += len(new_files.keys() - old_files.keys())
        differences["files_missing"] += len(old_files.keys() - new_files.keys())
        differences["directories"] += len(set(old["directories"]) ^ set(new["directories"]))
        for relative in old_files.keys() & new_files.keys():
            if relative == LIBRARY_REL:
                continue  # Every JSON value is checked by library_differences.
            path = Path(relative)
            if path.suffix == ".plist" and path.stem in DOMAINS:
                before = parse_preferences(read_file(backup / "payload" / name / relative))
                after = parse_preferences(read_file(root / relative))
                differences["preferences"] += int(preference_digest(before) != preference_digest(after))
                continue
            differences["files_changed"] += int(old_files[relative] != new_files[relative])
    settings = preferences(preferences_dir)
    for domain, current in settings.items():
        present = manifest["preferences_present"][domain]
        original = parse_preferences(read_file(backup / "preferences" / (domain + ".plist"))) if present else None
        differences["preferences"] += int((original is None) != (current is None) or
                                          preference_digest(original or {}) != preference_digest(current or {}))
    # SQLite may update scratch shared memory; only disposable copies are opened.
    with tempfile.TemporaryDirectory(prefix="gao-rhythm-verify-") as scratch:
        databases = sqlite_snapshots(roots, listings, Path(scratch) / "sqlite")
    if {name: inventory(root) for name, root in roots.items()} != listings:
        fail("live_data_changed_during_verification")
    if preferences(preferences_dir) != settings:
        fail("preferences_changed_during_verification")
    ok = not any(differences.values()) and not any(any(values.values()) for values in library_changes.values())
    return {"ok": ok, "command": "verify-live",
            "counts": public_counts(listings, summaries, len(databases)),
            "difference_counts": differences, "library_difference_counts": library_changes}


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("snapshot", help="Validate and privately snapshot existing data")
    make.add_argument("--version", required=True, help="Target app version, e.g. 4.01")
    make.add_argument("--backup-root", help="Private backup parent; never a source repository")
    check = commands.add_parser("verify-live", help="Verify snapshot and compare all live data")
    check.add_argument("backup", help="Snapshot directory returned by snapshot")
    for command in (make, check):
        command.add_argument("--rhythm-root", help="Override data root for fixtures")
        command.add_argument("--group-root", help="Override App Group root for fixtures")
        command.add_argument("--preferences-dir", help="Read fixture plists instead of macOS defaults")
    args = parser.parse_args()
    try:
        result = snapshot(args) if args.command == "snapshot" else verify_live(args)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0 if result["ok"] else 1
    except SafetyError as error:
        print(json.dumps({"ok": False, "command": args.command, "error": str(error)}), file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError, OverflowError) as error:
        # Keep personal filenames, business content, settings and credentials
        # out of terminal logs and eventual GitHub descriptions.
        print(json.dumps({"ok": False, "command": args.command,
                          "error": "read_or_integrity_check_failed", "error_type": type(error).__name__}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
