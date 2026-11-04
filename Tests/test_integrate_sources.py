#!/usr/bin/env python3
"""Synthetic migration safety tests. Never opens an app or real user data."""
from __future__ import annotations
import contextlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/integrate_sources.py"
spec = importlib.util.spec_from_file_location("rhythm_integration_migration", SCRIPT)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Fixture:
    def __init__(self, base):
        self.base = base
        self.source = base / "sources"; self.source.mkdir()
        self.target = base / "target"; self.target.mkdir()
        (self.target / "unrelated-rhythm-record.txt").write_text("keep-original-rhythm")
        self.connections = []
        roots = {}
        for name in sorted(m.ROOT_KEYS):
            if name == "footprintsRestore":
                roots[name] = None
            elif name in m.FILE_ROOTS:
                roots[name] = str(self.source / (name + ".plist" if "Preferences" in name else name + ".json"))
            else:
                p = self.source / name; p.mkdir(); roots[name] = str(p)
        self.roots = roots
        health = Path(roots["healthGroup"]) / "Health"; health.mkdir()
        (health / "Backups").mkdir(); (health / "Backups/old.healthbackup").write_bytes(b"old-full-backup")
        (health / ".initialized").write_bytes(b"keep-marker")
        c = self.db(health / "health.sqlite", wal=True)
        c.executescript("CREATE TABLE state(id INTEGER PRIMARY KEY,json BLOB NOT NULL);"
                        "CREATE TABLE records(id TEXT PRIMARY KEY,kind TEXT,occurred_at REAL,json BLOB);"
                        "CREATE TABLE events(id TEXT PRIMARY KEY,type_id TEXT,occurred_at REAL,json BLOB);"
                        "PRAGMA user_version=1;")
        state = {"schemaVersion": 2, "preferences": {"cup": 200},
                 "island": {"inventory": {"wood": 9}, "rewardedSleepIDs": ["S1"]},
                 "ledgers": {"2026-11-01": {"sleepEnergy": 7}}, "requests": ["old-request-id"]}
        c.execute("INSERT INTO state VALUES(1,?)", (json.dumps(state).encode(),))
        c.execute("INSERT INTO records VALUES('H1','water',100,?)", (b'{"id":"H1","amount":200}',))
        c.commit()
        sleep = Path(roots["healthGroup"]) / "SharedSleep"; sleep.mkdir()
        (sleep / ".initialized").write_bytes(b"SharedSleep schema 1\n")
        c = self.db(sleep / "sleep-records.sqlite", wal=True)
        c.executescript("CREATE TABLE sleep_metadata(id INTEGER PRIMARY KEY,version INTEGER);"
                        "INSERT INTO sleep_metadata VALUES(1,1);"
                        "CREATE TABLE sleep_records(id TEXT PRIMARY KEY,payload BLOB,deleted INTEGER);"
                        "CREATE TABLE sleep_migrations(key TEXT PRIMARY KEY);"
                        "INSERT INTO sleep_migrations VALUES('rhythm-library-v1');PRAGMA user_version=1;")
        self.sleep = {"id": "S1", "startedAt": 100, "endedAt": 200, "durationSeconds": 100,
                      "score": 80, "pastureYield": 3, "manualGrowthCreditedSeconds": 100,
                      "manualProductionCreditedCycles": 2, "origin": "rhythm"}
        c.execute("INSERT INTO sleep_records VALUES('S1',?,0)", (json.dumps(self.sleep).encode(),))
        c.execute("INSERT INTO sleep_records VALUES('deleted-id',NULL,1)"); c.commit()
        fp = Path(roots["footprintsSupport"])
        (fp / "Photos").mkdir(); (fp / "Snapshots").mkdir()
        photo_id = "11223344-1122-3344-5566-112233445566"
        filename = photo_id + ".jpg"; photo = b"synthetic-jpg-bytes"
        (fp / "Photos" / filename).write_bytes(photo)
        (fp / "Snapshots/old.json").write_bytes(b'{"preserve":"snapshot"}')
        (fp / "pre-restore.footprintsbackup").write_bytes(b"preserve-restore-backup")
        c = self.db(fp / "footprints.sqlite", wal=True)
        c.execute("CREATE TABLE items(kind TEXT,id TEXT,payload BLOB,PRIMARY KEY(kind,id))")
        rows = [("meta", "main", {"schema": 1, "train": {"coins": 17, "rewardedVisits": ["V1"]}}),
                ("visit", "V1", {"id": "V1", "photoIDs": [photo_id], "tripID": "T1"}),
                ("trip", "T1", {"id": "T1", "name": "synthetic-trip"}),
                ("photo", photo_id, {"id": photo_id, "filename": filename,
                                     "size": len(photo), "sha256": m.sha(photo)})]
        c.executemany("INSERT INTO items VALUES(?,?,?)", [(k, i, json.dumps(v).encode()) for k, i, v in rows]); c.commit()
        (Path(roots["footprintsGroup"]) / "widget-generation.json").write_bytes(b'{"preserve":"old-widget-data"}')
        (Path(roots["healthSupport"]) / "document.pdf").write_bytes(b"private-attachment-fixture")
        (Path(roots["healthRestore"]) / "pending.json").write_bytes(b'{"staged":"old-source-only-job"}')
        prefs = {"standard": {"gqns.language": "en", "oldBookmark": b"opaque-bookmark"},
                 "module": {"animationEnabled": False, "soundEnabled": True, "ownerName": "fixture-owner"}}
        for key in ("healthPreferences", "footprintsPreferences"):
            Path(roots[key]).write_bytes(plistlib.dumps(prefs, fmt=plistlib.FMT_BINARY))
        Path(roots["rhythmLibrary"]).write_bytes(json.dumps({"version": 11, "sleepRecords": [self.sleep],
                                                            "coins": 662, "activeSleep": None, "activeFocus": None}).encode())
        self.config = base / "source-config.json"
        self.config.write_bytes(m.canonical({"schemaVersion": 1, "roots": roots,
                                            "explicitAbsences": ["footprintsRestore"],
                                            "absentPaths": {"footprintsRestore": str(self.source / "footprintsRestore")}}))
    def db(self, path, wal=False):
        c = sqlite3.connect(path)
        if wal:
            c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA wal_autocheckpoint=0")
        self.connections.append(c); return c
    def plan(self, tx="transaction_1"):
        return m.make_plan(self.config, self.target, tx)
    def freeze(self, plan):
        value = {"schemaVersion": 1, "transactionID": plan["transactionID"],
                 "planSHA256": m.sha(m.canonical(plan)), "sourceRevisions": plan["sourceRevisions"],
                 "sourcesFrozen": True, "stoppedWriterBundleIDs": sorted(m.WRITERS),
                 "footprintsPublisherStopped": True, "oldWidgetsCannotWrite": True,
                 "backupsVerified": True, "rollbackVerified": True,
                 "verifiedAt": m.now(), "evidence": ["SYNTHETIC_FIXTURE_ONLY_NOT_REAL_FREEZE"]}
        path = self.base / ("freeze-" + plan["transactionID"] + ".json")
        path.write_bytes(m.canonical(value)); return path
    def close(self):
        for c in self.connections:
            c.close()


class MigrationSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(suffix=".noindex")
        self.base = Path(self.temp.name).resolve()
        self.fx = Fixture(self.base)
    def tearDown(self):
        self.fx.close(); self.temp.cleanup()
    def assert_refuses(self, code, operation):
        with self.assertRaises(m.MigrationError) as caught:
            operation()
        self.assertEqual(str(caught.exception), code)
    def prepare(self):
        plan = self.fx.plan(); freeze = self.fx.freeze(plan)
        result = m.apply(plan, freeze)
        self.assertEqual(result["status"], "prepared_not_active")
        return plan, freeze
    def test_plan_reads_wal_and_does_not_touch_source_or_target(self):
        cfg = m.load_config(self.fx.config); before = m.collect_sources(cfg)
        plan = self.fx.plan()
        self.assertEqual(plan["databases"]["health"]["summary"]["tables"]["records"]["count"], 1)
        self.assertEqual(before, m.collect_sources(cfg))
        self.assertFalse((self.fx.target / "Integration").exists())
    def test_plan_roundtrip_and_public_cli_read_only(self):
        output = self.base / "plan.json"
        self.assertEqual(m.main(["plan", "--source-config", str(self.fx.config), "--target-group", str(self.fx.target),
                                 "--transaction", "tx-roundtrip", "--output", str(output)]), 0)
        plan = m.load_plan(output)
        freeze = self.fx.freeze(plan)
        self.assertEqual(m.apply(plan, freeze)["status"], "prepared_not_active")
        self.assertFalse((self.fx.target / "Integration/authority.json").exists())
    def test_prepared_preserves_archives_photos_games_and_preferences(self):
        before = m.collect_sources(m.load_config(self.fx.config)); plan, freeze = self.prepare()
        root = self.fx.target / "Integration"
        self.assertEqual(before, m.collect_sources(plan["sourceConfig"]))
        self.assertEqual((root / "SourceArchives/Health/Preferences.plist").read_bytes(),
                         Path(self.fx.roots["healthPreferences"]).read_bytes())
        self.assertEqual((root / "SourceArchives/Health/PendingRestore/pending.json").read_bytes(),
                         b'{"staged":"old-source-only-job"}')
        prefs = plistlib.loads((root / "Modules/Footprints/Preferences.plist").read_bytes())
        self.assertEqual(prefs["transactionID"], plan["transactionID"])
        self.assertFalse(prefs["module"]["animationEnabled"])
        self.assertEqual(prefs["standard"]["oldBookmark"], b"opaque-bookmark")
        with contextlib.closing(m.open_ro(root / "SharedSleep/sleep-records.sqlite")) as c:
            self.assertEqual(c.execute("SELECT id,deleted FROM sleep_records ORDER BY id").fetchall(),
                             [("S1", 0), ("deleted-id", 1)])
            self.assertEqual(c.execute("SELECT key FROM sleep_migrations").fetchall(), [("rhythm-library-v1",)])
        self.assertTrue((root / "Modules/Footprints/WidgetData/widget-generation.json").is_file())
        self.assertEqual((self.fx.target / "unrelated-rhythm-record.txt").read_text(), "keep-original-rhythm")
        self.assertEqual(m.apply(plan, freeze)["status"], "prepared_not_active")
    def test_activate_atomic_and_replay_does_not_rollback_new_game_progress(self):
        plan, freeze = self.prepare(); self.assertEqual(m.activate(plan, freeze)["status"], "active")
        root = self.fx.target / "Integration"
        authority = m.parse_json((root / "authority.json").read_bytes())
        self.assertEqual(authority["modulePaths"], m.MODULE_PATHS)
        self.assertEqual(authority["sharedSleepPath"], "SharedSleep")
        self.assertFalse(authority["permissionsTransferred"])
        database = root / "Modules/Health/health.sqlite"
        with sqlite3.connect(database) as c:
            state = json.loads(c.execute("SELECT json FROM state").fetchone()[0])
            state["island"]["inventory"]["wood"] = 99
            c.execute("UPDATE state SET json=?", (json.dumps(state).encode(),))
        before = m.file_hash(database)
        self.assertEqual(m.activate(plan, freeze)["status"], "already_active")
        self.assertEqual(m.apply(plan, freeze)["status"], "already_active")
        self.assertEqual(m.file_hash(database), before)
        self.assertEqual(m.verify(plan)["status"], "active")
        self.assert_refuses("prepared_or_archived_data_changed", lambda: m.verify(plan, strict=True))
    def test_wrong_freeze_and_missing_writers_refuse(self):
        plan = self.fx.plan(); path = self.fx.freeze(plan)
        value = m.parse_json(path.read_bytes()); value["sourceRevisions"]["healthGroup"] = "0" * 64
        path.write_bytes(m.canonical(value))
        self.assert_refuses("freeze_receipt_mismatch", lambda: m.apply(plan, path))
        value["sourceRevisions"] = plan["sourceRevisions"]; value["stoppedWriterBundleIDs"].remove("com.gaoseries.GaoJianKang.widgets")
        path.write_bytes(m.canonical(value))
        self.assert_refuses("not_all_source_and_target_writers_frozen", lambda: m.apply(plan, path))
        self.assertFalse((self.fx.target / "Integration/Modules").exists())
    def test_unverified_recovery_backup_refuses(self):
        plan = self.fx.plan(); path = self.fx.freeze(plan); value = m.parse_json(path.read_bytes())
        value["rollbackVerified"] = False; path.write_bytes(m.canonical(value))
        self.assert_refuses("restorable_backups_not_verified", lambda: m.apply(plan, path))
    def test_source_cas_refuses_changes_before_apply(self):
        plan = self.fx.plan(); freeze = self.fx.freeze(plan)
        (Path(self.fx.roots["healthSupport"]) / "document.pdf").write_bytes(b"changed")
        self.assert_refuses("source_changed_since_plan", lambda: m.apply(plan, freeze))
        self.assertFalse((self.fx.target / "Integration/Modules").exists())
    def test_source_change_between_preparation_and_activation_never_commits(self):
        plan, freeze = self.prepare()
        (Path(self.fx.roots["footprintsGroup"]) / "widget-generation.json").write_bytes(b"new-source-data")
        self.assert_refuses("source_changed_since_plan", lambda: m.activate(plan, freeze))
        self.assertFalse((self.fx.target / "Integration/authority.json").exists())
        self.assertTrue((self.fx.target / "Integration/Modules/Footprints/footprints.sqlite").exists())
    def test_unowned_destination_never_overwritten(self):
        plan = self.fx.plan(); freeze = self.fx.freeze(plan)
        p = self.fx.target / "Integration/Modules/Health"; p.mkdir(parents=True)
        (p / "personal.txt").write_text("unowned-data")
        self.assert_refuses("unowned_runtime_component_exists", lambda: m.apply(plan, freeze))
        self.assertEqual((p / "personal.txt").read_text(), "unowned-data")
    def test_interrupted_component_promotion_resumes_exactly(self):
        plan = self.fx.plan(); freeze = self.fx.freeze(plan); real = m.os.rename
        calls = []
        def fail_second(a, b):
            calls.append((a, b))
            if len(calls) == 2:
                raise OSError("SYNTHETIC_INTERRUPTION")
            return real(a, b)
        with mock.patch.object(m.os, "rename", side_effect=fail_second):
            with self.assertRaises(OSError):
                m.apply(plan, freeze)
        self.assertTrue((self.fx.target / "Integration/Modules/Health").exists())
        self.assertFalse((self.fx.target / "Integration/authority.json").exists())
        self.assertEqual(m.apply(plan, freeze)["status"], "prepared_not_active")
        self.assertEqual(m.activate(plan, freeze)["status"], "active")
    def test_interrupted_staging_is_retained_and_new_attempt_succeeds(self):
        plan = self.fx.plan(); freeze = self.fx.freeze(plan); real = m.build_payload
        def partial(plan, path):
            path.mkdir(); (path / "partial.bin").write_bytes(b"retain-evidence")
            raise OSError("SYNTHETIC_INTERRUPTION")
        with mock.patch.object(m, "build_payload", side_effect=partial):
            with self.assertRaises(OSError):
                m.apply(plan, freeze)
        self.assertEqual(m.apply(plan, freeze)["status"], "prepared_not_active")
        leftovers = list((self.fx.target / "Integration/Transactions.noindex/transaction_1").glob("Payload-*/partial.bin"))
        self.assertEqual(len(leftovers), 1)
    def test_missing_or_corrupt_database_never_initializes_blank(self):
        p = Path(self.fx.roots["healthGroup"]) / "Health/health.sqlite"
        p.unlink()
        self.assert_refuses("database_missing_or_empty", self.fx.plan)
        self.assertFalse(p.exists()); self.assertFalse((self.fx.target / "Integration").exists())
    def test_future_schema_rejected(self):
        self.fx.connections[0].execute("PRAGMA user_version=99"); self.fx.connections[0].commit()
        self.assert_refuses("unsupported_health_database_schema", self.fx.plan)
    def test_legacy_seed_missing_and_pending_reward_refuse(self):
        c = self.fx.connections[1]
        c.execute("DELETE FROM sleep_migrations"); c.commit()
        self.assert_refuses("legacy_sleep_seed_not_complete", self.fx.plan)
        c.execute("INSERT INTO sleep_migrations VALUES('rhythm-library-v1')"); c.commit()
        rhythm = m.parse_json(Path(self.fx.roots["rhythmLibrary"]).read_bytes())
        rhythm["sleepRecords"][0]["pastureYield"] = 99
        Path(self.fx.roots["rhythmLibrary"]).write_bytes(m.canonical(rhythm))
        self.assert_refuses("rhythm_sleep_pending_settlement_mismatch", self.fx.plan)
    def test_pending_sleep_id_not_present_refuses(self):
        rhythm = m.parse_json(Path(self.fx.roots["rhythmLibrary"]).read_bytes())
        rhythm["sleepRecords"][0]["id"] = "not-yet-canonical"
        Path(self.fx.roots["rhythmLibrary"]).write_bytes(m.canonical(rhythm))
        self.assert_refuses("pending_rhythm_sleep_not_in_canonical_journal", self.fx.plan)
    def test_active_original_session_requires_normal_coordinated_end(self):
        rhythm = m.parse_json(Path(self.fx.roots["rhythmLibrary"]).read_bytes())
        rhythm["activeFocus"] = {"id": "ongoing"}
        Path(self.fx.roots["rhythmLibrary"]).write_bytes(m.canonical(rhythm))
        self.assert_refuses("active_rhythm_session_requires_coordinated_freeze", self.fx.plan)
    def test_photo_missing_or_changed_refuses(self):
        photo = next((Path(self.fx.roots["footprintsSupport"]) / "Photos").iterdir())
        photo.write_bytes(b"changed-jpg")
        self.assert_refuses("photo_missing_or_changed", self.fx.plan)
    def test_missing_preference_domain_is_not_empty_default(self):
        Path(self.fx.roots["footprintsPreferences"]).write_bytes(plistlib.dumps({"standard": {}}))
        self.assert_refuses("preference_domains_not_explicit", self.fx.plan)
    def test_symlinks_and_path_traversal_refused(self):
        p = Path(self.fx.roots["healthSupport"]) / "link"; p.symlink_to(self.fx.config)
        self.assert_refuses("symlink_entry_refused", self.fx.plan)
        p.unlink()
        self.assert_refuses("invalid_transaction_id", lambda: self.fx.plan("../../escape"))
    def test_source_target_overlap_and_implicit_missing_root_refused(self):
        self.assert_refuses("source_target_overlap", lambda: m.make_plan(self.fx.config,
                            Path(self.fx.roots["healthGroup"]), "tx"))
        cfg = m.parse_json(self.fx.config.read_bytes()); cfg["roots"]["healthSupport"] = None
        self.fx.config.write_bytes(m.canonical(cfg))
        self.assert_refuses("absence_not_explicit", self.fx.plan)
    def test_explicitly_absent_source_appearing_before_apply_refuses(self):
        plan = self.fx.plan(); freeze = self.fx.freeze(plan)
        (self.fx.source / "footprintsRestore").mkdir()
        self.assert_refuses("explicitly_absent_source_now_exists", lambda: m.apply(plan, freeze))
    def test_unknown_authority_never_overwritten(self):
        plan, freeze = self.prepare(); root = self.fx.target / "Integration"
        other = {"schemaVersion": 1, "state": "active", "transactionID": "foreign-transaction"}
        (root / "authority.json").write_bytes(m.canonical(other))
        self.assert_refuses("authority_conflict", lambda: m.activate(plan, freeze))
        self.assertEqual(m.parse_json((root / "authority.json").read_bytes()), other)
    def test_plan_output_cannot_create_declared_absent_source_or_touch_target(self):
        for output in (self.fx.source / "footprintsRestore/plan.json", self.fx.target / "plan.json"):
            self.assertEqual(m.main(["plan", "--source-config", str(self.fx.config), "--target-group", str(self.fx.target),
                                     "--transaction", "out-refusal", "--output", str(output)]), 1)
            self.assertFalse(output.exists())
        self.assertFalse((self.fx.source / "footprintsRestore").exists())
    def test_future_footprint_database_schema_refused(self):
        c = self.fx.connections[2]; c.execute("PRAGMA user_version=99"); c.commit()
        self.assert_refuses("unsupported_footprint_database_schema", self.fx.plan)
    @unittest.skipUnless(sys.platform == "darwin", "macOS metadata integration")
    def test_binary_empty_xattrs_and_acl_survive_archives_and_sqlite_backup(self):
        doc = Path(self.fx.roots["healthSupport"]) / "document.pdf"
        db = Path(self.fx.roots["healthGroup"]) / "Health/health.sqlite"
        for p in (doc, db):
            subprocess.run(["/usr/bin/xattr", "-wx", "com.gao.integration.binary", "00ff10", str(p)], check=True)
            subprocess.run(["/usr/bin/xattr", "-w", "com.gao.integration.empty", "", str(p)], check=True)
            subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(p)], check=True)
        plan, freeze = self.prepare(); root = self.fx.target / "Integration"
        for source, target in ((doc, root / "SourceArchives/Health/ApplicationSupport/document.pdf"),
                               (db, root / "Modules/Health/health.sqlite")):
            self.assertEqual(m.metadata(source), m.metadata(target))
        self.assertEqual(m.activate(plan, freeze)["status"], "active")
    def test_database_without_identity_primary_key_refused(self):
        c = self.fx.connections[1]
        c.executescript("ALTER TABLE sleep_records RENAME TO old_records;"
                        "CREATE TABLE sleep_records(id TEXT,payload BLOB,deleted INTEGER);"
                        "INSERT INTO sleep_records SELECT * FROM old_records;DROP TABLE old_records;")
        c.commit()
        self.assert_refuses("unsupported_database_table_shape", self.fx.plan)
    def test_health_support_remains_accessible_as_exact_raw_tree(self):
        source = Path(self.fx.roots["healthSupport"])
        (source / "empty-folder").mkdir()
        (source / "personal-notes.sqlite").write_bytes(b"opaque-user-file-not-for-migration-sqlite")
        (source / "personal-notes.sqlite-wal").write_bytes(b"raw-uninterpreted-wal")
        (source / "personal-notes.sqlite-shm").write_bytes(b"raw-uninterpreted-shm")
        expected = m.inventory(source); plan, freeze = self.prepare()
        target = self.fx.target / "Integration/Modules/Health/ImportedSupport"
        self.assertEqual(m.inventory(target), expected)
        self.assertEqual(m.inventory(self.fx.target / "Integration/SourceArchives/Health/ApplicationSupport"), expected)
        self.assertEqual(m.activate(plan, freeze)["status"], "active")
        self.assertEqual(m.verify(plan)["status"], "active")
    def test_explicit_absent_health_support_does_not_create_empty_access_directory(self):
        source = Path(self.fx.roots["healthSupport"])
        (source / "document.pdf").unlink(); source.rmdir()
        cfg = m.parse_json(self.fx.config.read_bytes()); cfg["roots"]["healthSupport"] = None
        cfg["explicitAbsences"].append("healthSupport"); cfg["absentPaths"]["healthSupport"] = str(source)
        self.fx.config.write_bytes(m.canonical(cfg)); plan, freeze = self.prepare()
        self.assertFalse((self.fx.target / "Integration/Modules/Health/ImportedSupport").exists())
        self.assertFalse((self.fx.target / "Integration/SourceArchives/Health/ApplicationSupport").exists())
        self.assertEqual(m.activate(plan, freeze)["status"], "active")
    def test_health_support_target_name_conflict_refuses_without_overwrite(self):
        collision = Path(self.fx.roots["healthGroup"]) / "Health/ImportedSupport"
        collision.mkdir(); (collision / "existing.txt").write_bytes(b"keep-existing-user-file")
        self.assert_refuses("imported_support_name_conflict", self.fx.plan)
        self.assertEqual((collision / "existing.txt").read_bytes(), b"keep-existing-user-file")
        self.assertFalse((self.fx.target / "Integration").exists())
    def test_runtime_damage_refuses_without_repair_or_overwrite(self):
        plan, freeze = self.prepare(); m.activate(plan, freeze)
        database = self.fx.target / "Integration/Modules/Health/health.sqlite"; database.unlink()
        with self.assertRaises((m.MigrationError, FileNotFoundError)):
            m.verify(plan)
        self.assertFalse(database.exists())
    def test_immutable_archive_change_refuses_even_after_activation(self):
        plan, freeze = self.prepare(); m.activate(plan, freeze)
        p = self.fx.target / "Integration/SourceArchives/Health/ApplicationSupport/document.pdf"
        p.write_bytes(b"changed-archive")
        self.assert_refuses("prepared_or_archived_data_changed", lambda: m.apply(plan, freeze))
        self.assertEqual(p.read_bytes(), b"changed-archive")

    def test_runtime_only_allows_retired_source_archives(self):
        plan, freeze = self.prepare(); m.activate(plan, freeze)
        archives = self.fx.target / "Integration/SourceArchives"
        shutil.rmtree(archives / "Health"); shutil.rmtree(archives / "Footprints")
        result = m.verify(plan, runtime_only=True)
        self.assertEqual(result["status"], "active")
        self.assertFalse(result["sourceArchivesChecked"])
        self.assert_refuses("prepared_or_archived_data_changed", lambda: m.verify(plan))

    def test_runtime_only_requires_active_and_disallows_strict_import(self):
        plan, freeze = self.prepare()
        self.assert_refuses("runtime_only_requires_active_authority", lambda: m.verify(plan, runtime_only=True))
        m.activate(plan, freeze)
        self.assert_refuses("runtime_only_requires_active_authority", lambda: m.verify(plan, strict=True, runtime_only=True))

    def test_runtime_only_still_requires_current_business_database(self):
        plan, freeze = self.prepare(); m.activate(plan, freeze)
        shutil.rmtree(self.fx.target / "Integration/SourceArchives/Health")
        database = self.fx.target / "Integration/Modules/Health/health.sqlite"
        database.unlink()
        with self.assertRaises((m.MigrationError, FileNotFoundError)):
            m.verify(plan, runtime_only=True)
        self.assertFalse(database.exists())


if __name__ == "__main__":
    unittest.main()
