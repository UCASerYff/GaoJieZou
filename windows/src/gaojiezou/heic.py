"""Generate a local preview with the Windows Imaging Component HEIF codec."""

from __future__ import annotations

import ctypes as ct
import struct
import sys
import threading
import uuid
import zlib

from gaojiezou.errors import AppError


HEIF_MIME = {"image/heic", "image/heif"}
MAX_HEIF_BYTES = 30 * 1024 * 1024
MAX_SOURCE_PIXELS = 60_000_000
PREVIEW_SIDE = 2400

_PTR = ct.c_void_p
_OUT = ct.POINTER(_PTR)
_UINT = ct.c_uint32
_HR = ct.c_int32
_DECODE = threading.BoundedSemaphore(1)
_FACTORY_CLASS = "cacaf262-9370-4615-a13b-9f5539da4c0a"
_FACTORY_INTERFACE = "ec5ec8a9-c395-4314-9c77-54d7a935ff70"
_RGB_24 = "6fddc324-4e03-4bfe-b185-3d77768dc90d"


def heif_extension(data: bytes) -> str | None:
    if len(data) < 16 or data[4:8] != b"ftyp":
        return None
    header_size = 8
    box_size = int.from_bytes(data[:4], "big")
    if box_size == 1:
        header_size = 16
        box_size = int.from_bytes(data[8:16], "big")
    if not header_size + 8 <= box_size <= min(4096, len(data)) or (box_size - header_size) % 4:
        return None
    major = data[header_size:header_size + 4]
    if major in {b"avif", b"avis"}:
        return None
    brands = {major, *(data[i:i + 4] for i in range(header_size + 8, box_size, 4))}
    if brands & {b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"hevm", b"hevs"}:
        return ".heic"
    if brands & {b"mif1", b"msf1", b"mif2"}:
        return ".heif"
    return None


def _boxes(data: bytes, start: int, end: int):
    while start < end:
        if end - start < 8:
            raise ValueError("truncated HEIF box header")
        size, kind = struct.unpack_from(">I4s", data, start)
        header = 8
        if size == 1:
            if end - start < 16:
                raise ValueError("truncated HEIF large box header")
            size, = struct.unpack_from(">Q", data, start + 8)
            header = 16
        elif size == 0:
            size = end - start
        if kind == b"uuid":
            header += 16
        if not header <= size <= end - start:
            raise ValueError("HEIF box extends outside its container")
        yield kind, start + header, start + size
        start += size


def has_heif_media(data: bytes) -> bool:
    """Recognize a self-contained image item or sequence without requiring a codec."""
    if not heif_extension(data):
        return False
    indexed_items = inline_media = track = top_level_media = False
    try:
        for kind, start, end in _boxes(data, 0, len(data)):
            if kind == b"meta":
                if end - start < 4:  # The FullBox version and flags precede its children.
                    return False
                items = {child for child, payload, limit in _boxes(data, start + 4, end) if payload < limit}
                if {b"iloc", b"iinf"}.issubset(items):
                    indexed_items = True
                    inline_media |= b"idat" in items
            elif kind == b"moov":
                for child, payload, limit in _boxes(data, start, end):
                    track |= child == b"trak" and payload < limit
            elif kind in {b"mdat", b"imda"}:
                # Identified media data begins with a four-byte identifier.
                top_level_media |= end - start > (4 if kind == b"imda" else 0)
    except ValueError:
        return False
    return inline_media or (top_level_media and (indexed_items or track))


def heif_preview(data: bytes) -> bytes:
    """Decode the primary still and emit PNG pixels without carrying EXIF metadata."""
    if not data or len(data) > MAX_HEIF_BYTES:
        raise AppError("单张照片必须小于或等于 30 MB。", "invalid")
    if not heif_extension(data):
        raise AppError("未识别到 HEIC 或 HEIF 照片。", "invalid")
    if sys.platform != "win32":
        raise AppError("HEIC 预览需要 Windows 图像组件。", "codec")
    try:
        with _DECODE:
            width, height, pixels = _wic_rgb(data)
        return _rgb_png(width, height, pixels)
    except OSError as exc:
        raise AppError(
            "Windows 无法解码这张 HEIC 照片。请确认已安装 HEIF 图像扩展和 HEVC 视频扩展，并检查原文件。",
            "codec",
        ) from exc


def _guid(value: str):
    return (ct.c_ubyte * 16).from_buffer_copy(uuid.UUID(value).bytes_le)


def _check(result: int, operation: str) -> None:
    if result < 0:
        raise OSError(f"{operation} failed (0x{result & 0xFFFFFFFF:08X})")


def _call(obj, slot, operation, signature, *arguments):
    table = ct.cast(obj, ct.POINTER(ct.POINTER(_PTR))).contents
    function = ct.WINFUNCTYPE(_HR, _PTR, *signature)(table[slot])
    _check(function(obj, *arguments), operation)


def _release(obj) -> None:
    table = ct.cast(obj, ct.POINTER(ct.POINTER(_PTR))).contents
    ct.WINFUNCTYPE(_UINT, _PTR)(table[2])(obj)


def _wic_rgb(data: bytes):
    ole = ct.WinDLL("ole32")
    ole.CoInitializeEx.argtypes = (_PTR, _UINT)
    ole.CoInitializeEx.restype = _HR
    ole.CoCreateInstance.argtypes = (_PTR, _PTR, _UINT, _PTR, _OUT)
    ole.CoCreateInstance.restype = _HR
    ole.CoUninitialize.restype = None
    apartment = ole.CoInitializeEx(None, 0)  # COINIT_MULTITHREADED
    if apartment != -2147417850:  # RPC_E_CHANGED_MODE: this thread already owns an apartment
        _check(apartment, "CoInitializeEx")
    factory, stream, decoder, frame, scaler, converter = (_PTR() for _ in range(6))
    try:
        _check(ole.CoCreateInstance(_guid(_FACTORY_CLASS), None, 1, _guid(_FACTORY_INTERFACE), ct.byref(factory)),
               "IWICImagingFactory creation")
        _call(factory, 14, "IWICImagingFactory.CreateStream", (_OUT,), ct.byref(stream))
        buffer = ct.create_string_buffer(data)
        _call(stream, 16, "IWICStream.InitializeFromMemory", (_PTR, _UINT), buffer, len(data))
        _call(factory, 4, "IWICImagingFactory.CreateDecoderFromStream", (_PTR, _PTR, _UINT, _OUT),
              stream, None, 0, ct.byref(decoder))
        _call(decoder, 13, "IWICBitmapDecoder.GetFrame", (_UINT, _OUT), 0, ct.byref(frame))

        width, height = _UINT(), _UINT()
        size_pointer = ct.POINTER(_UINT)
        _call(frame, 3, "IWICBitmapSource.GetSize", (size_pointer, size_pointer), ct.byref(width), ct.byref(height))
        columns, rows = width.value, height.value
        if not columns or not rows or columns * rows > MAX_SOURCE_PIXELS:
            raise AppError("HEIC 照片像素尺寸超出支持范围。", "invalid")
        source = frame
        longest = max(columns, rows)
        if longest > PREVIEW_SIDE:
            columns = max(1, columns * PREVIEW_SIDE // longest)
            rows = max(1, rows * PREVIEW_SIDE // longest)
            _call(factory, 11, "IWICImagingFactory.CreateBitmapScaler", (_OUT,), ct.byref(scaler))
            _call(scaler, 8, "IWICBitmapScaler.Initialize", (_PTR, _UINT, _UINT, _UINT), frame, columns, rows, 3)
            source = scaler
        _call(factory, 10, "IWICImagingFactory.CreateFormatConverter", (_OUT,), ct.byref(converter))
        _call(converter, 8, "IWICFormatConverter.Initialize", (_PTR, _PTR, _UINT, _PTR, ct.c_double, _UINT),
              source, _guid(_RGB_24), 0, None, 0.0, 0)
        stride = columns * 3
        pixels = ct.create_string_buffer(stride * rows)
        _call(converter, 7, "IWICBitmapSource.CopyPixels", (_PTR, _UINT, _UINT, _PTR),
              None, stride, len(pixels), pixels)
        return columns, rows, pixels.raw
    finally:
        for obj in (converter, scaler, frame, decoder, stream, factory):
            if obj:
                _release(obj)
        if apartment >= 0:
            ole.CoUninitialize()


def _rgb_png(width, height, pixels) -> bytes:
    def chunk(kind, content):
        return struct.pack(">I", len(content)) + kind + content + struct.pack(">I", zlib.crc32(kind + content))

    compressor = zlib.compressobj(3)
    stride = width * 3
    data = bytearray()
    for offset in range(0, len(pixels), stride):
        data.extend(compressor.compress(b"\x00" + pixels[offset:offset + stride]))
    data.extend(compressor.flush())
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", data) + chunk(b"IEND", b"")
