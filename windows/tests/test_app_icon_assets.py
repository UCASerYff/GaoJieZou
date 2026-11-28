from __future__ import annotations

import ctypes as C
import struct
import sys
from ctypes import wintypes as W

import pytest

from gaojiezou.resources import asset_dir


SCALED_WINDOW_ICONS = ((16, 32), (20, 40), (24, 48), (28, 56), (32, 64))


def test_icon_contains_native_sizes_and_rounded_corner_alpha():
    data = (asset_dir() / "GaoJieZou.ico").read_bytes()
    zero, kind, count = struct.unpack_from("<HHH", data)
    assert (zero, kind) == (0, 1)
    sizes = set()
    end = 6 + count * 16
    for index in range(count):
        width, height, _, _, planes, bpp, length, offset = struct.unpack_from("<BBBBHHII", data, 6 + index * 16)
        size = width or 256
        assert size not in sizes and (size, planes, bpp) == (height or 256, 1, 32)
        sizes.add(size)
        assert offset == end
        end = offset + length
        if size == 256:
            assert data[offset:offset + 8] == b"\x89PNG\r\n\x1a\n"
            continue
        assert struct.unpack_from("<IiiHHI", data, offset) == (40, size, size * 2, 1, 32, 0)
        bottom_left_alpha = data[offset + 43]
        center_alpha = data[offset + 43 + (size // 2 * size + size // 2) * 4]
        assert bottom_left_alpha <= 4 and center_alpha == 255
    assert end == len(data)
    assert {16, 48, 96, 128, 256} | {size for pair in SCALED_WINDOW_ICONS for size in pair} <= sizes


def test_workbench_uses_bundled_icon_and_size_specific_marks():
    html = (asset_dir() / "index.html").read_text(encoding="utf-8")
    assert 'href="/GaoJieZou.ico"' in html
    assert 'src="/GaoJieZouMark.png" width="34" height="34"' in html
    for filename, size in [("GaoJieZouMark.png", 128)] + [
        (f"GaoJieZouMark-{size}.png", size) for _, size in SCALED_WINDOW_ICONS
    ]:
        png = (asset_dir() / filename).read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack_from(">IIBB", png, 16) == (size, size, 8, 6)


@pytest.mark.skipif(sys.platform != "win32", reason="requires the native Windows icon loader")
@pytest.mark.parametrize("size", sorted({size for pair in SCALED_WINDOW_ICONS for size in pair} | {256}))
def test_windows_loads_exact_raster_size(size):
    class IconInfo(C.Structure):
        _fields_ = [("is_icon", W.BOOL), ("x", W.DWORD), ("y", W.DWORD),
                    ("mask", W.HBITMAP), ("color", W.HBITMAP)]

    class Bitmap(C.Structure):
        _fields_ = [("kind", W.LONG), ("width", W.LONG), ("height", W.LONG), ("stride", W.LONG),
                    ("planes", W.WORD), ("bpp", W.WORD), ("bits", C.c_void_p)]

    user = C.WinDLL("user32", use_last_error=True)
    gdi = C.WinDLL("gdi32", use_last_error=True)
    user.LoadImageW.argtypes = (W.HINSTANCE, W.LPCWSTR, W.UINT, C.c_int, C.c_int, W.UINT)
    user.LoadImageW.restype = W.HICON
    user.GetIconInfo.argtypes = (W.HICON, C.POINTER(IconInfo))
    user.DestroyIcon.argtypes = (W.HICON,)
    gdi.GetObjectW.argtypes = (W.HANDLE, C.c_int, C.c_void_p)
    gdi.DeleteObject.argtypes = (W.HGDIOBJ,)
    # IMAGE_ICON, LR_LOADFROMFILE. A private handle is returned.
    icon = user.LoadImageW(None, str(asset_dir() / "GaoJieZou.ico"), 1, size, size, 0x10)
    assert icon, C.get_last_error()
    info, bitmap = IconInfo(), Bitmap()
    try:
        assert user.GetIconInfo(icon, C.byref(info)) and info.is_icon and info.color
        assert gdi.GetObjectW(info.color, C.sizeof(bitmap), C.byref(bitmap)) == C.sizeof(bitmap)
        assert (bitmap.width, bitmap.height, bitmap.bpp) == (size, size, 32)
    finally:
        for handle in (info.mask, info.color):
            if handle:
                gdi.DeleteObject(handle)
        user.DestroyIcon(icon)
