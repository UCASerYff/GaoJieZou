"""Regenerate the Windows icon and workbench mark from the original calligraphy."""

from __future__ import annotations

import io
import struct
from pathlib import Path

from PIL import Image, ImageDraw


# 16, 24, 32 and 48 logical pixels at the customary Windows scale factors,
# plus other Shell thumbnail sizes. The 256 px frame is stored as PNG.
ICON_SIZES = (16, 20, 24, 28, 30, 32, 36, 40, 42, 44, 48, 56, 60, 64, 72, 80, 84, 96, 128, 256)
WIDGET_MARK_SIZES = (32, 40, 48, 56, 64)
CORNER_RADIUS = 0.22


def icon_image(source: Image.Image, size: int) -> Image.Image:
    intermediate = size * 4
    image = source.resize((intermediate, intermediate), Image.Resampling.LANCZOS).convert("RGBA")
    mask = Image.new("L", image.size)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, intermediate - 1, intermediate - 1),
        radius=round(intermediate * CORNER_RADIUS), fill=255,
    )
    image.putalpha(mask)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def png_bytes(image: Image.Image) -> bytes:
    with io.BytesIO() as output:
        image.save(output, format="PNG", optimize=True)
        return output.getvalue()


def dib_bytes(image: Image.Image) -> bytes:
    size = image.width
    pixels = image.tobytes("raw", "BGRA", 0, -1)
    mask_stride = (size + 31) // 32 * 4
    mask = bytearray(mask_stride * size)
    alpha = image.getchannel("A").tobytes()
    for y in range(size):
        row = (size - 1 - y) * mask_stride
        for x in range(size):
            if alpha[y * size + x] == 0:
                mask[row + x // 8] |= 0x80 >> (x % 8)
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, len(pixels), 0, 0, 0, 0)
    return header + pixels + mask


def write_icons(source: Path, destination: Path) -> None:
    with Image.open(source) as original:
        art = original.convert("RGB")
    directory = bytearray(struct.pack("<HHH", 0, 1, len(ICON_SIZES)))
    frames = bytearray()
    offset = 6 + len(ICON_SIZES) * 16
    for size in ICON_SIZES:
        image = icon_image(art, size)
        frame = png_bytes(image) if size == 256 else dib_bytes(image)
        directory.extend(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(frame), offset))
        frames.extend(frame)
        offset += len(frame)
    (destination / "GaoJieZou.ico").write_bytes(directory + frames)
    (destination / "GaoJieZouMark.png").write_bytes(png_bytes(icon_image(art, 128)))
    for size in WIDGET_MARK_SIZES:
        (destination / f"GaoJieZouMark-{size}.png").write_bytes(png_bytes(icon_image(art, size)))


if __name__ == "__main__":
    windows = Path(__file__).resolve().parent
    write_icons(windows.parent / "Resources" / "GaoJieZouIcon.png", windows / "src" / "gaojiezou" / "assets")
