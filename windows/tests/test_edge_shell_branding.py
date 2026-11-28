import ctypes as C
import subprocess
import sys
from ctypes import wintypes as W
from pathlib import Path

import pytest

from gaojiezou.appwindow import (
    EdgeWindow, _APP_ID, _PREVENT_PINNING, _RELAUNCH_COMMAND, _RELAUNCH_ICON, _RELAUNCH_NAME,
    _VT_BOOL, _VT_EMPTY, _VT_LPWSTR, _WM_GETICON, _WM_SETICON, _WindowBranding, _WindowProperties,
)
from gaojiezou.notifications import APP_USER_MODEL_ID


pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Uses native Windows HWNDs")


@pytest.fixture
def foreign_windows():
    child = subprocess.Popen(
        [sys.executable, "-B", "-c", """
import ctypes as C
from ctypes import wintypes as W

user = C.WinDLL("user32", use_last_error=True)
create = user.CreateWindowExW
create.restype = W.HWND
create.argtypes = [W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD, C.c_int, C.c_int, C.c_int, C.c_int,
                   W.HWND, W.HMENU, W.HINSTANCE, C.c_void_p]
windows = [create(0, "STATIC", "Rhythm icon test", 0xcf0000, 0, 0, 200, 100, None, None, None, None)
           for _ in range(2)]
if not all(windows):
    raise C.WinError(C.get_last_error())
print(*windows, flush=True)
message = W.MSG()
user.GetMessageW.argtypes = [C.POINTER(W.MSG), W.HWND, W.UINT, W.UINT]
user.DispatchMessageW.argtypes = [C.POINTER(W.MSG)]
while user.GetMessageW(C.byref(message), None, 0, 0) > 0:
    user.DispatchMessageW(C.byref(message))
"""],
        stdout=subprocess.PIPE, text=True, creationflags=subprocess.CREATE_NO_WINDOW,
    )
    try:
        yield tuple(map(int, child.stdout.readline().split()))
    finally:
        child.terminate()
        child.wait(timeout=5)
        child.stdout.close()


def test_cross_process_window_icons_and_shell_properties(foreign_windows):
    target, untouched = foreign_windows
    executable = r"C:\Program Files\Rhythm test\GaoJieZou.exe"
    custom_data = r"C:\Rhythm test\Isolated study"
    relaunch = (executable, "--data-dir", custom_data)
    edge = EdgeWindow(Path("unused-edge.exe"), relaunch=relaunch)
    branding = edge.branding
    assert branding.icon_file.is_file()
    # Stub only the existing verified-HWND discovery seam. Icon messages and COM
    # property writes still cross processes to a native window.
    edge.window = lambda: target
    try:
        assert edge.maintain_window() == target
        first_icons = [branding._message(target, _WM_GETICON, size, 96) for size in (0, 1)]
        assert all(first_icons)
        assert set(first_icons) <= set(branding.icons.values())
        assert [branding._message(untouched, _WM_GETICON, size, 96) for size in (0, 1)] == [0, 0]

        with _WindowProperties(target) as props:
            assert props is not None
            assert props.read(_APP_ID) == (_VT_LPWSTR, APP_USER_MODEL_ID)
            assert props.read(_RELAUNCH_COMMAND) == (_VT_LPWSTR, subprocess.list2cmdline(relaunch))
            assert props.read(_RELAUNCH_ICON) == (_VT_LPWSTR, executable + ",0")
            assert props.read(_RELAUNCH_NAME) == (_VT_LPWSTR, "GaoJieZou")
            assert props.read(_PREVENT_PINNING) == (_VT_EMPTY, None)
            assert props.write(_APP_ID, "Synthetic.Edge.Window")
        with _WindowProperties(untouched) as props:
            assert props.read(_APP_ID) == (_VT_EMPTY, None)

        branding._message(target, _WM_SETICON, 0, 0)
        edge.maintain_window()
        assert branding._message(target, _WM_GETICON, 0, 96) == first_icons[0]
        with _WindowProperties(target) as props:
            assert props.read(_APP_ID) == (_VT_LPWSTR, APP_USER_MODEL_ID)
        branding.clear_shell(target)
        with _WindowProperties(target) as props:
            assert props.read(_APP_ID) == (_VT_EMPTY, None)
            assert props.read(_RELAUNCH_COMMAND) == (_VT_EMPTY, None)
    finally:
        for size in (0, 1):
            branding._message(target, _WM_SETICON, size, 0)
        branding.close()


def test_verified_window_cache_does_not_enumerate_again(foreign_windows, monkeypatch):
    target, _ = foreign_windows
    edge = EdgeWindow(Path("unused-edge.exe"))
    pid = W.DWORD()
    assert edge.window_pid(target, C.byref(pid))
    edge.job = 1
    edge.window_owner = (target, pid.value)
    # The native test fixture is hidden; make only its visibility predicate true.
    monkeypatch.setattr(edge, "visible", lambda window: window == target)
    monkeypatch.setattr("gaojiezou.appwindow.bind", lambda *_args: pytest.fail("re-enumerated known HWND"))
    assert edge.window() == target


def test_unrepresentable_relaunch_keeps_identity_but_disables_new_pins(foreign_windows):
    target, _ = foreign_windows
    executable = r"C:\Program Files\Rhythm test\GaoJieZou.exe"
    custom_data = "C:\\" + "\\".join(["isolated-directory" * 5] * 4)
    edge = EdgeWindow(Path("unused-edge.exe"), relaunch=(executable, "--data-dir", custom_data))
    branding = edge.branding
    try:
        with _WindowProperties(target) as props:
            assert props.write(_RELAUNCH_COMMAND, r"C:\Edge\msedge.exe --app=http://127.0.0.1:12345/")
        branding.update_shell(target)
        with _WindowProperties(target) as props:
            assert props.read(_APP_ID) == (_VT_LPWSTR, APP_USER_MODEL_ID)
            assert props.read(_PREVENT_PINNING) == (_VT_BOOL, True)
            assert props.read(_RELAUNCH_COMMAND) == (_VT_EMPTY, None)
    finally:
        branding.clear_shell(target)
        branding.close()
    with _WindowProperties(target) as props:
        assert props.read(_PREVENT_PINNING) == (_VT_EMPTY, None)


def test_icons_follow_window_dpi_without_destroying_previous_handles(monkeypatch):
    user = C.WinDLL("user32", use_last_error=True)
    branding = _WindowBranding(user, None)
    dpi = 96
    active = {}
    loaded = []
    destroyed = []

    def icon_message(_window, message, size, value):
        if message == _WM_GETICON:
            return active.get(size, 0)
        active[size] = value
        return 0

    def load_icon(_instance, _filename, _kind, width, height, _flags):
        loaded.append((width, height))
        return len(loaded)

    monkeypatch.setattr(branding, "get_dpi", lambda _window: dpi)
    monkeypatch.setattr(branding, "metric_for_dpi", lambda metric, value: (16 if metric >= 49 else 32) * value // 96)
    monkeypatch.setattr(branding, "_message", icon_message)
    monkeypatch.setattr(branding, "load_icon", load_icon)
    monkeypatch.setattr(branding, "destroy_icon", destroyed.append)
    branding.update_icons(123)
    dpi = 144
    branding.update_icons(123)
    assert active == {0: 3, 1: 4}
    assert loaded == [(16, 16), (32, 32), (24, 24), (48, 48)]
    assert destroyed == []
    dpi = 96
    branding.update_icons(123)
    assert active == {0: 1, 1: 2}
    branding.close()
    assert destroyed == [1, 2, 3, 4]
