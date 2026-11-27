"""足迹资料 footprints.sqlite（schema 1）与旅行列车规则。

城市数据沿用 Mac 版离线目录。照片以 SHA-256 校验，列车物资独立结算。
"""

from __future__ import annotations

import base64
import binascii
import copy
import csv
import gzip
import hashlib
import io
import json
import math
import sqlite3
import unicodedata
import uuid
from collections import defaultdict
from datetime import date
from functools import lru_cache
from pathlib import Path

from gaojiezou.catalog import TRAIN_CARRIAGES, train_upgrade_cost
from gaojiezou.errors import AppError
from gaojiezou.library import dumps
from gaojiezou.resources import asset_dir
from gaojiezou.timeutil import cocoa, from_cocoa

DATASET_VERSION = "2026-09-21.1"
PHOTO_LIMIT = 20
PHOTO_BYTES_LIMIT = 30 * 1024 * 1024
PHOTO_MIME = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".heic": "image/heic", ".heif": "image/heif", ".webp": "image/webp", ".gif": "image/gif",
}
FOOTPRINT_PREFERENCES = {"ownerName": "", "soundEnabled": False, "animationEnabled": True}


class FootprintStore:
    def __init__(self, directory: Path):
        self.directory = directory
        self.path = directory / "footprints.sqlite"
        self.photos = directory / "Photos"
        self._db = None
        self._meta = {}
        self._undo = None
        self.journal: dict | None = None

    @property
    def available(self) -> bool:
        return self.path.exists() and self.path.stat().st_size > 0

    def create_fresh(self, now) -> None:
        if self.directory.exists() and any(self.directory.iterdir()):
            raise AppError("足迹目录已有文件，未新建空库。", "protected")
        self.directory.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(self.path, check_same_thread=False)
        self._db.execute(
            "CREATE TABLE items (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind, id))"
        )
        self.journal = fresh_journal(now)
        self._write()

    def open_existing(self) -> None:
        if not self.available:
            raise AppError("足迹库不存在或为空，未新建空库。", "missing")
        self._db = sqlite3.connect(self.path.resolve().as_uri() + "?mode=rw", uri=True, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        try:
            if self._db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise AppError("足迹库校验失败，已停止写入。", "protected")
            self._load()
        except (AppError, sqlite3.Error, ValueError, TypeError, AttributeError) as exc:
            self.close()
            if isinstance(exc, AppError):
                raise
            raise AppError("无法读取足迹库，已停止写入。", "protected") from exc

    def _load(self) -> None:
        rows = self._db.execute("SELECT kind, id, payload FROM items ORDER BY rowid").fetchall()
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
            "preferences": {**FOOTPRINT_PREFERENCES, **(meta.get("preferences") or {})},
            "visits": [],
            "trips": [],
            "customCities": [],
            "attachments": [],
        }
        kinds = {"visit": "visits", "trip": "trips", "city": "customCities", "photo": "attachments"}
        for row in rows:
            key = kinds.get(row["kind"])
            if key:
                payload = json.loads(row["payload"])
                if not isinstance(payload, dict) or payload.get("id") != row["id"]:
                    raise AppError("足迹库存在无法识别的记录，已停止写入。", "protected")
                journal[key].append(payload)
        self._meta = meta
        self.journal = journal

    def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None
        self.journal = None
        self._undo = None

    def save_visit(self, visit: dict, now) -> dict:
        self._require()
        journal = copy.deepcopy(self.journal)
        visit_id = visit.get("id")
        previous = next((row for row in journal["visits"] if row["id"] == visit_id), None)
        raw_ids = visit.get("cityIDs", [visit.get("cityID")])
        if not isinstance(raw_ids, list) or not raw_ids or not all(isinstance(item, str) for item in raw_ids):
            raise AppError("请选择至少一个地点。", "invalid")
        city_ids = list(dict.fromkeys(raw_ids))
        if len(city_ids) > 80 or previous and len(city_ids) != 1:
            raise AppError("本次选择的地点数量无效。", "invalid")
        if not all(_known_city(city_id, journal) for city_id in city_ids):
            raise AppError("城市不在离线城市表或自定义城市中。", "invalid")
        trip_id = visit.get("tripID") or None
        if "tripID" not in visit and previous:
            trip_id = previous.get("tripID")
        new_trip_name = str(visit.get("newTripName") or "").strip()
        if new_trip_name:
            trip_id = _new_id()
            journal["trips"].append({"id": trip_id, "name": new_trip_name, "note": "", "createdAt": cocoa(now)})
        elif trip_id and trip_id not in {trip["id"] for trip in journal["trips"]}:
            raise AppError("旅行不存在。", "invalid")
        visit_date = visit.get("date", (previous or {}).get("date")) or {"precision": "unknown"}
        _validate_date(visit_date, now)
        visit_date = {key: value for key, value in visit_date.items() if key in {"precision", "year", "month", "day"} and value is not None}
        visit_date.setdefault("precision", "unknown")
        if ("cityIDs" in visit or "allowDuplicate" in visit) and not visit.get("allowDuplicate") and any(
            row["id"] != visit_id and row["cityID"] in city_ids
            and {key: value for key, value in row.get("date", {}).items() if value is not None} == visit_date
            and row.get("tripID") == trip_id for row in journal["visits"]
        ):
            raise AppError("相同城市、日期和旅行已有记录。仍要保存这次到访吗？", "duplicate")
        photo_ids = visit.get("photoIDs", (previous or {}).get("photoIDs", []))
        uploads = visit.get("photos", [])
        if not isinstance(photo_ids, list) or not all(isinstance(item, str) for item in photo_ids) or not isinstance(uploads, list):
            raise AppError("照片列表无效。", "invalid")
        if len(photo_ids) + len(uploads) > PHOTO_LIMIT:
            raise AppError("每条足迹最多 20 张照片。", "invalid")
        attachments = {row["id"]: row for row in journal["attachments"]}
        for photo_id in set(photo_ids):
            if photo_id not in attachments or not self._photo_path(attachments[photo_id]).is_file():
                raise AppError("照片文件缺失，未保存。", "missing")
        pending = {}
        photo_ids = list(dict.fromkeys(photo_ids))
        for upload in uploads:
            try:
                content = base64.b64decode(upload["contentBase64"], validate=True)
            except (binascii.Error, ValueError, TypeError, KeyError) as exc:
                raise AppError("照片上传数据无效。", "invalid") from exc
            attachment = self._register_photo(journal, pending, upload.get("filename", ""), content, strict=True)
            if attachment["id"] not in photo_ids:
                photo_ids.append(attachment["id"])
        note = str(visit.get("note", (previous or {}).get("note")) or "").strip()
        moment = cocoa(now)
        saved = []
        for index, city_id in enumerate(sorted(city_ids)):
            row = {
                **(previous or {}), "id": visit_id if index == 0 and visit_id else _new_id(),
                "cityID": city_id, "date": visit_date, "note": note, "photoIDs": photo_ids, "modifiedAt": moment,
            }
            row.setdefault("createdAt", moment)
            if trip_id:
                row["tripID"] = trip_id
            else:
                row.pop("tripID", None)
            saved.append(row)
        journal["visits"] = [row for row in journal["visits"] if row["id"] != visit_id] + saved
        gained = settle_train(journal)
        _prepare_train(journal)
        self._commit(journal, now, pending)
        return {**saved[0], "trainMaterialsGained": gained, "savedIDs": [row["id"] for row in saved]}

    def delete_visit(self, visit_id: str, now) -> None:
        self._require()
        journal = copy.deepcopy(self.journal)
        journal["visits"] = [row for row in journal["visits"] if row["id"] != visit_id]
        _prepare_train(journal)
        self._commit(journal, now)

    def delete_trip(self, trip_id: str, now) -> None:
        self._require()
        journal = copy.deepcopy(self.journal)
        journal["trips"] = [trip for trip in journal["trips"] if trip["id"] != trip_id]
        for visit in journal["visits"]:
            if visit.get("tripID") == trip_id:
                visit.pop("tripID")
        self._commit(journal, now)

    def undo(self, now) -> bool:
        self._require()
        if self._undo is None:
            return False
        journal = copy.deepcopy(self._undo)
        journal["train"] = copy.deepcopy(self.journal["train"])
        journal["preferences"] = copy.deepcopy(self.journal["preferences"])
        # Keep successfully imported files registered so a later reuse can deduplicate them.
        journal["attachments"] = copy.deepcopy(self.journal["attachments"])
        _prepare_train(journal)
        self._commit(journal, now)
        self._undo = None
        return True

    def save_trip(self, trip: dict, now) -> dict:
        self._require()
        journal = copy.deepcopy(self.journal)
        name = str(trip.get("name") or "").strip()
        if not name:
            raise AppError("旅行名称不能为空。", "invalid")
        trip_id = trip.get("id") or _new_id()
        previous = next((row for row in journal["trips"] if row["id"] == trip_id), {})
        trip = {**previous, "id": trip_id, "name": name, "note": str(trip.get("note", previous.get("note")) or "").strip()}
        trip.setdefault("createdAt", cocoa(now))
        journal["trips"] = [row for row in journal["trips"] if row["id"] != trip_id] + [trip]
        settle_train(journal)
        self._commit(journal, now)
        return trip

    def set_resident(self, city_id: str | None, now) -> None:
        self._require()
        if city_id and not _known_city(city_id, self.journal):
            raise AppError("常驻城市不在离线城市表中。", "invalid")
        journal = copy.deepcopy(self.journal)
        journal["residentCityID"] = city_id or None
        self._commit(journal, now)

    def add_custom_city(self, city: dict, now) -> dict:
        self._require()
        journal = copy.deepcopy(self.journal)
        country = _countries().get(city.get("countryID") or "")
        name = str(city.get("name") or "").strip()
        if not country or not name:
            raise AppError("请填写地点名称并选择国家或地区。", "invalid")
        try:
            longitude, latitude = float(city["longitude"]), float(city["latitude"])
        except (TypeError, ValueError, KeyError) as exc:
            raise AppError("自定义城市坐标无效。", "invalid") from exc
        city = {
            "id": city.get("id") or "custom-" + _new_id(), "name": name,
            "english": str(city.get("english") or "").strip(), "aliases": str(city.get("aliases") or "").strip(),
            "countryID": country["id"], "continent": country["continent"], "provinceID": "",
            "province": str(city.get("province") or "").strip(), "isCustom": True,
            "longitude": longitude, "latitude": latitude,
        }
        if not _valid_station(city):
            raise AppError("自定义城市坐标无效。", "invalid")
        for existing in (*load_cities()["cities"], *journal["customCities"]):
            if existing["countryID"] == city["countryID"] and _search_key(existing["name"]) == _search_key(city["name"]):
                return existing
        if city["id"] in _city_index():
            raise AppError("自定义地点编号与离线目录重复。", "invalid")
        journal["customCities"] = [row for row in journal["customCities"] if row["id"] != city["id"]] + [city]
        self._commit(journal, now)
        return city

    def add_photo(self, visit_id: str, filename: str, content: bytes, now) -> dict:
        self._require()
        journal = copy.deepcopy(self.journal)
        visit = next((row for row in journal["visits"] if row["id"] == visit_id), None)
        if visit is None:
            raise AppError("足迹不存在。", "invalid")
        photo_ids = visit.setdefault("photoIDs", [])
        pending = {}
        attachment = self._register_photo(journal, pending, filename, content)
        if len(photo_ids) >= PHOTO_LIMIT and attachment["id"] not in photo_ids:
            raise AppError("每条足迹最多 20 张照片。", "invalid")
        if attachment["id"] in photo_ids and not pending:
            return attachment
        if attachment["id"] not in photo_ids:
            photo_ids.append(attachment["id"])
        visit["modifiedAt"] = cocoa(now)
        settle_train(journal)
        self._commit(journal, now, pending)
        return attachment

    def _register_photo(self, journal, pending, filename, content, *, strict=False) -> dict:
        if not content:
            raise AppError("照片是空文件，未保存。", "invalid")
        if len(content) > PHOTO_BYTES_LIMIT:
            raise AppError("单张照片不能超过 30 MB。", "invalid")
        suffix = _image_extension(content)
        if strict and suffix is None:
            raise AppError("无法读取照片，请使用 JPEG、PNG 或 HEIC。", "invalid")
        digest = hashlib.sha256(content).hexdigest()
        for attachment in journal["attachments"]:
            if attachment["sha256"] != digest:
                continue
            target = self._photo_path(attachment)
            if target in pending:
                return attachment
            if not target.exists():
                pending[target] = content
                return attachment
            if target.stat().st_size == len(content) and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
                return attachment
        suffix = suffix or Path(str(filename)).suffix.lower()
        if suffix not in PHOTO_MIME:
            suffix = ".bin"
        identifier = _new_id()
        attachment = {"id": identifier, "filename": identifier + suffix, "sha256": digest, "size": len(content)}
        pending[self._photo_path(attachment)] = content
        journal["attachments"].append(attachment)
        return attachment

    def _photo_path(self, attachment) -> Path:
        filename = attachment.get("filename")
        if not isinstance(filename, str) or not filename or any(char in filename for char in "/\\:") or filename in {".", ".."}:
            raise AppError("照片文件名无效。", "protected")
        root = self.photos.resolve()
        target = (self.photos / filename).resolve()
        if root.parent != self.directory.resolve() or target.parent != root:
            raise AppError("照片路径无效。", "protected")
        return target

    def photo(self, photo_id: str) -> tuple[bytes, str]:
        self._require()
        attachment = next((row for row in self.journal["attachments"] if row["id"] == photo_id), None)
        if not attachment:
            raise AppError("照片不存在。", "missing")
        path = self._photo_path(attachment)
        try:
            if path.stat().st_size != attachment["size"] or path.stat().st_size > PHOTO_BYTES_LIMIT:
                raise AppError("照片校验失败。", "protected")
            content = path.read_bytes()
        except OSError as exc:
            raise AppError("照片文件缺失或无法读取。", "missing") from exc
        if hashlib.sha256(content).hexdigest() != attachment["sha256"]:
            raise AppError("照片校验失败。", "protected")
        return content, PHOTO_MIME.get(_image_extension(content), "application/octet-stream")

    def upgrade_carriage(self, carriage: str, now=None) -> bool:
        self._require()
        if carriage not in TRAIN_CARRIAGES:
            raise AppError("没有这节车厢。", "invalid")
        journal = copy.deepcopy(self.journal)
        train = journal["train"]
        level = int((train.get("carriageLevels") or {}).get(carriage) or 0)
        nxt = level + 1
        if nxt > 4:
            return False
        cost = train_upgrade_cost(nxt)
        if int(train.get("materials") or 0) < cost:
            return False
        train["materials"] = int(train["materials"]) - cost
        train.setdefault("carriageLevels", {})[carriage] = nxt
        self._commit(journal, now, footprints=False)
        return True

    def depart(self, destination_id: str | None, now) -> bool:
        self._require()
        self.sync_train(now)
        journal = copy.deepcopy(self.journal)
        train = journal["train"]
        if train.get("journey") and not train["journey"].get("completed", False):
            return False
        origin = train.get("currentStation")
        destination_id = destination_id or train.get("routeCityID")
        destination = _visited_stations(journal).get(destination_id)
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
        self._commit(journal, now, footprints=False)
        return True

    def arrive(self, now) -> bool:
        self._require()
        journal = copy.deepcopy(self.journal)
        if _arrive_train(journal["train"], now):
            _prepare_train(journal)
            self._commit(journal, now, footprints=False)
            return True
        return False

    def prepare_station(self) -> None:
        self._require()
        journal = copy.deepcopy(self.journal)
        _prepare_train(journal)
        self._commit(journal, None, footprints=False)

    def sync_train(self, now) -> bool:
        self._require()
        journal = copy.deepcopy(self.journal)
        settle_train(journal)
        arrived = _arrive_train(journal["train"], now)
        _prepare_train(journal)
        self._commit(journal, now, footprints=False)
        return arrived

    def set_train_route(self, destination_id: str, now) -> bool:
        self._require()
        journal = copy.deepcopy(self.journal)
        train = journal["train"]
        station = train.get("currentStation") or {}
        if train.get("journey") and not train["journey"].get("completed", False):
            return False
        if destination_id and (destination_id not in _visited_stations(journal) or destination_id == station.get("id")):
            return False
        train["routeCityID"] = destination_id
        self._commit(journal, now, footprints=False)
        return True

    def reorder_carriage(self, carriage: str, slot: int, now) -> bool:
        self._require()
        journal = copy.deepcopy(self.journal)
        train = journal["train"]
        levels = train.get("carriageLevels") or {}
        if carriage not in TRAIN_CARRIAGES or not levels.get(carriage) or type(slot) is not int:
            raise AppError("车厢位置无效。", "invalid")
        order = list(dict.fromkeys([*(train.get("carriageOrder") or []), *TRAIN_CARRIAGES]))
        order = [item for item in order if item != carriage and levels.get(item)]
        order.insert(min(max(slot, 0), len(order)), carriage)
        train["carriageOrder"] = order
        self._commit(journal, now, footprints=False)
        return True

    def search(self, query: str, country: str | None = None) -> list[dict]:
        custom = self.journal["customCities"] if self.journal is not None else []
        return search_cities(query, 80, country=country, custom=custom, include_empty=True)

    def set_preferences(self, preferences: dict, now) -> dict:
        self._require()
        journal = copy.deepcopy(self.journal)
        settings = journal["preferences"]
        if "ownerName" in preferences:
            settings["ownerName"] = str(preferences["ownerName"] or "").strip()[:100]
        for key in ("soundEnabled", "animationEnabled"):
            if key in preferences:
                if type(preferences[key]) is not bool:
                    raise AppError("足迹设置格式无效。", "invalid")
                settings[key] = preferences[key]
        self._commit(journal, None, footprints=False)
        return settings

    def export_csv(self) -> str:
        self._require()
        output = io.StringIO(newline="")
        output.write("\ufeff记录ID,城市,国家或地区代码,日期精度,年份,月份,日期,旅行,笔记,照片数\r\n")
        writer = csv.writer(output, quoting=csv.QUOTE_ALL)
        cities = _journal_cities(self.journal)
        trips = {trip["id"]: trip["name"] for trip in self.journal["trips"]}
        for visit in self.journal["visits"]:
            city = cities.get(visit["cityID"], {})
            date_fields = visit.get("date") or {}
            fields = [visit["id"], city.get("name") or visit["cityID"], city.get("countryID", ""),
                      date_fields.get("precision", "unknown"), date_fields.get("year"), date_fields.get("month"),
                      date_fields.get("day"), trips.get(visit.get("tripID"), ""), visit.get("note", ""),
                      len(visit.get("photoIDs") or [])]
            values = [str(value) if value is not None else "" for value in fields]
            writer.writerow("'" + value if value.lstrip().startswith(("=", "+", "-", "@")) or value.startswith(("\t", "\r"))
                            else value for value in values)
        return output.getvalue()

    def export_json(self) -> str:
        self._require()
        return json.dumps({key: value for key, value in self.journal.items() if key != "preferences"},
                          ensure_ascii=False, indent=2)

    def summary(self) -> dict:
        if self.journal is None:
            return {"available": False}
        cities = _journal_cities(self.journal)
        metrics = compute_metrics(self.journal, cities)
        plotted = []
        seen = set()
        for visit in self.journal["visits"]:
            city = cities.get(visit["cityID"])
            if city and city["id"] not in seen:
                seen.add(city["id"])
                plotted.append(city)
        resident = cities.get(self.journal.get("residentCityID"))
        return {
            "available": True,
            "metrics": metrics,
            "plotted": plotted,
            "visits": self.journal["visits"],
            "trips": self.journal["trips"],
            "residentCityID": self.journal.get("residentCityID"),
            "residentCity": resident,
            "countries": load_cities()["countries"],
            "chinaTotal": sum(city["countryID"] == "CHN" for city in _city_index().values()),
            "undoAvailable": self._undo is not None,
            "preferences": self.journal["preferences"],
            "years": sorted({row["date"]["year"] for row in self.journal["visits"] if row.get("date", {}).get("year")}, reverse=True),
            "attachments": self.journal["attachments"],
            "train": self.journal["train"],
            "customCities": self.journal["customCities"],
        }

    def _commit(self, journal, now, pending=None, *, footprints=True) -> None:
        previous = self.journal
        if journal == previous and not pending:
            return
        if now is not None:
            journal["modifiedAt"] = cocoa(now)
            if footprints:
                journal["footprintModifiedAt"] = cocoa(now)
        created = []
        try:
            if pending:
                self.photos.mkdir(parents=True, exist_ok=True)
                for target, content in pending.items():
                    temporary = target.with_name(target.name + "." + _new_id() + ".tmp")
                    try:
                        temporary.write_bytes(content)
                        if target.exists():
                            raise AppError("照片文件已存在，未覆盖。", "protected")
                        temporary.replace(target)
                        created.append(target)
                    finally:
                        temporary.unlink(missing_ok=True)
            self._write(journal, previous)
        except (AppError, OSError, sqlite3.Error) as exc:
            for path in created:
                path.unlink(missing_ok=True)
            if isinstance(exc, AppError):
                raise
            raise AppError("无法保存足迹，未更新资料。", "protected") from exc
        self.journal = journal
        if footprints:
            self._undo = previous

    def _write(self, journal=None, previous=None) -> None:
        journal = self.journal if journal is None else journal
        meta = {
            **self._meta,
            "schema": 1,
            "datasetVersion": journal.get("datasetVersion") or DATASET_VERSION,
            "modifiedAt": journal.get("modifiedAt"),
            "footprintModifiedAt": journal.get("footprintModifiedAt"),
            "residentCityID": journal.get("residentCityID"),
            "train": journal.get("train") or fresh_train(),
            "preferences": journal["preferences"],
        }
        upsert = "INSERT INTO items(kind, id, payload) VALUES (?, ?, ?) ON CONFLICT(kind, id) DO UPDATE SET payload = excluded.payload"
        with self._db:
            self._db.execute(upsert, ("meta", "main", dumps(meta)))
            for kind, key in (("visit", "visits"), ("trip", "trips"), ("city", "customCities"), ("photo", "attachments")):
                current = {row["id"]: row for row in journal[key]}
                before = {row["id"]: row for row in previous[key]} if previous is not None else {}
                self._db.executemany("DELETE FROM items WHERE kind = ? AND id = ?", ((kind, identifier) for identifier in before.keys() - current.keys()))
                self._db.executemany(upsert, ((kind, identifier, dumps(row)) for identifier, row in current.items() if row != before.get(identifier)))
        self._meta = meta

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
        "preferences": dict(FOOTPRINT_PREFERENCES),
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
    lifetime = int(train.get("lifetimeMaterials") or 0)
    gained = min(gained, max(0, 1_000_000 - lifetime))
    train["materials"] = int(train.get("materials") or 0) + gained
    train["lifetimeMaterials"] = lifetime + gained
    return gained


def compute_metrics(journal: dict, cities: dict, year=None, trip_id=None) -> dict:
    visits = journal["visits"]
    selected = [visit for visit in visits if (year is None or visit.get("date", {}).get("year") == year)
                and (trip_id is None or trip_id == visit.get("tripID"))]
    found = [cities[item] for item in {visit["cityID"] for visit in selected} if item in cities]
    countries = {city.get("countryID") for city in found if city.get("countryID") and city.get("countryID") != "ATA"}
    continents = {city.get("continent") for city in found if city.get("continent") not in {"", "南极洲", "其他", None}}
    by_city = defaultdict(list)
    by_country = defaultdict(list)
    for visit in visits:
        by_city[visit["cityID"]].append(visit)
        city = cities.get(visit["cityID"])
        if city:
            by_country[city["countryID"]].append(visit)
    first_visit_ids = {min(group, key=_visit_sort_key)["id"] for group in by_city.values()}

    def first_known_year(group):
        years = [visit.get("date", {}).get("year") for visit in group]
        return all(years) and (year is None or min(years) == year)

    return {
        "cities": len([city for city in found if city.get("countryID") != "ATA"]),
        "countries": len(countries),
        "china": sum(city.get("countryID") == "CHN" for city in found),
        "visits": len(selected),
        "trips": len({visit.get("tripID") for visit in selected if visit.get("tripID")}),
        "continents": len(continents),
        "newCities": sum(city.get("countryID") != "ATA" and first_known_year(by_city[city["id"]]) for city in found),
        "newCountries": sum(first_known_year(by_country[country]) for country in countries),
        "revisits": sum(visit["id"] not in first_visit_ids for visit in selected),
    }


def _visit_sort_key(visit: dict) -> tuple:
    components = visit.get("date") or {}
    return tuple(components.get(key) or 0 for key in ("year", "month", "day")) + (visit["createdAt"], visit["id"])


def search_cities(query: str, limit: int = 20, *, country=None, custom=(), include_empty=False) -> list[dict]:
    query = _search_key(query)
    if not query and not country and not include_empty:
        return []
    matches = [city for key, city in (*_search_index(), *((_city_search_key(city), city) for city in custom))
               if (country is None or city["countryID"] == country) and (not query or query in key)]

    def order(city):
        name = _search_key(city["name"])
        english = _search_key(city.get("english") or "")
        pinyin = _search_key(city.get("pinyin") or "")
        return (query not in {name, english, pinyin}, not any(value.startswith(query) for value in (name, english, pinyin)),
                city["countryID"] != "CHN", city["countryID"], pinyin or name)

    return sorted(matches, key=order)[:limit]


def _search_key(value: str) -> str:
    return "".join(char for char in unicodedata.normalize("NFKD", value).casefold()
                   if not unicodedata.combining(char) and not char.isspace())


def _city_search_key(city: dict) -> str:
    country = _countries().get(city["countryID"], {})
    keys = ("name", "english", "province", "aliases", "pinyin", "simplified")
    return "|".join(_search_key(value) for value in [*(city.get(key) or "" for key in keys),
                                                       country.get("name") or "", country.get("english") or ""])


@lru_cache(maxsize=1)
def _search_index():
    return tuple((_city_search_key(city), city) for city in load_cities()["cities"])


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


@lru_cache(maxsize=1)
def _countries() -> dict:
    return {country["id"]: country for country in load_cities()["countries"]}


def _journal_cities(journal: dict) -> dict:
    return {**_city_index(), **{city["id"]: city for city in journal["customCities"]}}


def _known_city(city_id: str | None, journal: dict) -> bool:
    if not city_id:
        return False
    if city_id in _city_index():
        return True
    return any(city["id"] == city_id for city in journal.get("customCities") or [])


def _validate_date(value: dict, now) -> None:
    if not isinstance(value, dict) or value.get("precision", "unknown") not in {"unknown", "year", "month", "day"}:
        raise AppError("日期精度无效。", "invalid")
    precision = value.get("precision") or "unknown"
    if precision == "unknown":
        if any(value.get(field) is not None for field in ("year", "month", "day")):
            raise AppError("未知日期不应包含年月日。", "invalid")
        return
    year = value.get("year")
    if type(year) is not int or year < 1 or year > now.year:
        raise AppError("年份无效或位于未来。", "invalid")
    if precision == "year":
        if value.get("month") is not None or value.get("day") is not None:
            raise AppError("仅年份的记录不能包含月日。", "invalid")
        return
    month = value.get("month")
    if type(month) is not int or not 1 <= month <= 12:
        raise AppError("月份必须为 1–12。", "invalid")
    if year == now.year and month > now.month:
        raise AppError("不能把未来的旅行标记为去过。", "invalid")
    if precision == "month":
        if value.get("day") is not None:
            raise AppError("仅月份的记录不能包含日。", "invalid")
        return
    day = value.get("day")
    if type(day) is not int:
        raise AppError("日期不存在。", "invalid")
    try:
        candidate = date(year, month, day)
    except ValueError as exc:
        raise AppError("日期不存在，请检查月份和天数。", "invalid") from exc
    if candidate > now.date():
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
        "aliases": city.get("aliases") or "",
        "countryID": city.get("countryID") or "",
        "provinceID": city.get("provinceID") or "",
        "province": city.get("province") or "",
        "continent": city.get("continent") or "",
        "longitude": float(city["longitude"]),
        "latitude": float(city["latitude"]),
        "isCustom": bool(city.get("isCustom")),
    }


def _distance(left: dict, right: dict) -> float:
    radians = math.pi / 180
    lat = (right["latitude"] - left["latitude"]) * radians
    lon = (right["longitude"] - left["longitude"]) * radians
    h = math.sin(lat / 2) ** 2 + math.cos(left["latitude"] * radians) * math.cos(right["latitude"] * radians) * math.sin(lon / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(min(1, max(0, h))))


def _visited_stations(journal):
    custom = {city["id"]: city for city in journal["customCities"]}
    result = {}
    for city_id in sorted({visit["cityID"] for visit in journal["visits"]}):
        city = custom.get(city_id) or city_by_id(city_id)
        if city and _valid_station(city):
            result[city_id] = _station(city)
    return result


def _prepare_train(journal):
    train = journal["train"]
    stations = _visited_stations(journal)
    current = train.get("currentStation") or {}
    journey = train.get("journey")
    if not current or (not journey and current["id"] not in stations and not train.get("cruiseCount")):
        current = (stations.get(train.get("routeCityID")) if train.get("cruiseCount") else None) or next(iter(stations.values()), None)
        if current:
            train["currentStation"] = current
        else:
            train.pop("currentStation", None)
    if journey and not journey.get("completed", False):
        return
    city_id = (current or {}).get("id")
    route = train.get("routeCityID")
    if route not in stations or route == city_id:
        train["routeCityID"] = next((identifier for identifier in stations if identifier != city_id), "")


def _arrive_train(train, now):
    journey = train.get("journey")
    if not journey or journey.get("completed") or cocoa(now) < journey["arrivesAt"]:
        return False
    journey["completed"] = True
    train["currentStation"] = journey["destination"]
    lifetime = int(train.get("lifetimeMaterials") or 0)
    gained = min(int(journey.get("reward") or 0), max(0, 1_000_000 - lifetime))
    train["materials"] = int(train.get("materials") or 0) + gained
    train["lifetimeMaterials"] = lifetime + gained
    train["cruiseCount"] = min(1_000_000, int(train.get("cruiseCount") or 0) + 1)
    return True


def _new_id():
    return str(uuid.uuid4()).upper()


def _image_extension(content):
    if content.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if content.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if content[:4] == b"RIFF" and content[8:12] == b"WEBP":
        return ".webp"
    if content[4:8] == b"ftyp":
        if content[8:12] in {b"heic", b"heix", b"hevc", b"hevx"}:
            return ".heic"
        if content[8:12] in {b"mif1", b"msf1"}:
            return ".heif"
    return None
