"""共同睡眠的 schema 1 SQLite 日志，与 macOS 使用同一 JSON 格式。"""

from __future__ import annotations

import json
import math
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from threading import RLock

from gaojiezou.errors import AppError
from gaojiezou.library import atomic_write, dumps
from gaojiezou.timeutil import cocoa

MIGRATION_KEY = "rhythm-library-v1"
SCHEMA_NOTE = "SharedSleep schema 1\n"
INTEGER_CREDITS = ("pastureYield", "healthProductionCreditedCycles", "manualProductionCreditedCycles")
DURATION_CREDITS = ("healthGrowthCreditedSeconds", "manualGrowthCreditedSeconds")
SOURCE_FIELDS = ("healthSource", "manualEntry", "origin")


class SharedSleep:
    def __init__(self, directory: Path, clock=None):
        self.directory = directory
        self.path = directory / "sleep-records.sqlite"
        self.initialized = directory / ".initialized"
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self._db: sqlite3.Connection | None = None
        self._identity = None
        self._lock = RLock()

    @property
    def available(self) -> bool:
        try:
            return not self.path.is_symlink() and self.path.is_file() and self.path.stat().st_size > 0
        except OSError:
            return False

    @property
    def is_open(self) -> bool:
        with self._lock:
            return self._db is not None

    def create_fresh(self) -> None:
        with self._lock:
            if any(path.exists() or path.is_symlink() for path in (
                self.path, self.initialized, self.path.with_suffix(".sqlite-wal"), self.path.with_suffix(".sqlite-shm"),
            )):
                raise AppError("共享睡眠库已有痕迹，未新建空库。", "protected")
            self.directory.mkdir(parents=True, exist_ok=True)
            try:
                self.path.touch(exist_ok=False)
                self._connect()
                self._db.execute("PRAGMA journal_mode=WAL")
                self._db.executescript(
                    """
                    BEGIN IMMEDIATE;
                    CREATE TABLE sleep_metadata(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL);
                    INSERT INTO sleep_metadata(id, version) VALUES (1, 1);
                    CREATE TABLE sleep_records(
                        id TEXT PRIMARY KEY NOT NULL,
                        payload BLOB,
                        deleted INTEGER NOT NULL CHECK(deleted IN (0, 1)),
                        CHECK(deleted=1 OR payload IS NOT NULL)
                    );
                    CREATE TABLE sleep_migrations(key TEXT PRIMARY KEY NOT NULL);
                    PRAGMA user_version = 1;
                    """
                )
                self._db.execute("INSERT INTO sleep_migrations(key) VALUES (?)", (MIGRATION_KEY,))
                self._db.commit()
                atomic_write(self.initialized, SCHEMA_NOTE.encode("utf-8"))
            except (OSError, sqlite3.DatabaseError) as exc:
                self.close()
                raise AppError("无法新建共享睡眠库，未覆盖已有资料。", "protected") from exc

    def open_existing(self) -> None:
        with self._lock:
            self.close()
            if not self.available:
                raise AppError("共享睡眠权威缺失或不可读，未新建空库。", "protected")
            try:
                self._connect()
                if self._db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                    raise AppError("共享睡眠库完整性检查未通过。", "protected")
                version = self._db.execute("PRAGMA user_version").fetchone()[0]
                metadata = self._db.execute("SELECT version FROM sleep_metadata WHERE id=1").fetchone()
                if version != 1 or metadata is None or metadata[0] != 1:
                    raise AppError("共享睡眠库版本或元数据无效。", "protected")
                self._rows()
                self._require_migration()
            except (OSError, sqlite3.DatabaseError) as exc:
                self.close()
                raise AppError("共享睡眠库无法读取，原资料已保留。", "protected") from exc
            except AppError:
                self.close()
                raise

    def migration_present(self) -> bool:
        with self._lock:
            if self._db is None:
                return False
            self._verify_identity()
            try:
                return self._db.execute("SELECT 1 FROM sleep_migrations WHERE key=?", (MIGRATION_KEY,)).fetchone() is not None
            except sqlite3.DatabaseError as exc:
                raise AppError("共享睡眠历史迁移凭据不可读。", "protected") from exc

    def close(self) -> None:
        with self._lock:
            if self._db is not None:
                self._db.close()
                self._db = None
                self._identity = None

    def entries(self) -> list[dict]:
        with self._lock:
            self._verify_identity()
            self._require_migration()
            try:
                return [
                    {"id": record_id, "deleted": True} if entry is None else {**entry, "deleted": False}
                    for record_id, entry in self._rows().items()
                ]
            except sqlite3.DatabaseError as exc:
                raise AppError("共享睡眠记录无法读取。", "protected") from exc

    def live(self) -> list[dict]:
        rows = [row for row in self.entries() if not row.pop("deleted")]
        return sorted(rows, key=lambda row: (-float(row["endedAt"]), row["id"]))

    def upsert(self, entry: dict) -> None:
        self._validate(entry, prevent_future=True)
        entry = {key: value for key, value in entry.items() if key != "deleted"}
        with self._transaction():
            rows = self._rows()
            if entry["id"] in rows:
                existing = rows[entry["id"]]
                if existing is None:
                    raise AppError("这条睡眠已删除，请刷新列表。", "tombstone")
                entry = merge_credits(existing, entry)
                for key in SOURCE_FIELDS:
                    if entry.get(key) is None and existing.get(key) is not None:
                        entry[key] = existing[key]
                if entry == existing:
                    return
            elif any(_near(row, entry) for row in rows.values() if row is not None):
                raise AppError("已有起止时间相近的睡眠记录。", "duplicate")
            self._write_live(entry)

    def update_settlement(self, entry: dict) -> None:
        self._validate(entry)
        with self._transaction():
            rows = self._rows()
            if entry["id"] not in rows:
                raise AppError("未找到这条睡眠记录，请刷新列表。", "missing")
            existing = rows[entry["id"]]
            if existing is None:
                raise AppError("这条睡眠已删除，请刷新列表。", "tombstone")
            updated = merge_credits(entry, existing)
            if updated != existing:
                self._write_live(updated)

    def reconcile_pending(self, entry: dict, settlement: dict) -> None:
        self._validate(entry)
        self._validate(settlement)
        if entry["id"] != settlement["id"]:
            raise AppError("待同步记录和结算的标识必须相同。", "invalid")
        with self._transaction():
            rows = self._rows()
            if entry["id"] in rows:
                return
            for existing in sorted((row for row in rows.values() if row is not None), key=lambda row: row["id"]):
                if _near(existing, entry):
                    updated = merge_credits(settlement, existing)
                    if updated != existing:
                        self._write_live(updated)
                    self._write_tombstone(entry["id"])
                    return
            self._validate(entry, prevent_future=True)
            self._write_live(entry)

    def remove(self, record_id: str) -> None:
        if not _valid_id(record_id):
            raise AppError("睡眠记录标识无效。", "invalid")
        with self._transaction():
            rows = self._rows()
            if record_id not in rows or rows[record_id] is not None:
                self._write_tombstone(record_id)

    def _connect(self) -> None:
        stat = self.path.stat()
        self._identity = (stat.st_dev, stat.st_ino)
        self._db = sqlite3.connect(self.path.resolve().as_uri() + "?mode=rw", uri=True, timeout=10, check_same_thread=False)
        self._db.execute("PRAGMA synchronous=FULL")

    def _verify_identity(self) -> None:
        if self._db is None:
            raise AppError("共享睡眠库未打开。", "missing")
        try:
            stat = self.path.stat()
            if self.available and (stat.st_dev, stat.st_ino) == self._identity:
                return
        except OSError:
            pass
        raise AppError("共享睡眠权威已更改或不可读，原资料已保留。", "protected")

    def _require_migration(self) -> None:
        if not self.migration_present():
            raise AppError("共享睡眠缺少一次性迁移凭据，已停止同步。", "protected")

    @contextmanager
    def _transaction(self):
        with self._lock:
            self._verify_identity()
            try:
                self._db.execute("BEGIN IMMEDIATE")
                with self._db:
                    self._verify_identity()
                    self._require_migration()
                    yield
            except sqlite3.DatabaseError as exc:
                raise AppError("共享睡眠数据库操作失败，原记录已保留。", "protected") from exc

    def _rows(self) -> dict[str, dict | None]:
        rows = {}
        for record_id, payload, deleted in self._db.execute("SELECT id,payload,deleted FROM sleep_records"):
            try:
                if not _valid_id(record_id) or type(deleted) is not int or deleted not in (0, 1) or record_id in rows:
                    raise ValueError("sleep identity")
                if deleted:
                    rows[record_id] = None
                    continue
                if not isinstance(payload, bytes):
                    raise ValueError("sleep payload")
                entry = json.loads(payload)
                if not isinstance(entry, dict) or entry.get("id") != record_id:
                    raise ValueError("sleep payload identity")
                entry.pop("deleted", None)
                self._validate(entry)
                rows[record_id] = entry
            except (AppError, ValueError, UnicodeError) as exc:
                raise AppError("共享睡眠记录损坏，已停止同步。", "protected") from exc
        return rows

    def _write_live(self, entry: dict) -> None:
        self._db.execute(
            "INSERT INTO sleep_records(id, payload, deleted) VALUES (?, ?, 0) "
            "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, deleted=0",
            (entry["id"], dumps(entry)),
        )

    def _write_tombstone(self, record_id: str) -> None:
        self._db.execute(
            "INSERT INTO sleep_records(id, payload, deleted) VALUES (?, NULL, 1) "
            "ON CONFLICT(id) DO UPDATE SET payload=NULL, deleted=1",
            (record_id,),
        )

    def _validate(self, entry: dict, prevent_future: bool = False) -> None:
        try:
            if not _valid_id(entry["id"]):
                raise ValueError("sleep identity")
            start, end, duration = (entry[key] for key in ("startedAt", "endedAt", "durationSeconds"))
            if not all(_number(item) for item in (start, end, duration)) or end < start or duration < 0:
                raise ValueError("sleep dates")
            if not _integer(entry["score"]) or not 0 <= entry["score"] <= 100 or not _integer(entry["pastureYield"]):
                raise ValueError("sleep score or yield")
            for key in INTEGER_CREDITS:
                value = entry.get(key)
                if value is not None and (not _integer(value) or value < 0):
                    raise ValueError("sleep credit")
            for key in DURATION_CREDITS:
                value = entry.get(key)
                if value is not None and (not _number(value) or value < 0):
                    raise ValueError("sleep credit")
            if any(entry.get(key) is not None and not isinstance(entry[key], str) for key in ("healthSource", "origin")):
                raise ValueError("sleep source")
            if entry.get("manualEntry") is not None and type(entry["manualEntry"]) is not bool:
                raise ValueError("sleep source")
            if prevent_future and end > cocoa(self.clock()) + 1:
                raise ValueError("future sleep")
        except (KeyError, TypeError, ValueError, OverflowError) as exc:
            raise AppError("睡眠记录的标识、时间、评分或结算字段无效。", "invalid") from exc


def _valid_id(value) -> bool:
    return isinstance(value, str) and bool(value.strip()) and "\x00" not in value


def _number(value) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def _integer(value) -> bool:
    # Older Windows builds serialized merged counters as integer-valued floats.
    return _number(value) and int(value) == value and -(2 ** 63) <= value < 2 ** 63


def _near(left: dict, right: dict) -> bool:
    return abs(left["startedAt"] - right["startedAt"]) <= 60 and abs(left["endedAt"] - right["endedAt"]) <= 60


def merge_credits(source: dict, target: dict) -> dict:
    merged = dict(target)
    for key in INTEGER_CREDITS + DURATION_CREDITS:
        values = [row[key] for row in (target, source) if row.get(key) is not None]
        if values:
            maximum = max(values)
            merged[key] = int(maximum) if key in INTEGER_CREDITS else maximum
    return merged
