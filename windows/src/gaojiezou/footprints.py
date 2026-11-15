"""足迹资料 footprints.sqlite（schema 1）与旅行列车规则。

城市坐标来自 Mac 版地理数据包的城市表，不含行政区多边形和地图瓦片。
照片按 SHA-256 保存。列车物资不兑换节奏金币。
"""

from __future__ import annotations

import gzip
import hashlib
import json
import math
import uuid
from functools import lru_cache
from pathlib import Path

from gaojiezou.catalog import TRAIN_CARRIAGES, train_upgrade_cost
from gaojiezou.errors import AppError
from gaojiezou.library import dumps
from gaojiezou.resources import asset_dir
from gaojiezou.timeutil import cocoa, from_cocoa

DATASET_VERSION = "2026-09-21.1"
PHOTO_LIMIT = 20


class FootprintStore:
    def __init__(self, directory: Path):
        self.directory = directory
        self.path = directory / "footprints.sqlite"
        self.photos = directory / "Photos"
        self._db = None
        self.journal: dict | None = None

    @property
    def available(self) -> bool:
        return self.path.exists() and self.path.stat().st_size > 0

    def create_fresh(self, now) -> None:
        if self.directory.exists() and any(self.directory.iterdir()):
            raise AppError("足迹目录已有文件，未新建空库。", "protected")
        self.directory.mkdir(parents=True, exist_ok=True)
        import sqlite3
        self._db = sqlite3.connect(self.path)
        self._db.execute(
            "CREATE TABLE items (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind, id))"
        )
        self.journal = fresh_journal(now)
        self._write()

    def open_existing(self) -> None:
        if not self.available:
            raise AppError("足迹库不存在或为空，未新建空库。", "missing")
        import sqlite3
        self._db = sqlite3.connect(self.path)
        self._db.row_factory = sqlite3.Row
        rows = self._db.execute("SELECT kind, id, payload FROM items").fetchall()
        meta = next((json.loads(row["payload"]) for row in rows if row["kind"] == "meta" and row["id"] == "main"), None)
        if meta is None:
            raise AppError("足迹库缺少 meta，已停止写入。", "protected")
        if int(meta.get("schema") or 0) != 1:
            raise AppError("足迹存档版本不受支持，未写入。", "protected")
        journal = {
            "schema": 1,
            "datasetVersion": meta.get("datasetVersion") or DATASET_VERSION,
            "modifiedAt": meta.get("modifiedAt"),
            "footprintModifiedAt": meta.get("footprintModifiedAt"),
            "residentCityID": meta.get("residentCityID"),
            "train": meta.get("train") or fresh_train(),
            "visits": [],
            "trips": [],
            "customCities": [],
            "attachments": [],
        }
        for row in rows:
            payload = json.loads(row["payload"])
            if row["kind"] == "visit":
                journal["visits"].append(payload)
            elif row["kind"] == "trip":
                journal["trips"].append(payload)
            elif row["kind"] == "city":
                journal["customCities"].append(payload)
            elif row["kind"] == "photo":
                journal["attachments"].append(payload)
        self.journal = journal

    def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None

    def save_visit(self, visit: dict, now) -> dict:
        self._require()
        visit = dict(visit)
        visit.setdefault("id", str(uuid.uuid4()).upper())
        visit.setdefault("note", "")
        visit.setdefault("photoIDs", [])
        visit.setdefault("createdAt", cocoa(now))
        visit["modifiedAt"] = cocoa(now)
        _validate_date(visit.get("date") or {"precision": "unknown"}, now)
        if len(visit["photoIDs"]) > PHOTO_LIMIT:
            raise AppError("每条足迹最多 20 张照片。", "invalid")
        if not _known_city(visit.get("cityID"), self.journal):
            raise AppError("城市不在离线城市表或自定义城市中。", "invalid")
        if visit.get("tripID") and visit["tripID"] not in {trip["id"] for trip in self.journal["trips"]}:
            raise AppError("旅行不存在。", "invalid")
        self.journal["visits"] = [row for row in self.journal["visits"] if row["id"] != visit["id"]]
        self.journal["visits"].append(visit)
        self._touch(now, footprints=True)
        gained = settle_train(self.journal)
        self._write()
        visit["trainMaterialsGained"] = gained
        return visit

    def delete_visit(self, visit_id: str, now) -> None:
        self._require()
        self.journal["visits"] = [row for row in self.journal["visits"] if row["id"] != visit_id]
        self._touch(now, footprints=True)
        self._write()

    def save_trip(self, trip: dict, now) -> dict:
        self._require()
        trip = dict(trip)
        name = str(trip.get("name") or "").strip()
        if not name:
            raise AppError("旅行名称不能为空。", "invalid")
        trip["name"] = name
        trip.setdefault("id", str(uuid.uuid4()).upper())
        trip.setdefault("note", "")
        trip.setdefault("createdAt", cocoa(now))
        self.journal["trips"] = [row for row in self.journal["trips"] if row["id"] != trip["id"]]
        self.journal["trips"].append(trip)
        self._touch(now, footprints=True)
        settle_train(self.journal)
        self._write()
        return trip

    def set_resident(self, city_id: str | None, now) -> None:
        self._require()
        if city_id and not _known_city(city_id, self.journal):
            raise AppError("常驻城市不在离线城市表中。", "invalid")
        self.journal["residentCityID"] = city_id or None
        self._touch(now, footprints=True)
        self._write()

    def add_custom_city(self, city: dict, now) -> dict:
        self._require()
        city = dict(city)
        city.setdefault("id", "custom-" + str(uuid.uuid4()).upper())
        city["isCustom"] = True
        if not _valid_station(city):
            raise AppError("自定义城市坐标无效。", "invalid")
        self.journal["customCities"] = [row for row in self.journal["customCities"] if row["id"] != city["id"]]
        self.journal["customCities"].append(city)
        self._touch(now, footprints=True)
        self._write()
        return city

    def add_photo(self, visit_id: str, filename: str, content: bytes, now) -> dict:
        self._require()
        visit = next((row for row in self.journal["visits"] if row["id"] == visit_id), None)
        if visit is None:
            raise AppError("足迹不存在。", "invalid")
        if len(visit.get("photoIDs") or []) >= PHOTO_LIMIT:
            raise AppError("每条足迹最多 20 张照片。", "invalid")
        if not content:
            raise AppError("照片是空文件，未保存。", "invalid")
        digest = hashlib.sha256(content).hexdigest()
        existing = next((row for row in self.journal["attachments"] if row["sha256"] == digest), None)
        if existing is None:
            suffix = Path(filename).suffix.lower()
            if suffix not in {".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"}:
                suffix = ".bin"
            attachment = {
                "id": str(uuid.uuid4()).upper(),
                "filename": str(uuid.uuid4()).upper() + suffix,
                "sha256": digest,
                "size": len(content),
            }
            self.photos.mkdir(parents=True, exist_ok=True)
            target = self.photos / attachment["filename"]
            temporary = target.with_name(target.name + ".tmp")
            temporary.write_bytes(content)
            temporary.replace(target)
            self.journal["attachments"].append(attachment)
        else:
            attachment = existing
        visit.setdefault("photoIDs", [])
        if attachment["id"] not in visit["photoIDs"]:
            visit["photoIDs"].append(attachment["id"])
        visit["modifiedAt"] = cocoa(now)
        self._touch(now, footprints=True)
        settle_train(self.journal)
        self._write()
        return attachment

    def upgrade_carriage(self, carriage: str) -> bool:
        self._require()
        if carriage not in TRAIN_CARRIAGES:
            raise AppError("没有这节车厢。", "invalid")
        train = self.journal["train"]
        level = int((train.get("carriageLevels") or {}).get(carriage) or 0)
        nxt = level + 1
        if nxt > 4:
            return False
        cost = train_upgrade_cost(nxt)
        if int(train.get("materials") or 0) < cost:
            return False
        train["materials"] = int(train["materials"]) - cost
        train.setdefault("carriageLevels", {})[carriage] = nxt
        self._write()
        return True

    def depart(self, destination_id: str, now) -> bool:
        self._require()
        train = self.journal["train"]
        if train.get("journey") and not train["journey"].get("completed", False):
            return False
        origin = train.get("currentStation")
        destination = city_by_id(destination_id) or next(
            (row for row in self.journal["customCities"] if row["id"] == destination_id), None
        )
        if not origin or not destination or not _valid_station(origin) or not _valid_station(destination):
            return False
        if origin["id"] == destination["id"]:
            return False
        sleeper = int((train.get("carriageLevels") or {}).get("sleeper") or 0)
        dining = int((train.get("carriageLevels") or {}).get("dining") or 0)
        last = train.get("lastCruiseAt")
        reward_ready = True
        if last is not None:
            ready_at = from_cocoa(last).timestamp() + (24 - 2 * sleeper) * 3600
            reward_ready = now.timestamp() >= ready_at
        distance = _distance(origin, destination)
        duration = min(600, max(120, 120 + distance / 8))
        reward = 2 + dining if reward_ready else 0
        train["journey"] = {
            "id": str(uuid.uuid4()).upper(),
            "origin": origin,
            "destination": destination,
            "startedAt": cocoa(now),
            "arrivesAt": cocoa(now) + duration,
            "reward": reward,
            "completed": False,
        }
        if reward_ready:
            train["lastCruiseAt"] = cocoa(now)
        train["routeCityID"] = destination["id"]
        self._write()
        return True

    def arrive(self, now) -> bool:
        self._require()
        train = self.journal["train"]
        journey = train.get("journey")
        if not journey or journey.get("completed") or now.timestamp() < from_cocoa(journey["arrivesAt"]).timestamp():
            return False
        journey["completed"] = True
        train["currentStation"] = journey["destination"]
        gained = min(int(journey.get("reward") or 0), max(0, 1_000_000 - int(train.get("lifetimeMaterials") or 0)))
        train["materials"] = int(train.get("materials") or 0) + gained
        train["lifetimeMaterials"] = int(train.get("lifetimeMaterials") or 0) + gained
        train["cruiseCount"] = min(1_000_000, int(train.get("cruiseCount") or 0) + 1)
        self._write()
        return True

    def prepare_station(self) -> None:
        self._require()
        train = self.journal["train"]
        if train.get("currentStation"):
            return
        cities = load_cities()["cities"][:1]
        if cities:
            train["currentStation"] = _station(cities[0])
            self._write()

    def summary(self) -> dict:
        if self.journal is None:
            return {"available": False}
        cities = _city_index()
        for city in self.journal["customCities"]:
            cities[city["id"]] = city
        metrics = compute_metrics(self.journal, cities)
        plotted = []
        seen = set()
        for visit in self.journal["visits"]:
            city = cities.get(visit["cityID"])
            if city and city["id"] not in seen:
                seen.add(city["id"])
                plotted.append({
                    "id": city["id"],
                    "name": city.get("name") or city["id"],
                    "longitude": city["longitude"],
                    "latitude": city["latitude"],
                })
        return {
            "available": True,
            "metrics": metrics,
            "plotted": plotted,
            "visits": self.journal["visits"],
            "trips": self.journal["trips"],
            "residentCityID": self.journal.get("residentCityID"),
            "attachments": self.journal["attachments"],
            "train": self.journal["train"],
            "customCities": self.journal["customCities"],
        }

    def _touch(self, now, footprints: bool) -> None:
        moment = cocoa(now)
        self.journal["modifiedAt"] = moment
        if footprints:
            self.journal["footprintModifiedAt"] = moment

    def _write(self) -> None:
        journal = self.journal
        meta = {
            "schema": 1,
            "datasetVersion": journal.get("datasetVersion") or DATASET_VERSION,
            "modifiedAt": journal.get("modifiedAt"),
            "footprintModifiedAt": journal.get("footprintModifiedAt"),
            "residentCityID": journal.get("residentCityID"),
            "train": journal.get("train") or fresh_train(),
        }
        self._db.execute("DELETE FROM items")
        self._db.execute(
            "INSERT INTO items(kind, id, payload) VALUES ('meta', 'main', ?)",
            (dumps(meta),),
        )
        for visit in journal["visits"]:
            self._db.execute("INSERT INTO items(kind, id, payload) VALUES ('visit', ?, ?)", (visit["id"], dumps(visit)))
        for trip in journal["trips"]:
            self._db.execute("INSERT INTO items(kind, id, payload) VALUES ('trip', ?, ?)", (trip["id"], dumps(trip)))
        for city in journal["customCities"]:
            self._db.execute("INSERT INTO items(kind, id, payload) VALUES ('city', ?, ?)", (city["id"], dumps(city)))
        for photo in journal["attachments"]:
            self._db.execute("INSERT INTO items(kind, id, payload) VALUES ('photo', ?, ?)", (photo["id"], dumps(photo)))
        self._db.commit()

    def _require(self) -> None:
        if self._db is None or self.journal is None:
            raise AppError("足迹库未打开。", "missing")


def fresh_journal(now) -> dict:
    moment = cocoa(now)
    return {
        "schema": 1,
        "datasetVersion": DATASET_VERSION,
        "visits": [],
        "trips": [],
        "customCities": [],
        "residentCityID": None,
        "attachments": [],
        "modifiedAt": moment,
        "footprintModifiedAt": moment,
        "train": fresh_train(),
    }


def fresh_train() -> dict:
    return {
        "materials": 0,
        "lifetimeMaterials": 0,
        "carriageLevels": {},
        "claimedVisitIDs": [],
        "claimedCityIDs": [],
        "claimedPhotoIDs": [],
        "claimedTripIDs": [],
        "claimedNoteIDs": [],
        "cruiseCount": 0,
        "carriageOrder": [],
        "routeCityID": "",
    }


def settle_train(journal: dict) -> int:
    train = journal.setdefault("train", fresh_train())
    visits_claimed = set(train.get("claimedVisitIDs") or [])
    cities_claimed = set(train.get("claimedCityIDs") or [])
    photos_claimed = set(train.get("claimedPhotoIDs") or [])
    trips_claimed = set(train.get("claimedTripIDs") or [])
    notes_claimed = set(train.get("claimedNoteIDs") or [])
    observation = int((train.get("carriageLevels") or {}).get("observation") or 0)
    garden = int((train.get("carriageLevels") or {}).get("garden") or 0)
    library = int((train.get("carriageLevels") or {}).get("library") or 0)
    gained = 0
    for visit in journal.get("visits") or []:
        if visit["id"] not in visits_claimed:
            visits_claimed.add(visit["id"])
            train.setdefault("claimedVisitIDs", []).append(visit["id"])
            gained += 1
        if visit["cityID"] not in cities_claimed:
            cities_claimed.add(visit["cityID"])
            train.setdefault("claimedCityIDs", []).append(visit["cityID"])
            gained += 2 + observation
        note = str(visit.get("note") or "").strip()
        if len(note) >= 4 and visit["id"] not in notes_claimed:
            notes_claimed.add(visit["id"])
            train.setdefault("claimedNoteIDs", []).append(visit["id"])
            gained += 2 + library
        for photo in visit.get("photoIDs") or []:
            if photo not in photos_claimed:
                photos_claimed.add(photo)
                train.setdefault("claimedPhotoIDs", []).append(photo)
                gained += 2 + garden
    linked = {visit.get("tripID") for visit in journal.get("visits") or [] if visit.get("tripID")}
    for trip in journal.get("trips") or []:
        if trip["id"] in linked and trip["id"] not in trips_claimed:
            trips_claimed.add(trip["id"])
            train.setdefault("claimedTripIDs", []).append(trip["id"])
            gained += 3
    train["materials"] = int(train.get("materials") or 0) + gained
    train["lifetimeMaterials"] = int(train.get("lifetimeMaterials") or 0) + gained
    return gained


def compute_metrics(journal: dict, cities: dict) -> dict:
    ids = []
    seen = set()
    for visit in journal.get("visits") or []:
        if visit["cityID"] not in seen:
            seen.add(visit["cityID"])
            ids.append(visit["cityID"])
    found = [cities[item] for item in ids if item in cities]
    countries = {city.get("countryID") for city in found if city.get("countryID") and city.get("countryID") != "ATA"}
    china = [city for city in found if city.get("countryID") == "CHN"]
    continents = {city.get("continent") for city in found if city.get("continent") not in {"", "南极洲", "其他", None}}
    return {
        "cities": len([city for city in found if city.get("countryID") != "ATA"]),
        "countries": len(countries),
        "china": len(china),
        "visits": len(journal.get("visits") or []),
        "trips": len({visit.get("tripID") for visit in journal.get("visits") or [] if visit.get("tripID")}),
        "continents": len(continents),
    }


def search_cities(query: str, limit: int = 20) -> list[dict]:
    text = query.strip().casefold().replace(" ", "")
    if not text:
        return []
    matches = []
    for city in load_cities()["cities"]:
        haystack = "".join([
            city.get("name") or "",
            city.get("english") or "",
            city.get("province") or "",
        ]).casefold().replace(" ", "")
        if text in haystack:
            matches.append(city)
            if len(matches) >= limit:
                break
    return matches


def city_by_id(city_id: str | None) -> dict | None:
    if not city_id:
        return None
    return _city_index().get(city_id)


@lru_cache(maxsize=1)
def load_cities() -> dict:
    blob = gzip.decompress((asset_dir() / "cities.json.gz").read_bytes())
    return json.loads(blob.decode("utf-8"))


@lru_cache(maxsize=1)
def _city_index() -> dict:
    return {city["id"]: city for city in load_cities()["cities"]}


def _known_city(city_id: str | None, journal: dict) -> bool:
    if not city_id:
        return False
    if city_id in _city_index():
        return True
    return any(city["id"] == city_id for city in journal.get("customCities") or [])


def _validate_date(value: dict, now) -> None:
    precision = value.get("precision") or "unknown"
    if precision == "unknown":
        if value.get("year") or value.get("month") or value.get("day"):
            raise AppError("未知日期不应包含年月日。", "invalid")
        return
    year = value.get("year")
    if not isinstance(year, int) or year < 1 or year > now.year:
        raise AppError("年份无效或位于未来。", "invalid")
    if precision == "year":
        if value.get("month") or value.get("day"):
            raise AppError("仅年份的记录不能包含月日。", "invalid")
        return
    month = value.get("month")
    if not isinstance(month, int) or not 1 <= month <= 12:
        raise AppError("月份必须为 1–12。", "invalid")
    if year == now.year and month > now.month:
        raise AppError("不能把未来的旅行标记为去过。", "invalid")
    if precision == "month":
        if value.get("day"):
            raise AppError("仅月份的记录不能包含日。", "invalid")
        return
    day = value.get("day")
    if not isinstance(day, int):
        raise AppError("日期不存在。", "invalid")
    try:
        candidate = now.replace(year=year, month=month, day=day, hour=12, minute=0, second=0, microsecond=0)
    except ValueError as exc:
        raise AppError("日期不存在，请检查月份和天数。", "invalid") from exc
    if candidate > now:
        raise AppError("不能记录未来到访。", "invalid")


def _valid_station(city: dict) -> bool:
    try:
        lon = float(city["longitude"])
        lat = float(city["latitude"])
    except (KeyError, TypeError, ValueError):
        return False
    return bool(city.get("id")) and len(str(city["id"])) < 200 and bool(city.get("countryID")) and -180 <= lon <= 180 and -90 <= lat <= 90


def _station(city: dict) -> dict:
    return {
        "id": city["id"],
        "name": city.get("name") or "",
        "english": city.get("english") or "",
        "countryID": city.get("countryID") or "",
        "province": city.get("province") or "",
        "continent": city.get("continent") or "",
        "longitude": city["longitude"],
        "latitude": city["latitude"],
        "isCustom": bool(city.get("isCustom")),
    }


def _distance(left: dict, right: dict) -> float:
    radians = math.pi / 180
    lat = (right["latitude"] - left["latitude"]) * radians
    lon = (right["longitude"] - left["longitude"]) * radians
    h = math.sin(lat / 2) ** 2 + math.cos(left["latitude"] * radians) * math.cos(right["latitude"] * radians) * math.sin(lon / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(min(1, max(0, h))))
