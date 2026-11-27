"""Rebuild the offline Windows atlas using geoBoundaries ADM1 and the repository city catalog."""

import argparse
import ctypes
import gzip
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "windows" / "src" / "gaojiezou" / "assets"
CHINA_SOURCE = "https://www.geoboundaries.org/data/snapshots/1c423398df24ddf6e730b116567d2181c9782778d0459c3f3b76ca2f9f12b6bc/gbOpen/CHN/ADM1/geoBoundaries-CHN-ADM1.geojson"
PROVINCE_IDS = dict(zip(
    ("Beijing", "Tianjin", "Hebei", "Shanxi", "Inner Mongolia", "Liaoning", "Jilin", "Heilongjiang",
     "Shanghai", "Jiangsu", "Zhejiang", "Anhui", "Fujian", "Jiangxi", "Shandong", "Henan", "Hubei",
     "Hunan", "Guangzhou", "Guangxi", "Hainan", "Chongqing", "Sichuan", "Guizhou", "Yunnan", "Tibet",
     "Shaanxi", "Gansu", "Qinghai", "Ningxia", "Xinjiang", "Taiwan", "Hong Kong", "Macau"),
    (11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 33, 34, 35, 36, 37, 41, 42,
     43, 44, 45, 46, 50, 51, 52, 53, 54, 61, 62, 63, 64, 65, 71, 81, 82),
))


def city_names(cities):
    icu = ctypes.WinDLL("icu.dll")
    icu.utrans_openU.argtypes = [ctypes.c_wchar_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
                                ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    icu.utrans_openU.restype = ctypes.c_void_p
    icu.utrans_transUChars.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int),
                                     ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    icu.utrans_transUChars.restype = None
    icu.utrans_close.argtypes = [ctypes.c_void_p]
    transforms = []
    try:
        for identifier in ("Traditional-Simplified", "Han-Latin; Latin-ASCII"):
            status = ctypes.c_int()
            transform = icu.utrans_openU(identifier, -1, 0, None, 0, None, ctypes.byref(status))
            if not transform or status.value > 0:
                raise RuntimeError(f"Windows ICU could not open {identifier}: {status.value}")
            transforms.append(transform)
        for city in cities:
            for transform, field in zip(transforms, ("simplified", "pinyin")):
                if field == "pinyin" and city["countryID"] != "CHN":
                    continue
                text = ctypes.create_unicode_buffer(city["name"], 512)
                length = ctypes.c_int(len(text.value.encode("utf-16-le")) // 2)
                limit = ctypes.c_int(length.value)
                status = ctypes.c_int()
                icu.utrans_transUChars(transform, text, ctypes.byref(length), len(text), 0, ctypes.byref(limit), ctypes.byref(status))
                if status.value > 0:
                    raise RuntimeError(f"Windows ICU transliteration failed: {status.value}")
                if text.value != city["name"]:
                    city[field] = text.value
    finally:
        for transform in transforms:
            icu.utrans_close(transform)


def compact_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("china_geojson", type=Path, help="The geoBoundaries CHN ADM1 file")
    options = parser.parse_args()
    raw_china = options.china_geojson.read_bytes()
    china = json.loads(raw_china)
    mac = json.loads((REPO / "Integrated" / "Footprints" / "Resources" / "Geography.json").read_bytes())
    china_names = {city["provinceID"]: city["province"] for city in mac["cities"] if city["countryID"] == "CHN"}
    provinces = []
    for feature in china["features"]:
        name = feature["properties"]["shapeName"]
        prefix = next(key for key in PROVINCE_IDS if name.startswith(key + " "))
        province_id = f"{PROVINCE_IDS[prefix]}0000"
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        rings = [[[round(x, 4), round(y, 4)] for x, y in ring] for polygon in polygons for ring in polygon]
        provinces.append({"id": province_id, "name": china_names[province_id], "rings": rings})
    world = [{key: region[key] for key in ("id", "countryID", "name", "rings")} for region in mac["world"]]
    assert len(provinces) == len(china_names) == 34
    (ASSETS / "footprints-atlas.json").write_bytes(compact_json({
        "world": world,
        "china": provinces,
        "source": {
            "world": {"name": "Natural Earth 1:50m", "license": "Public domain"},
            "china": {"name": "geoBoundaries CHN ADM1 (2019)", "license": "Public domain",
                      "url": CHINA_SOURCE, "sha256": hashlib.sha256(raw_china).hexdigest()},
        },
    }))
    catalog = json.loads(gzip.decompress((ASSETS / "cities.json.gz").read_bytes()))
    catalog["cities"] = mac["cities"]
    city_names(catalog["cities"])
    with (ASSETS / "cities.json.gz").open("wb") as output:
        with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as zipped:
            zipped.write(compact_json(catalog))


if __name__ == "__main__":
    main()
