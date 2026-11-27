"""开发目录与 PyInstaller 解包目录里的只读资源。"""

from __future__ import annotations

import json
import re
import sys
from functools import lru_cache
from pathlib import Path


def asset_dir() -> Path:
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen) / "gaojiezou_assets"
    return Path(__file__).resolve().parent / "assets"


def artwork(name: str) -> Path | None:
    if not re.fullmatch(
        r"(?:GaoJieZouIcon|(?:Farm|Pasture|Fishing|Aquarium)GameSceneV15|"
        r"Crop(?:Young)?AtlasV15|Animal(?:Young)?AtlasV23|Fish-[a-z]+-V15|IslandSceneArt|"
        r"EstateMeadowV352|WorldMaterialsV357|FoliageV357|AquariumPanoramaV352)\.png",
        name,
    ):
        return None
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen) / "mac-assets" / name
    root = Path(__file__).resolve().parents[3]
    if name == "IslandSceneArt.png":
        return root / "Integrated" / "Health" / "Resources" / name
    if name in {"EstateMeadowV352.png", "WorldMaterialsV357.png", "FoliageV357.png"}:
        return root / "GameWorld" / "Resources" / name
    return root / "Resources" / name


@lru_cache(maxsize=1)
def english_strings() -> dict[str, str]:
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        path = Path(frozen) / "mac-assets" / "Localizable.strings"
    else:
        path = Path(__file__).resolve().parents[3] / "Resources" / "en.lproj" / "Localizable.strings"
    pairs = re.findall(
        r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;',
        path.read_text(encoding="utf-8-sig"),
        re.MULTILINE,
    )
    result = {}
    for key, value in pairs:
        try:
            result[json.loads(key)] = json.loads(value)
        except json.JSONDecodeError:
            continue
    return result
