from __future__ import annotations

import json
from datetime import datetime, timedelta
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

import pytest

from gaojiezou.errors import AppError
from gaojiezou.review import weekly_review
from gaojiezou.store import RhythmStore
from gaojiezou.timeutil import cocoa
from gaojiezou.web import serve


@pytest.fixture
def review_store(tmp_path):
    zone = ZoneInfo("America/New_York")
    clock = SimpleNamespace(now=datetime(2026, 11, 2, 10, tzinfo=zone))
    store = RhythmStore(tmp_path, tz=zone, clock=lambda: clock.now)
    store.create_library()
    for key in ("habits", "shortActions", "longGoals"):
        store.library[key].clear()
    return store, clock, zone


def focus_record(identifier, start, end, seconds=None):
    start, end = cocoa(start), cocoa(end)
    return {"id": identifier, "title": identifier, "startedAt": start, "endedAt": end,
            "durationSeconds": end - start if seconds is None else seconds}


def test_monday_weeks_split_saved_focus_at_local_midnight_and_dst(review_store):
    store, _, zone = review_store
    store.library["focusRecords"] = [
        focus_record("DST fallback", datetime(2026, 11, 1, 0, 30, tzinfo=zone),
                     datetime(2026, 11, 1, 3, 30, tzinfo=zone)),
        focus_record("Paused across weeks", datetime(2026, 11, 1, 23, 30, tzinfo=zone),
                     datetime(2026, 11, 2, 0, 30, tzinfo=zone), 1800),
        focus_record("Stopped at midnight", datetime(2026, 10, 31, 23, 0, tzinfo=zone),
                     datetime(2026, 11, 1, 0, 0, tzinfo=zone), 1500),
    ]
    store.start_focus()

    prior = weekly_review(store, "2026-11-01")
    assert (prior["weekStart"], prior["weekEnd"], prior["currentWeekStart"]) == (
        "2026-10-26", "2026-11-01", "2026-11-02")
    assert prior["days"][-2]["focusSeconds"] == 1500
    assert not prior["days"][-2]["focusEstimated"]
    sunday = prior["days"][-1]
    assert sunday["focusSeconds"] == 4 * 3600 + 900
    assert [(row["id"], row["estimated"]) for row in sunday["focus"]] == [
        ("DST fallback", False), ("Paused across weeks", True)]
    assert prior["plan"]["focusMinutes"] is None

    current = weekly_review(store)
    assert current["days"][0]["focusSeconds"] == 900
    assert current["days"][0]["focusEstimated"]
    assert current["totals"]["focusSeconds"] + prior["totals"]["focusSeconds"] == 4 * 3600 + 1800 + 1500
    assert store.library["activeFocus"]["segmentStartedAt"] is not None


def test_historical_check_ins_are_evidence_independent_of_current_schedule(review_store):
    store, _, zone = review_store
    habit = store.save_habit({"title": "Current name", "weekdays": [2]})
    store.library["habitCompletionKeys"] = [
        f'{habit["id"]}-2026-11-1', f'{habit["id"].lower()}-2026-11-01', "deleted-habit-2026-11-1",
        "invalid", "invalid-date-2026-2-30", f'{habit["id"]}-2026-11-3',
    ]
    old = weekly_review(store, "2026-10-30")
    assert old["plan"]["mode"] == "historical"
    assert all(day["habitPlan"] is None for day in old["days"])
    assert old["totals"]["habitPlan"] is None
    assert old["totals"]["habitDone"] == 2
    assert old["days"][-1]["habits"] == [
        {"id": habit["id"], "title": "Current name"}, {"id": "deleted-habit", "title": None}]

    existing = store.save_goal({"title": "Current project", "startDate": "2026-10-25", "targetDate": "2026-11-14"})
    completed = store.save_action({"title": "Dated work", "goalID": existing["id"], "startDate": "2026-11-02",
                                   "endDate": "2026-11-04", "estimatedMinutes": 40, "isCompleted": True})
    store.save_action({"title": "Carried work", "startDate": "2026-10-31", "endDate": "2026-11-03", "estimatedMinutes": 20})
    store.save_action({"title": "Unscheduled", "startDate": None, "estimatedMinutes": 60})
    store.library["shortActions"].append({"id": "legacy", "title": "Old due date", "estimatedMinutes": 15,
                                          "createdAt": cocoa(datetime(2026, 10, 31, tzinfo=zone)),
                                          "dueDate": cocoa(datetime(2026, 11, 6, tzinfo=zone))})
    current = weekly_review(store, "2026-11-07")
    assert current["plan"]["mode"] == "current"
    assert current["totals"]["habitDone"] == 0
    assert current["totals"]["habitPlan"] == 1
    assert current["plan"]["focusMinutes"] == 55
    assert current["plan"]["datedActionCount"] == 3
    assert current["plan"]["goals"][0]["title"] == "Current project"
    assert current["days"][0]["actions"][0]["id"] == completed["id"]
    assert current["days"][0]["actions"][0]["goalTitle"] == "Current project"
    assert weekly_review(store, "2026-11-12")["totals"]["focusSeconds"] == 0


def test_goal_completion_is_dated_only_when_observed_and_preserves_rewards(review_store):
    store, clock, _ = review_store
    goal = store.save_goal({"title": "Actually completed", "status": "completed"})
    old_goal = {"id": "legacy", "title": "Completion date unknown", "status": "completed"}
    store.library["longGoals"].append(old_goal)
    report = weekly_review(store)
    assert report["days"][0]["goals"][0]["id"] == goal["id"]
    assert report["totals"]["goalDone"] == 1
    assert report["totals"]["undatedGoals"] == 1
    reported_historical = weekly_review(store, "2026-10-26")
    assert reported_historical["totals"]["goalDone"] == 0
    assert reported_historical["totals"]["undatedGoals"] == 1
    coins = store.library["coins"]
    first_date = goal["completedAt"]
    clock.now += timedelta(days=1)
    store.save_goal({**goal, "title": "Renamed"})
    assert goal["completedAt"] == first_date
    store.save_goal({**goal, "status": "active"})
    assert "completedAt" not in goal
    store.save_goal({**goal, "status": "completed"})
    assert goal["completedAt"] == cocoa(clock.now)
    assert store.library["coins"] == coins


def test_shared_sleep_wake_day_is_read_only_fresh_and_protected(review_store):
    store, _, zone = review_store
    start, end = datetime(2026, 11, 1, 22, tzinfo=zone), datetime(2026, 11, 2, 6, tzinfo=zone)
    row = store._manual_sleep_record(start, end, 8, store.now(), "health")
    store.sleep.upsert(row)
    document = store.directory / "library.json"
    before = document.read_bytes()
    previous = weekly_review(store, "2026-11-01")
    current = weekly_review(store)
    assert previous["totals"]["sleepSeconds"] is None
    assert current["sleepStatus"] == "ready"
    assert current["days"][0]["sleep"] == [{
        "id": row["id"], "startedAt": start.timestamp(), "endedAt": end.timestamp(), "seconds": 28800}]
    assert current["totals"]["sleepNights"] == 1
    assert current["days"][1]["sleepSeconds"] is None
    assert document.read_bytes() == before

    authority = store.directory / "Integration" / "authority.json"
    authority.write_text("{}", encoding="utf-8")
    unavailable = weekly_review(store)
    assert unavailable["sleepStatus"] == "unavailable"
    assert unavailable["totals"]["sleepNights"] is None and unavailable["totals"]["sleepSeconds"] is None
    assert document.read_bytes() == before


def test_week_endpoint_checks_session_token_and_date(review_store):
    store, _, _ = review_store
    server = serve(store, open_browser=False)
    url = server.url + "api/review/week"
    headers = {"X-Gao-Token": server.token}
    try:
        with pytest.raises(HTTPError) as denied:
            urlopen(url, timeout=4)
        assert denied.value.code == 403
        with urlopen(Request(url + "?date=2026-11-01", headers=headers), timeout=4) as response:
            assert json.load(response)["weekStart"] == "2026-10-26"
        for parameter in ("?date=2026-2-30", "?date=", "?date=20261127", "?date=2026-10-26&date=2026-11-02"):
            with pytest.raises(HTTPError) as invalid:
                urlopen(Request(url + parameter, headers=headers), timeout=4)
            assert invalid.value.code == 400
        with pytest.raises(AppError):
            weekly_review(store, "9999-12-31")
    finally:
        server.shutdown()
        server.server_close()
