"""library.json 的读取、迁移、原子保存与只读保护。

未知字段原样保留。ownedAnimals 是派生字段，保存时不写。
损坏、缺失痕迹或高于 schema 11 的库不改原文件。
"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime
from pathlib import Path

from gaojiezou import catalog
from gaojiezou.errors import AppError
from gaojiezou.timeutil import cocoa

LIBRARY_NAME = "library.json"
READ_ONLY_MARKER = "library.json.read-only"


def dumps(payload: dict) -> bytes:
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    return (text + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def directory_listing(directory: Path) -> list[str]:
    if not directory.exists():
        return []
    return sorted(entry.name for entry in directory.iterdir())


def is_blank_directory(directory: Path) -> bool:
    if not directory.exists():
        return True
    return not any(directory.iterdir())


def load_document(directory: Path) -> tuple[str, dict | None, str]:
    """返回 (status, document, notice)。

    status: missing, ready, protected
    """
    marker = directory / READ_ONLY_MARKER
    library_path = directory / LIBRARY_NAME
    if marker.exists():
        return "protected", None, "资料库处于只读保护，原文件未改动。"
    if not library_path.exists():
        if is_blank_directory(directory):
            return "missing", None, ""
        return "protected", None, "资料目录已有其他文件，但没有 library.json。未把缺失当成空白库。"
    try:
        raw = library_path.read_bytes()
        document = json.loads(raw.decode("utf-8"))
        if not isinstance(document, dict) or "version" not in document:
            raise ValueError("library shape")
        version = document["version"]
        if not isinstance(version, int) or isinstance(version, bool):
            raise ValueError("version")
        if version > catalog.SCHEMA_VERSION:
            _mark_protected(directory)
            return "protected", None, f"资料库版本 {version} 高于本程序支持的 schema {catalog.SCHEMA_VERSION}，未写入。"
        migrated = migrate(document)
        return "ready", migrated, ""
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        _mark_protected(directory)
        return "protected", None, "library.json 无法读取。原文件已保留，写入已停止。"


def _mark_protected(directory: Path) -> None:
    marker = directory / READ_ONLY_MARKER
    if marker.exists():
        return
    try:
        directory.mkdir(parents=True, exist_ok=True)
        marker.write_text(
            "Read-only protection: library unreadable or newer than schema 11.\n",
            encoding="utf-8",
        )
    except OSError:
        return


def save_document(directory: Path, document: dict) -> None:
    if (directory / READ_ONLY_MARKER).exists():
        raise AppError("资料处于只读保护，未写入。", "protected")
    payload = dict(document)
    payload.pop("ownedAnimals", None)
    payload["version"] = catalog.SCHEMA_VERSION
    atomic_write(directory / LIBRARY_NAME, dumps(payload))
    temporary = (directory / LIBRARY_NAME).with_name(LIBRARY_NAME + ".tmp")
    if temporary.exists():
        temporary.unlink()


def migrate(source: dict) -> dict:
    library = dict(source)
    version = int(library.get("version") or 0)
    _migrate_pasture(library)
    if library.get("aquariumFish") is None:
        library["aquariumFish"] = []
    if version < catalog.SCHEMA_VERSION:
        _clamp_habit_rewards(library)
        _rescale_farm(library)
        _rescale_pasture(library)
        _color_chores(library)
    _retitle_focus(library)
    library["version"] = catalog.SCHEMA_VERSION
    library["chores"] = list(library.get("chores") or [])
    library["decorations"] = list(library.get("decorations") or [])
    library["pastureAnimals"] = list(library.get("pastureAnimals") or [])
    animals = library["pastureAnimals"]
    stored = library.get("animalShelterCapacity")
    minimum = max(1, len(animals)) if stored is None else len(animals)
    library["animalShelterCapacity"] = max(int(stored) if stored is not None else minimum, len(animals))
    if library["animalShelterCapacity"] < 1 and not animals:
        library["animalShelterCapacity"] = 1
    library["focusRecords"] = sorted(library.get("focusRecords") or [], key=lambda row: _date_key(row, "endedAt"), reverse=True)
    library["sleepRecords"] = sorted(library.get("sleepRecords") or [], key=lambda row: _date_key(row, "endedAt"), reverse=True)
    events = list(library.get("rewardEvents") or [])
    events.sort(key=lambda row: _date_key(row, "date"), reverse=True)
    library["rewardEvents"] = events[: catalog.REWARD_EVENT_CAP]
    for key, default in (
        ("habitCompletionKeys", []),
        ("habitRewardKeys", []),
        ("habits", []),
        ("longGoals", []),
        ("shortActions", []),
        ("farmPlots", []),
        ("fishInventory", {}),
        ("fishCaught", {}),
        ("harvestedCrops", {}),
    ):
        if library.get(key) is None:
            library[key] = default if not isinstance(default, (list, dict)) else type(default)()
            if key.endswith("Keys"):
                library[key] = []
    return library


def _date_key(row: dict, field: str) -> float:
    value = row.get(field) if isinstance(row, dict) else None
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def _migrate_pasture(library: dict) -> None:
    if library.get("pastureAnimals") is not None:
        return
    migrated = []
    moment = cocoa(datetime.now().astimezone())
    for owned in library.get("ownedAnimals") or []:
        count = max(0, int(owned.get("count") or 0))
        if count <= 0:
            continue
        pending = int(owned.get("pendingProducts") or 0)
        base, extra = divmod(pending, count)
        spec = catalog.animal(owned.get("animalID"))
        maturity = catalog.maturity_hours(spec[6]) if spec else 0
        owned_id = str(owned.get("id") or "animal")
        for ordinal in range(count):
            migrated.append({
                "id": f"{owned_id}-{ordinal}",
                "animalID": owned.get("animalID"),
                "growthHours": maturity,
                "pendingProducts": base + (1 if ordinal < extra else 0),
                "acquiredAt": moment,
            })
    library["pastureAnimals"] = migrated


def _clamp_habit_rewards(library: dict) -> None:
    for habit in library.get("habits") or []:
        coins = int(habit.get("rewardCoins") or catalog.HABIT_REWARD_MIN)
        habit["rewardCoins"] = min(catalog.HABIT_REWARD_MAX, max(catalog.HABIT_REWARD_MIN, coins))


def _rescale_farm(library: dict) -> None:
    for plot in library.get("farmPlots") or []:
        crop_id = plot.get("cropID")
        spec = catalog.crop(crop_id) if crop_id else None
        old = catalog.LEGACY_CROP_GROWTH_MINUTES.get(crop_id or "")
        if not spec or not old:
            continue
        completion = min(1.0, max(0.0, float(plot.get("growthMinutes") or 0) / old))
        plot["growthMinutes"] = completion * spec[3]


def _rescale_pasture(library: dict) -> None:
    animals = library.get("pastureAnimals")
    if not animals:
        return
    for resident in animals:
        spec = catalog.animal(resident.get("animalID"))
        if not spec:
            continue
        old_hours = 6 + spec[6] * 2
        completion = min(1.0, max(0.0, float(resident.get("growthHours") or 0) / old_hours))
        resident["growthHours"] = completion * catalog.maturity_hours(spec[6])


def _color_chores(library: dict) -> None:
    chores = library.get("chores")
    if not chores:
        return
    for index, chore in enumerate(chores):
        if not chore.get("colorHex"):
            chore["colorHex"] = catalog.CHORE_COLORS[index % len(catalog.CHORE_COLORS)]


def _retitle_focus(library: dict) -> None:
    titles = {}
    for action in library.get("shortActions") or []:
        titles.setdefault(action.get("id"), action.get("title"))

    def retitle(row: dict) -> None:
        linked = row.get("linkedActionID")
        if linked and linked in titles:
            row["title"] = titles[linked]
        else:
            row["title"] = "其他事件"

    active = library.get("activeFocus")
    if isinstance(active, dict):
        retitle(active)
    for record in library.get("focusRecords") or []:
        if isinstance(record, dict):
            retitle(record)


def starter(now) -> dict:
    moment = cocoa(now)
    goal_id = _uuid()
    habit_ids = [_uuid() for _ in range(3)]
    return {
        "version": catalog.SCHEMA_VERSION,
        "habits": [
            _habit(habit_ids[0], "喝够八杯水", "drop.fill", 5, moment),
            _habit(habit_ids[1], "整理桌面", "sparkles", 5, moment),
            _habit(habit_ids[2], "阅读二十分钟", "book.fill", 8, moment),
        ],
        "habitCompletionKeys": [],
        "habitRewardKeys": [],
        "focusRecords": [],
        "sleepRecords": [],
        "longGoals": [{
            "id": goal_id,
            "title": "建立稳定的工作与休息节奏",
            "reason": "让每天的精力更可控，也为长期目标留出空间。",
            "outcome": "连续四周保持规律专注与睡眠",
            "targetValue": 4,
            "currentValue": 0,
            "unit": "周",
            "startDate": moment,
            "targetDate": moment + 31 * 86400,
            "status": "active",
            "rewardClaimed": False,
            "createdAt": moment,
        }],
        "shortActions": [{
            "id": _uuid(),
            "goalID": goal_id,
            "title": "完成第一次 25 分钟专注",
            "notes": "开始时可把专注记录关联到这个行动。",
            "dueDate": moment + 86400,
            "estimatedMinutes": 25,
            "focusedSeconds": 0,
            "isCompleted": False,
            "rewardClaimed": False,
            "createdAt": moment,
        }],
        "coins": 100,
        "bait": 2,
        "farmPlots": [{
            "id": _uuid(),
            "growthMinutes": 0,
            "nextFocusBoost": 0,
        }],
        "pastureAnimals": [],
        "animalShelterCapacity": 1,
        "fishInventory": {},
        "fishCaught": {},
        "aquariumFish": [],
        "harvestedCrops": {},
        "rewardEvents": [{
            "id": _uuid(),
            "date": moment,
            "title": "欢迎来到节奏庄园",
            "detail": "已获得 100 金币、2 个鱼饵，以及农场和牧场各 1 个初始坑位。",
            "coins": 100,
            "symbol": "leaf.fill",
        }],
        "chores": [],
        "decorations": [],
    }


def _habit(habit_id, title, symbol, coins, moment) -> dict:
    return {
        "id": habit_id,
        "title": title,
        "symbol": symbol,
        "weekdays": [1, 2, 3, 4, 5, 6, 7],
        "rewardCoins": coins,
        "createdAt": moment,
    }


def _uuid() -> str:
    return str(uuid.uuid4()).upper()
