from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from datetime import date, datetime, timedelta, timezone
from threading import Event, Lock
from types import SimpleNamespace

import pytest

from gaojiezou.desktop import DISPLAY_GUID, BackgroundRhythm, DesktopInstance, MSG_POWER, MSG_SESSION, WindowsDesktop, route_index
from gaojiezou.footprints import search_cities
from gaojiezou.store import RhythmStore
from gaojiezou.widgets import footprint_widget_data, health_widget_data, log_widget_health, month_segments, project_widget_map, widget_data


def new_server(tmp_path):
    clock = SimpleNamespace(now=datetime(2026, 11, 27, 21, 25, tzinfo=timezone.utc))
    store = RhythmStore(tmp_path, tz=timezone.utc, clock=lambda: clock.now)
    store.create_library()
    for habit in tuple(store.library["habits"]):
        store.delete_habit(habit["id"])
    for key in ("longGoals", "shortActions", "chores"):
        store.library[key].clear()
    return SimpleNamespace(store=store, lock=Lock(), shutdown_requested=Event()), clock


def test_overlapping_pause_reasons_and_manual_pause(tmp_path):
    server, clock = new_server(tmp_path)
    store = server.store
    store.start_focus()
    clock.now += timedelta(minutes=15)
    events = BackgroundRhythm(server, lambda *_: True)
    events.system_change("display", True)
    events.system_change("lock", True)
    clock.now += timedelta(hours=3)
    events.system_change("display", False)
    assert store.library["activeFocus"]["pausedForSystem"] is True
    assert store.focus_elapsed() == 15 * 60
    events.system_change("lock", False)
    assert store.library["activeFocus"]["segmentStartedAt"] is not None
    store.pause_focus()
    events.system_change("lock", True)
    events.system_change("lock", False)
    assert store.library["activeFocus"]["segmentStartedAt"] is None
    assert store.library["activeFocus"]["pausedForSystem"] is False


def test_reminder_uses_current_habits_time_and_restart_marker(tmp_path):
    server, clock = new_server(tmp_path)
    store = server.store
    first = store.save_habit({"title": "Read"})
    store.save_habit({"title": "Walk"})
    store.toggle_habit(first["id"])
    store.update_settings({"language": "en", "habitReminderHour": 21, "habitReminderMinute": 26, "habitReminderEnabled": True})
    notices = []

    def notify(*text):
        notices.append(text)
        return True

    events = BackgroundRhythm(server, notify)
    events.tick()
    assert notices == []
    clock.now += timedelta(minutes=1)
    events.tick()
    events.tick()
    BackgroundRhythm(server, notify).tick()
    assert notices == [("Rhythm", "You have 1 check-ins left today.")]


def test_widgets_use_live_focus_last_night_goals_and_month_lanes(tmp_path):
    server, clock = new_server(tmp_path)
    store = server.store
    goal = store.save_goal({"title": "A goal"})
    action = store.save_action({"title": "An action", "goalID": goal["id"], "estimatedMinutes": 15,
                                "startDate": "2026-11-26", "endDate": "2026-11-28"})
    store.toggle_action(action["id"])
    store.save_chore({"title": "Two days", "startDate": "2026-11-26", "endDate": "2026-11-27"})
    store.add_manual_sleep(clock.now.replace(hour=1), clock.now.replace(hour=8), 8)
    store.start_focus()
    clock.now += timedelta(minutes=15)
    data = widget_data(store)
    assert data["metrics"][:5] == (0, 0, 15 * 60, True, 7 * 3600)
    assert data["goals"] == [("A goal", 1, 1, False)]
    assert [row[3] for row in data["events"]] == ["Two days"]
    week = [date(2026, 11, n) for n in range(22, 29)]
    rows = month_segments(week, data["events"], 1)
    assert rows[0][:4] == (4, 5, 0, "Two days")
    assert route_index("gaojiezou://longGoals") > 0
    assert route_index("gaozuji://train") == route_index("gaojiezou://footprints/train")
    assert route_index("gaojiankang://weight") == route_index("gaojiezou://health/weight")
    with pytest.raises(ValueError):
        route_index("gaojiezou://longGoals?unexpected=1")


def test_integrated_widgets_write_real_health_and_use_visited_map_data(tmp_path):
    server, clock = new_server(tmp_path)
    store = server.store
    health = health_widget_data(store, 3)
    assert health["water"] == 0
    log_widget_health(store)
    assert health_widget_data(store, 3)["water"] == health["cup"]
    assert store.health.state["records"][-1]["source"] == "widget"
    event_type = health_widget_data(store, 4)["types"][0][0]
    log_widget_health(store, event_type)
    assert health_widget_data(store, 4, event_type)["days"][clock.now.day - 1] == 1
    assert store.health.state["events"][-1]["source"] == "widget"
    city = search_cities("Beijing")[0]
    store.footprints.save_visit({"cityID": city["id"], "date": {"precision": "unknown"}}, clock.now)
    store.footprints.set_resident(city["id"], clock.now)
    card = footprint_widget_data(store)
    assert card["metrics"]["cities"] == 1 and card["cities"][0]["id"] == card["resident"]["id"]
    x, y = project_widget_map(city["longitude"], city["latitude"])
    assert x > 0 and y < 0


@pytest.mark.skipif(sys.platform != "win32", reason="Needs the Windows message loop")
def test_native_message_registration_and_dispatch(tmp_path, monkeypatch):
    server, clock = new_server(tmp_path)
    store = server.store
    store.start_focus()
    primary = DesktopInstance(tmp_path)
    duplicate = DesktopInstance(tmp_path)
    desktop = WindowsDesktop(server, primary.name, tray=False)
    server.url = "http://127.0.0.1:9999/"
    opened = []
    browser = Event()

    def capture_route(url, route):
        opened.append((url, route))
        browser.set()

    monkeypatch.setattr("gaojiezou.desktop.open_window", capture_route)
    try:
        assert primary.owner and not duplicate.owner
        desktop.start()
        assert desktop.window
        assert desktop.session_registered and desktop.display_registered
        selected = route_index("gaojiezou://longGoals")
        assert duplicate.forward(selected) and browser.wait(3)
        assert opened == [(server.url, selected)]
        send = ctypes.WinDLL("user32").SendMessageW
        send.restype = ctypes.c_ssize_t
        send.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        clock.now += timedelta(minutes=15)
        send(desktop.window, MSG_SESSION, 7, 0)
        send(desktop.window, MSG_POWER, 4, 0)
        screen_off = ctypes.create_string_buffer(DISPLAY_GUID + bytes([4, 0, 0, 0, 0, 0, 0, 0]))
        send(desktop.window, MSG_POWER, 0x8013, ctypes.addressof(screen_off))
        clock.now += timedelta(hours=2)
        send(desktop.window, MSG_POWER, 18, 0)
        assert store.focus_elapsed() == 15 * 60
        assert store.library["activeFocus"]["pausedForSystem"]
        send(desktop.window, MSG_SESSION, 8, 0)
        assert store.library["activeFocus"]["pausedForSystem"]
        screen_on = ctypes.create_string_buffer(DISPLAY_GUID + bytes([4, 0, 0, 0, 1, 0, 0, 0]))
        send(desktop.window, MSG_POWER, 0x8013, ctypes.addressof(screen_on))
        clock.now += timedelta(minutes=5)
        assert store.focus_elapsed() == 20 * 60
        assert not store.library["activeFocus"]["pausedForSystem"]
    finally:
        desktop.close()
        duplicate.close()
        primary.close()
