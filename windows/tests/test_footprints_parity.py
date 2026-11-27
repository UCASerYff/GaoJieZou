import base64
import json
import os
import sqlite3
import struct
import sys
import zlib
from datetime import datetime, timedelta, timezone

import pytest

from gaojiezou.errors import AppError
from gaojiezou.footprints import FootprintStore, compute_metrics, load_cities, search_cities
from gaojiezou.heic import heif_extension, heif_preview
from gaojiezou.resources import asset_dir


PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")
# Synthetic red and green rectangles, encoded as a 96 by 64 HEVC still.
HEIC = base64.b64decode(
    "AAAAHGZ0eXBoZWljAAAAAG1pZjFoZWljbWlhZgAAAVZtZXRhAAAAAAAAACFoZGxyAAAAAAAA"
    "AABwaWN0AAAAAAAAAAAAAAAAAAAAACJpbG9jAAAAAERAAAEAAQAAAAABegABAAAAAAAAAJUA"
    "AAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAA5waXRtAAAAAAABAAAA1mlw"
    "cnAAAAC3aXBjbwAAAHhodmNDAQNwAAAAkAAAAAAAHvAA/P34+AAADwNgAAEAGEABDAH//wNw"
    "AAADAJAAAAMAAAMAHroCQGEAAQArQgEBA3AAAAMAkAAAAwAAAwAeoDCBBZbqSSmubgIaDAgA"
    "AAMAyAAAAwAIQGIAAQAHRAHBcrAiQAAAABNjb2xybmNseAABAA0ABoAAAAAUaXNwZQAAAAAA"
    "AABgAAAAQAAAABBwaXhpAAAAAAMICAgAAAAXaXBtYQAAAAAAAAABAAEEgQIDBAAAAJ1tZGF0"
    "AAAAkSgBrwa4Y7Dc/9L0v//+26Pof7VKtBfJ69/zI/33QQ//+jYtyHhb051EvZh0eJaZwaY"
    "1wb/DJONiyPs/Vu7VXMQ7RzShQLX8FYAdJk2kCEkGxH6Sogtb1bsPdsN7mnZNm6N6Xzn0fq"
    "bR2eqTA1CxwVr+EPDOwwxQozGebDGCONDfQNW8c7YdXv8z1m/7IhfOhOA="
)
NOW = datetime(2026, 11, 27, 8, tzinfo=timezone.utc)


@pytest.fixture
def store(tmp_path):
    footprints = FootprintStore(tmp_path)
    footprints.create_fresh(NOW)
    try:
        yield footprints
    finally:
        footprints.close()


def test_offline_atlas_uses_province_ids_and_search_matches_pinyin_and_english():
    atlas = json.loads((asset_dir() / "footprints-atlas.json").read_bytes())
    assert len(atlas["world"]) == 242
    assert len(atlas["china"]) == 34
    provinces = {city["provinceID"] for city in load_cities()["cities"] if city["countryID"] == "CHN"}
    assert {region["id"] for region in atlas["china"]} == provinces
    assert search_cities("Wuhan")[0]["id"] == "cn-420100"
    assert search_cities("bei jing")[0]["id"] == "cn-110000"
    assert search_cities("New York")[0]["english"].startswith("New York")
    assert all(city["countryID"] == "FRA" for city in search_cities("", country="FRA"))


def test_ctamap_uses_curated_codes_and_real_wuhan_boundary():
    atlas = json.loads((asset_dir() / "footprints-prefectures.json").read_bytes())
    assert atlas["source"]["license"] == "CC BY 4.0"
    assert len(atlas["provinces"]) == 34
    catalog_ids = {city["id"] for city in atlas["cities"]}
    areas = {area["id"]: area["rings"] for area in atlas["prefectures"]}
    assert len(areas) >= 340
    assert areas.keys() <= catalog_ids
    wuhan = [point for ring in areas["cn-420100"] for point in ring]
    assert min(x for x, _ in wuhan) < 114.3 < max(x for x, _ in wuhan)
    assert min(y for _, y in wuhan) < 30.6 < max(y for _, y in wuhan)


def test_heic_asset_keeps_legacy_original_and_identifies_hevc_brands(store):
    assert heif_extension(HEIC) == ".heic"
    assert heif_extension(b"\x00\x00\x00\x01ftypheic") is None
    visit = store.save_visit({"cityID": "cn-420100"}, NOW)
    photo = store.add_photo(visit["id"], "synthetic.heic", HEIC, NOW)
    assert store.photo(photo["id"]) == (HEIC, "image/heic")


@pytest.mark.skipif(sys.platform != "win32", reason="WIC is a Windows runtime feature")
def test_wic_decodes_genuine_heic_pixels():
    try:
        png = heif_preview(HEIC)
    except AppError as exc:
        if exc.code == "codec" and os.environ.get("GAOJIEZOU_TEST_REQUIRE_HEIC") != "1":
            pytest.skip("This Windows test host needs the HEIF and HEVC extensions")
        raise
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack_from(">II", png, 16)
    assert (width, height) == (96, 64)
    length, kind = struct.unpack_from(">I4s", png, 33)
    assert kind == b"IDAT"
    pixels = zlib.decompress(png[41:41 + length])
    stride = width * 3 + 1
    left = 20 * stride + 1 + 12 * 3
    right = 20 * stride + 1 + 76 * 3
    assert pixels[left] > 200 and pixels[left + 1] < 50
    assert pixels[right] < 60 and pixels[right + 1] > 125


def test_atomic_multi_city_visit_reuse_photos_and_preserve_trip_links_on_undo(store):
    cities = ["cn-420100", "cn-110000"]
    day = {"precision": "day", "year": 2026, "month": 11, "day": 27}
    payload = {
        "cityIDs": cities, "date": day, "note": "一起记录行程",
        "newTripName": "隔离旅行",
        "photos": [{"filename": "synthetic.png", "contentBase64": base64.b64encode(PNG).decode()}],
    }
    with pytest.raises(AppError, match="照片"):
        store.save_visit({**payload, "photos": payload["photos"] + [{"contentBase64": "bad*"}]}, NOW)
    assert store.summary()["visits"] == store.summary()["trips"] == []
    assert not store.photos.exists()

    first = store.save_visit(payload, NOW)
    state = store.summary()
    assert len(first["savedIDs"]) == 2
    assert state["metrics"]["cities"] == 2
    assert state["metrics"]["trips"] == 1
    assert len(state["attachments"]) == 1
    attachment_id = state["attachments"][0]["id"]
    assert [visit["photoIDs"] for visit in state["visits"]] == [[attachment_id], [attachment_id]]
    assert store.photo(attachment_id) == (PNG, "image/png")
    trip_id = first["tripID"]
    materials = state["train"]["materials"]

    with pytest.raises(AppError) as duplicate:
        store.save_visit({"cityIDs": [cities[0]], "date": day, "tripID": trip_id}, NOW)
    assert duplicate.value.code == "duplicate"
    store.delete_trip(trip_id, NOW)
    assert all(not visit.get("tripID") for visit in store.summary()["visits"])
    assert store.undo(NOW)
    assert all(visit["tripID"] == trip_id for visit in store.summary()["visits"])
    assert store.summary()["train"]["materials"] == materials
    store.close()
    store.open_existing()
    assert store.photo(attachment_id) == (PNG, "image/png")


def test_legacy_asset_and_unknown_rows_survive_edit(store):
    initial = store.save_visit({"cityID": "cn-420100", "note": "first"}, NOW)
    attachment = store.add_photo(initial["id"], "legacy.png", PNG, NOW)
    with sqlite3.connect(store.path) as connection:
        meta = json.loads(connection.execute("SELECT payload FROM items WHERE kind = 'meta'").fetchone()[0])
        meta["futureExtension"] = {"sample": True}
        connection.execute("UPDATE items SET payload = ? WHERE kind = 'meta'", (json.dumps(meta),))
        connection.execute("INSERT INTO items VALUES ('future', 'xyz', ?)", (b"unparsed original payload",))
    store.close()
    store.open_existing()
    store.save_visit({"id": initial["id"], "cityIDs": [initial["cityID"]], "note": "edited"}, NOW + timedelta(hours=1))
    assert store.summary()["visits"][0]["createdAt"] == initial["createdAt"]
    assert store.summary()["visits"][0]["photoIDs"] == [attachment["id"]]
    core = store.summary()
    assert core["train"]["claimedVisitIDs"] == [initial["id"]]
    with sqlite3.connect(store.path) as connection:
        assert json.loads(connection.execute("SELECT payload FROM items WHERE kind = 'meta'").fetchone()[0])["futureExtension"] == {"sample": True}
        assert connection.execute("SELECT payload FROM items WHERE kind = 'future'").fetchone()[0] == b"unparsed original payload"
    path = store.photos / attachment["filename"]
    path.write_bytes(PNG[:-1] + b"x")
    with pytest.raises(AppError, match="照片校验"):
        store.photo(attachment["id"])


def test_home_and_journeys_do_not_create_visits_or_double_claim_supplies(store):
    store.set_resident("cn-420100", NOW)
    assert store.summary()["metrics"]["visits"] == 0
    assert store.summary()["train"]["materials"] == 0
    assert not store.depart("cn-420100", NOW)
    for city in ("cn-420100", "cn-110000"):
        store.save_visit({"cityID": city}, NOW)
    assert not store.depart("cn-310000", NOW)
    assert store.depart(store.summary()["train"]["routeCityID"], NOW)
    assert not store.arrive(NOW)
    assert store.sync_train(NOW + timedelta(minutes=15))
    previous = store.summary()
    assert not store.sync_train(NOW + timedelta(minutes=16))
    assert store.summary()["train"]["materials"] == previous["train"]["materials"]
    assert previous["train"]["cruiseCount"] == 1
    assert previous["metrics"]["visits"] == 2
    catalog = {city["id"]: city for city in load_cities()["cities"]}
    assert compute_metrics(store.journal, catalog, year=2026)["cities"] == 0
