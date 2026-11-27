"""健康资料 health.sqlite、记录与荒岛结算。"""

from __future__ import annotations

import csv
import io
import json
import math
import sqlite3
import uuid
import zipfile
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from functools import wraps
from pathlib import Path
from threading import RLock
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from gaojiezou import catalog
from gaojiezou.errors import AppError
from gaojiezou.library import dumps
from gaojiezou.timeutil import cocoa, day_key, from_cocoa, in_zone

HEALTH_SCHEMA = 2
RULES_VERSION = 1
EVENT_SYMBOLS = (
    "cup.and.saucer.fill", "mug.fill", "waterbottle.fill", "brain.head.profile",
    "toilet.fill", "pills.fill", "heart.fill", "moon.fill", "figure.walk", "checkmark.circle",
)
EVENT_COLORS = ("blue", "teal", "orange", "purple", "pink", "green")
ISLAND_LEVEL_MARKS = (0, 20, 60, 100, 140, 190, 260, 340, 430, 520)
RECORD_TITLES = {"water": "喝水", "meal": "饮食", "exercise": "运动", "weight": "体重"}
RECORD_CSV_FIELDS = (
    "id", "occurred_at", "timezone", "type", "name", "amount", "unit", "kcal",
    "protein_g", "carbs_g", "fat_g", "meal_slot", "note", "source", "meal_source", "fullness_percent",
)
EVENT_CSV_FIELDS = ("id", "type_id", "name", "occurred_at", "count", "note", "source")
HEALTH_CSV_FILES = {f"{kind}.csv": kind for kind in RECORD_TITLES} | {"custom-events.csv": "events"}


def _mutating(operation):
    @wraps(operation)
    def run(self, *args, **kwargs):
        with self._lock:
            self._require()
            before = self.state
            undo = self._undo
            try:
                self._db.execute("BEGIN IMMEDIATE")
                with self._db:
                    self._require()
                    before = self._read_state()
                    self.state = deepcopy(before)
                    result = operation(self, *args, **kwargs)
                    if self.state != before:
                        self._write(before)
                return result
            except sqlite3.DatabaseError as exc:
                self.state, self._undo = before, undo
                raise AppError("健康数据库操作失败，原记录已保留。", "protected") from exc
            except Exception:
                self.state, self._undo = before, undo
                raise
    return run


class HealthStore:
    def __init__(self, directory: Path, tz):
        self.directory = directory
        self.path = directory / "health.sqlite"
        self._default_tz = tz
        self._lock = RLock()
        self._undo: tuple[str, dict, bool] | None = None
        self._db: sqlite3.Connection | None = None
        self._file_identity: tuple[int, int] | None = None
        self.state: dict | None = None

    @property
    def tz(self):
        name = (self.state or {}).get("preferences", {}).get("timezone")
        if name:
            try:
                return ZoneInfo(name)
            except (ValueError, ZoneInfoNotFoundError):
                pass
        return self._default_tz

    @property
    def available(self) -> bool:
        try:
            return self.path.is_file() and not self.path.is_symlink() and self.path.stat().st_size > 0
        except OSError:
            return False

    def create_fresh(self, now) -> None:
        if self.directory.exists() and any(self.directory.iterdir()):
            raise AppError("健康目录已有文件，未新建空库。", "protected")
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path.touch(exist_ok=False)
        self._connect()
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
        with self._lock:
            self.close()
            try:
                self._connect()
                if self._db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                    raise AppError("健康库完整性检查未通过。", "protected")
                version = self._db.execute("PRAGMA user_version").fetchone()[0]
                if version != 1:
                    raise AppError("健康库版本不受支持，未写入。", "protected")
                self.state = self._read_state()
            except (OSError, sqlite3.DatabaseError) as exc:
                self.close()
                raise AppError("健康数据库不可读，原记录已保留。", "protected") from exc
            except AppError:
                self.close()
                raise

    def _connect(self) -> None:
        stat = self.path.stat()
        self._file_identity = (stat.st_dev, stat.st_ino)
        self._db = sqlite3.connect(self.path.resolve().as_uri() + "?mode=rw", uri=True, timeout=10, check_same_thread=False)
        self._db.execute("PRAGMA synchronous=FULL")

    def _read_state(self) -> dict:
        try:
            row = self._db.execute("SELECT json FROM state WHERE id=1").fetchone()
            state = json.loads(row[0]) if row else None
            if not isinstance(state, dict) or state.get("schemaVersion") != HEALTH_SCHEMA or state.get("rulesVersion") != RULES_VERSION:
                raise ValueError("health schema")
            for key in ("preferences", "island"):
                if not isinstance(state.get(key), dict):
                    raise ValueError("health state")
            if state.get("records") or state.get("events"):
                raise ValueError("health row layout")
            state["records"] = self._read_rows("records", "kind", "kind")
            state["events"] = self._read_rows("events", "type_id", "typeID")
            state.setdefault("eventTypes", default_event_types())
            state.setdefault("ledgers", {})
            state.setdefault("requests", [])
            state.setdefault("templates", [])
            return state
        except (ValueError, TypeError, UnicodeError) as exc:
            raise AppError("健康库版本或记录格式无效，原记录已保留。", "protected") from exc

    def _read_rows(self, table: str, owner_column: str, owner_key: str) -> list[dict]:
        result = []
        for record_id, owner, payload in self._db.execute(f"SELECT id,{owner_column},json FROM {table} ORDER BY id"):
            row = json.loads(payload)
            if not isinstance(row, dict) or row.get("id") != record_id or row.get(owner_key) != owner:
                raise ValueError("health row identity")
            result.append(row)
        return result

    def close(self) -> None:
        with self._lock:
            if self._db is not None:
                self._db.close()
                self._db = None
                self._file_identity = None
                self.state = None

    @_mutating
    def save_record(self, record: dict, now) -> dict:
        return self._save_record(record, now)

    def _save_record(self, payload: dict, now, remember_undo: bool = True) -> dict:
        previous = next((row for row in self.state["records"] if row["id"] == payload.get("id")), None)
        record = {**(previous or {}), **payload}
        save_template = record.pop("saveTemplate", False)
        record.setdefault("id", str(uuid.uuid4()).upper())
        record.setdefault("slot", 0)
        record.setdefault("note", "")
        record.setdefault("title", "")
        record.setdefault("source", "manual")
        record.setdefault("baseAmount", 1)
        record.setdefault("usesNutrition", False)
        record.setdefault("foodUnit", "serving")
        record.setdefault("timezone", self.state["preferences"].get("timezone", "UTC"))
        record["occurredAt"] = _instant(record.get("occurredAt"), now)
        validate_record(record, now)
        record["updatedAt"] = cocoa(now)
        if previous is not None:
            record["createdAt"] = previous.get("createdAt", cocoa(now))
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
        if occurred == today and record["rewardEligible"] and _game_on(self.state) and cocoa(now) >= self.state["island"]["lastSettled"]:
            _apply_record_rewards(self.state, today, self.tz)
        if save_template:
            self.state["templates"].append({
                "id": str(uuid.uuid4()).upper(),
                "name": record["title"] or RECORD_TITLES[record["kind"]],
                "record": dict(record),
                "uses": 0,
            })
        if remember_undo:
            self._undo = ("records", previous or record, previous is None)
        self.state["updatedAt"] = cocoa(now)
        return record

    @_mutating
    def delete_record(self, record_id: str, now=None) -> None:
        self._delete_row("records", record_id, now or datetime.now(timezone.utc))

    @_mutating
    def save_event(self, event: dict, now) -> dict:
        previous = next((row for row in self.state["events"] if row["id"] == event.get("id")), None)
        event = {**(previous or {}), **event}
        event.setdefault("id", str(uuid.uuid4()).upper())
        event.setdefault("source", "manual")
        event.setdefault("note", "")
        count = _integer(event.get("count", 1), "事项次数")
        if not 1 <= count <= 999:
            raise AppError("事项次数须在 1 到 999 之间。", "invalid")
        if len(str(event.get("note") or "")) > 2000:
            raise AppError("事项备注过长。", "invalid")
        types = self.state.get("eventTypes") or []
        matched = next((item for item in types if item["id"] == event.get("typeID")), None)
        if matched is None or (matched.get("archived") and not any(row["id"] == event["id"] for row in self.state["events"])):
            raise AppError("事项类型已停用或不存在。", "invalid")
        event["occurredAt"] = _instant(event.get("occurredAt"), now)
        if from_cocoa(event["occurredAt"]) > now + timedelta(seconds=60):
            raise AppError("不能记录未来的事项。", "invalid")
        event["count"] = count
        self.state["events"] = [row for row in self.state["events"] if row["id"] != event["id"]]
        self.state["events"].append(event)
        self.state["updatedAt"] = cocoa(now)
        self._undo = ("events", previous or event, previous is None)
        return event

    @_mutating
    def delete_event(self, event_id: str, now=None) -> None:
        self._delete_row("events", event_id, now or datetime.now(timezone.utc))

    def _delete_row(self, table: str, record_id: str, now) -> None:
        record = next((row for row in self.state[table] if row["id"] == record_id), None)
        if record is None:
            return
        self.state[table] = [row for row in self.state[table] if row["id"] != record_id]
        self.state["updatedAt"] = cocoa(now)
        self._undo = (table, record, False)

    @_mutating
    def save_event_type(self, updates: dict, now) -> dict:
        types = self.state["eventTypes"]
        previous = next((row for row in types if row["id"] == updates.get("id")), None)
        event_type = dict(previous or {
            "id": str(uuid.uuid4()).upper(), "englishName": "", "symbol": "checkmark.circle",
            "color": "blue", "archived": False, "inWidget": True,
        })
        for key in ("name", "englishName", "symbol", "color", "archived", "inWidget"):
            if key in updates:
                event_type[key] = updates[key]
        name = str(event_type.get("name") or "").strip()
        if not 1 <= len(name) <= 24 or event_type["symbol"] not in EVENT_SYMBOLS or event_type["color"] not in EVENT_COLORS:
            raise AppError("请输入 1 到 24 字的事项名称，选择可用的图标和颜色。", "invalid")
        if any(row["id"] != event_type["id"] and row["name"].casefold() == name.casefold() for row in types):
            raise AppError("已有同名事项。", "duplicate")
        event_type["name"] = name
        if previous is None:
            types.append(event_type)
        else:
            types[types.index(previous)] = event_type
        self.state["updatedAt"] = cocoa(now)
        return event_type

    @_mutating
    def use_template(self, template_id: str, now) -> dict:
        template = next((row for row in self.state["templates"] if row["id"] == template_id), None)
        if template is None:
            raise AppError("找不到健康记录模板。", "missing")
        record = dict(template["record"])
        for key in ("id", "occurredAt", "createdAt", "updatedAt", "timezone"):
            record.pop(key, None)
        if record["kind"] == "meal":
            for key in ("calories", "protein", "carbs", "fat", "baseCalories", "baseProtein", "baseCarbs", "baseFat"):
                record.pop(key, None)
            record.update(amount=1, usesNutrition=False)
            if record.get("fullnessPercent") is None:
                record["fullnessPercent"] = 75
        saved = self._save_record(record, now)
        template["uses"] = int(template.get("uses", 0)) + 1
        return saved

    @_mutating
    def delete_template(self, template_id: str, now) -> None:
        self.state["templates"] = [row for row in self.state["templates"] if row["id"] != template_id]
        self.state["updatedAt"] = cocoa(now)

    @_mutating
    def undo(self, now) -> bool:
        if self._undo is None:
            return False
        table, record, was_creation = self._undo
        self.state[table] = [row for row in self.state[table] if row["id"] != record["id"]]
        if not was_creation:
            self.state[table].append(record)
        self.state["updatedAt"] = cocoa(now)
        self._undo = None
        return True

    def export_csv(self) -> bytes:
        with self._lock:
            self._require()
            with self._db:
                self._db.execute("BEGIN DEFERRED")
                state = self._read_state()
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            units = {"water": "mL", "exercise": "min", "weight": "kg"}
            names = {row["id"]: row["name"] for row in state["eventTypes"]}
            records = sorted(state["records"], key=lambda row: row["occurredAt"])
            for filename, kind in HEALTH_CSV_FILES.items():
                if kind == "events":
                    rows = (
                        [row["id"], row["typeID"], names.get(row["typeID"], ""), _iso(row["occurredAt"]),
                         row["count"], row.get("note"), row.get("source")]
                        for row in sorted(state["events"], key=lambda row: row["occurredAt"])
                    )
                    archive.writestr(filename, _csv_document(EVENT_CSV_FIELDS, rows))
                else:
                    rows = (
                        [row["id"], _iso(row["occurredAt"]), row.get("timezone", state["preferences"].get("timezone", "UTC")),
                         kind, row.get("title"), row["amount"], units.get(kind, row.get("foodUnit", "serving")),
                         row.get("calories"), row.get("protein"), row.get("carbs"), row.get("fat"),
                         row.get("slot") if kind == "meal" else "", row.get("note"), row.get("source"),
                         row.get("mealSource"), row.get("fullnessPercent") if kind == "meal" else ""]
                        for row in records if row["kind"] == kind
                    )
                    archive.writestr(filename, _csv_document(RECORD_CSV_FIELDS, rows))
        return output.getvalue()

    @_mutating
    def import_csv(self, inputs: dict, now) -> dict:
        if not isinstance(inputs, dict) or not inputs or any(name not in HEALTH_CSV_FILES or not isinstance(data, str) for name, data in inputs.items()):
            raise AppError("请选择导出的健康记录 CSV 文件。", "invalid")
        seen = {key: {row["id"].upper() for row in self.state[key]} for key in ("records", "events")}
        result = {"added": 0, "skipped": 0, "invalid": 0}
        types = self.state["eventTypes"]
        zone = self.state["preferences"].get("timezone", "UTC")
        for name, data in inputs.items():
            kind = HEALTH_CSV_FILES[name]
            target = "events" if kind == "events" else "records"
            reader = csv.DictReader(io.StringIO(data.removeprefix("\ufeff"), newline=""), strict=True)
            try:
                if not {"id", "occurred_at"}.issubset(reader.fieldnames or ()):
                    raise AppError(f"文件 {name} 缺少健康 CSV 列。", "invalid")
                for row in reader:
                    try:
                        payload = _import_csv_row(kind, row, types, zone, now)
                    except (AppError, TypeError, ValueError, AttributeError):
                        result["invalid"] += 1
                        continue
                    if payload["id"] in seen[target]:
                        result["skipped"] += 1
                        continue
                    self.state[target].append(payload)
                    seen[target].add(payload["id"])
                    result["added"] += 1
            except csv.Error as exc:
                raise AppError(f"文件 {name} 的 CSV 格式无效。", "invalid") from exc
        if result["added"]:
            self.state["updatedAt"] = cocoa(now)
        return result

    @_mutating
    def act(self, action_id: str, now) -> str:
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
        self.state["updatedAt"] = cocoa(now)
        return f"获得 {amount} {catalog.MATERIAL_NAMES.get(action[5], action[5])}"

    @_mutating
    def build(self, recipe_id: str, now) -> str:
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
        self.state["updatedAt"] = cocoa(now)
        return recipe[1]

    @_mutating
    def upgrade(self, recipe_id: str, now) -> str:
        visit(self.state, now, self.tz, welcome=True)
        recipe = catalog.RECIPES_BY_ID.get(recipe_id)
        if recipe is None or recipe[4]:
            raise AppError("请先建造可升级的建筑。", "invalid")
        level = building_level(self.state["island"], recipe_id)
        problem = upgrade_problem(self.state, recipe)
        if problem:
            raise AppError(problem, "unavailable")
        cost = {key: value * (level + 1) for key, value in recipe[2].items()}
        for key, value in cost.items():
            self.state["island"]["inventory"][key] -= value
        self.state["island"].setdefault("buildingLevels", {})[recipe_id] = level + 1
        _log(self.state, "upgrade", f"{recipe[1]} · Lv.{level + 1}", now)
        self.state["updatedAt"] = cocoa(now)
        return f"{recipe[1]} Lv.{level + 1}"

    @_mutating
    def expand(self, now) -> str:
        visit(self.state, now, self.tz, welcome=True)
        stage = int(self.state["island"].get("expansionLevel") or 0)
        problem = expansion_problem(self.state)
        if problem:
            raise AppError(problem, "unavailable")
        cost = catalog.ISLAND_EXPANSION_COSTS[stage]
        inventory = self.state["island"].setdefault("inventory", {})
        for key, value in cost.items():
            inventory[key] = int(inventory.get(key) or 0) - value
        self.state["island"]["expansionLevel"] = stage + 1
        _log(self.state, "expand", f"扩建海岸 · {stage + 1}/3", now)
        self.state["updatedAt"] = cocoa(now)
        return f"海岸 {stage + 1}/3"

    @_mutating
    def supply(self, now) -> str:
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
        self.state["updatedAt"] = cocoa(now)
        return f"饱食 +{gain}"

    @_mutating
    def reward_sleep(self, records: list[dict], now) -> float:
        if not _game_on(self.state):
            return 0
        pending = []
        known = set(self.state["island"].get("rewardedSleepIDs") or [])
        for record in records:
            duration = float(record.get("durationSeconds") or 0)
            ended = float(record["endedAt"])
            if (
                record.get("id")
                and record["id"] not in known
                and 1800 <= duration <= 86400
                and 0 <= cocoa(now) - ended <= 36 * 3600
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
        self.state["updatedAt"] = cocoa(now)
        return earned

    @_mutating
    def visit_island(self, now) -> None:
        visit(self.state, now, self.tz, welcome=True)
        self.state["updatedAt"] = cocoa(now)

    @_mutating
    def brew_tea(self, now) -> str:
        visit(self.state, now, self.tz, welcome=False)
        island = self.state["island"]
        level = building_level(island, "teaHouse")
        ledger = self.state["ledgers"].setdefault(day_key(now, self.tz), {})
        inventory = island["inventory"]
        if not _game_on(self.state) or level == 0:
            raise AppError("茶亭尚未开放。", "unavailable")
        if int(ledger.get("teaUses", 0)) >= 2:
            raise AppError("今日已泡茶 2 次。", "unavailable")
        if int(inventory.get("herb", 0)) < 2 or island["energy"] >= 100:
            raise AppError("需要 2 药材，且活力未满。", "unavailable")
        gain = min(100 - island["energy"], 8 + 4 * level)
        inventory["herb"] -= 2
        island["energy"] += gain
        ledger["teaUses"] = int(ledger.get("teaUses", 0)) + 1
        _log(self.state, "tea", f"茶亭休憩 · +{int(gain)} 活力", now)
        self.state["updatedAt"] = cocoa(now)
        return f"活力 +{int(gain)}"

    @_mutating
    def layout(self, placements: dict, now) -> None:
        island = self.state["island"]
        buildings = set(island.get("buildings") or [])
        if not isinstance(placements, dict) or set(placements) != buildings:
            raise AppError("建筑已变化，请重新进入布局模式。", "invalid")
        points = {}
        for key, point in placements.items():
            if not isinstance(point, dict) or "x" not in point or "z" not in point:
                raise AppError("建筑坐标无效。", "invalid")
            x, z = (_finite(point[axis], "建筑坐标") for axis in ("x", "z"))
            if not _inside((x, z), int(island.get("expansionLevel") or 0)):
                raise AppError("建筑不能超出海岸。", "invalid")
            if any(math.hypot(x - p["x"], z - p["z"]) <= 1.5 for p in points.values()):
                raise AppError("建筑不能重叠。", "invalid")
            points[key] = {"x": x, "z": z}
        island["placements"] = points
        self.state["updatedAt"] = cocoa(now)

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
        island_prosperity = prosperity(island)
        level = sum(island_prosperity >= mark for mark in ISLAND_LEVEL_MARKS)
        stage = int(island.get("expansionLevel") or 0)
        return {
            "available": True,
            "today": today,
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
                "placements": {key: {"x": _site(island, key)[0], "z": _site(island, key)[1]} for key in island.get("buildings") or []},
                "expansionLevel": island.get("expansionLevel") or 0,
                "prosperity": island_prosperity,
                "level": level,
                "nextThreshold": ISLAND_LEVEL_MARKS[level] if level < len(ISLAND_LEVEL_MARKS) else None,
                "paused": bool(island.get("paused")),
                "logs": list(island.get("logs") or []),
                "actionProblems": {key: action_problem(self.state, action) for key, action in catalog.ACTIONS_BY_ID.items()},
                "actionYields": {key: yield_amount(self.state, action) for key, action in catalog.ACTIONS_BY_ID.items()},
                "buildProblems": {key: build_problem(self.state, recipe) for key, recipe in catalog.RECIPES_BY_ID.items()},
                "upgradeProblems": {key: upgrade_problem(self.state, recipe) for key, recipe in catalog.RECIPES_BY_ID.items() if not recipe[4]},
                "expansionProblem": expansion_problem(self.state),
                "expansionCost": catalog.ISLAND_EXPANSION_COSTS[stage] if stage < len(catalog.ISLAND_EXPANSION_COSTS) else {},
                "expansionRequirement": catalog.ISLAND_EXPANSION_REQUIREMENTS[stage] if stage < len(catalog.ISLAND_EXPANSION_REQUIREMENTS) else None,
            },
            "records": self.state["records"],
            "events": self.state["events"],
            "eventTypes": self.state.get("eventTypes") or [],
            "preferences": prefs,
            "dailyConfig": _config(prefs, today),
            "dailyLedger": self.state["ledgers"].get(today, {}),
            "templates": self.state.get("templates") or [],
            "canUndo": self._undo is not None,
            "trendsByDays": {str(days): trends(self.state, now, self.tz, days) for days in (1, 7, 30)},
        }

    @_mutating
    def set_preferences(self, updates: dict, now=None) -> None:
        now = now or datetime.now(timezone.utc)
        settle(self.state, now, self.tz)
        prefs = self.state["preferences"]
        for key in ("english", "hideCalories", "hideWeight", "gameEnabled", "onboarding"):
            if key in updates:
                prefs[key] = bool(updates[key])
        if "paused" in updates:
            self.state["island"]["paused"] = bool(updates["paused"])
        if "cup" in updates:
            cup = _finite(updates["cup"], "水杯容量")
            if not 0 < cup <= 10000:
                raise AppError("水杯容量须大于 0 且不超过 10000 毫升。", "invalid")
            prefs["cup"] = cup
        if "appearance" in updates:
            if updates["appearance"] not in ("system", "light", "dark"):
                raise AppError("健康外观无效。", "invalid")
            prefs["appearance"] = updates["appearance"]
        if "backgroundHex" in updates:
            color = str(updates["backgroundHex"]).removeprefix("#")
            if color and (len(color) != 6 or any(c not in "0123456789abcdefABCDEF" for c in color)):
                raise AppError("背景颜色无效。", "invalid")
            prefs["backgroundHex"] = f"#{color}" if color else ""
        if "timezone" in updates:
            try:
                ZoneInfo(updates["timezone"])
            except (ValueError, TypeError, ZoneInfoNotFoundError) as exc:
                raise AppError("健康时区无效。", "invalid") from exc
            prefs["timezone"] = updates["timezone"]
        if any(key in updates for key in ("slots", "restHour", "waterGoal")):
            today = day_key(now, self.tz)
            config = {**_config(prefs, today), "effectiveDay": today}
            if "slots" in updates:
                slots = _integer(updates["slots"], "每日餐次")
                if not 1 <= slots <= 4:
                    raise AppError("每日餐次须在 1 到 4 之间。", "invalid")
                config["slots"] = slots
            if "restHour" in updates:
                rest = _integer(updates["restHour"], "休息时间")
                if not 0 <= rest <= 23:
                    raise AppError("休息时间须在 0 点到 23 点之间。", "invalid")
                config["restHour"] = rest
            if "waterGoal" in updates:
                goal = updates["waterGoal"]
                if goal is None or goal == "":
                    config.pop("waterGoal", None)
                else:
                    goal = _finite(goal, "饮水目标")
                    if not 0 < goal <= 10000:
                        raise AppError("饮水目标须大于 0 且不超过 10000 毫升。", "invalid")
                    config["waterGoal"] = goal
            prefs["configs"] = [row for row in prefs["configs"] if row["effectiveDay"] != today] + [config]
        self.state["island"]["lastSettled"] = self.state["island"]["lastVisit"] = cocoa(now)
        self.state["updatedAt"] = cocoa(now)

    def _write(self, before: dict) -> None:
        self._persist_state()
        for table, owner_column, owner_key in (("records", "kind", "kind"), ("events", "type_id", "typeID")):
            previous = {row["id"]: row for row in before[table]}
            current = {row["id"]: row for row in self.state[table]}
            self._db.executemany(f"DELETE FROM {table} WHERE id=?", [(key,) for key in previous.keys() - current.keys()])
            self._db.executemany(
                f"INSERT INTO {table}(id,{owner_column},occurred_at,json) VALUES (?,?,?,?) "
                f"ON CONFLICT(id) DO UPDATE SET {owner_column}=excluded.{owner_column}, "
                "occurred_at=excluded.occurred_at,json=excluded.json",
                [
                    (row["id"], row[owner_key], from_cocoa(row["occurredAt"]).timestamp(), dumps(row))
                    for record_id, row in current.items() if row != previous.get(record_id)
                ],
            )

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
        try:
            stat = self.path.stat()
            if not self.path.is_symlink() and (stat.st_dev, stat.st_ino) == self._file_identity:
                return
        except OSError:
            pass
        raise AppError("健康库已更改或不可读，原记录已保留。", "protected")


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
    if kind not in RECORD_TITLES:
        raise AppError("记录类型无效。", "invalid")
    amount = _finite(record.get("amount"), "数量")
    if not 0 < amount <= 100000:
        raise AppError("数量无效。", "invalid")
    record["amount"] = amount
    occurred = from_cocoa(record["occurredAt"])
    if occurred.timestamp() <= 0 or occurred > now + timedelta(seconds=5):
        raise AppError("记录时间无效或位于未来。", "invalid")
    slot = _integer(record.get("slot", 0), "餐次")
    if not 0 <= slot <= 4:
        raise AppError("餐次无效。", "invalid")
    record["slot"] = slot
    if len(str(record.get("title") or "")) > 200 or len(str(record.get("note") or "")) > 4000:
        raise AppError("标题或备注过长。", "invalid")
    limits = {"weight": 1000, "exercise": 1440, "water": 10000}
    if kind in limits and amount > limits[kind]:
        raise AppError("数量超出该类型上限。", "invalid")
    fullness = record.get("fullnessPercent")
    if kind == "meal" and fullness is not None:
        fullness = _integer(fullness, "饱食程度")
        if not 0 <= fullness <= 100:
            raise AppError("饱食程度须在 0 到 100 之间。", "invalid")
        record["fullnessPercent"] = fullness
    if record.get("mealSource") not in (None, "home", "canteen", "takeout", "snack", "restaurant", "hotel"):
        raise AppError("餐食来源无效。", "invalid")
    base = _finite(record.get("baseAmount", 1), "基准数量")
    if base <= 0:
        raise AppError("基准数量必须为正数。", "invalid")
    record["baseAmount"] = base
    for key in ("calories", "protein", "carbs", "fat", "baseCalories", "baseProtein", "baseCarbs", "baseFat"):
        if record.get(key) is not None:
            value = _finite(record[key], "营养值")
            if not 0 <= value <= 100000:
                raise AppError("营养值须在 0 到 100000 之间。", "invalid")
            record[key] = value


def settle(state: dict, now, tz) -> None:
    island = state["island"]
    logs = island.setdefault("logs", [])
    if len(logs) > 300:
        island["logs"] = logs[-300:]
    last = from_cocoa(island["lastSettled"])
    if now <= last:
        return
    finish = min(now, from_cocoa(island["lastVisit"]) + timedelta(days=1))
    if not _game_on(state):
        island["lastSettled"] = cocoa(now)
        return
    cursor = last
    while cursor < finish:
        local = in_zone(cursor, tz)
        end = min(finish, cursor + timedelta(minutes=60 - local.minute, seconds=-local.second, microseconds=-local.microsecond))
        if end <= cursor:
            end = min(finish, cursor + timedelta(hours=1))
        hours = (end - cursor).total_seconds() / 3600
        config = _config(state["preferences"], day_key(cursor, tz))
        resting = ((local.hour - int(config.get("restHour", 23)) + 24) % 24) < 8
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
    if welcome and not state["ledgers"].get(key, {}).get("welcomed") and cocoa(now) >= island["lastSettled"]:
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
            value = meal.get("fullnessPercent")
            fullness[slot] = max(fullness.get(slot, 0), 100 if value is None else int(value))
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


def upgrade_problem(state: dict, recipe) -> str | None:
    island = state["island"]
    level = building_level(island, recipe[0])
    if level == 0:
        return "请先建造"
    if level >= 4:
        return "已升至最高级"
    if not _game_on(state):
        return "岛屿休整中"
    if any(island["inventory"].get(key, 0) < count * (level + 1) for key, count in recipe[2].items()):
        return "材料尚不足"
    return None


def expansion_problem(state: dict) -> str | None:
    island = state["island"]
    stage = int(island.get("expansionLevel") or 0)
    if stage >= len(catalog.ISLAND_EXPANSION_COSTS):
        return "海岸已全部开拓"
    if not _game_on(state):
        return "岛屿休整中"
    if prosperity(island) < catalog.ISLAND_EXPANSION_REQUIREMENTS[stage]:
        return "繁荣度尚不足"
    if any(island["inventory"].get(key, 0) < count for key, count in catalog.ISLAND_EXPANSION_COSTS[stage].items()):
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
    if value is None:
        return cocoa(now)
    from gaojiezou.timeutil import parse_instant
    try:
        if isinstance(value, bool):
            raise ValueError("date")
        return cocoa(parse_instant(value, now.tzinfo))
    except (ValueError, OverflowError) as exc:
        raise AppError("记录时间格式无效。", "invalid") from exc


def _finite(value, label: str) -> float:
    try:
        if not isinstance(value, bool):
            number = float(value)
            if math.isfinite(number):
                return number
    except (ValueError, TypeError, OverflowError):
        pass
    raise AppError(f"{label}无效。", "invalid")


def _integer(value, label: str) -> int:
    number = _finite(value, label)
    if not number.is_integer():
        raise AppError(f"{label}须为整数。", "invalid")
    return int(number)


def _iso(value) -> str:
    return from_cocoa(value).isoformat(timespec="seconds").replace("+00:00", "Z")


def _csv_document(header, rows) -> str:
    def safe(value):
        value = "" if value is None else str(value)
        return "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value

    output = io.StringIO(newline="")
    writer = csv.writer(output, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
    writer.writerow(header)
    writer.writerows([safe(value) for value in row] for row in rows)
    return "\ufeff" + output.getvalue().removesuffix("\r\n")


def _import_csv_row(kind, row, types, zone, now) -> dict:
    if not row.get("occurred_at") or None in row:
        raise AppError("记录日期缺失。", "invalid")
    record_id = str(uuid.UUID(row["id"])).upper()
    occurred = _instant(row["occurred_at"], now)
    if kind == "events":
        type_id = (row.get("type_id") or "").upper()
        match = next((item for item in types if item["id"].upper() == type_id), None)
        if match is None and row.get("name"):
            match = next((item for item in types if row["name"] in (item["name"], item.get("englishName"))), None)
        count = _integer(row.get("count"), "事项次数")
        note = row.get("note") or ""
        if match is None or not 1 <= count <= 999 or len(note) > 2000 or occurred > cocoa(now) + 60:
            raise AppError("事项记录无效。", "invalid")
        return {"id": record_id, "typeID": match["id"], "occurredAt": occurred, "count": count,
                "note": note, "source": "import"}
    if row.get("type") and row["type"] != kind:
        raise AppError("记录类型和文件名不匹配。", "invalid")
    record_tz = row.get("timezone") or zone
    try:
        ZoneInfo(record_tz)
    except (ValueError, ZoneInfoNotFoundError):
        record_tz = zone
    record = {
        "id": record_id, "kind": kind, "occurredAt": occurred, "createdAt": cocoa(now), "updatedAt": cocoa(now),
        "title": row.get("name") or "", "amount": row.get("amount"), "note": row.get("note") or "",
        "timezone": record_tz, "rewardEligible": False, "source": "import", "slot": 0,
        "baseAmount": 1, "foodUnit": "serving", "usesNutrition": False,
    }
    for key, column in (("calories", "kcal"), ("protein", "protein_g"), ("carbs", "carbs_g"), ("fat", "fat_g")):
        if row.get(column):
            record[key] = _finite(row[column], column)
    if kind == "meal":
        record.update(slot=row.get("meal_slot") or 0, mealSource=row.get("meal_source") or None,
                      fullnessPercent=row.get("fullness_percent") or None)
        if row.get("unit") in ("serving", "g"):
            record["foodUnit"] = row["unit"]
    validate_record(record, now)
    return record


def trends(state: dict, now, tz, days: int) -> dict:
    """按日聚合。没有记录的日子不补 0。"""
    start = day_key(in_zone(now, tz) - timedelta(days=days - 1), tz)
    end = day_key(now, tz)
    buckets: dict[str, dict] = {}
    for row in state["records"]:
        key = day_key(from_cocoa(row["occurredAt"]), tz)
        if not start <= key <= end:
            continue
        bucket = buckets.setdefault(key, {
            "water": None, "exercise": None, "meals": 0, "weights": [],
            "intakeCalories": None, "exerciseCalories": None, "protein": None, "carbs": None, "fat": None,
        })
        kind = row.get("kind")
        amount = float(row.get("amount") or 0)
        if kind == "water":
            bucket["water"] = (bucket["water"] or 0) + amount
        elif kind == "exercise":
            bucket["exercise"] = (bucket["exercise"] or 0) + amount
        elif kind == "meal":
            bucket["meals"] += 1
        elif kind == "weight":
            bucket["weights"].append((float(row["occurredAt"]), amount))
        if not state["preferences"].get("hideCalories"):
            summary_keys = {"meal": ("intakeCalories", "protein", "carbs", "fat"), "exercise": ("exerciseCalories",)}.get(kind, ())
            for metric in summary_keys:
                source = "calories" if metric.endswith("Calories") else metric
                if row.get(source) is not None:
                    bucket[metric] = float(bucket[metric] or 0) + float(row[source])
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
            "calories": bucket["intakeCalories"],
            "intakeCalories": bucket["intakeCalories"],
            "exerciseCalories": bucket["exerciseCalories"],
            "protein": bucket["protein"],
            "carbs": bucket["carbs"],
            "fat": bucket["fat"],
        })
    configured_days = 0
    water_goal_hits = 0
    today = in_zone(now, tz).date()
    for offset in range(days):
        key = (today - timedelta(days=offset)).isoformat()
        goal = _config(state["preferences"], key).get("waterGoal")
        if goal is not None:
            configured_days += 1
            if (buckets.get(key, {}).get("water") or 0) >= goal:
                water_goal_hits += 1
    return {"days": days, "points": points, "start": start, "end": end, "configuredDays": configured_days, "waterGoalHits": water_goal_hits}
