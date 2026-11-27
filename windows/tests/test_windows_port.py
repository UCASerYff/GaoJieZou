"""搞节奏 Windows 版的资料保护、奖励规则和本地接口。"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from gaojiezou import catalog
from gaojiezou.errors import AppError
from gaojiezou.footprints import load_cities
from gaojiezou.library import LIBRARY_NAME
from gaojiezou.store import RhythmStore, focus_csv, habit_csv, sleep_csv
from gaojiezou.timeutil import cocoa
from gaojiezou.version import VERSION_LABEL
from gaojiezou.web import serve

UTC = timezone.utc


class Clock:
    def __init__(self, moment):
        self.moment = moment

    def __call__(self):
        return self.moment


def open_store(tmp_path: Path, moment=None) -> tuple[RhythmStore, Clock]:
    moment = moment or datetime(2026, 11, 14, 12, 0, tzinfo=UTC)
    clock = Clock(moment)
    store = RhythmStore(tmp_path, tz=UTC, clock=clock)
    return store, clock


def ready(tmp_path: Path, moment=None) -> tuple[RhythmStore, Clock]:
    store, clock = open_store(tmp_path, moment)
    store.create_library()
    return store, clock


def test_version_label():
    assert VERSION_LABEL == "4.12+5"


def test_create_preserves_unknown_field_and_omits_owned_animals(tmp_path):
    store, _clock = ready(tmp_path)
    store.library["futureNote"] = {"keep": True}
    store.save()
    text = (tmp_path / LIBRARY_NAME).read_text(encoding="utf-8")
    assert "ownedAnimals" not in text
    assert "futureNote" in text
    reloaded = RhythmStore(tmp_path, tz=UTC, clock=Clock(datetime(2026, 11, 14, 12, 0, tzinfo=UTC)))
    assert reloaded.library["futureNote"] == {"keep": True}
    assert reloaded.library["version"] == 11
    assert (tmp_path / "widget-snapshot.json").exists()
    assert (tmp_path / "Integration" / "authority.json").exists()
    assert (tmp_path / "Integration" / "SharedSleep" / "sleep-records.sqlite").exists()


def test_newer_or_corrupt_library_is_not_overwritten(tmp_path):
    original = {"version": 12, "habits": [{"title": "保留"}]}
    (tmp_path / LIBRARY_NAME).write_text(json.dumps(original), encoding="utf-8")
    store = RhythmStore(tmp_path, tz=UTC, clock=Clock(datetime(2026, 11, 14, tzinfo=UTC)))
    assert store.status == "protected"
    assert json.loads((tmp_path / LIBRARY_NAME).read_text(encoding="utf-8"))["version"] == 12
    with pytest.raises(AppError):
        store.save_habit({"title": "不应写入"})

    broken = tmp_path / "broken"
    broken.mkdir()
    (broken / LIBRARY_NAME).write_bytes(b"{")
    protected = RhythmStore(broken, tz=UTC, clock=Clock(datetime(2026, 11, 14, tzinfo=UTC)))
    assert protected.status == "protected"
    assert (broken / LIBRARY_NAME).read_bytes() == b"{"


def test_non_empty_directory_is_not_a_new_library(tmp_path):
    (tmp_path / "notes.txt").write_text("keep", encoding="utf-8")
    store = RhythmStore(tmp_path, tz=UTC, clock=Clock(datetime(2026, 11, 14, tzinfo=UTC)))
    assert store.status == "protected"
    with pytest.raises(AppError):
        store.create_library()
    assert not (tmp_path / LIBRARY_NAME).exists()


def test_windows_legacy_and_unreadable_settings_survive_record_updates(tmp_path):
    store, clock = ready(tmp_path)
    settings = tmp_path / "settings.json"
    settings.write_text('{"habitReminderHour":20,"legacySetting":{"value":true}}', encoding="utf-8")
    migrated = RhythmStore(tmp_path, tz=UTC, clock=clock)
    assert migrated.settings["habitReminderHour"] == 20
    assert migrated.settings["habitReminderMinute"] == 0
    migrated.update_settings({"habitReminderMinute": 15})
    assert json.loads(settings.read_text(encoding="utf-8"))["legacySetting"] == {"value": True}

    settings.write_bytes(b"{")
    protected = RhythmStore(tmp_path, tz=UTC, clock=clock)
    assert protected.status == "ready"
    protected.start_focus()
    with pytest.raises(AppError):
        protected.update_settings({"habitReminderMinute": 30})
    assert settings.read_bytes() == b"{"


def test_focus_coins_growth_and_segment_cap(tmp_path):
    store, clock = ready(tmp_path)
    plot_id = store.library["farmPlots"][0]["id"]
    store.plant(plot_id, "carrot")
    store.water(plot_id)
    assert store.library["farmPlots"][0]["nextFocusBoost"] == pytest.approx(0.15)
    store.start_focus(None)
    clock.moment += timedelta(minutes=45)
    record = store.finish_focus()
    assert record["earnedCoins"] == 3
    assert store.library["coins"] == 100 - 4 - 1 + 3
    assert store.library["farmPlots"][0]["growthMinutes"] == pytest.approx(45)
    assert store.library["farmPlots"][0]["nextFocusBoost"] == 0
    assert store.harvest(plot_id) == 7

    store.start_focus(None)
    clock.moment += timedelta(hours=10)
    store.pause_focus(for_system=False)
    assert store.library["activeFocus"]["accumulatedSeconds"] == pytest.approx(8 * 3600)
    assert store.library["activeFocus"]["pausedForSystem"] is False


def test_plot_does_not_receive_focus_before_planting_and_keeps_legacy_fields(tmp_path):
    store, clock = ready(tmp_path)
    plot = store.library["farmPlots"][0]
    plot["legacyField"] = {"preserved": True}
    store.start_focus()
    clock.moment += timedelta(minutes=30)
    store.plant(plot["id"], "carrot")
    clock.moment += timedelta(minutes=20)
    store.synchronize()
    assert plot["growthMinutes"] == 20
    assert store.harvest_all() == (0, 0)
    clock.moment += timedelta(minutes=30)
    assert store.harvest_all() == (1, 7)
    assert plot["legacyField"] == {"preserved": True}
    assert "cropID" not in plot
    assert store.harvest_all() == (0, 0)


def test_goal_edits_keep_action_dates_and_deletion_only_unlinks(tmp_path):
    store, _clock = ready(tmp_path)
    goal = store.library["longGoals"][0]
    action = store.save_action({
        "goalID": goal["id"],
        "title": "Scheduled action",
        "startDate": "2026-11-16",
        "endDate": "2026-11-18",
        "estimatedMinutes": 30,
    })
    store.save_goal({**goal, "status": "completed"})
    assert store.library["shortActions"][-1]["id"] == action["id"]
    assert action["startDate"] < action["endDate"] == action["dueDate"]
    store.delete_goal(goal["id"])
    assert "goalID" not in action
    assert action["startDate"] < action["endDate"]
    store.delete_action(action["id"])
    assert all(row["id"] != action["id"] for row in store.library["shortActions"])


def test_sell_one_and_return_aquarium_fish(tmp_path):
    store, _clock = ready(tmp_path)
    store.library["fishInventory"] = {"crucian": 3}
    assert store.sell_one_fish("crucian") == catalog.fish("crucian")[3]
    assert store.library["fishInventory"]["crucian"] == 2
    assert store.move_to_aquarium("crucian")
    resident = store.library["aquariumFish"][0]
    store.return_aquarium_fish(resident["id"])
    assert not store.library["aquariumFish"]
    assert store.library["fishInventory"]["crucian"] == 2


def test_short_focus_earns_nothing_and_cap_is_20(tmp_path):
    store, clock = ready(tmp_path)
    store.start_focus(None)
    clock.moment += timedelta(minutes=14)
    assert store.finish_focus()["earnedCoins"] == 0
    store.start_focus(None)
    clock.moment += timedelta(hours=6)
    assert store.finish_focus()["earnedCoins"] == 20


def test_habit_reward_is_once_and_future_is_rejected(tmp_path):
    store, clock = ready(tmp_path)
    habit = store.library["habits"][0]
    before = store.library["coins"]
    assert store.toggle_habit(habit["id"], clock.moment) is True
    assert store.library["coins"] == before + habit["rewardCoins"]
    assert store.toggle_habit(habit["id"], clock.moment) is False
    assert store.library["coins"] == before + habit["rewardCoins"]
    assert store.toggle_habit(habit["id"], clock.moment) is True
    assert store.library["coins"] == before + habit["rewardCoins"]
    with pytest.raises(AppError):
        store.toggle_habit(habit["id"], clock.moment + timedelta(days=1))
    yesterday = clock.moment - timedelta(days=1)
    store.library["habits"][0]["createdAt"] = cocoa(yesterday - timedelta(days=1))
    assert store.toggle_habit(habit["id"], yesterday) is True


def test_chore_goal_and_action_rewards_are_not_repeated(tmp_path):
    store, clock = ready(tmp_path)
    day = clock.moment.date().isoformat()
    chore = store.save_chore({"title": "买菜", "startDate": day, "endDate": day})
    store.toggle_chore(chore["id"])
    assert store.library["coins"] == 105
    store.toggle_chore(chore["id"])
    store.toggle_chore(chore["id"])
    assert store.library["coins"] == 105
    store.save_goal({"title": "写完一章", "status": "completed", "targetValue": 1, "currentValue": 1})
    assert store.library["bait"] == 5
    store.save_action({"title": "列提纲", "estimatedMinutes": 25, "isCompleted": True})
    assert store.library["bait"] == 6
    action = store.library["shortActions"][-1]
    store.toggle_action(action["id"])
    store.toggle_action(action["id"])
    assert store.library["bait"] == 6


def test_manual_sleep_settles_pasture_once_and_rejects_duplicates(tmp_path):
    store, clock = ready(tmp_path)
    store.buy_animal("chicken")
    resident = store.library["pastureAnimals"][0]
    resident["growthHours"] = catalog.maturity_hours(1)
    start = clock.moment - timedelta(hours=8)
    record = store.add_manual_sleep(start, clock.moment, 8)
    assert record["pastureYield"] == 2
    products = store.library["pastureAnimals"][0]["pendingProducts"]
    store._settle_manual(record["id"], 8)
    assert store.library["pastureAnimals"][0]["pendingProducts"] == products
    with pytest.raises(AppError) as caught:
        store.add_manual_sleep(start + timedelta(seconds=30), clock.moment, 8)
    assert caught.value.code == "duplicate"
    with pytest.raises(AppError):
        store.add_manual_sleep(clock.moment - timedelta(minutes=10), clock.moment, 8)


def test_shared_sleep_tombstone_is_not_revived(tmp_path):
    store, clock = ready(tmp_path)
    start = clock.moment - timedelta(hours=8)
    record = store.add_manual_sleep(start, clock.moment, 8)
    store.delete_sleep(record["id"])
    with pytest.raises(AppError) as caught:
        store.sleep.upsert(record)
    assert caught.value.code == "tombstone"
    assert store.sleep.migration_present()


def test_old_schema_rescales_growth_without_rewriting_until_save(tmp_path):
    payload = {
        "version": 10,
        "habits": [{
            "id": "H-1", "title": "早起", "symbol": "sun", "weekdays": [1, 2, 3, 4, 5, 6, 7],
            "rewardCoins": 99, "createdAt": 0,
        }],
        "habitCompletionKeys": [],
        "habitRewardKeys": [],
        "focusRecords": [],
        "sleepRecords": [],
        "longGoals": [],
        "shortActions": [],
        "coins": 10,
        "bait": 0,
        "farmPlots": [{"id": "P", "cropID": "carrot", "growthMinutes": 25, "nextFocusBoost": 0}],
        "pastureAnimals": [],
        "fishInventory": {},
        "fishCaught": {},
        "harvestedCrops": {},
        "rewardEvents": [],
        "chores": [{"id": "C", "title": "旧琐事", "startDate": 0, "endDate": 0, "isCompleted": False, "rewardClaimed": False}],
    }
    (tmp_path / LIBRARY_NAME).write_text(json.dumps(payload), encoding="utf-8")
    (tmp_path / "Integration").mkdir()
    (tmp_path / "Integration" / "authority.json").write_text("{}", encoding="utf-8")
    store = RhythmStore(tmp_path, tz=UTC, clock=Clock(datetime(2026, 11, 14, tzinfo=UTC)))
    assert store.library["habits"][0]["rewardCoins"] == 10
    assert store.library["farmPlots"][0]["growthMinutes"] == pytest.approx(45)
    assert store.library["chores"][0]["colorHex"] == "#EA8733"
    assert json.loads((tmp_path / LIBRARY_NAME).read_text(encoding="utf-8"))["version"] == 10


def test_fishing_rarity_and_aquarium_cap(tmp_path):
    assert catalog.fishing_rarity(1) == 5
    assert catalog.fishing_rarity(5) == 4
    assert catalog.fishing_rarity(17) == 3
    assert catalog.fishing_rarity(45) == 2
    assert catalog.fishing_rarity(46) == 1
    store, clock = ready(tmp_path)
    caught = store.grant_fish(1)
    assert caught["rarity"] == 5
    assert store.move_to_aquarium(caught["fishID"]) is True
    clock.moment += timedelta(days=9)
    assert store.collect_aquarium() == 7 * catalog.daily_income(5)


def test_health_record_rewards_and_island_gather(tmp_path):
    store, _clock = ready(tmp_path)
    with pytest.raises(AppError):
        store.health.save_record({"id": "W", "kind": "water", "amount": 20000, "occurredAt": cocoa(store.now()), "title": "太多"}, store.now())
    store.health.save_record({
        "id": "W1", "kind": "water", "amount": 500, "occurredAt": cocoa(store.now()),
        "title": "喝水", "slot": 0, "note": "", "source": "manual",
    }, store.now())
    assert store.health.state["island"]["water"] > 60
    message = store.health.act("chop", store.now())
    assert "木材" in message
    assert store.health.state["island"]["inventory"]["wood"] >= 3


def test_footprints_train_and_photo_limit(tmp_path):
    store, clock = ready(tmp_path)
    city = load_cities()["cities"][0]
    visit = store.footprints.save_visit({"cityID": city["id"], "date": {"precision": "unknown"}, "note": "短"}, clock.moment)
    assert store.footprints.journal["train"]["materials"] == 3
    with pytest.raises(AppError):
        store.footprints.save_visit({
            "cityID": city["id"],
            "date": {"precision": "day", "year": 2030, "month": 1, "day": 1},
        }, clock.moment)
    for index in range(20):
        store.footprints.add_photo(visit["id"], f"{index}.png", b"png" + bytes([index]), clock.moment)
    with pytest.raises(AppError):
        store.footprints.add_photo(visit["id"], "extra.png", b"png-extra", clock.moment)
    assert store.library["coins"] == 100


def test_csv_has_bom_and_headers(tmp_path):
    store, clock = ready(tmp_path)
    store.start_focus(None)
    clock.moment += timedelta(minutes=15)
    store.finish_focus()
    text = focus_csv(store)
    assert text.startswith("\ufeff开始时间,结束时间")
    assert "\r\n" in text
    assert sleep_csv(store).splitlines()[0].endswith("评分")
    store.toggle_habit(store.library["habits"][0]["id"])
    store.delete_habit(store.library["habits"][0]["id"])
    assert "已删除打卡" in habit_csv(store)


def test_local_http_creates_and_reads_library(tmp_path):
    store, _clock = open_store(tmp_path)
    server = serve(store, port=0, open_browser=False)
    try:
        import urllib.error
        import urllib.request
        page = urllib.request.urlopen(server.url).read().decode("utf-8")
        token = page.split('name="gao-token" content="', 1)[1].split('"', 1)[0]
        def post(path, body):
            request = urllib.request.Request(
                server.url.rstrip("/") + path,
                data=json.dumps(body).encode("utf-8"),
                headers={"Content-Type": "application/json", "X-Gao-Token": token},
                method="POST",
            )
            return json.loads(urllib.request.urlopen(request).read().decode("utf-8"))
        created = post("/api/library/create", {})
        assert created["ok"] is True
        assert (tmp_path / LIBRARY_NAME).exists()
        saved = post("/api/habits/save", {"title": "CI smoke habit", "rewardCoins": 4})
        assert saved["state"]["library"]["habits"][-1]["title"] == "CI smoke habit"
        disk = (tmp_path / LIBRARY_NAME).read_text(encoding="utf-8")
        assert "CI smoke habit" in disk
        denied = urllib.request.Request(server.url + "api/state")
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(denied)
    finally:
        server.shutdown()
        server.server_close()


def test_product_ui_has_no_backup_actions():
    root = Path(__file__).resolve().parents[1] / "src" / "gaojiezou" / "assets"
    text = "\n".join(path.read_text(encoding="utf-8") for path in root.glob("*.html"))
    text += "\n" + (root / "app.js").read_text(encoding="utf-8")
    for banned in ("导出完整资料", "从完整资料恢复", "恢复模块备份", "store.backup", "rollback"):
        assert banned not in text
