"""Turn the 2026 CTAmap GeoPackages into the Windows footprint atlas layer."""

from __future__ import annotations

import argparse
from collections import defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import sqlite3
import struct


ASSETS = Path(__file__).resolve().parent / "src" / "gaojiezou" / "assets"
DOI = "https://doi.org/10.5281/zenodo.22179207"
ARCHIVE_URL = "https://zenodo.org/records/22179207/files"
RELEASE_FILES = {
    "T2026_prefecture.gpkg": "2c935849e66db951eeb7cc368cbb563c",
    "T2026_province.gpkg": "d83c8cc972a17133b44f6008fc3c8598",
}
LICENSE = "https://creativecommons.org/licenses/by/4.0/"
SOURCE = {
    "name": "CTAmap v2.0",
    "authors": ["Rui Cheng", "Chiwei Xiao", "Yanjun Wang", "Yunfeng Hu"],
    "date": "2026-01-01",
    "url": DOI,
    "license": "CC BY 4.0",
    "licenseURL": LICENSE,
    "changes": "Selected matching six-digit collection codes and simplified WGS84 polygon rings.",
}


def quoted(identifier):
    return '"' + identifier.replace('"', '""') + '"'


def read_polygon(blob):
    if blob[:2] != b"GP" or len(blob) < 8 or blob[3] & 16:
        raise ValueError("Invalid or empty GeoPackage polygon")
    envelope = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[(blob[3] >> 1) & 7]
    offset = 8 + envelope
    rings = []

    def read_integer(byte_order):
        nonlocal offset
        number = struct.unpack_from(byte_order + "I", blob, offset)[0]
        offset += 4
        return number

    def read_item():
        nonlocal offset
        byte_order = "<" if blob[offset] == 1 else ">"
        offset += 1
        geometry = read_integer(byte_order)
        kind, ordinates = geometry % 1000, {0: 2, 1: 3, 2: 3, 3: 4}[geometry // 1000]
        count = read_integer(byte_order)
        if kind == 6:
            for _ in range(count):
                read_item()
        elif kind == 3:
            for _ in range(count):
                vertices = read_integer(byte_order)
                end = offset + vertices * ordinates * 8
                ring = [point[:2] for point in struct.iter_unpack(byte_order + "d" * ordinates, memoryview(blob)[offset:end])]
                offset = end
                if len(ring) >= 4:
                    rings.append(simplify_ring(ring))
        else:
            raise ValueError(f"Unexpected WKB geometry {geometry}")

    read_item()
    return rings


def simplify_ring(ring, tolerance=0.006):
    """Retain closure and simplify each half of a ring to sub-kilometre precision."""
    originX, originY = ring[0]
    pivot = max(range(1, len(ring) - 1), key=lambda i: (ring[i][0] - originX) ** 2 + (ring[i][1] - originY) ** 2)
    kept = {0, pivot, len(ring) - 1}
    ranges = [(0, pivot), (pivot, len(ring) - 1)]
    while ranges:
        start, end = ranges.pop()
        if end <= start + 1:
            continue
        x1, y1 = ring[start]
        dx, dy = ring[end][0] - x1, ring[end][1] - y1
        length2 = dx * dx + dy * dy
        distance, split = tolerance ** 2, None
        for i in range(start + 1, end):
            px, py = ring[i][0] - x1, ring[i][1] - y1
            proportion = min(1, max(0, (px * dx + py * dy) / length2)) if length2 else 0
            delta = (px - dx * proportion) ** 2 + (py - dy * proportion) ** 2
            if delta > distance:
                distance, split = delta, i
        if split is not None:
            kept.add(split)
            ranges.extend(((start, split), (split, end)))
    vertices = [ring[i] for i in sorted(kept)] if len(kept) >= 4 else ring
    return [[round(x, 4), round(y, 4)] for x, y in vertices]


def read_layer(path, filename, identifiers):
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, lambda: hashlib.md5(usedforsecurity=False)).hexdigest()
    if digest != RELEASE_FILES[filename]:
        raise ValueError(f"{filename} does not match the publisher's checksum")

    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as database:
        table, geometry, spatial_ref = database.execute(
            "SELECT table_name, column_name, srs_id FROM gpkg_geometry_columns"
        ).fetchone()
        if spatial_ref != 4326:
            raise ValueError(f"{table} is not WGS84")
        columns = {row[1].lower(): row[1] for row in database.execute(f"PRAGMA table_info({quoted(table)})")}
        key = columns["code"] if filename == "T2026_prefecture.gpkg" else columns["省级码"]
        groups = defaultdict(list)
        records = database.execute(f"SELECT {quoted(key)}, {quoted(geometry)} FROM {quoted(table)}")
        for code, blob in records:
            code = str(code)
            if code in identifiers and blob:
                groups[code].extend(read_polygon(blob))
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefecture", type=Path, help=f"{ARCHIVE_URL}/T2026_prefecture.gpkg")
    parser.add_argument("--province", type=Path, help=f"{ARCHIVE_URL}/T2026_province.gpkg")
    args = parser.parse_args()
    catalog = json.loads(gzip.decompress((ASSETS / "cities.json.gz").read_bytes()))
    cities = {item["id"].removeprefix("cn-"): item for item in catalog["cities"] if item["id"].startswith("cn-")}
    province_names = {item["provinceID"]: item["province"] for item in cities.values()}
    prefectures = read_layer(args.prefecture, "T2026_prefecture.gpkg", cities)
    provinces = read_layer(args.province, "T2026_province.gpkg", province_names) if args.province else {}
    result = {
        "source": SOURCE,
        "prefectures": [{"id": cities[code]["id"], "rings": rings} for code, rings in sorted(prefectures.items())],
        "provinces": [{"id": code, "name": province_names[code], "rings": rings} for code, rings in sorted(provinces.items())],
        "cities": list(cities.values()),
    }
    (ASSETS / "footprints-prefectures.json").write_text(
        json.dumps(result, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    print(f"Built {len(prefectures)} matched city areas and {len(provinces)} provinces")
    print("City units kept as points:", ", ".join(sorted(cities.keys() - prefectures.keys())))


if __name__ == "__main__":
    main()
