"""Own the Edge app window without attaching to the user's other browser windows."""

from __future__ import annotations

import ctypes as C
import logging
import shutil
import subprocess
import tempfile
import time
import uuid
from ctypes import wintypes as W
from pathlib import Path

from gaojiezou.notifications import APP_USER_MODEL_ID
from gaojiezou.resources import asset_dir


LOG = logging.getLogger(__name__)


def bind(dll, name, result, *args):
    function = getattr(dll, name)
    function.restype = result
    function.argtypes = args
    return function


def find_edge() -> Path | None:
    import winreg

    key_name = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            with winreg.OpenKey(hive, key_name) as key:
                executable = Path(winreg.QueryValue(key, None))
            if executable.is_file():
                return executable
        except OSError:
            continue
    return None


class JobLimits(C.Structure):
    _fields_ = [("process_time", C.c_int64), ("job_time", C.c_int64), ("flags", W.DWORD),
                ("min_working_set", C.c_size_t), ("max_working_set", C.c_size_t),
                ("active_limit", W.DWORD), ("affinity", C.c_size_t), ("priority", W.DWORD),
                ("scheduling", W.DWORD)]


class ExtendedLimits(C.Structure):
    _fields_ = [("basic", JobLimits), ("io", C.c_uint64 * 6), ("memory", C.c_size_t * 4)]


class PropertyKey(C.Structure):
    _fields_ = [("format_id", C.c_ubyte * 16), ("pid", W.DWORD)]


class PropVariantValue(C.Union):
    _fields_ = [("pointer", C.c_void_p), ("boolean", C.c_short), ("storage", C.c_uint64 * 2)]


class PropVariant(C.Structure):
    _fields_ = [("vt", C.c_ushort), ("reserved", C.c_ushort * 3),
                ("value", PropVariantValue)]


_APP_MODEL_FORMAT = (C.c_ubyte * 16).from_buffer_copy(uuid.UUID("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3").bytes_le)
_PROPERTY_STORE_IID = (C.c_ubyte * 16).from_buffer_copy(uuid.UUID("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99").bytes_le)
_RELAUNCH_COMMAND, _RELAUNCH_ICON, _RELAUNCH_NAME, _APP_ID, _PREVENT_PINNING = (2, 3, 4, 5, 9)
_VT_EMPTY, _VT_BOOL, _VT_LPWSTR = 0, 11, 31
_WM_SETICON, _WM_GETICON = 0x0080, 0x007F
_MAX_RELAUNCH_PROPERTY_UNITS = 259  # MAX_PATH minus the terminator.


class _WindowProperties:
    def __init__(self, window):
        self.ole = C.WinDLL("ole32")
        self.shell = C.WinDLL("shell32")
        self.window = window
        self.store = C.c_void_p()
        self.release = None
        self.initialized = False

    def __enter__(self):
        result = bind(self.ole, "CoInitializeEx", C.c_long, C.c_void_p, W.DWORD)(None, 2)
        if result < 0 and result & 0xFFFFFFFF != 0x80010106:  # RPC_E_CHANGED_MODE: COM is already active.
            return None
        self.initialized = result >= 0
        get_store = bind(self.shell, "SHGetPropertyStoreForWindow", C.c_long, W.HWND, C.c_void_p,
                         C.POINTER(C.c_void_p))
        if get_store(self.window, C.byref(_PROPERTY_STORE_IID), C.byref(self.store)) < 0 or not self.store:
            return None
        table = C.cast(self.store, C.POINTER(C.POINTER(C.c_void_p))).contents
        property_method = C.WINFUNCTYPE(C.c_long, C.c_void_p, C.POINTER(PropertyKey), C.POINTER(PropVariant))
        self.release = C.WINFUNCTYPE(W.ULONG, C.c_void_p)(table[2])
        self.get = property_method(table[5])
        self.set = property_method(table[6])
        return self

    def __exit__(self, *_exc):
        if self.release is not None:
            self.release(self.store)
        if self.initialized:
            bind(self.ole, "CoUninitialize", None)()

    def read(self, pid: int) -> tuple[int, str | bool | None] | None:
        key = PropertyKey(_APP_MODEL_FORMAT, pid)
        value = PropVariant()
        try:
            if self.get(self.store, C.byref(key), C.byref(value)) < 0:
                return None
            if value.vt == _VT_LPWSTR and value.value.pointer:
                return value.vt, C.wstring_at(value.value.pointer)
            if value.vt == _VT_BOOL:
                return value.vt, bool(value.value.boolean)
            return value.vt, None
        finally:
            bind(self.ole, "PropVariantClear", C.c_long, C.POINTER(PropVariant))(C.byref(value))

    def write(self, pid: int, data: str | bool | None) -> bool:
        key = PropertyKey(_APP_MODEL_FORMAT, pid)
        value = PropVariant()
        if isinstance(data, str):
            # SetValue copies the string. The buffer is owned by this caller.
            buffer = C.create_unicode_buffer(data)
            value.vt = _VT_LPWSTR
            value.value.pointer = C.cast(buffer, C.c_void_p).value
        elif isinstance(data, bool):
            value.vt = _VT_BOOL
            value.value.boolean = -int(data)
        result = self.set(self.store, C.byref(key), C.byref(value))
        if result < 0:
            LOG.debug("Could not set Windows window property %d (HRESULT %#010x)", pid, result & 0xFFFFFFFF)
        return result >= 0


class _WindowBranding:
    def __init__(self, user, relaunch: tuple[str, ...] | None):
        self.user = user
        self.icon_file = asset_dir() / "GaoJieZou.ico"
        self.icons: dict[tuple[int, int], int] = {}
        self.unpinnable_values = {
            _PREVENT_PINNING: True,
            _RELAUNCH_COMMAND: None,
            _RELAUNCH_ICON: None,
            _RELAUNCH_NAME: None,
            _APP_ID: APP_USER_MODEL_ID,
        }
        self.shell_values = {
            _RELAUNCH_COMMAND: subprocess.list2cmdline(relaunch),
            _RELAUNCH_ICON: relaunch[0] + ",0",
            _RELAUNCH_NAME: Path(relaunch[0]).stem,
            _PREVENT_PINNING: None,
            _APP_ID: APP_USER_MODEL_ID,
        } if relaunch else {}
        self.shell_fallback = any(len(value.encode("utf-16-le", "surrogatepass")) // 2 > _MAX_RELAUNCH_PROPERTY_UNITS
                                  for value in self.shell_values.values() if isinstance(value, str))
        self.send = bind(user, "SendMessageTimeoutW", C.c_ssize_t, W.HWND, W.UINT, W.WPARAM,
                         W.LPARAM, W.UINT, W.UINT, C.POINTER(C.c_size_t))
        self.load_icon = bind(user, "LoadImageW", W.HANDLE, W.HINSTANCE, W.LPCWSTR,
                              W.UINT, C.c_int, C.c_int, W.UINT)
        self.destroy_icon = bind(user, "DestroyIcon", W.BOOL, W.HICON)
        self.get_dpi = bind(user, "GetDpiForWindow", W.UINT, W.HWND) if hasattr(user, "GetDpiForWindow") else None
        self.metric_for_dpi = (bind(user, "GetSystemMetricsForDpi", C.c_int, C.c_int, W.UINT)
                               if hasattr(user, "GetSystemMetricsForDpi") else None)
        self.system_metric = bind(user, "GetSystemMetrics", C.c_int, C.c_int)

    def _message(self, window, message: int, size: int, value: int) -> int | None:
        result = C.c_size_t()
        # Bound any cross-process stall on the desktop's message thread.
        delivered = self.send(window, message, size, value, 0x22, 80, C.byref(result))
        return result.value if delivered else None

    def _icon(self, dpi: int, metric_x: int, metric_y: int):
        sizes = tuple(self.metric_for_dpi(metric, dpi) if self.metric_for_dpi else self.system_metric(metric)
                      for metric in (metric_x, metric_y))
        icon = self.icons.get(sizes)
        if icon is None:
            icon = self.load_icon(None, str(self.icon_file), 1, *sizes, 0x10)  # IMAGE_ICON, LR_LOADFROMFILE
            if icon:
                self.icons[sizes] = icon
        return icon

    def update_icons(self, window) -> None:
        if not self.icon_file.is_file():
            return
        dpi = (self.get_dpi(window) if self.get_dpi else 0) or 96
        for size, width, height in ((0, 49, 50), (1, 11, 12)):  # ICON_SMALL, ICON_BIG
            current = self._message(window, _WM_GETICON, size, dpi)
            if current is None:
                return
            icon = self._icon(dpi, width, height)
            if icon and current != icon:
                self._message(window, _WM_SETICON, size, icon)

    def update_shell(self, window) -> None:
        if not self.shell_values:
            return
        with _WindowProperties(window) as store:
            if not store:
                return
            if not self.shell_fallback and self._write_shell_values(store, self.shell_values):
                return
            # The shell limits these strings to MAX_PATH including the terminator.
            # An unrepresentable restart must not pin Edge or open a different library.
            self._write_shell_values(store, self.unpinnable_values)

    @staticmethod
    def _write_shell_values(store, values) -> bool:
        changed = []
        current_id = store.read(_APP_ID)
        for pid, data in values.items():
            if data is None:
                expected = (_VT_EMPTY, None)
            else:
                expected = (_VT_BOOL if isinstance(data, bool) else _VT_LPWSTR, data)
            actual = current_id if pid == _APP_ID else store.read(pid)
            if actual != expected:
                changed.append((pid, data))
        if not changed:
            return True
        # Explorer observes the ID as the final grouping notification. A pre-existing
        # ID must be removed before changing PreventPinning or relaunch metadata.
        if current_id != (_VT_EMPTY, None) and not store.write(_APP_ID, None):
            return False
        for pid, data in changed:
            if pid != _APP_ID and not store.write(pid, data):
                return False
        return store.write(_APP_ID, values[_APP_ID])

    def clear_shell(self, window) -> None:
        if not self.shell_values:
            return
        with _WindowProperties(window) as store:
            if store and store.read(_APP_ID) == (_VT_LPWSTR, APP_USER_MODEL_ID):
                for pid, text in reversed(self.shell_values.items()):
                    if text is not None and store.read(pid) == (_VT_LPWSTR, text):
                        store.write(pid, None)
                if store.read(_PREVENT_PINNING) == (_VT_BOOL, True):
                    store.write(_PREVENT_PINNING, None)

    def close(self) -> None:
        for icon in self.icons.values():
            self.destroy_icon(icon)
        self.icons.clear()


class EdgeWindow:
    def __init__(self, executable: Path, *, relaunch: tuple[str, ...] | None = None):
        self.executable = executable
        self.profile_root = None
        self.profile = None
        self.job = None
        self.process = None
        self.pid = None
        self.window_owner: tuple[int, int] | None = None
        self.seen = False
        self.started = 0.0
        self.user = C.WinDLL("user32", use_last_error=True)
        self.kernel = C.WinDLL("kernel32", use_last_error=True)
        self.window_pid = bind(self.user, "GetWindowThreadProcessId", W.DWORD, W.HWND, C.POINTER(W.DWORD))
        self.visible = bind(self.user, "IsWindowVisible", W.BOOL, W.HWND)
        self.branding = _WindowBranding(self.user, relaunch)

    def show(self, url: str) -> bool:
        """Bring the owned window forward. Return whether this reuses a launch."""
        import _winapi

        window = self.maintain_window()
        if window:
            if bind(self.user, "IsIconic", W.BOOL, W.HWND)(window):
                bind(self.user, "ShowWindowAsync", W.BOOL, W.HWND, C.c_int)(window, 9)  # SW_RESTORE
            bind(self.user, "SetForegroundWindow", W.BOOL, W.HWND)(window)
            return True
        if (self.process is not None and not self.seen and time.monotonic() - self.started < 8
                and _winapi.WaitForSingleObject(self.process, 0) == _winapi.WAIT_TIMEOUT):
            return True
        self._stop()
        self._start(url)
        return False

    def window(self):
        import _winapi

        if self.job is None:
            return None
        if self.window_owner:
            window, owner = self.window_owner
            current = W.DWORD()
            if self.window_pid(window, C.byref(current)) and current.value == owner and self.visible(window):
                return window
            self.window_owner = None
        if (self.seen and self.process is not None and
                _winapi.WaitForSingleObject(self.process, 0) != _winapi.WAIT_TIMEOUT):
            return None
        result = None
        visitor = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
        class_name = bind(self.user, "GetClassNameW", C.c_int, W.HWND, W.LPWSTR, C.c_int)
        open_process = bind(self.kernel, "OpenProcess", W.HANDLE, W.DWORD, W.BOOL, W.DWORD)
        is_in_job = bind(self.kernel, "IsProcessInJob", W.BOOL, W.HANDLE, W.HANDLE, C.POINTER(W.BOOL))

        @visitor
        def inspect(window, _):
            nonlocal result
            if not self.visible(window):
                return True
            name = C.create_unicode_buffer(48)
            class_name(window, name, len(name))
            if name.value != "Chrome_WidgetWin_1":
                return True
            pid, in_job = W.DWORD(), W.BOOL()
            if not self.window_pid(window, C.byref(pid)):
                return True
            process = open_process(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
            if process:
                try:
                    if is_in_job(process, self.job, C.byref(in_job)) and in_job.value:
                        result = (window, pid.value)
                        return False
                finally:
                    _winapi.CloseHandle(process)
            return True

        thread = bind(self.kernel, "GetCurrentThreadId", W.DWORD)()
        desktop = bind(self.user, "GetThreadDesktop", W.HANDLE, W.DWORD)(thread)
        bind(self.user, "EnumDesktopWindows", W.BOOL, W.HANDLE, visitor, W.LPARAM)(desktop, inspect, 0)
        if result:
            self.seen = True
            self.window_owner = result
            return result[0]
        return None

    def maintain_window(self):
        window = self.window()
        if window:
            try:
                self.branding.update_icons(window)
                self.branding.update_shell(window)
            except OSError:
                LOG.debug("Could not update the owned Edge window", exc_info=True)
        return window

    def close(self) -> None:
        import _winapi

        try:
            if window := self.window():
                try:
                    self.branding.clear_shell(window)
                except OSError:
                    LOG.debug("Could not clear the owned Edge window properties", exc_info=True)
                bind(self.user, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)(window, 0x10, 0, 0)
                _winapi.WaitForSingleObject(self.process, 1200)
        finally:
            self._stop()
            self.branding.close()
            if self.profile_root:
                self.profile_root.cleanup()
                self.profile_root = None

    def _stop(self) -> None:
        import _winapi

        if self.job is not None:
            _winapi.CloseHandle(self.job)
            self.job = None
        if self.process is not None:
            _winapi.WaitForSingleObject(self.process, 2000)
            _winapi.CloseHandle(self.process)
            self.process = self.pid = None
        if self.profile:
            shutil.rmtree(self.profile, ignore_errors=True)
            self.profile = None
        self.window_owner = None
        self.seen = False

    def _start(self, url: str) -> None:
        import _winapi

        if self.profile_root is None:
            self.profile_root = tempfile.TemporaryDirectory(prefix="gaojiezou-edge-", ignore_cleanup_errors=True)
        # A retiring Edge process can briefly hold its old profile's singleton lock.
        self.profile = tempfile.mkdtemp(prefix="window-", dir=self.profile_root.name)
        job = bind(self.kernel, "CreateJobObjectW", W.HANDLE, C.c_void_p, W.LPCWSTR)(None, None)
        if not job:
            raise C.WinError(C.get_last_error())
        self.job = job
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        configure = bind(self.kernel, "SetInformationJobObject", W.BOOL, W.HANDLE, C.c_int, C.c_void_p, W.DWORD)
        assign = bind(self.kernel, "AssignProcessToJobObject", W.BOOL, W.HANDLE, W.HANDLE)
        resume = bind(self.kernel, "ResumeThread", W.DWORD, W.HANDLE)
        try:
            if not configure(job, 9, C.byref(limits), C.sizeof(limits)):  # JobObjectExtendedLimitInformation
                raise C.WinError(C.get_last_error())
            arguments = [str(self.executable), f"--user-data-dir={self.profile}", f"--app={url}",
                         "--no-first-run", "--no-default-browser-check", "--disable-background-mode"]
            suspended = 0x4  # CREATE_SUSPENDED
            process, thread, pid, _ = _winapi.CreateProcess(
                str(self.executable), subprocess.list2cmdline(arguments), None, None, False,
                suspended | subprocess.CREATE_NO_WINDOW, None, None, subprocess.STARTUPINFO())
            try:
                if not assign(job, process) or resume(thread) == 0xFFFFFFFF:
                    error = C.get_last_error()
                    _winapi.TerminateProcess(process, 1)
                    _winapi.CloseHandle(process)
                    raise C.WinError(error)
            finally:
                _winapi.CloseHandle(thread)
            self.process, self.pid = process, pid
            self.started = time.monotonic()
        except OSError:
            self._stop()
            raise
