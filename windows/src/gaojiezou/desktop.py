"""Windows session, power, notification area and desktop-window integration."""

from __future__ import annotations

import ctypes as C
import hashlib
import logging
import math
import os
import sys
import threading
import time
import uuid
from ctypes import wintypes as W
from pathlib import Path
from urllib.parse import quote, urlsplit

from gaojiezou import library
from gaojiezou.appwindow import EdgeWindow, bind as _binding, find_edge
from gaojiezou.errors import AppError
from gaojiezou.notifications import ToastResult, set_process_identity, submit_habit_toast
from gaojiezou.store import _habit_key, _scheduled

LOG = logging.getLogger(__name__)
ROUTES = (
    "", "focus", "sleep", "habits", "chores", "longGoals", "shortActions", "statistics",
    "health", "health/records", "health/trends", "health/events", "health/island",
    "health/water", "health/sleep", "health/meal", "health/exercise", "health/weight",
    "footprints", "footprints/trips", "footprints/timeline", "footprints/resident-city", "footprints/train",
    "farm", "pasture", "fishing", "today",
)
DISPLAY_GUID = uuid.UUID("2b84c20e-ad23-4ddf-93db-05ffbd7efca5").bytes_le
MSG_ENDSESSION, MSG_TIMER, MSG_POWER, MSG_SESSION = 0x16, 0x113, 0x218, 0x2B1
MSG_TRAY, MSG_OPEN, MSG_STOP = 0x8001, 0x8002, 0x8003
NIM_ADD, NIM_MODIFY, NIM_DELETE, NIM_SETVERSION = 0, 1, 2, 4
TOOLTIP_FLAGS = 0x84  # NIF_TIP | NIF_SHOWTIP (standard tooltip with version 4).
TOOLTIP_RETRY_SECONDS = 10


def route_index(uri: str | None) -> int:
    if not uri:
        return 0
    parsed = urlsplit(uri)
    if parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ValueError("不支持的搞节奏链接。")
    aliases = {"gaojiankang": "health", "gaozuji": "footprints"}
    path = (parsed.netloc + parsed.path).strip("/").lower()
    if parsed.scheme in aliases:
        path = "/".join(segment for segment in (aliases[parsed.scheme], path) if segment)
    elif parsed.scheme != "gaojiezou":
        raise ValueError("不支持的搞节奏链接。")
    path = {"health/overview": "health", "health/game": "health/island",
            "footprints/map": "footprints", "footprints/game": "footprints/train",
            "footprints/residentcity": "footprints/resident-city", "footprints/home": "footprints/resident-city"}.get(path, path)
    by_name = {name.lower(): i for i, name in enumerate(ROUTES) if name}
    try:
        return by_name[path]
    except KeyError as exc:
        raise ValueError("找不到该搞节奏页面。") from exc


def open_window(url: str, route: int = 0) -> bool:
    import webbrowser

    separator = "&" if "?" in url else "?"
    target = url if route == 0 else f"{url}{separator}route={quote('gaojiezou://' + ROUTES[route], safe='')}"
    return webbrowser.open(target)


def habit_counts(store, now) -> tuple[int, int]:
    doc = store.library or {}
    habits = [row for row in doc.get("habits", ()) if _scheduled(row, now, store.tz)]
    keys = set(doc.get("habitCompletionKeys", ()))
    return len(habits), sum(_habit_key(row["id"], now, store.tz) in keys for row in habits)


def _tooltip_minute_count(minutes: int) -> str:
    digits = str(minutes)
    if len(digits) > 9:  # Keep an unusually large imported estimate within szTip.
        return f"≈{digits[0]}.{digits[1:3]}e{len(digits) - 1}"
    return digits


def focus_tray_tooltip(store) -> str:
    english = store.settings.get("language") == "en"
    app = "Rhythm" if english else "搞节奏"
    library = store.library or {}
    focus = library.get("activeFocus")
    if not focus:
        return app

    running = focus.get("segmentStartedAt") is not None
    if running:
        status = "Focus" if english else "专注"
    elif focus.get("pausedForSystem"):
        status = "Focus paused by Windows" if english else "系统暂停专注"
    else:
        status = "Focus paused" if english else "专注已暂停"

    elapsed = store.focus_elapsed()
    elapsed_minutes = int(max(0, elapsed) // 60) if math.isfinite(elapsed) else 0
    linked = focus.get("linkedActionID")
    action = next((item for item in library.get("shortActions", ()) if item.get("id") == linked), {}) if linked else {}
    target = action.get("estimatedMinutes")
    if type(target) is float and target.is_integer():
        target = int(target)

    if type(target) is not int or target <= 0:
        minutes = _tooltip_minute_count(elapsed_minutes)
        detail = f"{minutes} min elapsed (no countdown)" if english else f"已专注 {minutes} 分钟（无倒计时）"
    elif elapsed_minutes < target:
        # Integer-minute goals show one minute left until the final minute elapses.
        minutes = _tooltip_minute_count(target - elapsed_minutes)
        detail = f"{minutes} min left" if english else f"剩余 {minutes} 分钟"
    else:
        extra = elapsed_minutes - target
        detail = "target reached" if english else "目标已达"
        if extra:
            minutes = _tooltip_minute_count(extra)
            detail += f" (+{minutes} min)" if english else f"（额外 {minutes} 分钟）"
    return f"{app} · {status}: {detail}" if english else f"{app} · {status} · {detail}"


class BackgroundRhythm:
    def __init__(self, server, notify):
        self.server = server
        self.notify = notify
        self.inactive: set[str] = set()
        self.last_save = time.monotonic()
        self.last_sleep_sync = self.last_save
        self.last_reminder_check = None
        self.reminder_marker = server.store.directory / "last-habit-reminder.txt"
        try:
            self.last_reminder = self.reminder_marker.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            self.last_reminder = ""

    def system_change(self, source: str, inactive: bool) -> None:
        with self.server.lock:
            if self.server.shutdown_requested.is_set() or getattr(self.server, "exiting", False):
                return
            was_inactive = bool(self.inactive)
            if inactive:
                self.inactive.add(source)
            else:
                self.inactive.discard(source)
            self._reconcile_focus()
            if was_inactive and not self.inactive:
                self.server.store.synchronize_sleep_records()
                self.last_sleep_sync = time.monotonic()

    def _reconcile_focus(self) -> None:
        store = self.server.store
        focus = (store.library or {}).get("activeFocus")
        if not focus or store.status != "ready":
            return
        if self.inactive and focus.get("segmentStartedAt") is not None:
            store.pause_focus(for_system=True)
        elif not self.inactive and focus.get("pausedForSystem") and focus.get("segmentStartedAt") is None:
            store.resume_focus()

    def tick(self) -> None:
        with self.server.lock:
            if self.server.shutdown_requested.is_set() or getattr(self.server, "exiting", False):
                return
            store = self.server.store
            if store.status != "ready" or store.library is None:
                return
            now = store.now()
            tick = time.monotonic()
            if tick - self.last_sleep_sync >= 30:
                self.last_sleep_sync = tick
                store.synchronize_sleep_records(now)
            self._reconcile_focus()
            focus = store.library.get("activeFocus") or {}
            if focus.get("segmentStartedAt") is not None or store.library.get("activeSleep"):
                store.synchronize(now)
                if tick - self.last_save >= 30:
                    self.last_save = tick
                    store.save()
            settings = store.settings
            day = now.date().isoformat()
            check = self.last_reminder_check
            self.last_reminder_check = now
            due = settings.get("habitReminderHour", 21), settings.get("habitReminderMinute", 0)
            minute = now.hour, now.minute
            crossed_due_today = check is not None and check.date() == now.date() and (check.hour, check.minute) < due <= minute
            if (settings.get("habitReminderEnabled") and day != self.last_reminder
                    and (minute == due or crossed_due_today)):
                total, complete = habit_counts(store, now)
                pending = total - complete
                if pending:
                    title = "Rhythm" if settings.get("language") == "en" else "搞节奏"
                    body = (f"You have {pending} check-ins left today." if title == "Rhythm"
                            else f"今天还有 {pending} 项打卡未完成")
                    if self.notify(title, body):
                        self.last_reminder = day
                        library.atomic_write(self.reminder_marker, (day + "\n").encode("ascii"))


class GUID(C.Structure):
    _fields_ = [("value", C.c_ubyte * 16)]


class NotifyIcon(C.Structure):
    _fields_ = [
        ("size", W.DWORD), ("window", W.HWND), ("id", W.UINT), ("flags", W.UINT),
        ("callback", W.UINT), ("icon", W.HICON), ("tip", W.WCHAR * 128),
        ("state", W.DWORD), ("state_mask", W.DWORD), ("info", W.WCHAR * 256),
        ("version", W.UINT), ("title", W.WCHAR * 64), ("info_flags", W.DWORD),
        ("guid", GUID), ("balloon_icon", W.HICON),
    ]


def _instance_name(directory: Path) -> str:
    key = os.path.normcase(str(directory.resolve()))
    return "GaoJieZou.Rhythm." + hashlib.sha256(key.encode("utf-8")).hexdigest()[:24]


class DesktopInstance:
    """Serialize app owners by library directory and forward second launches."""

    def __init__(self, directory: Path):
        self.name = _instance_name(directory)
        kernel = C.WinDLL("kernel32", use_last_error=True)
        C.set_last_error(0)
        self.handle = _binding(kernel, "CreateMutexW", W.HANDLE, C.c_void_p, W.BOOL, W.LPCWSTR)(
            None, False, "Local\\" + self.name)
        if not self.handle:
            raise C.WinError(C.get_last_error())
        self.owner = C.get_last_error() != 183  # ERROR_ALREADY_EXISTS
        self.close_handle = _binding(kernel, "CloseHandle", W.BOOL, W.HANDLE)

    def forward(self, route: int, widgets: bool = False) -> bool:
        user = C.WinDLL("user32", use_last_error=True)
        find = _binding(user, "FindWindowW", W.HWND, W.LPCWSTR, W.LPCWSTR)
        post = _binding(user, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
        window_pid = _binding(user, "GetWindowThreadProcessId", W.DWORD, W.HWND, C.POINTER(W.DWORD))
        allow_focus = _binding(user, "AllowSetForegroundWindow", W.BOOL, W.DWORD)
        for _attempt in range(20):
            window = find(self.name, None)
            if window:
                owner = W.DWORD()
                if window_pid(window, C.byref(owner)):
                    allow_focus(owner.value)
                return bool(post(window, MSG_OPEN, route, int(widgets)))
            time.sleep(0.1)
        return False

    def close(self) -> None:
        self.close_handle(self.handle)


class WindowsDesktop:
    def __init__(self, server, name: str, tray: bool = True, allow_main: bool = True):
        self.server = server
        self.name = name
        self.tray = tray
        self.allow_main = allow_main
        self.browser = None
        self.window = None
        self.widget = None
        self.tray_added = False
        self._sent_tooltip = None
        self._tooltip_retry_at = 0.0
        self.failure = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, name="gaojiezou-windows", daemon=True)
        self.background = BackgroundRhythm(server, self._notify)

    def start(self) -> None:
        self.toast_identity = self.tray and set_process_identity()
        user = C.WinDLL("user32", use_last_error=True)
        if hasattr(user, "SetProcessDpiAwarenessContext"):
            _binding(user, "SetProcessDpiAwarenessContext", W.BOOL, C.c_void_p)(-4)  # Per-monitor v2.
        self.thread.start()
        if not self.ready.wait(5):
            raise OSError("Windows 桌面事件窗口启动超时。")
        if self.failure:
            raise self.failure

    def show_widgets(self) -> None:
        if self.window:
            self.post(self.window, MSG_OPEN, 0, 1)

    def show_main(self, route: int = 0) -> None:
        if self.window:
            self.post(self.window, MSG_OPEN, route, 0)

    def _show_main(self, route: int = 0) -> None:
        if not self.allow_main:
            return
        if self.browser is None:
            if executable := find_edge():
                self.browser = EdgeWindow(executable)
        target = self.server.url + f"?desktop={self.server.window_revision}"
        if self.browser is not None:
            link = "gaojiezou://" + ROUTES[route] if route else ""
            edge_target = target + "&route=" + quote(link, safe="") if link else target
            try:
                if self.browser.show(edge_target) and link:
                    self.server.navigate_window(link)
                return
            except OSError:
                self.browser.close()
                self.browser = None
                LOG.exception("Unable to launch the owned Edge window")
        if not open_window(target, route):
            english = self.server.store.settings.get("language") == "en"
            text = "Couldn't open the Rhythm window." if english else "无法打开搞节奏窗口。"
            self._message_box(text, "Rhythm" if english else "搞节奏", 0x10)

    def close(self) -> None:
        if self.window:
            self.post(self.window, MSG_STOP, 0, 0)
        if self.thread.is_alive():
            self.thread.join(timeout=10)

    def _run(self) -> None:
        try:
            self._message_loop()
        except Exception as exc:
            self.failure = exc
            LOG.exception("Windows desktop integration failed")
            if self.ready.is_set():
                self._request_exit(system=True)
        finally:
            self.ready.set()

    def _message_loop(self):
        self.user = user = C.WinDLL("user32", use_last_error=True)
        kernel = C.WinDLL("kernel32", use_last_error=True)
        shell = C.WinDLL("shell32", use_last_error=True)
        wts = C.WinDLL("wtsapi32", use_last_error=True)
        lresult = C.c_ssize_t
        wndproc_type = C.WINFUNCTYPE(lresult, W.HWND, W.UINT, W.WPARAM, W.LPARAM)

        class WindowClass(C.Structure):
            _fields_ = [("style", W.UINT), ("proc", wndproc_type), ("class_extra", C.c_int),
                        ("window_extra", C.c_int), ("module", W.HINSTANCE), ("icon", W.HICON),
                        ("cursor", W.HANDLE), ("background", W.HBRUSH), ("menu", W.LPCWSTR), ("name", W.LPCWSTR)]

        module = _binding(kernel, "GetModuleHandleW", W.HMODULE, W.LPCWSTR)(None)
        self.process = _binding(kernel, "GetCurrentProcess", W.HANDLE)()
        self.read_memory = _binding(kernel, "ReadProcessMemory", W.BOOL, W.HANDLE, C.c_void_p,
                                    C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t))
        proc = wndproc_type(self._messages)
        self.def_window = _binding(user, "DefWindowProcW", lresult, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
        self.post = _binding(user, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
        self.quit_loop = _binding(user, "PostQuitMessage", None, C.c_int)
        self.notify_icon = _binding(shell, "Shell_NotifyIconW", W.BOOL, W.DWORD, C.POINTER(NotifyIcon))
        self.taskbar_restored = _binding(user, "RegisterWindowMessageW", W.UINT, W.LPCWSTR)("TaskbarCreated")
        register = _binding(user, "RegisterClassW", W.ATOM, C.POINTER(WindowClass))
        unregister = _binding(user, "UnregisterClassW", W.BOOL, W.LPCWSTR, W.HINSTANCE)
        create = _binding(user, "CreateWindowExW", W.HWND, W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD,
                          C.c_int, C.c_int, C.c_int, C.c_int, W.HWND, W.HMENU, W.HINSTANCE, C.c_void_p)
        destroy = _binding(user, "DestroyWindow", W.BOOL, W.HWND)
        get_message = _binding(user, "GetMessageW", C.c_int, C.POINTER(W.MSG), W.HWND, W.UINT, W.UINT)
        dispatch = _binding(user, "DispatchMessageW", lresult, C.POINTER(W.MSG))
        register_session = _binding(wts, "WTSRegisterSessionNotification", W.BOOL, W.HWND, W.DWORD)
        unregister_session = _binding(wts, "WTSUnRegisterSessionNotification", W.BOOL, W.HWND)
        register_power = _binding(user, "RegisterPowerSettingNotification", W.HANDLE, W.HANDLE, C.POINTER(GUID), W.DWORD)
        unregister_power = _binding(user, "UnregisterPowerSettingNotification", W.BOOL, W.HANDLE)
        timer = _binding(user, "SetTimer", C.c_size_t, W.HWND, C.c_size_t, W.UINT, C.c_void_p)
        kill_timer = _binding(user, "KillTimer", W.BOOL, W.HWND, C.c_size_t)

        window_class = WindowClass(0, proc, 0, 0, module, None, None, None, None, self.name)
        if not register(C.byref(window_class)):
            raise C.WinError(C.get_last_error())
        window = create(0, self.name, "", 0, 0, 0, 0, 0, None, None, module, None)
        if not window:
            unregister(self.name, module)
            raise C.WinError(C.get_last_error())
        self.window = window
        self.session_registered = bool(register_session(window, 0))
        power = register_power(window, C.byref(GUID((C.c_ubyte * 16).from_buffer_copy(DISPLAY_GUID))), 0)
        self.display_registered = bool(power)
        self.icon = self._load_icon(shell)
        self.tray_added = self.tray and self._register_icon()
        timer_id = timer(window, 1, 1000, None)
        self.ready.set()
        try:
            msg = W.MSG()
            while (status := get_message(C.byref(msg), None, 0, 0)) > 0:
                dispatch(C.byref(msg))
            if status < 0:
                raise C.WinError(C.get_last_error())
        finally:
            if self.widget:
                self.widget.close()
            if timer_id:
                kill_timer(window, timer_id)
            if self.tray_added:
                self.notify_icon(NIM_DELETE, C.byref(self._notification()))
            if self.browser:
                self.browser.close()
            if self.icon and getattr(sys, "frozen", False):
                _binding(user, "DestroyIcon", W.BOOL, W.HICON)(self.icon)
            if power:
                unregister_power(power)
            if self.session_registered:
                unregister_session(window)
            destroy(window)
            self.window = None
            unregister(self.name, module)

    def _load_icon(self, shell):
        if getattr(sys, "frozen", False):
            icon = W.HICON()
            extract = _binding(shell, "ExtractIconExW", W.UINT, W.LPCWSTR, C.c_int,
                               C.POINTER(W.HICON), C.POINTER(W.HICON), W.UINT)
            if extract(sys.executable, 0, None, C.byref(icon), 1) == 1:
                return icon.value
            return None
        return _binding(self.user, "LoadIconW", W.HICON, W.HINSTANCE, C.c_void_p)(None, 32512)

    def _notification(self) -> NotifyIcon:
        icon = NotifyIcon()
        icon.size = C.sizeof(NotifyIcon)
        icon.window = self.window
        icon.id = 1
        return icon

    def _register_icon(self) -> bool:
        icon = self._notification()
        icon.flags = 0x03 | TOOLTIP_FLAGS  # Callback, icon and standard tooltip.
        icon.callback = MSG_TRAY
        icon.icon = self.icon
        with self.server.lock:
            icon.tip = focus_tray_tooltip(self.server.store)
        if not self.notify_icon(NIM_ADD, C.byref(icon)) and (
                not self.tray_added or not self.notify_icon(NIM_MODIFY, C.byref(icon))):
            return False
        icon.version = 4
        self.notify_icon(NIM_SETVERSION, C.byref(icon))
        self._sent_tooltip = icon.tip
        self._tooltip_retry_at = 0.0
        return True

    def _refresh_tray_tooltip(self) -> None:
        if not self.tray_added:
            return
        with self.server.lock:
            if self.server.shutdown_requested.is_set() or getattr(self.server, "exiting", False):
                return
            tip = focus_tray_tooltip(self.server.store)
        if tip == self._sent_tooltip or time.monotonic() < self._tooltip_retry_at:
            return
        icon = self._notification()
        icon.flags = TOOLTIP_FLAGS
        icon.tip = tip
        if self.notify_icon(NIM_MODIFY, C.byref(icon)):
            self._sent_tooltip = tip
            self._tooltip_retry_at = 0.0
        else:
            self._tooltip_retry_at = time.monotonic() + TOOLTIP_RETRY_SECONDS

    def _notify(self, title: str, message: str) -> bool:
        if self.toast_identity:
            result = submit_habit_toast(title, message)
            if result is not ToastResult.UNAVAILABLE:
                return True
        if not self.tray_added:
            return False
        icon = self._notification()
        icon.flags = 0x10  # NIF_INFO
        icon.info_flags = 0x81  # NIIF_INFO | NIIF_RESPECT_QUIET_TIME
        icon.title, icon.info = title, message
        return bool(self.notify_icon(NIM_MODIFY, C.byref(icon)))

    def _messages(self, window, message, wparam, lparam):
        try:
            if message == MSG_SESSION:
                if wparam in (1, 2, 3, 4):  # Console/RDP connect and disconnect.
                    self.background.system_change("session", wparam in (2, 4))
                elif wparam in (7, 8):  # WTS_SESSION_LOCK / UNLOCK.
                    self.background.system_change("lock", wparam == 7)
                self._refresh_tray_tooltip()
            elif message == MSG_POWER:
                if wparam in (4, 7, 18):  # Suspend and its two resume variants.
                    self.background.system_change("suspend", wparam == 4)
                elif wparam == 0x8013 and lparam:  # PBT_POWERSETTINGCHANGE.
                    payload = C.create_string_buffer(24)
                    if self.read_memory(self.process, lparam, payload, len(payload), None):
                        data = payload.raw
                        if data[:16] == DISPLAY_GUID and int.from_bytes(data[16:20], "little") == 4:
                            self.background.system_change("display", not int.from_bytes(data[20:24], "little"))
                self._refresh_tray_tooltip()
                return 1
            elif message == MSG_TIMER:
                self.background.tick()
                self._refresh_tray_tooltip()
                if self.browser and not self.browser.seen:
                    self.browser.window()
            elif (self.taskbar_restored and message == self.taskbar_restored and self.tray
                  and not self.server.shutdown_requested.is_set() and not getattr(self.server, "exiting", False)):
                self.tray_added = self._register_icon()
            elif message == MSG_TRAY:
                event = lparam & 0xFFFF
                if getattr(self.server, "exiting", False):
                    return 0
                if event in (0x202, 0x400, 0x401):  # Mouse, selection and keyboard selection.
                    self._show_main()
                elif event == 0x405:  # Balloon clicked.
                    self._show_main(route_index("gaojiezou://habits"))
                elif event in (0x205, 0x7B):  # Legacy mouse callback and v4 context menu.
                    self._menu(wparam if event == 0x7B else None)
            elif message == MSG_OPEN:
                if getattr(self.server, "exiting", False):
                    return 0
                if lparam == 1:
                    if self.widget is None:
                        from gaojiezou.widgets import WidgetHost

                        self.widget = WidgetHost(self.server, lambda _url, route: self.show_main(route))
                    self.widget.show()
                elif 0 <= wparam < len(ROUTES):
                    self._show_main(wparam)
            elif message == MSG_ENDSESSION and wparam:
                self._request_exit(system=True)
            elif message == 0x10:  # Close requested on the native host, not the separate app window.
                self._request_exit()
                return 0
            elif message == MSG_STOP:
                self.quit_loop(0)
                return 0
        except Exception:
            LOG.exception("Windows desktop event failed")
        return self.def_window(window, message, wparam, lparam)

    def _menu(self, position: int | None = None) -> None:
        user = self.user
        menu = _binding(user, "CreatePopupMenu", W.HMENU)()
        if not menu:
            return
        append = _binding(user, "AppendMenuW", W.BOOL, W.HMENU, W.UINT, C.c_size_t, W.LPCWSTR)
        destroy = _binding(user, "DestroyMenu", W.BOOL, W.HMENU)
        track = _binding(user, "TrackPopupMenu", W.BOOL, W.HMENU, W.UINT, C.c_int, C.c_int,
                         C.c_int, W.HWND, C.c_void_p)
        english = self.server.store.settings.get("language") == "en"
        append(menu, 0, 1, "Open Rhythm" if english else "打开搞节奏")
        append(menu, 0, 2, "Desktop widgets" if english else "桌面小组件")
        append(menu, 0x800, 0, None)
        append(menu, 0, 3, "Quit" if english else "退出")
        if position is None:
            point = W.POINT()
            _binding(user, "GetCursorPos", W.BOOL, C.POINTER(W.POINT))(C.byref(point))
        else:
            point = W.POINT(C.c_short(position & 0xFFFF).value, C.c_short((position >> 16) & 0xFFFF).value)
        _binding(user, "SetForegroundWindow", W.BOOL, W.HWND)(self.window)
        command = track(menu, 0x182, point.x, point.y, 0, self.window, None)
        destroy(menu)
        self.post(self.window, 0, 0, 0)
        self._tray_command(command)

    def _tray_command(self, command: int) -> None:
        if command == 1:
            self._show_main()
        elif command == 2:
            self.show_widgets()
        elif command == 3:
            english = self.server.store.settings.get("language") == "en"
            text = ("Rhythm will save records and pause any running focus session." if english else
                    "应用将保存记录并暂停正在运行的专注。")
            title = "Quit Rhythm?" if english else "退出搞节奏？"
            if self._message_box(text, title, 0x121) == 1:  # OK/Cancel, question, default Cancel.
                self._request_exit()

    def _message_box(self, text: str, title: str, style: int) -> int:
        message_box = _binding(self.user, "MessageBoxW", C.c_int, W.HWND, W.LPCWSTR, W.LPCWSTR, W.UINT)
        return message_box(self.window, text, title, style)

    def _request_exit(self, system: bool = False) -> None:
        try:
            self.server.request_exit()
        except (AppError, OSError) as error:
            LOG.exception("Unable to save Rhythm when quitting")
            if system:
                self.server.shutdown_requested.set()
            else:
                self._message_box(str(error), "搞节奏", 0x10)
