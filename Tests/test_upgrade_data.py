#!/usr/bin/env python3
"""Shared-sleep snapshot coverage; all data/preferences are disposable fixtures."""
import argparse
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/upgrade_data.py"
spec = importlib.util.spec_from_file_location("rhythm_upgrade", SCRIPT)
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


class UpgradeSleepSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rhythm-upgrade-test-")
        self.root = Path(self.temp.name).resolve()
        self.rhythm, self.group, self.shared, self.prefs = (self.root / name for name in ("rhythm", "group", "shared", "preferences"))
        for directory in (self.rhythm, self.group, self.prefs):
            directory.mkdir()
        library = {name: [] for name in (*upgrade.COLLECTIONS, *upgrade.GAME_COLLECTIONS, *upgrade.SET_FIELDS)}
        library.update(version=11, coins=50, bait=1, fishInventory={}, fishCaught={}, harvestedCrops={})
        for directory in (self.rhythm, self.group):
            (directory / "library.json").write_text(json.dumps(library))
        self.args = argparse.Namespace(version="4.02", backup_root=str(self.root / "backups"),
                                      rhythm_root=str(self.rhythm), group_root=str(self.group),
                                      shared_sleep_root=str(self.shared), preferences_dir=str(self.prefs))

    def tearDown(self):
        self.temp.cleanup()

    def snapshot(self):
        result = upgrade.snapshot(self.args)
        self.args.backup = result["backup"]
        return result

    def test_pre_migration_absence_is_explicit_and_verified(self):
        self.snapshot()
        manifest = upgrade.verify_backup(Path(self.args.backup))
        self.assertTrue(manifest["sources"]["shared_sleep"]["absent"])
        self.assertTrue(upgrade.verify_live(self.args)["ok"])
        self.shared.mkdir()
        with sqlite3.connect(self.shared / "sleep-records.sqlite") as connection:
            connection.execute("CREATE TABLE sleep_records(id TEXT)")
        result = upgrade.verify_live(self.args)
        self.assertFalse(result["ok"])
        self.assertEqual(result["difference_counts"]["source_presence"], 1)

    def test_shared_wal_database_and_markers_are_in_snapshot(self):
        self.shared.mkdir()
        (self.shared / ".initialized").write_text("SharedSleep schema 1\n")
        connection = sqlite3.connect(self.shared / "sleep-records.sqlite")
        try:
            connection.executescript("PRAGMA journal_mode=WAL;CREATE TABLE sleep_records(id TEXT,payload BLOB,deleted INTEGER);"
                                     "INSERT INTO sleep_records VALUES('deleted-id',NULL,1);")
            connection.commit()
            result = self.snapshot()
            self.assertEqual(result["counts"]["sqlite_databases"], 1)
            self.assertTrue(upgrade.verify_live(self.args)["ok"])
            journal = Path(result["backup"]) / "sqlite-consistent/shared_sleep/sleep-records.sqlite"
            with sqlite3.connect(journal.as_uri() + "?mode=ro&immutable=1", uri=True) as copied:
                self.assertEqual(copied.execute("SELECT deleted FROM sleep_records").fetchall(), [(1,)])
            self.assertTrue((Path(result["backup"]) / "payload/shared_sleep/.initialized").exists())
        finally:
            connection.close()

    def test_unsafe_shared_root_and_corrupt_database_fail(self):
        self.shared.symlink_to(self.group)
        with self.assertRaises(upgrade.SafetyError):
            self.snapshot()
        self.shared.unlink()
        self.shared.mkdir()
        with self.assertRaises(upgrade.SafetyError):
            self.snapshot()
        (self.shared / "sleep-records.sqlite").write_bytes(b"not a database")
        with self.assertRaises(upgrade.SafetyError):
            self.snapshot()


if __name__ == "__main__":
    unittest.main()
