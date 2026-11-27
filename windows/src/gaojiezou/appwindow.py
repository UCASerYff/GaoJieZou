"""Own the Edge app window without attaching to the user's other browser windows."""

from __future__ import annotations

import ctypes as C
import shutil
import subprocess
import tempfile
import time
from ctypes import wintypes as W
from pathlib import Path


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


class EdgeWindow:
    def __init__(self, executable: Path):
        self.executable = executable
        self.profile_root = None
        self.profile = None
        self.job = None
        self.process = None
        self.pid = None
        self.seen = False
        self.started = 0.0
        self.user = C.WinDLL("user32", use_last_error=True)
        self.kernel = C.WinDLL("kernel32", use_last_error=True)

    def show(self, url: str) -> bool:
        """Bring the owned window forward. Return whether this reuses a launch."""
        import _winapi

        window = self.window()
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
        result = None
        visitor = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
        owner_pid = bind(self.user, "GetWindowThreadProcessId", W.DWORD, W.HWND, C.POINTER(W.DWORD))
        visible = bind(self.user, "IsWindowVisible", W.BOOL, W.HWND)
        class_name = bind(self.user, "GetClassNameW", C.c_int, W.HWND, W.LPWSTR, C.c_int)
        open_process = bind(self.kernel, "OpenProcess", W.HANDLE, W.DWORD, W.BOOL, W.DWORD)
        is_in_job = bind(self.kernel, "IsProcessInJob", W.BOOL, W.HANDLE, W.HANDLE, C.POINTER(W.BOOL))

        @visitor
        def inspect(window, _):
            nonlocal result
            if not visible(window):
                return True
            name = C.create_unicode_buffer(48)
            class_name(window, name, len(name))
            if name.value != "Chrome_WidgetWin_1":
                return True
            pid, in_job = W.DWORD(), W.BOOL()
            owner_pid(window, C.byref(pid))
            process = open_process(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
            if process:
                try:
                    if is_in_job(process, self.job, C.byref(in_job)) and in_job.value:
                        result = window
                        return False
                finally:
                    _winapi.CloseHandle(process)
            return True

        thread = bind(self.kernel, "GetCurrentThreadId", W.DWORD)()
        desktop = bind(self.user, "GetThreadDesktop", W.HANDLE, W.DWORD)(thread)
        bind(self.user, "EnumDesktopWindows", W.BOOL, W.HANDLE, visitor, W.LPARAM)(desktop, inspect, 0)
        self.seen |= result is not None
        return result

    def close(self) -> None:
        import _winapi

        try:
            if window := self.window():
                bind(self.user, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)(window, 0x10, 0, 0)
                _winapi.WaitForSingleObject(self.process, 1200)
        finally:
            self._stop()
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
