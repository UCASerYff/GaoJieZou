#!/usr/bin/env python3
"""Synthetic tests for the isolated receiver whitelist recovery tool.

Fixtures are disposable. Nothing here reads a home directory, keychain, or live
App Group, and a passing test is not a completed recovery of a real install.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


migration = load("rhythm_integration_migration", ROOT / "scripts/integrate_sources.py")
upgrade = load("rhythm_upgrade_for_recovery", ROOT / "scripts/upgrade_data.py")
tool = load("receiver_whitelist_recovery", ROOT / "scripts/receiver_whitelist_recovery.py")

BUSINESS_RAW = "BUSINESS-RAW-KEEP"
SOURCE_RAW = "SOURCE-RAW-SECRET"
CANARY = "PREF-CANARY-DO-NOT-PRINT"
PHOTO_ID = "11223344-1122-3344-5566-112233445566"


def library_bytes(sleep):
    library = {name: [] for name in (*upgrade.COLLECTIONS, *upgrade.GAME_COLLECTIONS, *upgrade.SET_FIELDS)}
    library.update(version=11, coins=50, bait=1, animalShelterCapacity=2,
                   fishInventory={}, fishCaught={}, harvestedCrops={},
                   activeSleep=None, activeFocus=None, sleepRecords=[sleep])
    return migration.canonical(library)


class World:
    def __init__(self, base):
        self.base = base
        self.connections = []
        self.source = base / "sources"
        self.group = base / "group"
        self.support = base / "Rhythm"
        self.preferences = base / "preferences"
        self.plan_path = base / "migration-plan.json"
        for directory in (self.source, self.group, self.support, self.preferences):
            directory.mkdir()
        roots = {}
        for name in sorted(migration.ROOT_KEYS):
            if name == "footprintsRestore":
                roots[name] = None
            elif name in migration.FILE_ROOTS:
                roots[name] = str(self.source / (name + ".plist" if "Preferences" in name else name + ".json"))
            else:
                path = self.source / name
                path.mkdir()
                roots[name] = str(path)
        self.roots = roots
        self.sleep = {"id": "S1", "startedAt": 100, "endedAt": 200, "durationSeconds": 100,
                      "score": 80, "pastureYield": 3, "manualGrowthCreditedSeconds": 100,
                      "manualProductionCreditedCycles": 2, "origin": "rhythm"}
        self._write_sources()
        config = base / "source-config.json"
        config.write_bytes(migration.canonical({
            "schemaVersion": 1, "roots": roots, "explicitAbsences": ["footprintsRestore"],
            "absentPaths": {"footprintsRestore": str(self.source / "footprintsRestore")}}))
        self.plan = migration.make_plan(config, self.group, "receiver-tx-1")
        freeze = self._freeze(self.plan)
        self.plan_path.write_bytes(migration.canonical(self.plan))
        migration.apply(self.plan, freeze)
        migration.activate(self.plan, freeze)
        self._close()
        self._receiver_overlay()

    def _db(self, path):
        connection = sqlite3.connect(path)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA wal_autocheckpoint=0")
        self.connections.append(connection)
        return connection

    def _write_sources(self):
        health = Path(self.roots["healthGroup"]) / "Health"
        health.mkdir()
        (health / "Backups").mkdir()
        (health / "Backups/old.healthbackup").write_bytes(b"old-full-backup")
        (health / ".initialized").write_bytes(b"keep-marker")
        connection = self._db(health / "health.sqlite")
        connection.executescript(
            "CREATE TABLE state(id INTEGER PRIMARY KEY,json BLOB NOT NULL);"
            "CREATE TABLE records(id TEXT PRIMARY KEY,kind TEXT,occurred_at REAL,json BLOB);"
            "CREATE TABLE events(id TEXT PRIMARY KEY,type_id TEXT,occurred_at REAL,json BLOB);"
            "PRAGMA user_version=1;")
        state = {"schemaVersion": 2, "preferences": {"cup": 200},
                 "island": {"inventory": {"wood": 9}, "rewardedSleepIDs": ["S1"]},
                 "ledgers": {"2026-11-01": {"sleepEnergy": 7}}, "requests": ["old-request-id"]}
        connection.execute("INSERT INTO state VALUES(1,?)", (json.dumps(state).encode(),))
        connection.execute("INSERT INTO records VALUES('H1','water',100,?)", (b'{"id":"H1","amount":200}',))
        connection.commit()
        sleep = Path(self.roots["healthGroup"]) / "SharedSleep"
        sleep.mkdir()
        (sleep / ".initialized").write_bytes(b"SharedSleep schema 1\n")
        connection = self._db(sleep / "sleep-records.sqlite")
        connection.executescript(
            "CREATE TABLE sleep_metadata(id INTEGER PRIMARY KEY,version INTEGER);"
            "INSERT INTO sleep_metadata VALUES(1,1);"
            "CREATE TABLE sleep_records(id TEXT PRIMARY KEY,payload BLOB,deleted INTEGER);"
            "CREATE TABLE sleep_migrations(key TEXT PRIMARY KEY);"
            "INSERT INTO sleep_migrations VALUES('rhythm-library-v1');PRAGMA user_version=1;")
        connection.execute("INSERT INTO sleep_records VALUES('S1',?,0)", (json.dumps(self.sleep).encode(),))
        connection.execute("INSERT INTO sleep_records VALUES('deleted-id',NULL,1)")
        connection.commit()
        footprints = Path(self.roots["footprintsSupport"])
        (footprints / "Photos").mkdir()
        (footprints / "Snapshots").mkdir()
        photo = b"synthetic-jpg-bytes"
        (footprints / "Photos" / (PHOTO_ID + ".jpg")).write_bytes(photo)
        (footprints / "Snapshots/old.json").write_bytes(b'{"preserve":"snapshot"}')
        connection = self._db(footprints / "footprints.sqlite")
        connection.execute("CREATE TABLE items(kind TEXT,id TEXT,payload BLOB,PRIMARY KEY(kind,id))")
        rows = [("meta", "main", {"schema": 1, "train": {"coins": 17, "rewardedVisits": ["V1"]}}),
                ("visit", "V1", {"id": "V1", "photoIDs": [PHOTO_ID], "tripID": "T1"}),
                ("trip", "T1", {"id": "T1", "name": "synthetic-trip"}),
                ("photo", PHOTO_ID, {"id": PHOTO_ID, "filename": PHOTO_ID + ".jpg",
                                     "size": len(photo), "sha256": migration.sha(photo)})]
        connection.executemany("INSERT INTO items VALUES(?,?,?)",
                               [(kind, row_id, json.dumps(value).encode()) for kind, row_id, value in rows])
        connection.commit()
        (Path(self.roots["footprintsGroup"]) / "widget-generation.json").write_bytes(b'{"preserve":"old-widget-data"}')
        (Path(self.roots["healthSupport"]) / "document.pdf").write_bytes(b"private-attachment-fixture")
        (Path(self.roots["healthRestore"]) / "pending.json").write_bytes(b'{"staged":"old-source-only-job"}')
        prefs = {"standard": {"gqns.language": "en"}, "module": {"animationEnabled": False, "soundEnabled": True,
                                                                 "ownerName": "fixture-owner"}}
        for key in ("healthPreferences", "footprintsPreferences"):
            Path(self.roots[key]).write_bytes(plistlib.dumps(prefs, fmt=plistlib.FMT_BINARY))
        Path(self.roots["rhythmLibrary"]).write_bytes(json.dumps({
            "version": 11, "sleepRecords": [self.sleep], "coins": 662,
            "activeSleep": None, "activeFocus": None}).encode())

    def _freeze(self, plan):
        value = {"schemaVersion": 1, "transactionID": plan["transactionID"],
                 "planSHA256": migration.sha(migration.canonical(plan)),
                 "sourceRevisions": plan["sourceRevisions"], "sourcesFrozen": True,
                 "stoppedWriterBundleIDs": sorted(migration.WRITERS),
                 "footprintsPublisherStopped": True, "oldWidgetsCannotWrite": True,
                 "backupsVerified": True, "rollbackVerified": True, "verifiedAt": migration.now(),
                 "evidence": ["SYNTHETIC_FIXTURE_ONLY_NOT_REAL_FREEZE"]}
        path = self.base / "freeze.json"
        path.write_bytes(migration.canonical(value))
        return path

    def _receiver_overlay(self):
        data = library_bytes(self.sleep)
        (self.support / "library.json").write_bytes(data)
        (self.group / "library.json").write_bytes(data)
        health = self.group / "Integration/Modules/Health/health.sqlite"
        connection = sqlite3.connect(health)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA wal_autocheckpoint=0")
        connection.execute("INSERT INTO records VALUES('H-WAL','water',101,?)", (b'{"id":"H-WAL"}',))
        connection.commit()
        # Keep the writer open so the committed frame stays in the WAL instead of
        # being checkpointed by the last connection close.
        self.connections.append(connection)
        os.setxattr(health, "user.rhythm.db", b"db-meta", follow_symlinks=False)
        marker = self.group / "Integration/Modules/Health/ImportedSupport/business-marker.json"
        marker.write_bytes(json.dumps({"label": "keep", "rawBase64": BUSINESS_RAW}).encode())
        os.setxattr(marker, "user.rhythm.keep", b"kept-meta", follow_symlinks=False)
        escrow = self.group / "Integration/SourceArchives/Health/NativeMetadata.noindex/0000.json"
        escrow.parent.mkdir(mode=0o700)
        escrow.write_bytes(json.dumps({
            "stage": "copy", "changes": [{"source": {"rawBase64": SOURCE_RAW}, "native": {"rawBase64": None}}]
        }).encode())
        tx = self.group / "Integration/Transactions.noindex/receiver-tx-1"
        payload = tx / "Payload-0123456789abcdef"
        (payload / "SourceArchives/Health").mkdir(parents=True)
        (payload / "SourceArchives/Health/secret.txt").write_bytes(SOURCE_RAW.encode())
        rhythm = self.group / "Integration/SourceArchives/Rhythm/library.json"
        (payload / "SourceArchives/Rhythm").mkdir(parents=True)
        (payload / "SourceArchives/Rhythm/library.json").write_bytes(rhythm.read_bytes())
        (payload / "Modules/Health").mkdir(parents=True)
        (payload / "Modules/Health/staged.sqlite").write_bytes(b"staged-not-current")
        moves = tx / "NativeMoves.noindex"
        moves.mkdir()
        provenance = {"present": True, "length": len(SOURCE_RAW), "sha256": migration.sha(SOURCE_RAW.encode()),
                      "rawBase64": SOURCE_RAW}
        absent = {"present": False, "length": 0, "sha256": None, "rawBase64": None}
        (moves / "Modules-Health.intent.json").write_bytes(json.dumps({"rootProvenance": provenance}).encode())
        (moves / "SharedSleep.observed.json").write_bytes(json.dumps({
            "rootProvenance": provenance, "changes": [{"source": provenance, "native": absent}]}).encode())
        (self.group / "Integration/Transactions.noindex/other-tx").mkdir()
        (self.group / "Integration/Transactions.noindex/other-tx/owner.json").write_bytes(b'{"foreign":true}')
        for domain in tool.DOMAINS:
            (self.preferences / (domain + ".plist")).write_bytes(plistlib.dumps(
                {"canary": CANARY, "domain": domain}, fmt=plistlib.FMT_BINARY))

    def _close(self):
        for connection in self.connections:
            connection.close()
        self.connections.clear()

    def export(self, output=None, **kwargs):
        output = output or (self.base / "package.noindex")
        return tool.export_package(self.group, self.support, self.preferences, self.plan_path, output, **kwargs)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(suffix=".noindex")
        self.base = Path(self.temp.name).resolve()
        self.world = World(self.base)

    def tearDown(self):
        self.world._close()
        self.temp.cleanup()

    def package_bytes(self, package):
        blob = b""
        for path in sorted(package.rglob("*")):
            if path.is_file() and not path.is_symlink():
                blob += path.read_bytes()
        return blob

    def test_whitelist_excludes_source_raw_and_preserves_business_field(self):
        package = self.base / "package.noindex"
        before = {
            "plan": self.world.plan_path.read_bytes(),
            "authority": (self.world.group / "Integration/authority.json").read_bytes(),
            "receipt": (self.world.group / "Integration/Transactions.noindex/receiver-tx-1/receipt.json").read_bytes(),
            "owner": (self.world.group / "Integration/Transactions.noindex/receiver-tx-1/owner.json").read_bytes(),
        }
        summary = self.world.export(package)
        self.assertFalse(summary["realRecoveryCompleted"])
        self.assertFalse(summary["activeWrite"])
        self.assertEqual(summary["rootMaintenanceEvidence"], "NOT_EXECUTED")
        self.assertEqual(summary["productionPlanByteHashVerified"], "NOT_EXECUTED")
        self.assertGreaterEqual(summary["businessRawBase64Preserved"], 1)
        self.assertEqual(before["plan"], self.world.plan_path.read_bytes())
        self.assertEqual(before["authority"], (self.world.group / "Integration/authority.json").read_bytes())
        self.assertEqual(before["receipt"], (self.world.group / "Integration/Transactions.noindex/receiver-tx-1/receipt.json").read_bytes())
        self.assertEqual(before["owner"], (self.world.group / "Integration/Transactions.noindex/receiver-tx-1/owner.json").read_bytes())
        payload = package / "payload"
        self.assertTrue((payload / "GroupContainer/Integration/Modules/Health/health.sqlite").is_file())
        self.assertTrue((payload / "GroupContainer/Integration/Modules/Footprints/Photos").is_dir())
        self.assertTrue((payload / "GroupContainer/Integration/SharedSleep/sleep-records.sqlite").is_file())
        self.assertTrue((payload / "GroupContainer/Integration/authority.json").is_file())
        self.assertTrue((payload / "GroupContainer/Integration/SourceArchives/Rhythm/library.json").is_file())
        self.assertTrue((payload / "GroupContainer/Integration/SourceArchives/explicit-absences.json").is_file())
        self.assertFalse((payload / "GroupContainer/Integration/SourceArchives/Health").exists())
        self.assertFalse((payload / "GroupContainer/Integration/SourceArchives/Footprints").exists())
        self.assertFalse((payload / "GroupContainer/Integration/Transactions.noindex/receiver-tx-1/Payload-0123456789abcdef").exists())
        self.assertFalse((payload / "GroupContainer/Integration/Transactions.noindex/receiver-tx-1/NativeMoves.noindex").exists())
        self.assertFalse((payload / "GroupContainer/Integration/Transactions.noindex/other-tx").exists())
        self.assertFalse(list(payload.rglob("*.sqlite-wal")))
        blob = self.package_bytes(package / "payload/GroupContainer")
        self.assertIn(BUSINESS_RAW.encode(), blob)
        self.assertNotIn(SOURCE_RAW.encode(), blob)
        for domain in tool.DOMAINS:
            stored = (package / "payload/Preferences" / (domain + ".plist")).read_bytes()
            self.assertEqual(stored, (self.world.preferences / (domain + ".plist")).read_bytes())
        with sqlite3.connect(payload / "GroupContainer/Integration/Modules/Health/health.sqlite") as connection:
            ids = {row[0] for row in connection.execute("SELECT id FROM records")}
        self.assertIn("H-WAL", ids)
        self.assertTrue((self.world.group / "Integration/Modules/Health/health.sqlite-wal").is_file())
        policy = json.loads((package / "manifests/metadata-policy.json").read_text())
        self.assertEqual(policy["macosQuarantineFidelity"], "UNVERIFIED")
        self.assertEqual(policy["bsdFlags"], "UNVERIFIED")
        self.assertEqual(policy["acl"], "UNVERIFIED")
        self.assertFalse(policy["quarantineAttributesObserved"])
        if sys.platform != "darwin":
            self.assertEqual(policy["appleMetadata"], "SKIP")
            self.assertEqual(policy["platform"], "non_darwin")
        kept = payload / "GroupContainer/Integration/Modules/Health/ImportedSupport/business-marker.json"
        self.assertEqual(os.getxattr(kept, "user.rhythm.keep", follow_symlinks=False), b"kept-meta")
        database = payload / "GroupContainer/Integration/Modules/Health/health.sqlite"
        self.assertEqual(os.getxattr(database, "user.rhythm.db", follow_symlinks=False), b"db-meta")

    def test_isolated_restore_matches_archive_without_a_preexisting_group(self):
        package = self.base / "package.noindex"
        self.world.export(package)
        target = self.base / "sandbox.noindex"
        self.assertFalse(target.exists())
        restored = tool.restore_package(package, target)
        self.assertFalse(restored["realRecoveryCompleted"])
        self.assertFalse(restored["preexistingGroupRequired"])
        self.assertTrue((target / "GroupContainer/Integration/Modules/Footprints/footprints.sqlite").is_file())
        self.assertEqual((target / "ApplicationSupport/GaoSeries/Rhythm/library.json").read_bytes(),
                         (self.world.support / "library.json").read_bytes())
        checked = tool.verify_package(package, self.world.plan_path, restored=target, source_group=self.world.group)
        self.assertEqual(checked["integrateSourcesRuntimeOnly"]["status"], "active")
        self.assertFalse(checked["integrateSourcesRuntimeOnly"]["sourceArchivesChecked"])
        self.assertTrue(checked["equivalentReadersApplied"])
        self.assertFalse(checked["realRecoveryCompleted"])
        self.assertEqual(checked["productionPlanByteHashVerified"], "NOT_EXECUTED")
        receipt = json.loads((target / "recovery-receipt.json").read_text())
        self.assertFalse(receipt["reMigration"])
        self.assertFalse(receipt["reActivation"])
        self.assertFalse(receipt["activeBusinessRolledBack"])
        self.assertFalse(receipt["realRecoveryCompleted"])
        self.assertNotEqual(receipt["restoreCheckAt"], "NOT_EXECUTED")
        package_receipt = (package / "manifests/receipt.json").read_bytes()
        self.assertEqual((package / "manifests/receipt.json").read_bytes(), package_receipt)

    def test_duplicate_restore_and_interrupt_leave_sources_and_target_unchanged(self):
        package = self.base / "package.noindex"
        authority = (self.world.group / "Integration/authority.json").read_bytes()
        with self.assertRaises(tool.RecoveryError) as interrupted:
            self.world.export(package, failpoint="before_commit")
        self.assertEqual(interrupted.exception.code, "failpoint_before_commit")
        self.assertFalse(package.exists())
        self.assertFalse((self.base / "package.partial.noindex").exists())
        self.assertEqual(authority, (self.world.group / "Integration/authority.json").read_bytes())
        self.world.export(package)
        target = self.base / "sandbox.noindex"
        with self.assertRaises(tool.RecoveryError) as restore_interrupted:
            tool.restore_package(package, target, failpoint="before_commit")
        self.assertEqual(restore_interrupted.exception.code, "failpoint_before_commit")
        self.assertFalse(target.exists())
        tool.restore_package(package, target)
        marker = (target / "GroupContainer/Integration/authority.json").read_bytes()
        with self.assertRaises(tool.RecoveryError) as duplicate:
            tool.restore_package(package, target)
        self.assertEqual(duplicate.exception.code, "restore_target_exists")
        self.assertEqual(marker, (target / "GroupContainer/Integration/authority.json").read_bytes())

    def test_unknown_paths_preferences_symlinks_and_raw_pointers_fail_closed(self):
        with self.assertRaises(tool.RecoveryError) as missing:
            self.world.preferences.joinpath("com.gaojiezou.rhythm.plist").unlink()
            self.world.export(self.base / "missing-pref.noindex")
        self.assertEqual(missing.exception.code, "preference_domain_missing")
        (self.world.preferences / "com.gaojiezou.rhythm.plist").write_bytes(plistlib.dumps({"canary": CANARY}))
        (self.world.preferences / "com.example.extra.plist").write_bytes(plistlib.dumps({"a": 1}))
        with self.assertRaises(tool.RecoveryError) as extra:
            self.world.export(self.base / "extra-pref.noindex")
        self.assertEqual(extra.exception.code, "unknown_preference_domain")
        (self.world.preferences / "com.example.extra.plist").unlink()

        (self.world.group / "mystery.bin").write_bytes(b"unknown")
        with self.assertRaises(tool.RecoveryError) as unknown:
            self.world.export(self.base / "unknown.noindex")
        self.assertEqual(unknown.exception.code, "unclassified_group_entry")
        (self.world.group / "mystery.bin").unlink()

        link = self.world.group / "Integration/Modules/Health/alias"
        link.symlink_to(self.world.support / "library.json")
        with self.assertRaises(tool.RecoveryError) as linked:
            self.world.export(self.base / "link.noindex")
        self.assertEqual(linked.exception.code, "symlink_refused")
        link.unlink()

        moves = self.world.group / "Integration/Transactions.noindex/receiver-tx-1/NativeMoves.noindex"
        (moves / "SourceArchives.observed.json").write_bytes(json.dumps({
            "rootProvenance": {"rawBase64": SOURCE_RAW},
            "businessNote": {"rawBase64": "not-a-metadata-state"}}).encode())
        with self.assertRaises(tool.RecoveryError) as mixed:
            self.world.export(self.base / "mixed.noindex")
        self.assertEqual(mixed.exception.code, "rawbase64_ownership_unresolved")
        self.assertFalse((self.base / "mixed.noindex").exists())
        (moves / "SourceArchives.observed.json").unlink()

        payload = self.world.group / "Integration/Transactions.noindex/receiver-tx-1/Payload-0123456789abcdef"
        (payload / "SourceArchives/Rhythm/library.json").write_bytes(b"different-from-live")
        with self.assertRaises(tool.RecoveryError) as diverged:
            self.world.export(self.base / "diverged.noindex")
        self.assertEqual(diverged.exception.code, "staged_rhythm_archive_diverges_from_live")
        live = (self.world.group / "Integration/SourceArchives/Rhythm/library.json").read_bytes()
        (payload / "SourceArchives/Rhythm/library.json").write_bytes(live)
        (payload / "extra.bin").write_bytes(b"unclassified-leaf")
        with self.assertRaises(tool.RecoveryError) as leaf:
            self.world.export(self.base / "leaf.noindex")
        self.assertEqual(leaf.exception.code, "unclassified_payload_leaf")
        (payload / "extra.bin").unlink()

        receipt = self.world.group / "Integration/Transactions.noindex/receiver-tx-1/receipt.json"
        original = receipt.read_bytes()
        poisoned_receipt = json.loads(original)
        poisoned_receipt["rawBase64"] = "nope"
        receipt.write_bytes(json.dumps(poisoned_receipt).encode())
        with self.assertRaises(tool.RecoveryError) as poisoned:
            self.world.export(self.base / "receipt.noindex")
        self.assertEqual(poisoned.exception.code, "immutable_receipt_contains_rawbase64")
        self.assertEqual(json.loads(receipt.read_bytes())["rawBase64"], "nope")
        receipt.write_bytes(original)

    def test_missing_group_integration_and_live_targets_are_refused(self):
        integration = self.world.group / "Integration"
        held = self.base / "held-integration"
        integration.rename(held)
        with self.assertRaises(tool.RecoveryError) as missing:
            self.world.export(self.base / "no-integration.noindex")
        self.assertEqual(missing.exception.code, "required_authority_missing")
        held.rename(integration)
        with self.assertRaises(tool.RecoveryError) as relative:
            tool.check_relative("Modules/../../escape")
        self.assertEqual(relative.exception.code, "unsafe_relative_path")
        home = self.base / "home"
        live = home / "Library/Group Containers" / tool.GROUP_ID
        live.mkdir(parents=True)
        (live / "placeholder").mkdir()
        with self.assertRaises(tool.RecoveryError) as refused:
            tool.refuse_live(live / "placeholder", home=home)
        self.assertEqual(refused.exception.code, "live_data_root_refused")
        with self.assertRaises(tool.RecoveryError) as applications:
            tool.refuse_live(Path("/Applications/GaoJieZou.app"), home=home)
        self.assertEqual(applications.exception.code, "live_data_root_refused")
        marker = self.world.group / ".rhythm-integration-maintenance.json"
        marker.write_bytes(b'{"owner":"host"}')
        with self.assertRaises(tool.RecoveryError) as maintenance:
            self.world.export(self.base / "maintenance.noindex")
        self.assertEqual(maintenance.exception.code, "source_maintenance_in_progress")
        marker.unlink()
        (self.world.support / "library.json.read-only").write_bytes(b"blocked")
        with self.assertRaises(tool.RecoveryError) as readonly:
            self.world.export(self.base / "readonly.noindex")
        self.assertEqual(readonly.exception.code, "library_read_only_marker_present")

    def test_cli_does_not_print_preference_or_claim_real_recovery(self):
        package = self.base / "package.noindex"
        completed = subprocess.run([sys.executable, str(ROOT / "scripts/receiver_whitelist_recovery.py"),
                                    "export", "--group", str(self.world.group), "--app-support", str(self.world.support),
                                    "--preferences-dir", str(self.world.preferences), "--plan", str(self.world.plan_path),
                                    "--output", str(package)], check=False, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn(CANARY, completed.stdout)
        self.assertNotIn(SOURCE_RAW, completed.stdout)
        body = json.loads(completed.stdout)
        self.assertFalse(body["realRecoveryCompleted"])
        self.assertEqual(body["scope"], "isolated_noindex_only")
        target = self.base / "cli-sandbox.noindex"
        restored = subprocess.run([sys.executable, str(ROOT / "scripts/receiver_whitelist_recovery.py"),
                                   "restore", "--package", str(package), "--target", str(target)],
                                  check=False, capture_output=True, text=True)
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertFalse(json.loads(restored.stdout)["realRecoveryCompleted"])
        verified = subprocess.run([sys.executable, str(ROOT / "scripts/receiver_whitelist_recovery.py"),
                                   "verify", "--package", str(package), "--plan", str(self.world.plan_path),
                                   "--restored", str(target), "--source-group", str(self.world.group)],
                                  check=False, capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertNotIn(CANARY, verified.stdout)
        self.assertFalse(json.loads(verified.stdout)["realRecoveryCompleted"])
        rejected = subprocess.run([sys.executable, str(ROOT / "scripts/receiver_whitelist_recovery.py"), "apply"],
                                  check=False, capture_output=True, text=True)
        self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main()
