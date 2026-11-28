import ctypes as C
import sys
from ctypes import wintypes as W
from threading import Event, Lock
from types import SimpleNamespace

import pytest

from gaojiezou import desktop


def test_tray_size_uses_explorer_dpi_and_legacy_small_metric():
    shell_window = 67
    lookup = []
    source = desktop._TrayIconSource.__new__(desktop._TrayIconSource)
    source.find_window = lambda name, title: lookup.append((name, title)) or shell_window
    source.window_dpi = lambda window: {67: 144}[window]
    source.system_dpi = lambda: 192
    source.dpi_metric = lambda metric, dpi: {desktop.SM_CXSMICON: dpi // 6}[metric]
    source.system_metric = lambda metric: {desktop.SM_CXSMICON: 20}[metric]

    assert source.pixels() == 24
    assert lookup == [("Shell_TrayWnd", None)]
    shell_window = 0
    assert source.pixels() == 32
    source.dpi_metric = None
    assert source.pixels() == 20
    source.system_metric = lambda _metric: 0
    assert source.pixels() == 16


def tray_fixture(tmp_path, monkeypatch):
    clock = SimpleNamespace(now=100, pixels=16)
    monkeypatch.setattr(desktop.time, "monotonic", lambda: clock.now)
    store = SimpleNamespace(directory=tmp_path, status="missing", library=None, settings={})
    server = SimpleNamespace(store=store, lock=Lock(), shutdown_requested=Event(), exiting=False)
    app = desktop.WindowsDesktop(server, "dpi-tray-fixture")
    app.window = 42
    app.taskbar_restored = 0xA011
    app.def_window = lambda *_args: 0
    calls, loads, destroyed, blocked = [], [], [], []

    def load(size):
        loads.append(size)
        return 1000 + size, size != 20  # Simulate a shared fallback at 20 px.

    def send(command, data):
        row = data._obj
        calls.append((command, row.id, row.flags, row.icon, row.version))
        return command not in blocked

    app._tray_icons = SimpleNamespace(pixels=lambda: clock.pixels, load=load, destroy=destroyed.append)
    app.notify_icon = send
    app._sync_tray_icon()
    return app, clock, calls, loads, destroyed, blocked


def test_dpi_notifications_update_in_place_and_explorer_reuses_the_icon(tmp_path, monkeypatch):
    app, clock, calls, loads, destroyed, _blocked = tray_fixture(tmp_path, monkeypatch)
    dispatch = lambda message: app._messages(app.window, message, 288, 0)
    assert [call[0] for call in calls] == [desktop.NIM_ADD, desktop.NIM_SETVERSION]
    assert calls[0][3] == 1016 and calls[1][4] == 4
    clock.pixels = 20
    dispatch(desktop.MSG_SETTINGCHANGE)
    dispatch(desktop.MSG_DISPLAYCHANGE)
    dispatch(desktop.MSG_DPICHANGED)
    assert len(calls) == 2
    dispatch(desktop.MSG_TIMER)
    assert calls[2:] == [(desktop.NIM_MODIFY, 1, desktop.NIF_ICON, 1020, 0)]
    dispatch(desktop.MSG_DPICHANGED)  # The hidden host's DPI in wParam is irrelevant.
    dispatch(desktop.MSG_TIMER)
    assert loads == [16, 20] and destroyed == [1016]
    assert len(calls) == 3

    dispatch(app.taskbar_restored)
    assert calls[-2][0:2] == (desktop.NIM_ADD, 1) and calls[-2][3] == 1020 and calls[-1][4] == 4
    clock.pixels = 32  # Explorer reports its new DPI after the restore broadcast.
    dispatch(desktop.MSG_TIMER)
    assert calls[-1] == (desktop.NIM_MODIFY, 1, desktop.NIF_ICON, 1032, 0)
    assert loads == [16, 20, 32] and destroyed == [1016]
    app.server.exiting = True
    count = len(calls)
    dispatch(app.taskbar_restored)
    dispatch(desktop.MSG_TIMER)
    assert len(calls) == count
    app._release_tray_icon()
    app._release_tray_icon()
    assert destroyed == [1016, 1032]


def test_failed_dpi_update_and_explorer_recovery_back_off_without_reloading(tmp_path, monkeypatch):
    app, clock, calls, loads, destroyed, blocked = tray_fixture(tmp_path, monkeypatch)
    clock.pixels = 24
    blocked[:] = [desktop.NIM_MODIFY, desktop.NIM_ADD]
    app._messages(app.window, desktop.MSG_DPICHANGED, 0, 0)
    app._maintain_tray_icon()
    assert calls[-1] == (desktop.NIM_MODIFY, 1, desktop.NIF_ICON, 1024, 0)
    app._maintain_tray_icon()
    assert len(calls) == 3
    clock.now += desktop.TRAY_RETRY_SECONDS
    app._maintain_tray_icon()
    assert not app.tray_added
    assert [row[0] for row in calls[-2:]] == [desktop.NIM_ADD, desktop.NIM_MODIFY]
    assert loads == [16, 24]

    clock.now += desktop.TRAY_RETRY_SECONDS
    blocked[:] = [desktop.NIM_ADD]  # Explorer reports that our existing identity is already present.
    app._maintain_tray_icon()
    assert app.tray_added
    assert [row[0] for row in calls[-3:]] == [desktop.NIM_ADD, desktop.NIM_MODIFY, desktop.NIM_SETVERSION]
    assert calls[-2][3] == 1024 and calls[-1][4] == 4
    app._maintain_tray_icon()
    assert len(calls) == 8 and loads == [16, 24] and destroyed == [1016]


@pytest.mark.skipif(sys.platform != "win32", reason="requires native Win32 icon APIs")
def test_native_icon_dimensions_at_100_through_200_percent_and_small_fallback(tmp_path, monkeypatch):
    class IconInfo(C.Structure):
        _fields_ = [("is_icon", W.BOOL), ("x_hotspot", W.DWORD), ("y_hotspot", W.DWORD),
                    ("mask", W.HBITMAP), ("color", W.HBITMAP)]

    class Bitmap(C.Structure):
        _fields_ = [("kind", W.LONG), ("width", W.LONG), ("height", W.LONG), ("stride", W.LONG),
                    ("planes", W.WORD), ("bits_per_pixel", W.WORD), ("bits", C.c_void_p)]

    user = C.WinDLL("user32", use_last_error=True)
    gdi = C.WinDLL("gdi32", use_last_error=True)
    shell = C.WinDLL("shell32", use_last_error=True)
    get_icon = desktop._binding(user, "GetIconInfo", W.BOOL, W.HICON, C.POINTER(IconInfo))
    get_bitmap = desktop._binding(gdi, "GetObjectW", C.c_int, W.HANDLE, C.c_int, C.c_void_p)
    delete_bitmap = desktop._binding(gdi, "DeleteObject", W.BOOL, W.HANDLE)
    source = desktop._TrayIconSource(user, shell)

    def dimensions(icon):
        info = IconInfo()
        assert get_icon(icon, C.byref(info))
        try:
            bitmap = Bitmap()
            assert get_bitmap(info.color or info.mask, C.sizeof(bitmap), C.byref(bitmap))
            return bitmap.width, bitmap.height if info.color else bitmap.height // 2
        finally:
            for handle in (info.color, info.mask):
                if handle:
                    delete_bitmap(handle)

    if source.dpi_metric is None:
        pytest.skip("Windows predates GetSystemMetricsForDpi")

    asset = desktop.asset_dir() / "GaoJieZou.ico"
    assert asset.is_file()
    source.find_window = lambda *_args: 1
    for dpi, pixels in ((96, 16), (120, 20), (144, 24), (168, 28), (192, 32)):
        source.window_dpi = lambda _window: dpi
        assert source.pixels() == pixels
        icon, owned = source.load(pixels)
        try:
            assert icon and owned and dimensions(icon) == (pixels, pixels)
        finally:
            if icon and owned:
                assert source.destroy(icon)

    monkeypatch.setattr(desktop, "asset_dir", lambda: tmp_path)
    icon, owned = source.load(16)
    try:
        assert icon and dimensions(icon) == (16, 16)
    finally:
        if icon and owned:
            assert source.destroy(icon)
