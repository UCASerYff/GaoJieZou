from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from datetime import date, datetime, timedelta, timezone
from threading import Event, Lock
from types import SimpleNamespace
from xml.etree import ElementTree

import pytest

from gaojiezou.desktop import DISPLAY_GUID, BackgroundRhythm, DesktopInstance, MSG_POWER, MSG_SESSION, WindowsDesktop, route_index
from gaojiezou.footprints import search_cities
from gaojiezou.notifications import ToastResult, habit_toast_xml
from gaojiezou.store import RhythmStore
from gaojiezou.web import RhythmServer
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


def test_reminder_recovers_from_suspend_across_due_minute_on_same_day(tmp_path):
    server, clock = new_server(tmp_path)
    server.store.save_habit({"title": "Read"})
    server.store.update_settings({"habitReminderHour": 21, "habitReminderMinute": 26, "habitReminderEnabled": True})
    notices = []

    def notify(*text):
        notices.append(text)
        return True

    events = BackgroundRhythm(server, notify)
    events.tick()
    clock.now += timedelta(minutes=25)
    events.tick()
    assert notices == [("搞节奏", "今天还有 1 项打卡未完成")]


def test_toast_payload_and_tray_fallback_preserve_windows_notification_preference(monkeypatch, tmp_path):
    document = ElementTree.fromstring(habit_toast_xml("搞节奏", "A & B < 3"))
    assert document.attrib == {"activationType": "protocol", "launch": "gaojiezou://habits"}
    assert [text.text for text in document.findall("./visual/binding/text")] == ["搞节奏", "A & B < 3"]

    desktop = WindowsDesktop(SimpleNamespace(store=SimpleNamespace(directory=tmp_path)), "test")
    desktop.toast_identity, desktop.tray_added = True, True
    deliveries = []

    def send_to_tray(message, icon):
        deliveries.append((message, icon._obj.info))
        return True

    desktop.notify_icon = send_to_tray
    monkeypatch.setattr("gaojiezou.desktop.submit_habit_toast", lambda *_: ToastResult.DISABLED)
    assert desktop._notify("Rhythm", "Due")
    assert deliveries == []

    monkeypatch.setattr("gaojiezou.desktop.submit_habit_toast", lambda *_: ToastResult.UNAVAILABLE)
    assert desktop._notify("Rhythm", "Due")
    assert deliveries == [(1, "Due")]


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
    assert route_index("gaojiezou://health/overview") == route_index("gaojiezou://health")
    assert route_index("gaojiezou://footprints/map") == route_index("gaojiezou://footprints")
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

    def capture_route(route):
        opened.append(route)
        browser.set()

    monkeypatch.setattr(desktop, "_show_main", capture_route)
    try:
        assert primary.owner and not duplicate.owner
        desktop.start()
        assert desktop.window
        assert desktop.session_registered and desktop.display_registered
        selected = route_index("gaojiezou://longGoals")
        assert duplicate.forward(selected) and browser.wait(3)
        assert opened == [selected]
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


def test_shutdown_stays_open_on_save_error_and_persists_focus_once(tmp_path, monkeypatch):
    source, clock = new_server(tmp_path)
    store = source.store
    server = RhythmServer(store)
    store.start_focus()
    clock.now += timedelta(minutes=15)
    real_save = store.prepare_for_exit
    calls = []

    def fail():
        calls.append("failure")
        raise OSError("Synthetic exit write failure")

    def save():
        calls.append("save")
        real_save()

    try:
        monkeypatch.setattr(store, "prepare_for_exit", fail)
        with pytest.raises(OSError):
            server.request_exit()
        assert not server.exiting and not server.shutdown_requested.is_set()
        assert store.library["activeFocus"]["segmentStartedAt"] is not None

        monkeypatch.setattr(store, "prepare_for_exit", save)
        server.begin_exit()  # HTTP accepts after saving and acknowledges before signaling.
        assert server.exiting and not server.shutdown_requested.is_set()
        server.request_exit()  # Native exit shares the same commit.
        assert server.shutdown_requested.is_set()
        assert calls == ["failure", "save"]
        assert store.library["activeFocus"]["segmentStartedAt"] is None
        assert store.focus_elapsed() == 15 * 60
        reopened = RhythmStore(tmp_path, tz=timezone.utc, clock=lambda: clock.now)
        assert reopened.focus_elapsed() == 15 * 60
    finally:
        server.server_close()


def test_a_single_browser_receives_deep_links_only_when_the_window_is_reused(tmp_path):
    source, _ = new_server(tmp_path)
    server = RhythmServer(source.store)
    desktop = WindowsDesktop(server, "test")
    urls = []

    def show(url):
        urls.append(url)
        return len(urls) > 1

    desktop.browser = SimpleNamespace(show=show)
    try:
        desktop._show_main(route_index("gaojiezou://health"))
        assert "?desktop=0&route=gaojiezou%3A%2F%2Fhealth" in urls[-1]
        assert server.window_revision == 0
        desktop._show_main()
        assert urls[-1].endswith("?desktop=0")
        assert server.window_revision == 0
        desktop._show_main(route_index("gaojiezou://today"))
        assert server.window_update(0) == {"revision": 1, "route": "gaojiezou://today", "exiting": False}
        desktop._show_main(route_index("gaojiezou://footprints/train"))
        assert server.window_update(1) == {"revision": 2, "route": "gaojiezou://footprints/train", "exiting": False}
        server.request_exit()
        assert server.window_update(2)["exiting"]
    finally:
        server.server_close()
