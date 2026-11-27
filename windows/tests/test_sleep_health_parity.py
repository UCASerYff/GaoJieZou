import csv
import io
import json
import sqlite3
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen

import pytest

from gaojiezou.errors import AppError
from gaojiezou.health import HealthStore
from gaojiezou.sleepstore import SharedSleep
from gaojiezou.store import RhythmStore
from gaojiezou.timeutil import cocoa
from gaojiezou.web import serve


NOW = datetime(2026, 11, 23, 10, tzinfo=timezone.utc)


def entry(record_id, start=None, end=None, **changes):
    start = start or NOW - timedelta(hours=8)
    end = end or NOW
    return {
        "id": record_id,
        "startedAt": cocoa(start),
        "endedAt": cocoa(end),
        "durationSeconds": (end - start).total_seconds(),
        "score": 100,
        "pastureYield": 0,
        **changes,
    }


def test_shared_sleep_serializes_duplicate_check_and_preserves_peer_edits(tmp_path):
    first = SharedSleep(tmp_path, lambda: NOW)
    first.create_fresh()
    peer = SharedSleep(tmp_path, lambda: NOW)
    peer.open_existing()

    def add(store, record_id):
        try:
            store.upsert(entry(record_id))
            return record_id
        except AppError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = (pool.submit(add, first, "one"), pool.submit(add, peer, "two"))
        identities = [result.result() for result in results]
    assert identities.count("duplicate") == 1
    record_id = next(value for value in identities if value != "duplicate")
    first.upsert(entry(record_id, score=88, origin="health", manualEntry=True, pastureYield=3))
    peer.upsert(entry(record_id, score=66, pastureYield=1))
    peer.update_settlement(entry(record_id, score=99, pastureYield=2, manualProductionCreditedCycles=1))
    assert first.live() == [entry(record_id, score=66, pastureYield=3, origin="health", manualEntry=True, manualProductionCreditedCycles=1)]
    peer.remove(record_id)
    with pytest.raises(AppError, match="已删除"):
        first.update_settlement(entry(record_id, pastureYield=5))
    assert first.entries() == [{"id": record_id, "deleted": True}]
    first.close()
    peer.close()


def test_pending_alias_tombstone_and_missing_migration_are_preserved(tmp_path):
    sleep = SharedSleep(tmp_path, lambda: NOW)
    sleep.create_fresh()
    sleep.upsert(entry("canonical", score=80, origin="health"))
    pending = entry("alias", score=91, pastureYield=2)
    sleep.reconcile_pending(pending, {**pending, "manualProductionCreditedCycles": 2})
    assert sleep.live()[0]["score"] == 80
    assert sleep.live()[0]["manualProductionCreditedCycles"] == 2
    sleep.remove("canonical")
    sleep.reconcile_pending(pending, pending)
    assert sleep.live() == []
    sleep.close()
    with sqlite3.connect(sleep.path) as db:
        db.execute("DELETE FROM sleep_migrations")
    before = sleep.path.read_bytes()
    with pytest.raises(AppError, match="迁移凭据"):
        sleep.open_existing()
    assert sleep.path.read_bytes() == before
    assert not sleep.is_open


def test_windows_open_does_not_recreate_missing_sleep_or_reward_local_pending(tmp_path):
    store = RhythmStore(tmp_path, timezone.utc, lambda: NOW)
    store.create_library()
    store.sleep.close()
    store.sleep.path.unlink()
    local = store.add_manual_sleep(NOW - timedelta(hours=8), NOW)
    snapshot = store.snapshot()
    assert snapshot["library"]["sleepRecords"][0]["id"] == local["id"]
    assert store.health.state["island"]["rewardedSleepIDs"] == []
    assert snapshot["health"]["sleepRecords"] == []
    assert snapshot["sleepSyncError"]
    assert not store.sleep.path.exists()


def test_both_sleep_entry_points_share_receipts_through_reopen(tmp_path):
    store = RhythmStore(tmp_path, timezone.utc, lambda: NOW)
    store.create_library()
    store.buy_animal("chicken")
    health_sleep = store.add_health_sleep(NOW - timedelta(hours=8), NOW)
    assert store.library["sleepRecords"][0]["healthSource"] == "搞健康"
    assert store.sleep.live()[0]["manualProductionCreditedCycles"] == 2
    assert store.health.state["island"]["rewardedSleepIDs"] == [health_sleep["id"]]
    assert store.health.state["ledgers"]["2026-11-23"]["sleepEnergy"] == 24
    with pytest.raises(AppError) as error:
        store.add_manual_sleep(NOW - timedelta(hours=8, seconds=60), NOW - timedelta(seconds=60))
    assert error.value.code == "duplicate"
    store.sleep.close()
    store.health.close()
    reopened = RhythmStore(tmp_path, timezone.utc, lambda: NOW)
    rewards = reopened.snapshot()["health"]["island"]["energy"]
    assert reopened.snapshot()["health"]["island"]["energy"] == rewards
    reopened.delete_sleep(health_sleep["id"])
    assert reopened.snapshot()["health"]["sleepRecords"] == []
    assert reopened.snapshot()["library"]["sleepRecords"] == []
    assert reopened.health.state["island"]["rewardedSleepIDs"] == [health_sleep["id"]]


def test_health_peer_updates_and_undo_preserve_credits_and_wire_format(tmp_path):
    first = HealthStore(tmp_path, timezone.utc)
    first.create_fresh(NOW)
    peer = HealthStore(tmp_path, timezone.utc)
    peer.open_existing()
    meal = first.save_record({
        "kind": "meal", "amount": 1, "occurredAt": NOW.isoformat(), "title": "午餐",
        "mealSource": "canteen", "fullnessPercent": 0, "saveTemplate": True,
    }, NOW)
    assert first.state["ledgers"]["2026-11-23"]["food"] == 0
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert pool.submit(peer.reward_sleep, [entry("shared")], NOW).result() == 24
        assert pool.submit(first.reward_sleep, [entry("shared")], NOW).result() == 0
    first.set_preferences({"waterGoal": 1700, "slots": 2, "restHour": 0}, NOW)
    with pytest.raises(AppError):
        first.set_preferences({"cup": -1}, NOW)
    assert first.summary(NOW)["dailyConfig"]["restHour"] == 0
    assert first.summary(NOW)["preferences"]["cup"] == 250
    first.delete_record(meal["id"], NOW)
    first.undo(NOW)
    assert first.summary(NOW)["meals"] == 1
    assert first.summary(NOW)["templates"][0]["record"]["mealSource"] == "canteen"
    with sqlite3.connect(first.path) as db:
        occurred, raw = db.execute("SELECT occurred_at,json FROM records").fetchone()
    assert occurred == NOW.timestamp()
    record = json.loads(raw)
    assert record["occurredAt"] == cocoa(NOW)
    assert record["baseAmount"] == 1
    assert record["timezone"] == "UTC"
    first.close()
    peer.close()


def test_health_http_actions_use_the_shared_journal(tmp_path):
    store = RhythmStore(tmp_path, timezone.utc, lambda: NOW)
    store.create_library()
    server = serve(store, open_browser=False)

    def api(path, payload=None):
        body = json.dumps(payload).encode() if payload is not None else None
        request = Request(server.url + path, body, {
            "X-Gao-Token": server.token, "Content-Type": "application/json",
        })
        with urlopen(request, timeout=3) as response:
            return json.load(response)

    try:
        water = api("api/health/record", {"kind": "water", "amount": 300})
        assert water["state"]["health"]["water"] == 300
        health_sleep = api("api/health/sleep/add", {
            "start": (NOW - timedelta(hours=8)).isoformat(),
            "end": NOW.isoformat(),
        })
        record_id = health_sleep["result"]["id"]
        assert health_sleep["state"]["health"]["sleepRecords"][0]["id"] == record_id
        assert health_sleep["state"]["library"]["sleepRecords"][0]["id"] == record_id
        assert health_sleep["state"]["health"]["dailyLedger"]["sleepEnergy"] == 24
        assert api("api/health/sleep/delete", {"id": record_id})["state"]["library"]["sleepRecords"] == []
        assert api("api/state")["health"]["dailyLedger"]["sleepEnergy"] == 24
        event_type = api("api/health/event/type", {"name": "测试事项"})["result"]["id"]
        event = api("api/health/event", {"typeID": event_type, "count": 2})["result"]["id"]
        assert api("api/health/event/delete", {"id": event})["state"]["health"]["events"] == []
        assert api("api/health/undo", {})["state"]["health"]["events"][0]["id"] == event
    finally:
        server.shutdown()
        server.server_close()
        store.sleep.close()
        store.health.close()


def test_health_csv_uses_mac_filenames_and_import_does_not_reward(tmp_path):
    source = HealthStore(tmp_path / "source", timezone.utc)
    target = HealthStore(tmp_path / "target", timezone.utc)
    source.create_fresh(NOW)
    target.create_fresh(NOW)
    note = '无糖\n半杯，含 "引号"'
    meal = source.save_record({
        "kind": "meal", "amount": 1, "mealSource": "home", "fullnessPercent": 0,
        "note": note, "title": "=1+2",
    }, NOW)
    type_id = source.state["eventTypes"][0]["id"]
    source.save_event({"typeID": type_id, "count": 2}, NOW)
    with zipfile.ZipFile(io.BytesIO(source.export_csv())) as archive:
        assert set(archive.namelist()) == {"water.csv", "meal.csv", "exercise.csv", "weight.csv", "custom-events.csv"}
        files = {name: archive.read(name).decode("utf-8") for name in archive.namelist()}
    exported = list(csv.DictReader(io.StringIO(files["meal.csv"].removeprefix("\ufeff"))))
    assert exported[0]["name"] == "'=1+2"
    assert exported[0]["note"] == note
    assert target.import_csv(files, NOW) == {"added": 2, "skipped": 0, "invalid": 0}
    assert target.import_csv(files, NOW) == {"added": 0, "skipped": 2, "invalid": 0}
    imported = target.summary(NOW)["records"][0]
    assert imported["id"] == meal["id"]
    assert imported["note"] == note
    assert imported["rewardEligible"] is False
    assert imported["fullnessPercent"] == 0
    assert target.state["island"]["energy"] == 60
    assert target.state["ledgers"] == {}
    source.close()
    target.close()
