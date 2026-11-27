from datetime import datetime, timedelta, timezone
from threading import Event, Lock
from types import SimpleNamespace

from gaojiezou.desktop import (
    MSG_POWER, MSG_SESSION, MSG_TIMER, NIM_ADD, NIM_MODIFY, NIM_SETVERSION,
    TOOLTIP_FLAGS, WindowsDesktop, focus_tray_tooltip,
)
from gaojiezou.store import RhythmStore


def sample(tmp_path):
    clock = SimpleNamespace(now=datetime(2026, 11, 27, 10, tzinfo=timezone.utc))
    store = RhythmStore(tmp_path, tz=timezone.utc, clock=lambda: clock.now)
    store.create_library()
    action = store.save_action({"title": "Synthetic target", "estimatedMinutes": 25})
    server = SimpleNamespace(store=store, lock=Lock(), shutdown_requested=Event(), exiting=False)
    return server, clock, action


def test_focus_tooltip_uses_action_estimate_and_effective_session_time(tmp_path):
    server, clock, action = sample(tmp_path)
    store = server.store
    assert focus_tray_tooltip(store) == "搞节奏"
    store.start_focus(action["id"])
    assert focus_tray_tooltip(store) == "搞节奏 · 专注 · 剩余 25 分钟"

    clock.now += timedelta(seconds=59)
    assert focus_tray_tooltip(store).endswith("剩余 25 分钟")
    clock.now += timedelta(seconds=1)
    store.pause_focus()
    clock.now += timedelta(hours=2)
    assert store.focus_elapsed() == 60
    assert focus_tray_tooltip(store) == "搞节奏 · 专注已暂停 · 剩余 24 分钟"

    store.resume_focus()
    clock.now += timedelta(minutes=24)
    assert focus_tray_tooltip(store) == "搞节奏 · 专注 · 目标已达"
    clock.now += timedelta(seconds=59)
    assert focus_tray_tooltip(store).endswith("目标已达")
    clock.now += timedelta(seconds=1)
    assert focus_tray_tooltip(store) == "搞节奏 · 专注 · 目标已达（额外 1 分钟）"
    store.finish_focus()
    assert focus_tray_tooltip(store) == "搞节奏"


def test_no_target_and_missing_link_do_not_invent_a_countdown(tmp_path):
    server, clock, action = sample(tmp_path)
    store = server.store
    store.update_settings({"language": "en"})
    store.start_focus()
    clock.now += timedelta(minutes=3, seconds=10)
    assert focus_tray_tooltip(store) == "Rhythm · Focus: 3 min elapsed (no countdown)"
    store.cancel_focus()
    store.start_focus(action["id"])
    store.library["shortActions"].remove(action)
    assert focus_tray_tooltip(store) == "Rhythm · Focus: 0 min elapsed (no countdown)"
    store.pause_focus(for_system=True)
    clock.now += timedelta(minutes=3)
    assert focus_tray_tooltip(store) == "Rhythm · Focus paused by Windows: 0 min elapsed (no countdown)"


def test_large_target_fits_the_native_tooltip(tmp_path):
    server, _, action = sample(tmp_path)
    store = server.store
    action["estimatedMinutes"] = 10**150
    store.start_focus(action["id"])
    native, calls = observe_tray(server)
    assert native.tray_added and "≈1.00e150" in calls[0][3]
    assert len(calls[0][3]) < 128


def observe_tray(server, callback=None):
    native = WindowsDesktop(server, "focus-tooltip-test")
    native.window = 42
    native.icon = 51
    native.taskbar_restored = 0xA011
    native.def_window = lambda *_: 0
    calls = []

    def observe(command, icon):
        row = icon._obj
        calls.append((command, row.id, row.flags, row.tip, row.info))
        return callback(command) if callback else True

    native.notify_icon = observe
    native.tray_added = native._register_icon()
    return native, calls


def test_tray_uses_one_icon_no_balloon_and_reloads_tip_after_explorer_restart(tmp_path):
    server, clock, action = sample(tmp_path)
    native, calls = observe_tray(server)
    store = server.store
    assert [row[0] for row in calls] == [NIM_ADD, NIM_SETVERSION]
    assert calls[0][3] == "搞节奏"

    def event(message, wparam=0):
        native._messages(native.window, message, wparam, 0)

    store.start_focus(action["id"])
    event(MSG_TIMER)
    for _ in range(59):
        clock.now += timedelta(seconds=1)
        event(MSG_TIMER)
    assert calls[2:] == [(NIM_MODIFY, 1, TOOLTIP_FLAGS, "搞节奏 · 专注 · 剩余 25 分钟", "")]

    clock.now += timedelta(seconds=1)
    event(MSG_TIMER)
    assert calls[-1][3].endswith("剩余 24 分钟")
    event(MSG_SESSION, 7)
    assert calls[-1][3] == "搞节奏 · 系统暂停专注 · 剩余 24 分钟"
    pause_count = len(calls)
    event(MSG_POWER, 4)
    clock.now += timedelta(minutes=10)
    event(MSG_TIMER)
    event(MSG_SESSION, 8)
    assert len(calls) == pause_count
    event(MSG_POWER, 18)
    assert calls[-1][3] == "搞节奏 · 专注 · 剩余 24 分钟"
    store.pause_focus()
    event(MSG_TIMER)
    assert calls[-1][3] == "搞节奏 · 专注已暂停 · 剩余 24 分钟"

    event(native.taskbar_restored)
    assert [row[0] for row in calls[-2:]] == [NIM_ADD, NIM_SETVERSION]
    assert calls[-2][3] == calls[-3][3]
    restart_count = len(calls)
    event(MSG_TIMER)
    assert len(calls) == restart_count
    store.cancel_focus()
    event(MSG_TIMER)
    assert calls[-1] == (NIM_MODIFY, 1, TOOLTIP_FLAGS, "搞节奏", "")

    server.exiting = True
    store.update_settings({"language": "en"})
    quit_count = len(calls)
    event(MSG_TIMER)
    event(native.taskbar_restored)
    assert len(calls) == quit_count
    assert all(row[1] == 1 and row[4] == "" for row in calls)


def test_failed_tip_update_is_retried_with_backoff(tmp_path, monkeypatch):
    server, _, action = sample(tmp_path)
    clock = SimpleNamespace(tick=100, fail=True)
    monkeypatch.setattr("gaojiezou.desktop.time.monotonic", lambda: clock.tick)
    native, calls = observe_tray(server, callback=lambda command: command != NIM_MODIFY or not clock.fail)
    server.store.start_focus(action["id"])
    native._refresh_tray_tooltip()
    first = calls[-1]
    assert first[0] == NIM_MODIFY
    clock.tick += 9
    native._refresh_tray_tooltip()
    assert calls.count(first) == 1
    clock.fail = False
    clock.tick += 1
    native._refresh_tray_tooltip()
    native._refresh_tray_tooltip()
    assert calls.count(first) == 2
