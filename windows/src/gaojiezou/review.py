"""Read-only review of a Monday–Sunday week in the local calendar."""

from __future__ import annotations

import math
from datetime import date, datetime, timedelta

from gaojiezou.errors import AppError
from gaojiezou.timeutil import COCOA_EPOCH, from_cocoa

_DAY = timedelta(days=1)
_UNIX_OFFSET = COCOA_EPOCH.timestamp()


def _number(value) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            return float(value) if math.isfinite(value) else None
        except OverflowError:
            pass
    return None


def _instant(value, zone) -> datetime | None:
    seconds = _number(value)
    if seconds is not None:
        try:
            return from_cocoa(seconds).astimezone(zone)
        except (OSError, OverflowError, ValueError):
            pass
    return None


def _date(value, zone) -> date | None:
    moment = _instant(value, zone)
    return moment.date() if moment is not None else None


def _monday(day: date) -> date:
    return day - day.weekday() * _DAY


def _midnight(day: date, zone) -> float:
    # Resolve the OS offset for each midnight, including short and long DST days.
    return datetime(day.year, day.month, day.day, tzinfo=zone).timestamp()


def _week(value: str | None, today: date, zone) -> tuple[list[date], list[float]]:
    try:
        chosen = date.fromisoformat(value) if value is not None else today
        if value is not None and chosen.isoformat() != value:
            raise ValueError
        start = _monday(chosen)
        boundaries = [start + offset * _DAY for offset in range(8)]
        return boundaries[:-1], [_midnight(day, zone) for day in boundaries]
    except (OSError, OverflowError, ValueError) as exc:
        raise AppError("复盘日期须是有效的 YYYY-MM-DD 本地日期。", "invalid") from exc


def _focus_records(rows, days, dates, limits, zone, now) -> None:
    for row in rows:
        start, end = (_number(row.get(field)) for field in ("startedAt", "endedAt"))
        seconds = _number(row.get("durationSeconds"))
        if end is None or seconds is None or seconds < 0:
            continue
        end += _UNIX_OFFSET
        if end > now or end < limits[0] or (start is not None and start + _UNIX_OFFSET >= limits[-1]):
            continue
        start = start + _UNIX_OFFSET if start is not None else None
        detail = {"id": row["id"], "title": row.get("title"), "startedAt": start, "endedAt": end}
        if start is None or start >= end or not seconds:
            day = _date(row["endedAt"], zone)
            if day in days:
                days[day]["focus"].append({**detail, "seconds": seconds, "estimated": bool(seconds)})
            continue
        span = end - start
        last_instant = row["endedAt"] - min(0.001, span / 2)
        estimated = abs(span - seconds) > 1 and _date(row["startedAt"], zone) != _date(last_instant, zone)
        for index, day in enumerate(dates):
            overlap = min(end, limits[index + 1]) - max(start, limits[index])
            if overlap > 0:
                days[day]["focus"].append({**detail, "seconds": seconds * overlap / span, "estimated": estimated})


def _check_ins(library, days, today) -> None:
    habits = {row["id"].casefold(): row for row in library["habits"]}
    seen = set()
    for key in library["habitCompletionKeys"]:
        try:
            habit_id, year, month, day = key.rsplit("-", 3)
            checked_on = date(int(year), int(month), int(day))
            identity = (habit_id.casefold(), checked_on)
        except (AttributeError, ValueError):
            continue
        if not habit_id or checked_on not in days or checked_on > today or identity in seen:
            continue
        seen.add(identity)
        habit = habits.get(identity[0], {})
        days[checked_on]["habits"].append({"id": habit.get("id", habit_id), "title": habit.get("title")})


def _sleep_records(store, days, zone, now) -> str:
    try:
        store._require_sleep_authority()
        rows = store.sleep.live()
    except (AppError, OSError):
        return "unavailable"
    for row in rows:
        end = _instant(row["endedAt"], zone)
        if end is None or end.timestamp() > now or end.date() not in days:
            continue
        days[end.date()]["sleep"].append({
            "id": row["id"], "startedAt": row["startedAt"] + _UNIX_OFFSET,
            "endedAt": end.timestamp(), "seconds": row["durationSeconds"],
        })
    return "ready"


def _completions(rows, target, check, days, zone, now, goals) -> int:
    undated = 0
    for row in rows:
        if not check(row):
            continue
        completed = _instant(row.get("completedAt"), zone)
        if completed is None or completed.timestamp() > now:
            undated += 1
        elif completed.date() in days:
            entry = {"id": row["id"], "title": row.get("title"), "completedAt": completed.timestamp()}
            if target == "actions":
                entry["goalTitle"] = goals.get(row.get("goalID"), {}).get("title")
            days[completed.date()][target].append(entry)
    return undated


def _planning(store, days, dates, current_week, goals, zone) -> dict:
    plan = {"mode": "historical", "focusMinutes": None, "datedActionCount": None, "goalCount": None,
            "sleepTargetHours": None, "habitCount": None, "items": [], "goals": []}
    first, last = dates[0], dates[-1]
    if first < current_week:
        return plan
    plan["mode"] = "current"
    habits = [(row, _date(row.get("createdAt"), zone)) for row in store.library["habits"]]
    for day in dates:
        # Swift stores Sunday as 1 and Monday as 2.
        weekday = (day.weekday() + 1) % 7 + 1
        days[day]["habitPlan"] = sum(
            (created is None or created <= day) and weekday in (row.get("weekdays") or ())
            for row, created in habits
        )
    plan["habitCount"] = sum(days[day]["habitPlan"] for day in dates)
    plan["sleepTargetHours"] = None if store.settings_protected else _number(store.settings.get("sleepTargetHours"))
    for row in store.library["shortActions"]:
        start = _date(row.get("startDate"), zone)
        if "startDate" not in row:
            # Old writers also used the creation day as a placeholder due date.
            due, created = (_date(row.get(field), zone) for field in ("dueDate", "createdAt"))
            if due is not None and created is not None and due > created:
                start = due
        end = _date(row.get("endDate"), zone) or start
        if start is None or not (start <= last and end >= first):
            continue
        plan["items"].append({
            "id": row["id"], "title": row.get("title"), "goalTitle": goals.get(row.get("goalID"), {}).get("title"),
            "startDate": start.isoformat(), "endDate": max(start, end).isoformat(),
            "estimatedMinutes": _number(row.get("estimatedMinutes")),
        })
    for row in goals.values():
        start, end = (_date(row.get(field), zone) for field in ("startDate", "targetDate"))
        if start is not None and end is not None and start <= last and end >= first:
            plan["goals"].append({"id": row["id"], "title": row.get("title"), "status": row.get("status"),
                                  "startDate": start.isoformat(), "endDate": end.isoformat()})
    plan["items"].sort(key=lambda row: (row["startDate"], row["endDate"], row["id"]))
    plan["goals"].sort(key=lambda row: (row["endDate"], row["id"]))
    plan["datedActionCount"] = len(plan["items"])
    plan["goalCount"] = len(plan["goals"])
    starting = [item["estimatedMinutes"] for item in plan["items"] if item["startDate"] >= first.isoformat()]
    plan["focusMinutes"] = sum(starting) if all(value is not None and value > 0 for value in starting) else None
    return plan


def weekly_review(store, requested: str | None = None) -> dict:
    store._ready()
    zone = store.review_timezone
    current = store.now().astimezone(zone)
    today = current.date()
    now = current.timestamp()
    current_week = _monday(today)
    dates, limits = _week(requested, today, zone)
    days = {day: {"date": day.isoformat(), "focus": [], "habits": [], "sleep": [], "actions": [], "goals": [],
                  "habitPlan": None} for day in dates}
    library = store.library
    goals = {row["id"]: row for row in library["longGoals"]}
    _focus_records(library["focusRecords"], days, dates, limits, zone, now)
    _check_ins(library, days, today)
    sleep_status = _sleep_records(store, days, zone, now)
    undated_actions = _completions(library["shortActions"], "actions", lambda row: row.get("isCompleted"),
                                   days, zone, now, goals)
    undated_goals = _completions(library["longGoals"], "goals", lambda row: row.get("status") == "completed",
                                 days, zone, now, goals)
    plan = _planning(store, days, dates, current_week, goals, zone)
    for data in days.values():
        data["focusSeconds"] = sum(row["seconds"] for row in data["focus"])
        data["focusEstimated"] = any(row["estimated"] for row in data["focus"])
        data["sleepSeconds"] = sum(row["seconds"] for row in data["sleep"]) if data["sleep"] else None
        for count, collection in (("habitDone", "habits"), ("actionDone", "actions"), ("goalDone", "goals")):
            data[count] = len(data[collection])
    values = list(days.values())
    sleep_days = [day["sleepSeconds"] for day in values if day["sleepSeconds"] is not None]
    totals = {
        **{key: sum(day[key] for day in values) for key in ("focusSeconds", "habitDone", "actionDone", "goalDone")},
        "focusEstimated": any(day["focusEstimated"] for day in values),
        "habitPlan": plan["habitCount"],
        "sleepSeconds": sum(sleep_days) if sleep_days else None,
        "sleepNights": len(sleep_days) if sleep_status == "ready" else None,
        "undatedActions": undated_actions, "undatedGoals": undated_goals,
    }
    return {"weekStart": dates[0].isoformat(), "weekEnd": dates[-1].isoformat(),
            "currentWeekStart": current_week.isoformat(), "today": today.isoformat(), "days": values,
            "totals": totals, "plan": plan, "sleepStatus": sleep_status}
