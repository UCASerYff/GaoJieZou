"""健康资料 health.sqlite（user_version 1）与荒岛结算。

记录、事项和岛屿进度按 Mac 版字段保存。三维场景不在这里。
已有目录却缺少数据库时不创建空库。
"""

from __future__ import annotations

import json
import math
import sqlite3
import uuid
from pathlib import Path

from gaojiezou import catalog
from gaojiezou.errors import AppError
from gaojiezou.library import atomic_write, dumps
from gaojiezou.timeutil import cocoa, day_key, from_cocoa, in_zone

HEALTH_SCHEMA = 2
RULES_VERSION = 1


class HealthStore:
    def __init__(self, directory: Path, tz):
        self.directory = directory
        self.path = directory / "health.sqlite"
        self.tz = tz
        self._db: sqlite3.Connection | None = None
        self.state: dict | None = None

    @property
    def available(self) -> bool:
        return self.path.exists() and self.path.stat().st_size > 0

    def create_fresh(self, now) -> None:
        if self.directory.exists() and any(self.directory.iterdir()):
            raise AppError("健康目录已有文件，未新建空库。", "protected")
        self.directory.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(self.path)
        self._db.executescript(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = FULL;
            CREATE TABLE state (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL);
            CREATE TABLE records (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                json BLOB NOT NULL
            );
            CREATE TABLE events (
                id TEXT PRIMARY KEY,
                type_id TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                json BLOB NOT NULL
            );
            PRAGMA user_version = 1;
            """
        )
        self.state = fresh_state(now, self.tz)
        self._persist_state()
        self._db.commit()

    def open_existing(self) -> None:
        if not self.available:
            raise AppError("健康库不存在或为空，未新建空库。", "missing")
        self._db = sqlite3.connect(self.path)
        self._db.row_factory = sqlite3.Row
        version = self._db.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, 1):
            raise AppError("健康库版本不受支持，未写入。", "protected")
        if version == 0:
            raise AppError("健康库仍是旧的单文件版本，Windows 版不降级也不拆写。", "protected")
        row = self._db.execute("SELECT json FROM state WHERE id=1").fetchone()
        if row is None:
            raise AppError("健康库缺少状态行，未写入。", "protected")
        self.state = json.loads(row["json"])
        if int(self.state.get("schemaVersion") or 0) != HEALTH_SCHEMA:
            raise AppError("健康状态版本不受支持，未写入。", "protected")
        if int(self.state.get("rulesVersion") or 0) != RULES_VERSION:
            raise AppError("健康规则版本不受支持，未写入。", "protected")
        self.state.setdefault("records", [])
        self.state.setdefault("events", [])
        self.state["records"] = [json.loads(item["json"]) for item in self._db.execute("SELECT json FROM records ORDER BY id")]
        self.state["events"] = [json.loads(item["json"]) for item in self._db.execute("SELECT json FROM events ORDER BY id")]
        self.state.setdefault("eventTypes", default_event_types())
        self.state.setdefault("ledgers", {})
        self.state.setdefault("requests", [])

    def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None

    def save_record(self, record: dict, now) -> dict:
        self._require()
        record = dict(record)
        record.setdefault("id", str(uuid.uuid4()).upper())
        record.setdefault("slot", 0)
        record.setdefault("note", "")
        record.setdefault("title", "")
        record.setdefault("source", "manual")
        if record.get("occurredAt") is None:
            record["occurredAt"] = cocoa(now)
        validate_record(record, now)
        previous = next((row for row in self.state["records"] if row["id"] == record["id"]), None)
        record = dict(record)
        record["updatedAt"] = cocoa(now)
        if previous is not None:
            record["createdAt"] = previous.get("createdAt", record.get("createdAt"))
            record["rewardEligible"] = previous.get("rewardEligible", True)
        else:
            record.setdefault("createdAt", cocoa(now))
            prefs = self.state["preferences"]
            island = self.state["island"]
            record["rewardEligible"] = bool(prefs.get("gameEnabled", True) and not island.get("paused"))
        settle(self.state, now, self.tz)
        self.state["records"] = [row for row in self.state["records"] if row["id"] != record["id"]]
        self.state["records"].append(record)
        today = day_key(now, self.tz)
        occurred = day_key(from_cocoa(record["occurredAt"]), self.tz)
        if occurred == today:
            visit(self.state, now, self.tz, welcome=bool(record["rewardEligible"]))
        if occurred == today and record["rewardEligible"] and _game_on(self.state):
            _apply_record_rewards(self.state, today, self.tz)
        self._write()
        return record

    def delete_record(self, record_id: str) -> None:
        self._require()
        self.state["records"] = [row for row in self.state["records"] if row["id"] != record_id]
        self._write()

    def save_event(self, event: dict, now) -> dict:
        self._require()
        event = dict(event)
        event.setdefault("id", str(uuid.uuid4()).upper())
        event.setdefault("source", "manual")
        event.setdefault("note", "")
        count = int(event.get("count") or 0)
        if not 1 <= count <= 999:
            raise AppError("事项次数须在 1 到 999 之间。", "invalid")
        if len(str(event.get("note") or "")) > 2000:
            raise AppError("事项备注过长。", "invalid")
        types = self.state.get("eventTypes") or []
        matched = next((item for item in types if item["id"] == event.get("typeID")), None)
        if matched is None or (matched.get("archived") and not any(row["id"] == event["id"] for row in self.state["events"])):
            raise AppError("事项类型已停用或不存在。", "invalid")
        event["occurredAt"] = _instant(event.get("occurredAt"), now)
        if from_cocoa(event["occurredAt"]) > now:
            raise AppError("不能记录未来的事项。", "invalid")
        self.state["events"] = [row for row in self.state["events"] if row["id"] != event["id"]]
        self.state["events"].append(event)
        self._write()
        return event

    def delete_event(self, event_id: str) -> None:
        self._require()
        self.state["events"] = [row for row in self.state["events"] if row["id"] != event_id]
        self._write()

    def act(self, action_id: str, now) -> str:
        self._require()
        visit(self.state, now, self.tz, welcome=True)
        action = catalog.ACTIONS_BY_ID.get(action_id)
        if action is None:
            raise AppError("没有这个采集行动。", "invalid")
        problem = action_problem(self.state, action)
        if problem:
            raise AppError(problem, "unavailable")
        amount = yield_amount(self.state, action)
        island = self.state["island"]
        island["energy"] -= energy_cost(self.state, action)
        island["food"] -= action[3]
        island["water"] -= action[4]
        island.setdefault("inventory", {})
        island["inventory"][action[5]] = int(island["inventory"].get(action[5]) or 0) + amount
        if action_id == "coconut":
            island["food"] = min(100, island["food"] + 3)
        _log(self.state, action_id, f"{action[1]} · +{amount} {catalog.MATERIAL_NAMES.get(action[5], action[5])}", now)
        self._write()
        return f"获得 {amount} {catalog.MATERIAL_NAMES.get(action[5], action[5])}"

    def build(self, recipe_id: str, now) -> str:
        self._require()
        visit(self.state, now, self.tz, welcome=True)
        recipe = catalog.RECIPES_BY_ID.get(recipe_id)
        if recipe is None:
            raise AppError("没有这个配方。", "invalid")
        problem = build_problem(self.state, recipe)
        if problem:
            raise AppError(problem, "unavailable")
        island = self.state["island"]
        for key, value in recipe[2].items():
            island["inventory"][key] = int(island["inventory"].get(key) or 0) - value
        if recipe[4]:
            _set_add(island, "tools", recipe_id)
        else:
            site = free_site(island, recipe_id)
            if site is None:
                raise AppError("请调整建筑位置后再建造。", "unavailable")
            _set_add(island, "buildings", recipe_id)
            island.setdefault("placements", {})[recipe_id] = {"x": site[0], "z": site[1]}
        _log(self.state, recipe_id, recipe[1], now)
        self._write()
        return recipe[1]

    def upgrade(self, recipe_id: str, now) -> str:
        self._require()
        visit(self.state, now, self.tz, welcome=True)
        recipe = catalog.RECIPES_BY_ID.get(recipe_id)
        if recipe is None or recipe[4]:
            raise AppError("请先建造可升级的建筑。", "invalid")
        level = building_level(self.state["island"], recipe_id)
        if level == 0:
            raise AppError("请先建造。", "unavailable")
        if level >= 4:
            raise AppError("已升至最高级。", "unavailable")
        if not _game_on(self.state):
            raise AppError("岛屿休整中。", "unavailable")
        cost = {key: value * (level + 1) for key, value in recipe[2].items()}
        if any(int(self.state["island"]["inventory"].get(key) or 0) < value for key, value in cost.items()):
            raise AppError("材料尚不足。", "unavailable")
        for key, value in cost.items():
            self.state["island"]["inventory"][key] -= value
        self.state["island"].setdefault("buildingLevels", {})[recipe_id] = level + 1
        _log(self.state, "upgrade", f"{recipe[1]} · Lv.{level + 1}", now)
        self._write()
        return f"{recipe[1]} Lv.{level + 1}"

    def expand(self, now) -> str:
        self._require()
        visit(self.state, now, self.tz, welcome=True)
        stage = int(self.state["island"].get("expansionLevel") or 0)
        if stage >= len(catalog.ISLAND_EXPANSION_COSTS):
            raise AppError("海岸已全部开拓。", "unavailable")
        if not _game_on(self.state):
            raise AppError("岛屿休整中。", "unavailable")
        if prosperity(self.state["island"]) < catalog.ISLAND_EXPANSION_REQUIREMENTS[stage]:
            raise AppError("繁荣度尚不足。", "unavailable")
        cost = catalog.ISLAND_EXPANSION_COSTS[stage]
        inventory = self.state["island"].setdefault("inventory", {})
        if any(int(inventory.get(key) or 0) < value for key, value in cost.items()):
            raise AppError("材料尚不足。", "unavailable")
        for key, value in cost.items():
            inventory[key] = int(inventory.get(key) or 0) - value
        self.state["island"]["expansionLevel"] = stage + 1
        _log(self.state, "expand", f"扩建海岸 · {stage + 1}/3", now)
        self._write()
        return f"海岸 {stage + 1}/3"

    def supply(self, now) -> str:
        self._require()
        visit(self.state, now, self.tz, welcome=True)
        key = day_key(now, self.tz)
        ledger = self.state["ledgers"].setdefault(key, {})
        island = self.state["island"]
        if not _game_on(self.state) or int(island["inventory"].get("ration") or 0) <= 0 or island["food"] >= 100 or int(ledger.get("supplies") or 0) >= 3:
            raise AppError("暂无干粮、饱食已满或今日已使用 3 次。", "unavailable")
        kitchen = building_level(island, "kitchen")
        gain = 5 + 3 * kitchen
        island["inventory"]["ration"] = int(island["inventory"].get("ration") or 0) - 1
        island["food"] = min(100, island["food"] + gain)
        ledger["supplies"] = int(ledger.get("supplies") or 0) + 1
        _log(self.state, "supply", f"食用补给 · +{gain}", now)
        self._write()
        return f"饱食 +{gain}"

    def reward_sleep(self, records: list[dict], now) -> float:
        self._require()
        if not _game_on(self.state):
            return 0
        pending = []
        known = set(self.state["island"].get("rewardedSleepIDs") or [])
        for record in records:
            duration = float(record.get("durationSeconds") or 0)
            ended = from_cocoa(record["endedAt"])
            if (
                record.get("id")
                and record["id"] not in known
                and 1800 <= duration <= 86400
                and ended <= now
                and (now - ended).total_seconds() <= 36 * 3600
            ):
                pending.append(record)
        if not pending:
            return 0
        visit(self.state, now, self.tz, welcome=False)
        key = day_key(now, self.tz)
        ledger = self.state["ledgers"].setdefault(key, {})
        earned = 0.0
        rewarded = list(self.state["island"].get("rewardedSleepIDs") or [])
        for record in sorted(pending, key=lambda row: float(row["endedAt"])):
            if record["id"] in rewarded:
                continue
            rewarded.append(record["id"])
            gain = min(max(0, 24 - float(ledger.get("sleepEnergy") or 0)), float(record["durationSeconds"]) / 3600 * 3)
            ledger["sleepEnergy"] = float(ledger.get("sleepEnergy") or 0) + gain
            earned += gain
        self.state["island"]["rewardedSleepIDs"] = rewarded
        if earned > 0:
            self.state["island"]["energy"] = min(100, self.state["island"]["energy"] + earned)
            _log(self.state, "sleep", f"睡眠恢复活力 · +{int(round(earned))}", now)
        self._write()
        return earned

    def summary(self, now) -> dict:
        if self.state is None:
            return {"available": False}
        today = day_key(now, self.tz)
        records = [
            row for row in self.state["records"]
            if day_key(from_cocoa(row["occurredAt"]), self.tz) == today
        ]
        water = sum(float(row.get("amount") or 0) for row in records if row.get("kind") == "water")
        meals = sum(1 for row in records if row.get("kind") == "meal")
        exercise = sum(float(row.get("amount") or 0) for row in records if row.get("kind") == "exercise")
        weights = [row for row in records if row.get("kind") == "weight"]
        latest_weight = max(weights, key=lambda row: float(row["occurredAt"]))["amount"] if weights else None
        prefs = self.state["preferences"]
        goal = _config(prefs, today).get("waterGoal")
        island = self.state["island"]
        return {
            "available": True,
            "water": water,
            "waterGoal": goal,
            "meals": meals,
            "exerciseMinutes": exercise,
            "weight": None if prefs.get("hideWeight") else latest_weight,
            "hideWeight": bool(prefs.get("hideWeight")),
            "hideCalories": bool(prefs.get("hideCalories")),
            "streak": streak(self.state, now, self.tz),
            "island": {
                "water": island.get("water"),
                "food": island.get("food"),
                "energy": island.get("energy"),
                "inventory": island.get("inventory") or {},
                "tools": list(island.get("tools") or []),
                "buildings": list(island.get("buildings") or []),
                "buildingLevels": island.get("buildingLevels") or {},
                "expansionLevel": island.get("expansionLevel") or 0,
                "prosperity": prosperity(island),
                "paused": bool(island.get("paused")),
                "logs": list(island.get("logs") or [])[-12:],
            },
            "records": self.state["records"],
            "events": self.state["events"],
            "eventTypes": self.state.get("eventTypes") or [],
            "preferences": prefs,
        }

    def set_preferences(self, updates: dict) -> None:
        self._require()
        prefs = self.state["preferences"]
        for key in ("english", "appearance", "hideCalories", "hideWeight", "gameEnabled", "backgroundHex", "cup", "timezone"):
            if key in updates:
                prefs[key] = updates[key]
        if "cup" in prefs and not (0 < float(prefs["cup"]) <= 10000):
            raise AppError("水杯容量须在 0 到 10000 毫升之间。", "invalid")
        self._write()

    def _write(self) -> None:
        self._persist_state()
        self._db.execute("DELETE FROM records")
        self._db.execute("DELETE FROM events")
        for record in self.state["records"]:
            self._db.execute(
                "INSERT INTO records(id, kind, occurred_at, json) VALUES (?, ?, ?, ?)",
                (record["id"], record["kind"], float(from_cocoa(record["occurredAt"]).timestamp()), dumps(record)),
            )
        for event in self.state["events"]:
            self._db.execute(
                "INSERT INTO events(id, type_id, occurred_at, json) VALUES (?, ?, ?, ?)",
                (event["id"], event["typeID"], float(from_cocoa(event["occurredAt"]).timestamp()), dumps(event)),
            )
        self._db.commit()

    def _persist_state(self) -> None:
        blob = dict(self.state)
        blob["records"] = []
        blob["events"] = []
        blob["schemaVersion"] = HEALTH_SCHEMA
        blob["rulesVersion"] = RULES_VERSION
        self._db.execute("INSERT OR REPLACE INTO state(id, json) VALUES (1, ?)", (dumps(blob),))

    def _require(self) -> None:
        if self._db is None or self.state is None:
            raise AppError("健康库未打开。", "missing")


def fresh_state(now, tz) -> dict:
    moment = cocoa(now)
    return {
        "schemaVersion": HEALTH_SCHEMA,
        "rulesVersion": RULES_VERSION,
        "records": [],
        "templates": [],
        "preferences": {
            "english": False,
            "appearance": "system",
            "backgroundHex": "",
            "cup": 250,
            "hideCalories": False,
            "hideWeight": False,
            "gameEnabled": True,
            "timezone": getattr(tz, "key", None) or "UTC",
            "configs": [{"effectiveDay": "0000-01-01", "slots": 3, "restHour": 23}],
            "onboarding": False,
        },
        "island": {
            "water": 60,
            "food": 60,
            "energy": 60,
            "lastSettled": moment,
            "lastVisit": moment,
            "paused": False,
            "inventory": {"wood": 0, "stone": 0, "fiber": 0, "ration": 0, "iron": 0, "herb": 0},
            "tools": [],
            "buildings": [],
            "buildingLevels": {},
            "placements": {},
            "expansionLevel": 0,
            "rewardedSleepIDs": [],
            "logs": [],
        },
        "ledgers": {},
        "requests": [],
        "updatedAt": moment,
        "eventTypes": default_event_types(),
        "events": [],
    }


def default_event_types() -> list[dict]:
    return [
        {"id": item[0], "name": item[1], "englishName": item[2], "symbol": item[3], "color": item[4], "archived": False, "inWidget": True}
        for item in catalog.DEFAULT_EVENT_TYPES
    ]


def validate_record(record: dict, now) -> None:
    kind = record.get("kind")
    if kind not in {"water", "meal", "exercise", "weight"}:
        raise AppError("记录类型无效。", "invalid")
    amount = float(record.get("amount") or 0)
    if not math.isfinite(amount) or not 0 < amount <= 100000:
        raise AppError("数量无效。", "invalid")
    occurred = from_cocoa(_instant(record.get("occurredAt"), now))
    if occurred.timestamp() <= 0 or occurred > now + __import__("datetime").timedelta(seconds=5):
        raise AppError("记录时间无效或位于未来。", "invalid")
    if not 0 <= int(record.get("slot") or 0) <= 4:
        raise AppError("餐次无效。", "invalid")
    if len(str(record.get("title") or "")) > 200 or len(str(record.get("note") or "")) > 4000:
        raise AppError("标题或备注过长。", "invalid")
    limits = {"weight": 1000, "exercise": 1440, "water": 10000}
    if kind in limits and amount > limits[kind]:
        raise AppError("数量超出该类型上限。", "invalid")
    fullness = record.get("fullnessPercent")
    if kind == "meal" and fullness is not None and not 0 <= float(fullness) <= 100:
        raise AppError("饱食程度须在 0 到 100 之间。", "invalid")


def settle(state: dict, now, tz) -> None:
    island = state["island"]
    logs = island.setdefault("logs", [])
    if len(logs) > 300:
        island["logs"] = logs[-300:]
    last = from_cocoa(island["lastSettled"])
    if now <= last:
        return
    finish = min(now, from_cocoa(island["lastVisit"]) + __import__("datetime").timedelta(days=1))
    if not _game_on(state):
        island["lastSettled"] = cocoa(now)
        return
    cursor = last
    while cursor < finish:
        end = min(finish, cursor.replace(minute=0, second=0, microsecond=0) + __import__("datetime").timedelta(hours=1))
        if end <= cursor:
            end = min(finish, cursor + __import__("datetime").timedelta(hours=1))
        hours = (end - cursor).total_seconds() / 3600
        config = _config(state["preferences"], day_key(cursor, tz))
        resting = ((in_zone(cursor, tz).hour - int(config.get("restHour") or 23) + 24) % 24) < 8
        shelter = building_level(island, "shelter")
        if resting and shelter > 0:
            multiplier = 0.375 - (shelter - 1) * 0.055
        elif resting:
            multiplier = 0.5
        else:
            multiplier = 1.0
        well = building_level(island, "well")
        well_factor = 0.75 - (well - 1) * 0.10 if well > 0 else 1.0
        island["water"] = max(0, island["water"] - 3 * hours * multiplier * well_factor)
        island["food"] = max(0, island["food"] - 2.5 * hours * multiplier)
        island["energy"] = max(0, island["energy"] - 0.8 * hours * multiplier)
        cursor = end
    island["lastSettled"] = cocoa(now)


def visit(state: dict, now, tz, welcome: bool) -> None:
    settle(state, now, tz)
    island = state["island"]
    if not _game_on(state):
        island["lastVisit"] = cocoa(max(from_cocoa(island["lastVisit"]), now))
        return
    last_visit = from_cocoa(island["lastVisit"])
    last_gift = from_cocoa(island["lastGift"]) if island.get("lastGift") is not None else from_cocoa(0)
    if (now - last_visit).total_seconds() >= 3 * 86400 and (now - last_gift).total_seconds() >= 7 * 86400:
        island["water"] = max(island["water"], 30)
        island["food"] = max(island["food"], 30)
        island["energy"] = max(island["energy"], 30)
        island["lastGift"] = cocoa(now)
        _log(state, "return", "欢迎回来", now)
    island["lastVisit"] = cocoa(max(last_visit, now))
    key = day_key(now, tz)
    ledger = state["ledgers"].setdefault(key, {})
    if not ledger.get("harvested"):
        ledger["harvested"] = True
        gains = []
        inventory = island.setdefault("inventory", {})
        garden = building_level(island, "garden")
        if garden > 0:
            amount = garden + 1
            inventory["ration"] = int(inventory.get("ration") or 0) + amount
            gains.append(f"+{amount} 干粮")
        farm = building_level(island, "farm")
        if farm > 0:
            amount = 3 + 2 * farm
            inventory["ration"] = int(inventory.get("ration") or 0) + amount
            gains.append(f"+{amount} 干粮")
        clinic = building_level(island, "clinic")
        if clinic > 0:
            amount = 2 + 3 * clinic
            island["energy"] = min(100, island["energy"] + amount)
            gains.append(f"+{amount} 活力")
        rain = building_level(island, "rainCollector")
        if rain > 0:
            gain = min(100 - island["water"], 6 * rain)
            island["water"] += gain
            gains.append(f"+{int(gain)} 水分")
        fruit = building_level(island, "orchard")
        if fruit > 0:
            inventory["ration"] = int(inventory.get("ration") or 0) + 2 * fruit
            gains.append(f"+{2 * fruit} 干粮")
        if gains:
            _log(state, "harvest", "每日收获 · " + " · ".join(gains), now)
    if welcome and not state["ledgers"].get(key, {}).get("welcomed"):
        state["ledgers"].setdefault(key, {})["welcomed"] = True
        island["energy"] = min(100, island["energy"] + 20)


def _apply_record_rewards(state: dict, today: str, tz) -> None:
    rows = [
        row for row in state["records"]
        if row.get("rewardEligible") and day_key(from_cocoa(row["occurredAt"]), tz) == today
    ]
    water = min(80, sum(float(row.get("amount") or 0) for row in rows if row.get("kind") == "water") / 25)
    slots = int(_config(state["preferences"], today).get("slots") or 3)
    fullness = {}
    for meal in rows:
        if meal.get("kind") != "meal":
            continue
        slot = int(meal.get("slot") or 0)
        if 0 <= slot < slots:
            fullness[slot] = max(fullness.get(slot, 0), int(meal.get("fullnessPercent") or 100))
    food = min(75, sum(fullness.values()) * 75 / (slots * 100))
    training = building_level(state["island"], "training")
    activity_cap = 18 + max(0, training - 1) * 3
    factor = 1.25 + (training - 1) * 0.10 if training > 0 else 1
    activity = min(activity_cap, sum(float(row.get("amount") or 0) for row in rows if row.get("kind") == "exercise") * 0.6 * factor)
    ledger = state["ledgers"].setdefault(today, {})
    island = state["island"]
    island["water"] = min(100, island["water"] + max(0, water - float(ledger.get("water") or 0)))
    island["food"] = min(100, island["food"] + max(0, food - float(ledger.get("food") or 0)))
    island["energy"] = min(100, island["energy"] + max(0, activity - float(ledger.get("activity") or 0)))
    ledger["water"] = max(water, float(ledger.get("water") or 0))
    ledger["food"] = max(food, float(ledger.get("food") or 0))
    ledger["activity"] = max(activity, float(ledger.get("activity") or 0))


def streak(state: dict, now, tz) -> int:
    days = {day_key(from_cocoa(row["occurredAt"]), tz) for row in state["records"]}
    cursor = now
    if day_key(cursor, tz) not in days:
        cursor = cursor - __import__("datetime").timedelta(days=1)
    count = 0
    while day_key(cursor, tz) in days:
        count += 1
        cursor = cursor - __import__("datetime").timedelta(days=1)
    return count


def building_level(island: dict, recipe_id: str) -> int:
    buildings = set(island.get("buildings") or [])
    if recipe_id not in buildings:
        return 0
    return int((island.get("buildingLevels") or {}).get(recipe_id) or 1)


def prosperity(island: dict) -> int:
    levels = island.get("buildingLevels") or {}
    return (
        len(island.get("buildings") or []) * 20
        + len(island.get("tools") or []) * 5
        + sum((int(level) - 1) * 10 for level in levels.values())
        + int(island.get("expansionLevel") or 0) * 30
    )


def energy_cost(state: dict, action) -> float:
    return action[2] * (1 - 0.05 * building_level(state["island"], "workshop"))


def action_problem(state: dict, action) -> str | None:
    if not _game_on(state):
        return "请先恢复岛屿经营"
    if action[7] and not _has(state, action[7]):
        return "需要先获得对应工具或建筑"
    island = state["island"]
    missing = []
    if island["energy"] < energy_cost(state, action):
        missing.append("活力不足")
    if island["food"] < action[3]:
        missing.append("饱食不足")
    if island["water"] < action[4]:
        missing.append("水分不足")
    return " · ".join(missing) or None


def yield_amount(state: dict, action) -> int:
    island = state["island"]
    if action[0] == "chop":
        multiplier = 3 if _has(state, "ironAxe") else 2 if _has(state, "axe") else 1
    elif action[0] in {"quarry", "mine"}:
        multiplier = 2 if _has(state, "ironPickaxe") else 1
    elif action[0] == "fish":
        multiplier = 3 if _has(state, "net") else 2 if _has(state, "spear") else 1
    else:
        multiplier = 1
    if action[0] == "fish":
        bonus = max(0, building_level(island, "campfire") - 1)
    elif action[0] == "herb":
        bonus = max(0, building_level(island, "herbGarden") - 1)
    else:
        bonus = 0
    extra = building_level(island, "windmill") if action[0] == "fiber" else 0
    return action[6] * multiplier + bonus + extra


def build_problem(state: dict, recipe) -> str | None:
    if _has(state, recipe[0]):
        return "已拥有"
    if not _game_on(state):
        return "岛屿休整中"
    if recipe[3] and not _has(state, recipe[3]):
        return "需要先获得前置"
    if int(state["island"].get("expansionLevel") or 0) < recipe[5]:
        return f"需先扩建海岸至 {recipe[5]} 级"
    if not recipe[4] and free_site(state["island"], recipe[0]) is None:
        return "请调整建筑位置后再建造"
    inventory = state["island"].get("inventory") or {}
    if any(int(inventory.get(key) or 0) < value for key, value in recipe[2].items()):
        return "材料尚不足"
    return None


def free_site(island: dict, recipe_id: str):
    default = catalog.ISLAND_DEFAULT_SITES.get(recipe_id, (0, 0))
    candidates = [default]
    z = -7.0
    while z <= 7.0:
        x = -7.0
        while x <= 7.0:
            candidates.append((x, z))
            x += 0.7
        z += 0.7
    expansion = int(island.get("expansionLevel") or 0)
    for point in candidates:
        if not _inside(point, expansion):
            continue
        if all(_apart(point, _site(island, key)) for key in island.get("buildings") or []):
            return point
    return None


def _inside(point, expansion: int) -> bool:
    radius = math.sqrt(31) + min(3, max(0, expansion)) * 0.7
    return point[0] * point[0] + point[1] * point[1] < radius * radius


def _apart(left, right) -> bool:
    return math.hypot(left[0] - right[0], left[1] - right[1]) > 1.9


def _site(island: dict, recipe_id: str):
    placed = (island.get("placements") or {}).get(recipe_id)
    if placed:
        return (float(placed["x"]), float(placed["z"]))
    return catalog.ISLAND_DEFAULT_SITES.get(recipe_id, (0, 0))


def _has(state: dict, key: str) -> bool:
    island = state["island"]
    return key in set(island.get("tools") or []) or key in set(island.get("buildings") or [])


def _set_add(island: dict, field: str, value: str) -> None:
    current = list(island.get(field) or [])
    if value not in current:
        current.append(value)
    island[field] = current


def _game_on(state: dict) -> bool:
    return bool(state["preferences"].get("gameEnabled", True) and not state["island"].get("paused"))


def _config(preferences: dict, day: str) -> dict:
    configs = [row for row in preferences.get("configs") or [] if str(row.get("effectiveDay")) <= day]
    configs.sort(key=lambda row: str(row.get("effectiveDay")))
    return configs[-1] if configs else {"effectiveDay": "0000-01-01", "slots": 3, "restHour": 23}


def _log(state: dict, action: str, description: str, now) -> None:
    logs = state["island"].setdefault("logs", [])
    logs.append({
        "id": str(uuid.uuid4()).upper(),
        "date": cocoa(now),
        "action": action,
        "description": description,
    })
    if len(logs) > 300:
        state["island"]["logs"] = logs[-300:]


def _instant(value, now) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if value is None:
        return cocoa(now)
    from gaojiezou.timeutil import parse_instant
    return cocoa(parse_instant(value, now.tzinfo))


def trends(state: dict, now, tz, days: int) -> dict:
    """按日聚合。没有记录的日子不补 0。"""
    start = day_key(now - __import__("datetime").timedelta(days=days - 1), tz)
    end = day_key(now, tz)
    buckets: dict[str, dict] = {}
    for row in state["records"]:
        key = day_key(from_cocoa(row["occurredAt"]), tz)
        if not start <= key <= end:
            continue
        bucket = buckets.setdefault(key, {"water": 0, "exercise": 0, "meals": 0, "weights": [], "calories": None})
        kind = row.get("kind")
        amount = float(row.get("amount") or 0)
        if kind == "water":
            bucket["water"] += amount
        elif kind == "exercise":
            bucket["exercise"] += amount
        elif kind == "meal":
            bucket["meals"] += 1
        elif kind == "weight":
            bucket["weights"].append((float(row["occurredAt"]), amount))
        if row.get("calories") is not None and kind in {"meal", "exercise"} and not state["preferences"].get("hideCalories"):
            bucket["calories"] = float(bucket["calories"] or 0) + float(row["calories"])
    points = []
    for key in sorted(buckets):
        bucket = buckets[key]
        weight = max(bucket["weights"])[1] if bucket["weights"] else None
        points.append({
            "day": key,
            "water": bucket["water"],
            "exercise": bucket["exercise"],
            "meals": bucket["meals"],
            "weight": None if state["preferences"].get("hideWeight") else weight,
            "calories": bucket["calories"],
        })
    return {"days": days, "points": points}
