"""共享睡眠 SQLite。协议与 Mac SharedSleepStore schema 1 相同。

墓碑不可复活。起止时间相差不超过 60 秒视为重复。
迁移键 rhythm-library-v1 已存在时不再全量导入。
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from gaojiezou.errors import AppError
from gaojiezou.library import atomic_write, dumps

MIGRATION_KEY = "rhythm-library-v1"
SCHEMA_NOTE = "SharedSleep schema 1\n"


class SharedSleep:
    def __init__(self, directory: Path):
        self.directory = directory
        self.path = directory / "sleep-records.sqlite"
        self.initialized = directory / ".initialized"
        self._db: sqlite3.Connection | None = None

    @property
    def available(self) -> bool:
        return self.path.exists() and self.path.stat().st_size > 0

    def create_fresh(self) -> None:
        if self.path.exists() or self.initialized.exists():
            raise AppError("共享睡眠库已有痕迹，未新建空库。", "protected")
        self.directory.mkdir(parents=True, exist_ok=True)
        self._open_new()
        self._db.execute("INSERT INTO sleep_migrations(key) VALUES (?)", (MIGRATION_KEY,))
        self._db.commit()
        atomic_write(self.initialized, SCHEMA_NOTE.encode("utf-8"))

    def open_existing(self) -> None:
        if not self.available:
            if self.initialized.exists() or _wal_without_db(self.directory):
                raise AppError("共享睡眠库缺失或为空，未新建空库。", "protected")
            raise AppError("共享睡眠库不存在，未新建空库。", "missing")
        self._db = sqlite3.connect(self.path)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA query_only = OFF")
        quick = self._db.execute("PRAGMA quick_check").fetchone()[0]
        if quick != "ok":
            raise AppError("共享睡眠库完整性检查未通过，未写入。", "protected")
        version = self._db.execute("PRAGMA user_version").fetchone()[0]
        if version != 1:
            raise AppError("共享睡眠库版本不受支持，未写入。", "protected")
        row = self._db.execute("SELECT version FROM sleep_metadata WHERE id=1").fetchone()
        if row is None or row["version"] != 1:
            raise AppError("共享睡眠元数据无效，未写入。", "protected")

    def migration_present(self) -> bool:
        if self._db is None:
            return False
        row = self._db.execute(
            "SELECT 1 FROM sleep_migrations WHERE key=?", (MIGRATION_KEY,)
        ).fetchone()
        return row is not None

    def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None

    def entries(self) -> list[dict]:
        rows = self._db.execute("SELECT id, payload, deleted FROM sleep_records").fetchall()
        result = []
        for row in rows:
            if row["deleted"]:
                result.append({"id": row["id"], "deleted": True})
                continue
            payload = json.loads(row["payload"])
            payload["deleted"] = False
            result.append(payload)
        return result

    def live(self) -> list[dict]:
        return [row for row in self.entries() if not row.get("deleted")]

    def upsert(self, entry: dict) -> None:
        self._require()
        if not self.migration_present():
            raise AppError("共享睡眠尚未完成一次性迁移标记，已停止同步，未全量导入。", "protected")
        self._validate(entry)
        existing = self._db.execute(
            "SELECT id, payload, deleted FROM sleep_records WHERE id=?", (entry["id"],)
        ).fetchone()
        if existing is not None:
            if existing["deleted"]:
                raise AppError("这条睡眠已删除，不能用旧记录复活。", "tombstone")
            merged = _merge_credits(json.loads(existing["payload"]), entry)
            self._write_live(merged)
            return
        for row in self.live():
            if _near(row, entry):
                raise AppError("已有起止时间相近的睡眠记录。", "duplicate")
        self._write_live(entry)

    def remove(self, record_id: str) -> None:
        self._require()
        self._db.execute(
            "INSERT INTO sleep_records(id, payload, deleted) VALUES (?, NULL, 1) "
            "ON CONFLICT(id) DO UPDATE SET payload=NULL, deleted=1",
            (record_id,),
        )
        self._db.commit()

    def _write_live(self, entry: dict) -> None:
        payload = dumps(entry)
        self._db.execute(
            "INSERT INTO sleep_records(id, payload, deleted) VALUES (?, ?, 0) "
            "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, deleted=0",
            (entry["id"], payload),
        )
        self._db.commit()

    def _require(self) -> None:
        if self._db is None:
            raise AppError("共享睡眠库未打开。", "missing")

    def _validate(self, entry: dict) -> None:
        if not entry.get("id") or "\x00" in str(entry["id"]):
            raise AppError("睡眠记录标识无效。", "invalid")
        start = float(entry["startedAt"])
        end = float(entry["endedAt"])
        if end < start or float(entry["durationSeconds"]) < 0:
            raise AppError("睡眠起止时间无效。", "invalid")
        score = int(entry["score"])
        if not 0 <= score <= 100 or int(entry.get("pastureYield") or 0) < 0:
            raise AppError("睡眠评分或牧场产量无效。", "invalid")

    def _open_new(self) -> None:
        self._db = sqlite3.connect(self.path)
        self._db.row_factory = sqlite3.Row
        self._db.executescript(
            """
            PRAGMA user_version = 1;
            CREATE TABLE sleep_metadata (
                id INTEGER PRIMARY KEY CHECK(id=1),
                version INTEGER NOT NULL
            );
            INSERT INTO sleep_metadata(id, version) VALUES (1, 1);
            CREATE TABLE sleep_records (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB,
                deleted INTEGER NOT NULL CHECK(deleted IN (0, 1)),
                CHECK(deleted=1 OR payload IS NOT NULL)
            );
            CREATE TABLE sleep_migrations (
                key TEXT PRIMARY KEY NOT NULL
            );
            """
        )
        self._db.commit()


def _near(left: dict, right: dict) -> bool:
    return (
        abs(float(left["startedAt"]) - float(right["startedAt"])) <= 60
        and abs(float(left["endedAt"]) - float(right["endedAt"])) <= 60
    )


def _merge_credits(current: dict, incoming: dict) -> dict:
    merged = dict(current)
    for key in (
        "pastureYield",
        "healthGrowthCreditedSeconds",
        "healthProductionCreditedCycles",
        "manualGrowthCreditedSeconds",
        "manualProductionCreditedCycles",
    ):
        if key in current or key in incoming:
            merged[key] = max(float(current.get(key) or 0), float(incoming.get(key) or 0))
    return merged


def _wal_without_db(directory: Path) -> bool:
    return (directory / "sleep-records.sqlite-wal").exists() and not (directory / "sleep-records.sqlite").exists()
