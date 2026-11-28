"""节奏资料门面：专注、睡眠、打卡、目标、庄园，以及健康和足迹的打开方式。"""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from gaojiezou import catalog, library
from gaojiezou.errors import AppError
from gaojiezou.footprints import FootprintStore
from gaojiezou.health import HealthStore
from gaojiezou.sleepstore import SharedSleep, merge_credits
from gaojiezou.timeutil import add_days, cocoa, day_key, from_cocoa, in_zone, start_of_day, swift_weekday
from gaojiezou.version import MARKETING_VERSION, VERSION_LABEL, WINDOWS_BUILD

AUTHORITY = {
    "schemaVersion": 1,
    "state": "active",
    "modulePaths": {"health": "Modules/Health", "footprints": "Modules/Footprints"},
    "sharedSleepPath": "SharedSleep",
}
FISH_BITE_DURATION = 5.0


class RhythmStore:
    def __init__(self, directory: Path, tz=None, clock=None):
        self.directory = Path(directory)
        self.review_timezone = tz  # None asks the local calendar for each historical offset.
        self.tz = tz or datetime.now().astimezone().tzinfo
        self.clock = clock or (lambda: datetime.now(self.tz))
        self.library: dict | None = None
        self.status = "missing"
        self.notice = ""
        self.settings = {
            "sleepTargetHours": 8,
            "appearance": "system",
            "language": "zh-Hans",
            "habitReminderHour": 21,
            "habitReminderMinute": 0,
            "habitReminderEnabled": False,
            "backgroundHex": "",
        }
        self.settings_source = {}
        self.settings_protected = False
        self.sleep = SharedSleep(self.directory / "Integration" / "SharedSleep", self.now)
        self.sleep_sync_error = ""
        self._sleep_authority_token = None
        self.shared_sleep_records: list[dict] = []
        self.health = HealthStore(self.directory / "Integration" / "Modules" / "Health", self.tz)
        self.footprints = FootprintStore(self.directory / "Integration" / "Modules" / "Footprints")
        self.cast: dict | None = None
        self._load()

    def now(self) -> datetime:
        current = self.clock()
        if current.tzinfo is None:
            current = current.replace(tzinfo=self.tz)
        return current.astimezone(self.tz)

    def create_library(self) -> None:
        if (self.directory / library.LIBRARY_NAME).exists() or (self.directory / library.READ_ONLY_MARKER).exists():
            raise AppError("资料库已存在或处于只读保护，未新建。", "protected")
        if not library.is_blank_directory(self.directory):
            raise AppError("资料目录不是空的，未用空白库覆盖。", "protected")
        self.library = library.starter(self.now())
        self.status = "ready"
        self._write_authority_and_modules(self.now())
        self.save()

    def save(self) -> None:
        if self.status != "ready" or self.library is None:
            raise AppError("资料未打开或处于只读保护，未写入。", "protected")
        library.save_document(self.directory, self.library)
        self._write_settings()
        self._write_widget_snapshot()

    def prepare_for_exit(self) -> None:
        if self.status != "ready" or self.library is None:
            return
        if (self.library.get("activeFocus") or {}).get("segmentStartedAt") is not None:
            self.pause_focus(for_system=False)
        else:
            self.synchronize(self.now())
            self.save()

    # —— 打卡 ——

    def toggle_habit(self, habit_id: str, on: datetime | None = None) -> bool:
        self._ready()
        moment = on.astimezone(self.tz) if on else self.now()
        if start_of_day(moment, self.tz) > start_of_day(self.now(), self.tz):
            raise AppError("不能给未来的日期打卡。", "invalid")
        habit = self._habit(habit_id)
        if not _scheduled(habit, moment, self.tz):
            raise AppError("这一天没有安排这项打卡。", "invalid")
        key = _habit_key(habit_id, moment, self.tz)
        completions = self.library["habitCompletionKeys"]
        rewards = self.library["habitRewardKeys"]
        if key in completions:
            completions.remove(key)
        else:
            completions.append(key)
            if key not in rewards:
                rewards.append(key)
                coins = int(habit["rewardCoins"])
                self.library["coins"] += coins
                self._reward("补打日常打卡" if start_of_day(moment, self.tz) < start_of_day(self.now(), self.tz) else "完成日常打卡",
                             f"获得 {coins} 金币。", coins, habit.get("symbol") or "checkmark")
        self.save()
        return key in self.library["habitCompletionKeys"]

    def save_habit(self, payload: dict) -> dict:
        self._ready()
        title = str(payload.get("title") or "").strip()
        if not title:
            raise AppError("打卡名称不能为空。", "invalid")
        weekdays = sorted({int(day) for day in payload.get("weekdays") or [] if 1 <= int(day) <= 7}) or [1, 2, 3, 4, 5, 6, 7]
        coins = min(catalog.HABIT_REWARD_MAX, max(catalog.HABIT_REWARD_MIN, int(payload.get("rewardCoins") or 1)))
        existing = payload.get("id")
        if existing:
            habit = self._habit(existing)
            habit["title"] = title
            habit["symbol"] = payload.get("symbol") or habit.get("symbol") or "checkmark"
            habit["weekdays"] = weekdays
            habit["rewardCoins"] = coins
        else:
            habit = {
                "id": _uuid(),
                "title": title,
                "symbol": payload.get("symbol") or "checkmark",
                "weekdays": weekdays,
                "rewardCoins": coins,
                "createdAt": cocoa(self.now()),
            }
            self.library["habits"].append(habit)
        self.save()
        return habit

    def delete_habit(self, habit_id: str) -> None:
        self._ready()
        self.library["habits"] = [row for row in self.library["habits"] if row["id"] != habit_id]
        self.save()

    # —— 专注 ——

    def start_focus(self, linked_action_id: str | None = None) -> dict:
        self._ready()
        if self.library.get("activeFocus") or self.library.get("activeSleep"):
            raise AppError("同一时间只能运行一个专注或睡眠计时。", "busy")
        action = self._action(linked_action_id) if linked_action_id else None
        moment = self.now()
        focus = {
            "id": _uuid(),
            "title": action["title"] if action else "其他事件",
            "startedAt": cocoa(moment),
            "accumulatedSeconds": 0,
            "segmentStartedAt": cocoa(moment),
            "pausedForSystem": False,
            "growthCreditedSeconds": 0,
        }
        if action:
            focus["linkedActionID"] = action["id"]
        self.library["activeFocus"] = focus
        self.save()
        return focus

    def pause_focus(self, for_system: bool = False) -> None:
        self._ready()
        moment = self.now()
        self.synchronize(moment)
        focus = self.library.get("activeFocus")
        if not focus or focus.get("segmentStartedAt") is None:
            return
        segment = max(0, moment.timestamp() - from_cocoa(focus["segmentStartedAt"]).timestamp())
        focus["accumulatedSeconds"] = float(focus.get("accumulatedSeconds") or 0) + min(segment, catalog.MAX_FOCUS_DELTA_SECONDS)
        focus["segmentStartedAt"] = None
        focus["pausedForSystem"] = bool(for_system)
        focus["growthCreditedSeconds"] = focus["accumulatedSeconds"]
        self.save()

    def resume_focus(self) -> None:
        self._ready()
        focus = self.library.get("activeFocus")
        if not focus or focus.get("segmentStartedAt") is not None or self.library.get("activeSleep"):
            raise AppError("当前不能继续专注。", "busy")
        focus["segmentStartedAt"] = cocoa(self.now())
        focus["pausedForSystem"] = False
        self.save()

    def finish_focus(self) -> dict:
        self._ready()
        moment = self.now()
        self.synchronize(moment)
        focus = self.library.get("activeFocus")
        if not focus:
            raise AppError("没有进行中的专注。", "invalid")
        duration = self.focus_elapsed(moment)
        earned = min(catalog.FOCUS_SESSION_COIN_CAP, int(duration / (catalog.FOCUS_MINUTES_PER_COIN * 60)))
        record = {
            "id": focus["id"],
            "title": focus.get("title") or "其他事件",
            "startedAt": focus["startedAt"],
            "endedAt": cocoa(moment),
            "durationSeconds": duration,
            "earnedCoins": earned,
        }
        if focus.get("linkedActionID"):
            record["linkedActionID"] = focus["linkedActionID"]
            action = self._action(focus["linkedActionID"])
            if action:
                action["focusedSeconds"] = float(action.get("focusedSeconds") or 0) + duration
        self.library["focusRecords"].insert(0, record)
        self.library["activeFocus"] = None
        if duration > 0:
            for plot in self.library["farmPlots"]:
                if plot.get("cropID"):
                    plot["nextFocusBoost"] = 0
        self.library["coins"] += earned
        self._reward("完成专注", f"有效专注 {int(duration // 60)} 分钟。", earned, "timer")
        self.save()
        return record

    def cancel_focus(self) -> None:
        self._ready()
        self.synchronize(self.now())
        focus = self.library.get("activeFocus") or {}
        if float(focus.get("growthCreditedSeconds") or 0) > 0:
            for plot in self.library["farmPlots"]:
                if plot.get("cropID"):
                    plot["nextFocusBoost"] = 0
        self.library["activeFocus"] = None
        self.save()

    def focus_elapsed(self, moment: datetime | None = None) -> float:
        focus = (self.library or {}).get("activeFocus")
        if not focus:
            return 0
        moment = moment or self.now()
        running = 0
        if focus.get("segmentStartedAt") is not None:
            running = max(0, moment.timestamp() - from_cocoa(focus["segmentStartedAt"]).timestamp())
        return float(focus.get("accumulatedSeconds") or 0) + running

    def synchronize(self, moment: datetime | None = None) -> None:
        if self.library is None:
            return
        moment = moment or self.now()
        focus = self.library.get("activeFocus")
        if focus:
            elapsed = self.focus_elapsed(moment)
            credited = max(0, float(focus.get("growthCreditedSeconds") or 0))
            delta = min(catalog.MAX_FOCUS_DELTA_SECONDS, max(0, elapsed - credited))
            if delta > 0:
                for plot in self.library["farmPlots"]:
                    spec = catalog.crop(plot.get("cropID"))
                    if not spec:
                        continue
                    growth = (delta / 60) * (1 + float(plot.get("nextFocusBoost") or 0))
                    plot["growthMinutes"] = min(spec[3], float(plot.get("growthMinutes") or 0) + growth)
                focus["growthCreditedSeconds"] = elapsed
        sleep = self.library.get("activeSleep")
        if sleep:
            elapsed = max(0, moment.timestamp() - from_cocoa(sleep["startedAt"]).timestamp())
            self._settle_sleep_progress(sleep, elapsed, float(sleep.get("targetHours") or self.settings["sleepTargetHours"]), manual=False)

    # —— 睡眠 ——

    def start_sleep(self, target_hours: float | None = None) -> dict:
        self._ready()
        if self.library.get("activeFocus") or self.library.get("activeSleep"):
            raise AppError("同一时间只能运行一个专注或睡眠计时。", "busy")
        moment = self.now()
        target = self._sleep_target(target_hours)
        sleep = {
            "id": _uuid(),
            "startedAt": cocoa(moment),
            "targetHours": target,
            "growthCreditedSeconds": 0,
            "productionCyclesCredited": 0,
            "pastureYieldCredited": 0,
        }
        self.library["activeSleep"] = sleep
        self.save()
        return sleep

    def finish_sleep(self) -> dict:
        self._ready()
        moment = self.now()
        self.synchronize_sleep_records(moment)
        sleep = self.library.get("activeSleep")
        if not sleep:
            raise AppError("没有进行中的睡眠。", "invalid")
        if cocoa(moment) < sleep["startedAt"]:
            raise AppError("结束时间不能早于睡眠开始时间。", "invalid")
        before = json.loads(json.dumps(self.library))
        self.synchronize(moment)
        duration = cocoa(moment) - sleep["startedAt"]
        target = max(1.0, float(sleep.get("targetHours") or 8))
        hours = duration / 3600
        score = max(0, min(100, int(100 - abs(hours - target) * 18)))
        record = {
            "id": sleep["id"],
            "startedAt": sleep["startedAt"],
            "endedAt": cocoa(moment),
            "durationSeconds": duration,
            "score": score,
            "pastureYield": int(sleep.get("pastureYieldCredited") or 0),
            "origin": "rhythm",
        }
        self.library["sleepRecords"].insert(0, record)
        self.library["sleepRecords"].sort(key=lambda row: float(row["endedAt"]), reverse=True)
        self.library["activeSleep"] = None
        self._reward("结束睡眠计时", f"评分 {score}。", 0, "moon.stars.fill")
        self._save_completed_sleep(record, before, moment)
        return record

    def cancel_sleep(self) -> None:
        self._ready()
        self.synchronize(self.now())
        self.library["activeSleep"] = None
        self.save()

    def add_manual_sleep(self, start: datetime, end: datetime, target_hours: float | None = None) -> dict:
        self._ready()
        moment = self.now()
        target = self._sleep_target(target_hours)
        record = self._manual_sleep_record(start, end, target, moment, "rhythm")
        self.synchronize_sleep_records(moment)
        for row in self.library["sleepRecords"]:
            if abs(row["startedAt"] - record["startedAt"]) <= 60 and abs(row["endedAt"] - record["endedAt"]) <= 60:
                raise AppError("已有起止时间相近的睡眠记录。", "duplicate")
        before = json.loads(json.dumps(self.library))
        self.library["sleepRecords"].append(record)
        self.library["sleepRecords"].sort(key=lambda row: (-row["endedAt"], row["id"]))
        self._settle_manual(record["id"], target)
        self._reward("手动录入睡眠记录", f"牧场产物 {record['pastureYield']}。", 0, "moon.stars.fill")
        self._save_completed_sleep(record, before, moment)
        return record

    def add_health_sleep(self, start: datetime, end: datetime) -> dict:
        self._ready()
        moment = self.now()
        record = self._manual_sleep_record(start, end, 8, moment, "health")
        self._require_sleep_authority()
        self.sleep.upsert(record)
        self.synchronize_sleep_records(moment)
        return next((row for row in self.shared_sleep_records if row["id"] == record["id"]), record)

    def _manual_sleep_record(self, start: datetime, end: datetime, target: float, moment: datetime, origin: str) -> dict:
        started_at, ended_at = cocoa(start), cocoa(end)
        if ended_at <= started_at or ended_at > cocoa(moment):
            raise AppError("起床时间必须晚于就寝，且不能晚于现在。", "invalid")
        duration = ended_at - started_at
        if not 1800 <= duration <= 86400:
            raise AppError("睡眠时长须在 0.5 到 24 小时之间。", "invalid")
        return {
            "id": _uuid(),
            "startedAt": started_at,
            "endedAt": ended_at,
            "durationSeconds": duration,
            "score": max(0, min(100, int(100 - abs(duration / 3600 - target) * 18))),
            "pastureYield": 0,
            "manualEntry": True,
            "manualGrowthCreditedSeconds": 0,
            "manualProductionCreditedCycles": 0,
            "origin": origin,
        }

    def _sleep_target(self, target_hours: float | None) -> float:
        try:
            target = float(self.settings["sleepTargetHours"] if target_hours is None else target_hours)
            if math.isfinite(target) and target > 0:
                return max(1, target)
        except (TypeError, ValueError, OverflowError):
            pass
        raise AppError("睡眠目标必须为正数。", "invalid")

    def _save_completed_sleep(self, record: dict, before: dict, moment: datetime) -> None:
        try:
            self.save()
        except (AppError, OSError):
            self.library = before
            raise
        try:
            self._require_sleep_authority()
            self.sleep.upsert(record)
        except AppError as exc:
            if exc.code == "duplicate":
                self.library = before
                self.save()
                raise
            self.sleep_sync_error = f"睡眠已在本机保存，共同睡眠同步将重试。{exc.message}"
            return
        self.synchronize_sleep_records(moment)

    def delete_sleep(self, record_id: str) -> None:
        self._ready()
        self._require_sleep_authority()
        self.sleep.remove(record_id)
        self.synchronize_sleep_records()

    # —— 琐事与目标 ——

    def save_chore(self, payload: dict) -> dict:
        self._ready()
        title = str(payload.get("title") or "").strip()
        if not title:
            raise AppError("琐事标题不能为空。", "invalid")
        start = _as_cocoa(payload.get("startDate"), self.now(), self.tz)
        end = _as_cocoa(payload.get("endDate"), self.now(), self.tz)
        if end < start:
            raise AppError("结束日期不能早于开始日期。", "invalid")
        existing = payload.get("id")
        if existing:
            chore = self._chore(existing)
            chore["title"] = title
            chore["startDate"] = start
            chore["endDate"] = end
            if payload.get("colorHex"):
                chore["colorHex"] = payload["colorHex"]
        else:
            chore = {
                "id": _uuid(),
                "title": title,
                "startDate": start,
                "endDate": end,
                "isCompleted": False,
                "rewardClaimed": False,
                "createdAt": cocoa(self.now()),
                "colorHex": payload.get("colorHex") or catalog.CHORE_COLORS[len(self.library["chores"]) % len(catalog.CHORE_COLORS)],
            }
            self.library["chores"].append(chore)
        self.save()
        return chore

    def toggle_chore(self, chore_id: str) -> dict:
        self._ready()
        chore = self._chore(chore_id)
        chore["isCompleted"] = not bool(chore.get("isCompleted"))
        chore["completedAt"] = cocoa(self.now()) if chore["isCompleted"] else None
        if chore["isCompleted"] and not chore.get("rewardClaimed"):
            chore["rewardClaimed"] = True
            self.library["coins"] += catalog.CHORE_COINS
            self._reward("完成琐事", f"获得 {catalog.CHORE_COINS} 金币。", catalog.CHORE_COINS, "checklist")
        self.save()
        return chore

    def delete_chore(self, chore_id: str) -> None:
        self._ready()
        self._chore(chore_id)
        self.library["chores"] = [row for row in self.library["chores"] if row["id"] != chore_id]
        self.save()

    def save_goal(self, payload: dict) -> dict:
        self._ready()
        title = str(payload.get("title") or "").strip()
        if not title:
            raise AppError("目标标题不能为空。", "invalid")
        status = payload.get("status") or "active"
        if status not in {"planned", "active", "paused", "completed"}:
            raise AppError("目标状态无效。", "invalid")
        start = _as_cocoa(payload.get("startDate"), self.now(), self.tz)
        target = max(start, _as_cocoa(payload.get("targetDate"), self.now(), self.tz))
        existing = payload.get("id")
        if existing:
            goal = self._goal(existing)
            old = goal.get("status")
            goal.update({
                "title": title,
                "reason": payload.get("reason") or "",
                "outcome": payload.get("outcome") or "",
                "targetValue": max(0, float(payload.get("targetValue") or 0)),
                "currentValue": max(0, float(payload.get("currentValue") or 0)),
                "unit": payload.get("unit") or "",
                "startDate": start,
                "targetDate": target,
                "status": status,
            })
            if status == "completed" and old != "completed":
                goal["completedAt"] = cocoa(self.now())
                self._claim_goal(goal)
            elif status != "completed":
                goal.pop("completedAt", None)
        else:
            goal = {
                "id": _uuid(),
                "title": title,
                "reason": payload.get("reason") or "",
                "outcome": payload.get("outcome") or "",
                "targetValue": max(0, float(payload.get("targetValue") or 0)),
                "currentValue": max(0, float(payload.get("currentValue") or 0)),
                "unit": payload.get("unit") or "",
                "startDate": start,
                "targetDate": target,
                "status": status,
                "rewardClaimed": False,
                "createdAt": cocoa(self.now()),
            }
            self.library["longGoals"].append(goal)
            if status == "completed":
                goal["completedAt"] = cocoa(self.now())
                self._claim_goal(goal)
        self.save()
        return goal

    def delete_goal(self, goal_id: str) -> None:
        self._ready()
        self._goal(goal_id)
        self.library["longGoals"] = [row for row in self.library["longGoals"] if row["id"] != goal_id]
        for action in self.library["shortActions"]:
            if action.get("goalID") == goal_id:
                action.pop("goalID", None)
        self.save()

    def save_action(self, payload: dict) -> dict:
        self._ready()
        title = str(payload.get("title") or "").strip()
        minutes = int(payload.get("estimatedMinutes") or 0)
        if not title or minutes < 1:
            raise AppError("行动需要标题，预计分钟至少为 1。", "invalid")
        if "startDate" in payload:
            start = _as_cocoa(payload["startDate"], self.now(), self.tz) if payload["startDate"] else None
            end = _as_cocoa(payload["endDate"], self.now(), self.tz) if start is not None and payload.get("endDate") else start
        existing = payload.get("id")
        if existing:
            action = self._action(existing)
            if action is None:
                raise AppError("行动不存在。", "invalid")
            action["title"] = title
            action["notes"] = payload.get("notes") or ""
            action["estimatedMinutes"] = minutes
            action["goalID"] = payload.get("goalID")
        else:
            moment = cocoa(self.now())
            action = {
                "id": _uuid(),
                "title": title,
                "notes": payload.get("notes") or "",
                "dueDate": _as_cocoa(payload.get("dueDate"), self.now(), self.tz),
                "estimatedMinutes": minutes,
                "focusedSeconds": 0,
                "isCompleted": False,
                "rewardClaimed": False,
                "createdAt": moment,
            }
            if payload.get("goalID"):
                action["goalID"] = payload["goalID"]
            self.library["shortActions"].append(action)
        if "startDate" in payload:
            action["startDate"] = start
            action["endDate"] = max(start, end) if start is not None else None
            if not existing:
                action["dueDate"] = action["endDate"] if start is not None else cocoa(self.now())
        if payload.get("isCompleted") and not action.get("isCompleted"):
            self._complete_action(action, True)
        elif payload.get("isCompleted") is False:
            action["isCompleted"] = False
            action["completedAt"] = None
        self.save()
        return action

    def delete_action(self, action_id: str) -> None:
        self._ready()
        if self._action(action_id) is None:
            raise AppError("行动不存在。", "invalid")
        self.library["shortActions"] = [row for row in self.library["shortActions"] if row["id"] != action_id]
        self.save()

    def toggle_action(self, action_id: str) -> dict:
        self._ready()
        action = self._action(action_id)
        if action is None:
            raise AppError("行动不存在。", "invalid")
        self._complete_action(action, not bool(action.get("isCompleted")))
        self.save()
        return action

    # —— 庄园 ——

    def plant(self, plot_id: str, crop_id: str) -> dict:
        self._ready()
        spec = catalog.crop(crop_id)
        plot = self._plot(plot_id)
        if spec is None or plot.get("cropID"):
            raise AppError("这块田不能播种。", "unavailable")
        if self.library["coins"] < spec[4]:
            raise AppError("金币不足。", "funds")
        moment = self.now()
        self.synchronize(moment)
        self.library["coins"] -= spec[4]
        plot["cropID"] = spec[0]
        plot["growthMinutes"] = 0
        plot["nextFocusBoost"] = 0
        plot["plantedAt"] = cocoa(moment)
        self.save()
        return plot

    def buy_plot(self) -> dict:
        self._ready()
        if len(self.library["farmPlots"]) >= catalog.PLOT_CAP:
            raise AppError("田地已满。", "capacity")
        cost = catalog.farm_plot_cost(len(self.library["farmPlots"]))
        if self.library["coins"] < cost:
            raise AppError("金币不足。", "funds")
        self.library["coins"] -= cost
        plot = {"id": _uuid(), "growthMinutes": 0, "nextFocusBoost": 0}
        self.library["farmPlots"].append(plot)
        self.save()
        return plot

    def water(self, plot_id: str) -> None:
        self._boost(plot_id, catalog.WATER_COST, catalog.WATER_BOOST)

    def fertilize(self, plot_id: str) -> None:
        self._boost(plot_id, catalog.FERTILIZER_COST, catalog.FERTILIZER_BOOST)

    def harvest(self, plot_id: str) -> int:
        self._ready()
        self.synchronize()
        earned = self._harvest_plot(self._plot(plot_id))
        if not earned:
            raise AppError("作物还没成熟。", "unavailable")
        self.save()
        return earned

    def harvest_all(self) -> tuple[int, int]:
        self._ready()
        self.synchronize()
        earnings = [self._harvest_plot(plot) for plot in self.library["farmPlots"]]
        coins = sum(earnings)
        if coins:
            self.save()
        return sum(earned > 0 for earned in earnings), coins

    def _harvest_plot(self, plot: dict) -> int:
        spec = catalog.crop(plot.get("cropID"))
        if spec is None or float(plot.get("growthMinutes") or 0) < spec[3]:
            return 0
        self.library["coins"] += spec[5]
        self.library["harvestedCrops"][spec[0]] = int(self.library["harvestedCrops"].get(spec[0]) or 0) + 1
        plot.pop("cropID", None)
        plot.pop("plantedAt", None)
        plot["growthMinutes"] = 0
        plot["nextFocusBoost"] = 0
        self._reward(f"收获并出售{spec[1]}", f"获得 {spec[5]} 金币。", spec[5], "leaf.fill")
        return spec[5]

    def buy_shelter(self) -> int:
        self._ready()
        capacity = int(self.library["animalShelterCapacity"])
        if capacity >= catalog.SHELTER_CAP:
            raise AppError("窝位已满。", "capacity")
        cost = catalog.animal_shelter_cost(capacity)
        if self.library["coins"] < cost:
            raise AppError("金币不足。", "funds")
        self.library["coins"] -= cost
        self.library["animalShelterCapacity"] = capacity + 1
        self.save()
        return cost

    def buy_animal(self, animal_id: str) -> dict:
        self._ready()
        spec = catalog.animal(animal_id)
        if spec is None:
            raise AppError("没有这种动物。", "unavailable")
        if len(self.library["pastureAnimals"]) >= int(self.library["animalShelterCapacity"]):
            raise AppError("没有空余窝位。", "capacity")
        if self.library["coins"] < spec[4]:
            raise AppError("金币不足。", "funds")
        moment = self.now()
        self.synchronize(moment)
        self.library["coins"] -= spec[4]
        resident = {
            "id": _uuid(),
            "animalID": spec[0],
            "growthHours": 0,
            "pendingProducts": 0,
            "acquiredAt": cocoa(moment),
        }
        self.library["pastureAnimals"].append(resident)
        self.save()
        return resident

    def collect_products(self, resident_id: str | None = None) -> int:
        self._ready()
        self.synchronize()
        total = 0
        for resident in self.library["pastureAnimals"]:
            if resident_id and resident["id"] != resident_id:
                continue
            spec = catalog.animal(resident.get("animalID"))
            pending = int(resident.get("pendingProducts") or 0)
            if spec and pending:
                total += pending * spec[5]
                resident["pendingProducts"] = 0
        if total:
            self.library["coins"] += total
            self._reward("出售畜产", f"获得 {total} 金币。", total, "pawprint.fill")
            self.save()
        return total

    def sell_animal(self, resident_id: str) -> int:
        self._ready()
        self.synchronize()
        resident = next((row for row in self.library["pastureAnimals"] if row["id"] == resident_id), None)
        spec = catalog.animal(resident.get("animalID")) if resident else None
        if resident is None or spec is None:
            raise AppError("动物不存在。", "invalid")
        mature = float(resident.get("growthHours") or 0) >= catalog.maturity_hours(spec[6])
        price = catalog.adult_price(spec[4]) if mature else catalog.juvenile_price(spec[4])
        price += int(resident.get("pendingProducts") or 0) * spec[5]
        self.library["coins"] += price
        self.library["pastureAnimals"] = [row for row in self.library["pastureAnimals"] if row["id"] != resident_id]
        self._reward(f"出售{spec[1]}", f"获得 {price} 金币。", price, "pawprint.fill")
        self.save()
        return price

    def cast_line(self) -> dict:
        self._ready()
        moment = self.now()
        cast_at = cocoa(moment)
        if (self.cast and not self.cast["resolved"]
                and cast_at < self.cast["biteAt"] + FISH_BITE_DURATION):
            return {"biteAt": self.cast["biteAt"]}
        if self.library["bait"] <= 0:
            raise AppError("没有鱼饵。", "unavailable")
        wait = random.uniform(1.8, 3.8)
        bite = moment + timedelta(seconds=0.8 + max(1, wait))
        self.cast = {"castAt": cast_at, "biteAt": cocoa(bite), "resolved": False}
        return {"biteAt": self.cast["biteAt"]}

    def move_pasture_animal(self, resident_id: str, index: int) -> None:
        self._ready()
        animals = self.library["pastureAnimals"]
        animal = next((row for row in animals if row["id"] == resident_id), None)
        if animal is None:
            raise AppError("动物不存在。", "invalid")
        animals.remove(animal)
        animals.insert(max(0, min(index, len(animals))), animal)
        self.save()

    def cancel_cast(self) -> None:
        self.cast = None

    def reel(self, roll: int | None = None) -> dict:
        self._ready()
        if not self.cast or self.cast.get("resolved"):
            raise AppError("还没有抛竿。", "invalid")
        elapsed = cocoa(self.now()) - self.cast["biteAt"]
        if elapsed < 0 or elapsed >= FISH_BITE_DURATION:
            self.cast["resolved"] = True
            return {"hooked": False, "reason": "不在咬钩窗口内，未消耗鱼饵。"}
        marker = (math.sin(max(0, elapsed) * 2.4 - math.pi / 2) + 1) / 2
        self.cast["resolved"] = True
        if not 0.18 <= marker <= 0.82:
            return {"hooked": False, "marker": marker, "reason": "没有咬住，未消耗鱼饵。"}
        if self.library["bait"] <= 0:
            raise AppError("没有鱼饵。", "unavailable")
        self.library["bait"] -= 1
        chosen = roll if roll is not None else random.randint(1, 100)
        rarity = catalog.fishing_rarity(int(chosen))
        pool = catalog.fish_of_rarity(rarity) or list(catalog.FISH)
        caught = random.choice(pool)
        self.library["fishInventory"][caught[0]] = int(self.library["fishInventory"].get(caught[0]) or 0) + 1
        self.library["fishCaught"][caught[0]] = int(self.library["fishCaught"].get(caught[0]) or 0) + 1
        self._reward(f"钓到{caught[1]}", f"稀有度 {rarity}。", 0, "fish.fill")
        self.save()
        return {"hooked": True, "fishID": caught[0], "name": caught[1], "rarity": rarity, "roll": int(chosen)}

    def grant_fish(self, roll: int) -> dict:
        """测试与明确掷骰入口：直接按 1–100 的点数钓鱼，并消耗一枚鱼饵。"""
        self._ready()
        if self.library["bait"] <= 0:
            raise AppError("没有鱼饵。", "unavailable")
        self.library["bait"] -= 1
        rarity = catalog.fishing_rarity(roll)
        pool = catalog.fish_of_rarity(rarity) or list(catalog.FISH)
        caught = pool[0]
        self.library["fishInventory"][caught[0]] = int(self.library["fishInventory"].get(caught[0]) or 0) + 1
        self.library["fishCaught"][caught[0]] = int(self.library["fishCaught"].get(caught[0]) or 0) + 1
        self.save()
        return {"fishID": caught[0], "rarity": rarity}

    def sell_fish(self, fish_id: str | None = None) -> int:
        self._ready()
        total = 0
        items = list(self.library["fishInventory"].items())
        for key, count in items:
            if fish_id and key != fish_id:
                continue
            spec = catalog.fish(key)
            if spec and int(count) > 0:
                total += spec[3] * int(count)
                self.library["fishInventory"].pop(key, None)
        if total:
            self.library["coins"] += total
            self._reward("出售渔获", f"获得 {total} 金币。", total, "fish.fill")
            self.save()
        return total

    def move_to_aquarium(self, fish_id: str) -> bool:
        self._ready()
        if len(self.library["aquariumFish"]) >= catalog.AQUARIUM_CAPACITY:
            return False
        if catalog.fish(fish_id) is None or int(self.library["fishInventory"].get(fish_id) or 0) <= 0:
            return False
        self.library["fishInventory"][fish_id] -= 1
        if self.library["fishInventory"][fish_id] == 0:
            self.library["fishInventory"].pop(fish_id, None)
        today = start_of_day(self.now(), self.tz)
        self.library["aquariumFish"].append({
            "id": _uuid(),
            "fishID": fish_id,
            "addedAt": cocoa(self.now()),
            "lastIncomeDate": cocoa(today),
        })
        self.save()
        return True

    def sell_one_fish(self, fish_id: str) -> int:
        self._ready()
        spec = catalog.fish(fish_id)
        inventory = self.library["fishInventory"]
        count = int(inventory.get(fish_id) or 0)
        if spec is None or count < 1:
            raise AppError("鱼篓中没有这种鱼。", "unavailable")
        if count == 1:
            inventory.pop(fish_id)
        else:
            inventory[fish_id] = count - 1
        self.library["coins"] += spec[3]
        self._reward(f"出售{spec[1]}", f"获得 {spec[3]} 金币。", spec[3], "fish.fill")
        self.save()
        return spec[3]

    def return_aquarium_fish(self, resident_id: str) -> None:
        self._ready()
        residents = self.library["aquariumFish"]
        resident = next((row for row in residents if row["id"] == resident_id), None)
        if resident is None:
            raise AppError("水族馆中没有这条鱼。", "unavailable")
        residents.remove(resident)
        fish_id = resident["fishID"]
        inventory = self.library["fishInventory"]
        inventory[fish_id] = int(inventory.get(fish_id) or 0) + 1
        self.save()

    def collect_aquarium(self, at: datetime | None = None) -> int:
        self._ready()
        moment = at.astimezone(self.tz) if at else self.now()
        today = start_of_day(moment, self.tz)
        earned = 0
        for resident in self.library["aquariumFish"]:
            spec = catalog.fish(resident.get("fishID"))
            if not spec:
                continue
            days = _aquarium_days(resident, moment, self.tz)
            if days <= 0:
                continue
            earned += days * catalog.daily_income(spec[4])
            resident["lastIncomeDate"] = cocoa(today)
        if earned:
            self.library["coins"] += earned
            self._reward("领取水族馆收益", f"获得 {earned} 金币。", earned, "water.waves")
            self.save()
        return earned

    def buy_decoration(self, definition_id: str) -> int:
        self._ready()
        spec = catalog.decoration(definition_id)
        if spec is None or any(row.get("definitionID") == definition_id for row in self.library["decorations"]):
            raise AppError("装饰不可购买。", "unavailable")
        price = catalog.decoration_price(spec[2], 0)
        if self.library["coins"] < price:
            raise AppError("金币不足。", "funds")
        self.library["coins"] -= price
        self.library["decorations"].append({
            "id": _uuid(),
            "definitionID": definition_id,
            "level": 1,
            "placedAt": cocoa(self.now()),
        })
        self.save()
        return price

    def upgrade_decoration(self, decoration_id: str) -> int:
        self._ready()
        owned = next((row for row in self.library["decorations"] if row["id"] == decoration_id), None)
        spec = catalog.decoration(owned.get("definitionID")) if owned else None
        if owned is None or spec is None:
            raise AppError("装饰不存在。", "invalid")
        price = catalog.decoration_price(spec[2], int(owned["level"]))
        if self.library["coins"] < price:
            raise AppError("金币不足。", "funds")
        self.library["coins"] -= price
        owned["level"] = int(owned["level"]) + 1
        self.save()
        return price

    def update_settings(self, payload: dict) -> dict:
        if self.settings_protected:
            raise AppError("已有设置文件无法读取，未覆盖。", "protected")
        if "sleepTargetHours" in payload:
            self.settings["sleepTargetHours"] = min(12, max(5, float(payload["sleepTargetHours"])))
        if payload.get("appearance") in {"system", "light", "dark"}:
            self.settings["appearance"] = payload["appearance"]
        if payload.get("language") in {"zh-Hans", "en"}:
            self.settings["language"] = payload["language"]
        if "habitReminderHour" in payload:
            self.settings["habitReminderHour"] = min(23, max(0, int(payload["habitReminderHour"])))
        if "habitReminderMinute" in payload:
            self.settings["habitReminderMinute"] = min(59, max(0, int(payload["habitReminderMinute"])))
        if "habitReminderEnabled" in payload:
            self.settings["habitReminderEnabled"] = bool(payload["habitReminderEnabled"])
        if isinstance(payload.get("backgroundHex"), str) and re.fullmatch(r"(?:#[0-9a-fA-F]{6})?", payload["backgroundHex"]):
            self.settings["backgroundHex"] = payload["backgroundHex"]
        if self.status == "ready":
            self._write_settings()
        return self.settings

    def counts(self) -> dict:
        library_doc = self.library or {}
        return {
            "habits": len(library_doc.get("habits") or []),
            "chores": len(library_doc.get("chores") or []),
            "focusRecords": len(library_doc.get("focusRecords") or []),
            "sleepRecords": len(library_doc.get("sleepRecords") or []),
            "longGoals": len(library_doc.get("longGoals") or []),
            "shortActions": len(library_doc.get("shortActions") or []),
            "coins": library_doc.get("coins"),
            "bait": library_doc.get("bait"),
            "health": self.health.available,
            "footprints": self.footprints.available,
            "sharedSleep": self.sleep.available,
        }

    def snapshot(self) -> dict:
        moment = self.now()
        if self.status == "ready":
            self.synchronize_sleep_records(moment)
        health = None
        footprints = None
        if self.health.state is not None:
            health = self.health.summary(moment)
            health["trends"] = __import__("gaojiezou.health", fromlist=["trends"]).trends(self.health.state, moment, self.tz, 7)
            health["sleepRecords"] = self.shared_sleep_records
            health["sleepSyncError"] = self.sleep_sync_error
        if self.footprints.journal is not None:
            footprints = self.footprints.summary()
        current, longest = self.habit_streaks() if self.library else (0, 0)
        estate = {}
        if self.library:
            estate = {
                "nextPlotCost": catalog.farm_plot_cost(len(self.library["farmPlots"])),
                "nextShelterCost": catalog.animal_shelter_cost(self.library["animalShelterCapacity"]),
                "aquariumIncome": sum(
                    _aquarium_days(resident, moment, self.tz) * catalog.daily_income(spec[4])
                    for resident in self.library["aquariumFish"]
                    if (spec := catalog.fish(resident.get("fishID")))
                ),
            }
        return {
            "version": VERSION_LABEL,
            "marketingVersion": MARKETING_VERSION,
            "windowsBuild": WINDOWS_BUILD,
            "schema": catalog.SCHEMA_VERSION,
            "status": self.status,
            "notice": self.notice,
            "sleepSyncError": self.sleep_sync_error,
            "settings": self.settings,
            "counts": self.counts(),
            "library": self.library,
            "elapsedFocus": self.focus_elapsed(moment) if self.library else 0,
            "clock": cocoa(moment),
            "cast": self.cast if self.cast and not self.cast.get("resolved") else None,
            "habitStreaks": {"current": current, "longest": longest},
            "estate": estate,
            "health": health,
            "footprints": footprints,
            "catalog": {
                "crops": [{"id": row[0], "name": row[1], "emoji": row[2], "minutes": row[3], "seed": row[4], "sell": row[5]} for row in catalog.CROPS],
                "animals": [{"id": row[0], "name": row[1], "emoji": row[2], "product": row[3], "buy": row[4], "value": row[5],
                             "maturity": catalog.maturity_hours(row[6])} for row in catalog.ANIMALS],
                "fish": [{"id": row[0], "name": row[1], "emoji": row[2], "sell": row[3], "rarity": row[4]} for row in catalog.FISH],
                "decorations": [{"id": row[0], "name": row[1], "price": catalog.decoration_price(row[2], 0)} for row in catalog.DECORATIONS],
                "islandActions": [
                    {"id": row[0], "name": row[1], "energy": row[2], "food": row[3], "water": row[4],
                     "output": row[5], "yield": health["island"]["actionYields"].get(row[0], row[6]) if health else row[6]}
                    for row in catalog.ISLAND_ACTIONS
                ],
                "islandRecipes": [
                    {"id": row[0], "name": row[1], "cost": row[2], "tool": row[4]}
                    for row in catalog.ISLAND_RECIPES
                ],
            },
        }

    def _load(self) -> None:
        settings_path = self.directory / "settings.json"
        if settings_path.exists():
            try:
                stored = json.loads(settings_path.read_text(encoding="utf-8"))
                if not isinstance(stored, dict):
                    raise ValueError("settings must be an object")
                self.settings_source = stored
                self.settings.update({key: stored[key] for key in self.settings if key in stored})
            except (OSError, ValueError):
                self.settings_protected = True
                self.notice = "settings.json 无法读取，继续使用默认设置，未覆盖该文件。"
        status, document, notice = library.load_document(self.directory)
        self.status = status
        self.notice = notice or self.notice
        if status == "ready" and document is not None:
            self.library = document
            if (self.library.get("activeFocus") or {}).get("segmentStartedAt") is not None:
                self.pause_focus(for_system=False)
            self._open_modules()
        elif status == "missing":
            self.library = None

    def _open_modules(self) -> None:
        authority = self.directory / "Integration" / "authority.json"
        if not authority.exists():
            self.notice = (self.notice + " " if self.notice else "") + "未找到 Integration/authority.json，健康、足迹和共享睡眠未新建。"
            return
        try:
            self._require_sleep_authority()
        except AppError as exc:
            self.sleep_sync_error = exc.message
        for module in (self.health, self.footprints):
            if module.available:
                try:
                    module.open_existing()
                    if module is self.footprints:
                        self.footprints.prepare_station()
                except AppError as exc:
                    self.notice = (self.notice + " " if self.notice else "") + exc.message

    def _validate_sleep_authority(self) -> None:
        authority = self.directory / "Integration" / "authority.json"
        try:
            data = json.loads(authority.read_bytes())
            if not isinstance(data, dict) or any(data.get(key) != value for key, value in AUTHORITY.items()):
                raise ValueError("authority")
            token = (True, data.get("transactionID"))
            if self._sleep_authority_token is not None and token != self._sleep_authority_token:
                raise ValueError("authority changed")
            self._sleep_authority_token = token
        except (OSError, ValueError) as exc:
            raise AppError("共享睡眠权威配置缺失或无效，原资料已保留。", "protected") from exc

    def _require_sleep_authority(self) -> None:
        self._validate_sleep_authority()
        if not self.sleep.is_open:
            self.sleep.open_existing()

    def _write_authority_and_modules(self, now) -> None:
        root = self.directory / "Integration"
        root.mkdir(parents=True, exist_ok=True)
        library.atomic_write(root / "authority.json", library.dumps(AUTHORITY))
        self.sleep.create_fresh()
        self.health.create_fresh(now)
        self.footprints.create_fresh(now)
        self.footprints.prepare_station()

    def _write_settings(self) -> None:
        if not self.settings_protected:
            library.atomic_write(self.directory / "settings.json", library.dumps({**self.settings_source, **self.settings}))

    def _write_widget_snapshot(self) -> None:
        raw = (self.directory / library.LIBRARY_NAME).read_bytes()
        envelope = {
            "formatVersion": 1,
            "sourceSchema": catalog.SCHEMA_VERSION,
            "platform": "windows",
            "librarySHA256": hashlib.sha256(raw).hexdigest(),
            "businessSHA256": hashlib.sha256(_business_digest(self.library).encode("utf-8")).hexdigest(),
            "generatedAt": cocoa(self.now()),
            "sourceVersion": MARKETING_VERSION,
            "sourceBuild": WINDOWS_BUILD,
            "counts": self.counts(),
            "note": "Windows 计数快照。没有 WidgetKit，也不会注册 Mac App Group。",
        }
        library.atomic_write(self.directory / "widget-snapshot.json", library.dumps(envelope))

    def _ready(self) -> None:
        if self.status != "ready" or self.library is None:
            raise AppError(self.notice or "资料库尚未创建或处于只读保护。", "protected")

    def _habit(self, habit_id: str) -> dict:
        habit = next((row for row in self.library["habits"] if row["id"] == habit_id), None)
        if habit is None:
            raise AppError("打卡不存在。", "invalid")
        return habit

    def _chore(self, chore_id: str) -> dict:
        chore = next((row for row in self.library["chores"] if row["id"] == chore_id), None)
        if chore is None:
            raise AppError("琐事不存在。", "invalid")
        return chore

    def _goal(self, goal_id: str) -> dict:
        goal = next((row for row in self.library["longGoals"] if row["id"] == goal_id), None)
        if goal is None:
            raise AppError("目标不存在。", "invalid")
        return goal

    def _action(self, action_id: str | None) -> dict | None:
        if not action_id:
            return None
        return next((row for row in self.library["shortActions"] if row["id"] == action_id), None)

    def _plot(self, plot_id: str) -> dict:
        plot = next((row for row in self.library["farmPlots"] if row["id"] == plot_id), None)
        if plot is None:
            raise AppError("田地不存在。", "invalid")
        return plot

    def _boost(self, plot_id: str, cost: int, boost: float) -> None:
        self._ready()
        plot = self._plot(plot_id)
        if not plot.get("cropID"):
            raise AppError("田里没有作物。", "unavailable")
        if self.library["coins"] < cost:
            raise AppError("金币不足。", "funds")
        self.synchronize()
        self.library["coins"] -= cost
        plot["nextFocusBoost"] = min(catalog.MAXIMUM_FOCUS_BOOST, float(plot.get("nextFocusBoost") or 0) + boost)
        self.save()

    def _claim_goal(self, goal: dict) -> None:
        if goal.get("rewardClaimed"):
            return
        goal["rewardClaimed"] = True
        self.library["coins"] += catalog.LONG_GOAL_COINS
        self.library["bait"] += catalog.LONG_GOAL_BAIT
        self._reward("长期目标完成", f"获得 {catalog.LONG_GOAL_COINS} 金币和 {catalog.LONG_GOAL_BAIT} 个鱼饵。", catalog.LONG_GOAL_COINS, "flag.checkered")

    def _complete_action(self, action: dict, completed: bool) -> None:
        action["isCompleted"] = completed
        action["completedAt"] = cocoa(self.now()) if completed else None
        if completed and not action.get("rewardClaimed"):
            action["rewardClaimed"] = True
            self.library["coins"] += catalog.SHORT_ACTION_COINS
            self.library["bait"] += catalog.SHORT_ACTION_BAIT
            self._reward("完成短期行动", f"获得 {catalog.SHORT_ACTION_COINS} 金币和 {catalog.SHORT_ACTION_BAIT} 个鱼饵。", catalog.SHORT_ACTION_COINS, "checkmark.circle.fill")

    def _reward(self, title: str, detail: str, coins: int, symbol: str) -> None:
        self.library["rewardEvents"].insert(0, {
            "id": _uuid(),
            "date": cocoa(self.now()),
            "title": title,
            "detail": detail,
            "coins": coins,
            "symbol": symbol,
        })
        self.library["rewardEvents"] = self.library["rewardEvents"][: catalog.REWARD_EVENT_CAP]

    def _settle_sleep_progress(self, holder: dict, elapsed: float, target_hours: float, manual: bool) -> None:
        growth_key = "manualGrowthCreditedSeconds" if manual else "growthCreditedSeconds"
        cycle_key = "manualProductionCreditedCycles" if manual else "productionCyclesCredited"
        eligible_growth = min(catalog.SLEEP_GROWTH_CAP_SECONDS, elapsed)
        growth_delta = max(0, eligible_growth - float(holder.get(growth_key) or 0))
        if growth_delta > 0:
            hours = growth_delta / 3600
            for resident in self.library["pastureAnimals"]:
                spec = catalog.animal(resident.get("animalID"))
                if not spec:
                    continue
                cap = catalog.maturity_hours(spec[6])
                resident["growthHours"] = min(cap, float(resident.get("growthHours") or 0) + hours)
            holder[growth_key] = eligible_growth
        interval = max(1, target_hours) * 3600 / 2
        eligible_cycles = min(catalog.SLEEP_PRODUCTION_CYCLE_CAP, int(elapsed / interval))
        new_cycles = max(0, eligible_cycles - int(holder.get(cycle_key) or 0))
        if new_cycles > 0:
            new_yield = 0
            for resident in self.library["pastureAnimals"]:
                spec = catalog.animal(resident.get("animalID"))
                if spec and float(resident.get("growthHours") or 0) >= catalog.maturity_hours(spec[6]):
                    resident["pendingProducts"] = int(resident.get("pendingProducts") or 0) + new_cycles
                    new_yield += new_cycles
            holder[cycle_key] = eligible_cycles
            if manual:
                holder["pastureYield"] = int(holder.get("pastureYield") or 0) + new_yield
            else:
                holder["pastureYieldCredited"] = int(holder.get("pastureYieldCredited") or 0) + new_yield

    def _settle_manual(self, record_id: str, target_hours: float) -> None:
        record = next(row for row in self.library["sleepRecords"] if row["id"] == record_id)
        self._settle_sleep_progress(record, record["durationSeconds"], target_hours, manual=True)

    def synchronize_sleep_records(self, moment: datetime | None = None) -> None:
        if self.status != "ready" or self.library is None:
            return
        moment = moment or self.now()
        try:
            self._require_sleep_authority()
            previous = self.library["sleepRecords"]
            local = {row["id"]: row for row in previous}
            entries = self.sleep.entries()
            known = {entry["id"] for entry in entries}
            for record_id, record in local.items():
                if record_id in known:
                    continue
                origin = record.get("origin") or ("health" if record.get("healthSource") else "rhythm")
                pending = {**record, "origin": origin}
                settlement = dict(pending)
                if origin == "rhythm" and not pending.get("manualEntry"):
                    settlement["manualGrowthCreditedSeconds"] = max(
                        settlement.get("manualGrowthCreditedSeconds") or 0,
                        min(record["durationSeconds"], catalog.SLEEP_GROWTH_CAP_SECONDS),
                    )
                    settlement["manualProductionCreditedCycles"] = max(
                        settlement.get("manualProductionCreditedCycles") or 0, catalog.SLEEP_PRODUCTION_CYCLE_CAP,
                    )
                self.sleep.reconcile_pending(pending, settlement)
            canonical = self.sleep.live()
            self.shared_sleep_records = canonical
            incoming = [merge_credits(local.get(row["id"], {}), row) for row in canonical]
            for row in incoming:
                if row.get("origin") == "health" and not row.get("healthSource"):
                    row["healthSource"] = "搞健康"
            if incoming != previous:
                before = json.loads(json.dumps(self.library))
                try:
                    self.library["sleepRecords"] = incoming
                    for row in incoming:
                        if row.get("origin") == "health" and row["id"] not in local:
                            self._settle_manual(row["id"], self._sleep_target(None))
                    self.save()
                except (AppError, OSError):
                    self.library = before
                    raise
            updated = False
            for entry, record in zip(canonical, incoming):
                if merge_credits(record, entry) != entry:
                    self.sleep.update_settlement(record)
                    updated = True
            if updated:
                canonical = self.sleep.live()
                self.shared_sleep_records = canonical
            if self.health.state is not None:
                self.health.reward_sleep(canonical, moment)
            self.sleep_sync_error = ""
        except (AppError, OSError) as exc:
            self.sleep_sync_error = f"共同睡眠暂不可用，本地记录已保留。{exc}"

    def habit_streaks(self) -> tuple[int, int]:
        if not self.library or not self.library["habits"]:
            return 0, 0
        today = start_of_day(self.now(), self.tz)
        earliest = min(
            start_of_day(from_cocoa(habit["createdAt"]), self.tz)
            for habit in self.library["habits"] if habit.get("createdAt") is not None
        ) if all(habit.get("createdAt") is not None for habit in self.library["habits"]) else today
        completions = set(self.library["habitCompletionKeys"])
        days = []
        cursor = earliest
        while cursor <= today:
            scheduled = [habit for habit in self.library["habits"] if _scheduled(habit, cursor, self.tz)]
            done = sum(1 for habit in scheduled if _habit_key(habit["id"], cursor, self.tz) in completions)
            days.append((cursor, len(scheduled), done))
            cursor = cursor + timedelta(days=1)
        longest = run = 0
        for day, scheduled, done in days:
            if scheduled and done >= scheduled:
                run += 1
                longest = max(longest, run)
            elif scheduled and day != today:
                run = 0
        current = 0
        for day, scheduled, done in reversed(days):
            if scheduled and done >= scheduled:
                current += 1
            elif day == today:
                continue
            elif scheduled:
                break
        return current, longest


def default_data_dir() -> Path:
    override = os.environ.get("GAOJIEZOU_DATA_DIR")
    if override:
        return Path(override)
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "GaoSeries" / "Rhythm"
    return Path.home() / "GaoSeries" / "Rhythm"


def _uuid() -> str:
    return str(uuid.uuid4()).upper()


def _habit_key(habit_id: str, moment: datetime, tz) -> str:
    local = in_zone(moment, tz)
    return f"{habit_id}-{local.year}-{local.month}-{local.day}"


def _scheduled(habit: dict, moment: datetime, tz) -> bool:
    weekdays = {int(day) for day in habit.get("weekdays") or []}
    if swift_weekday(moment, tz) not in weekdays:
        return False
    if habit.get("createdAt") is None:
        return True
    return start_of_day(from_cocoa(habit["createdAt"]), tz) <= start_of_day(moment, tz)


def _as_cocoa(value, now: datetime, tz) -> float:
    if value is None:
        return cocoa(start_of_day(now, tz))
    if isinstance(value, (int, float)):
        return float(value)
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=tz)
    return cocoa(parsed.astimezone(tz))


def _aquarium_days(resident: dict, moment: datetime, tz) -> int:
    start = start_of_day(from_cocoa(resident["lastIncomeDate"]), tz)
    end = start_of_day(moment, tz)
    return max(0, min(catalog.AQUARIUM_OFFLINE_DAY_CAP, (end.date() - start.date()).days))


def _business_digest(document: dict | None) -> str:
    if not document:
        return ""
    focus = document.get("activeFocus") or {}
    sleep = document.get("activeSleep") or {}
    payload = {
        "version": document.get("version"),
        "habits": document.get("habits"),
        "habitCompletionKeys": sorted(document.get("habitCompletionKeys") or []),
        "activeFocus": {key: focus.get(key) for key in ("id", "title", "linkedActionID", "startedAt", "accumulatedSeconds", "segmentStartedAt", "pausedForSystem")} if focus else None,
        "activeSleep": {key: sleep.get(key) for key in ("id", "startedAt", "targetHours")} if sleep else None,
        "focusRecords": document.get("focusRecords"),
        "sleepRecords": [
            {key: row.get(key) for key in ("id", "healthSource", "startedAt", "endedAt", "durationSeconds", "score", "manualEntry")}
            for row in document.get("sleepRecords") or []
        ],
        "longGoals": document.get("longGoals"),
        "shortActions": document.get("shortActions"),
        "chores": document.get("chores"),
    }
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str)


def focus_csv(store: RhythmStore) -> str:
    rows = sorted(store.library.get("focusRecords") or [], key=lambda row: float(row["startedAt"]))
    lines = [_csv_row(["开始时间", "结束时间", "时长（分钟）", "关联行动", "金币"])]
    for row in rows:
        lines.append(_csv_row([
            _stamp(row["startedAt"], store.tz),
            _stamp(row["endedAt"], store.tz),
            f"{float(row['durationSeconds']) / 60:.1f}",
            row.get("title") or "",
            str(row.get("earnedCoins") or 0),
        ]))
    return "\ufeff" + "\r\n".join(lines) + "\r\n"


def sleep_csv(store: RhythmStore) -> str:
    rows = sorted(store.library.get("sleepRecords") or [], key=lambda row: float(row["startedAt"]))
    target = f"{float(store.settings['sleepTargetHours']):.1f}"
    lines = [_csv_row(["开始时间", "结束时间", "时长（小时）", "目标（小时）", "评分"])]
    for row in rows:
        lines.append(_csv_row([
            _stamp(row["startedAt"], store.tz),
            _stamp(row["endedAt"], store.tz),
            f"{float(row['durationSeconds']) / 3600:.2f}",
            target,
            str(row.get("score") or 0),
        ]))
    return "\ufeff" + "\r\n".join(lines) + "\r\n"


def habit_csv(store: RhythmStore) -> str:
    habits = {row["id"]: row for row in store.library.get("habits") or []}
    parsed = []
    for key in store.library.get("habitCompletionKeys") or []:
        parts = key.split("-")
        if len(parts) < 4:
            continue
        try:
            year, month, day = int(parts[-3]), int(parts[-2]), int(parts[-1])
        except ValueError:
            continue
        parsed.append(("-".join(parts[:-3]), year, month, day))
    parsed.sort(key=lambda item: (item[1], item[2], item[3], item[0]))
    lines = [_csv_row(["打卡名称", "日期", "奖励金币"])]
    for habit_id, year, month, day in parsed:
        habit = habits.get(habit_id)
        lines.append(_csv_row([
            habit["title"] if habit else "已删除打卡",
            f"{year:04d}-{month:02d}-{day:02d}",
            str(habit["rewardCoins"]) if habit else "",
        ]))
    return "\ufeff" + "\r\n".join(lines) + "\r\n"


def _stamp(value: float, tz) -> str:
    local = from_cocoa(value).astimezone(tz)
    return local.strftime("%Y-%m-%d %H:%M")


def _csv_row(fields: list[str]) -> str:
    escaped = []
    for field in fields:
        if any(char in field for char in ",\"\n\r"):
            escaped.append('"' + field.replace('"', '""') + '"')
        else:
            escaped.append(field)
    return ",".join(escaped)
