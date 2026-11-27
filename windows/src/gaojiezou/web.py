"""只监听 127.0.0.1 的本地页面。个人资料不离开这台电脑。"""

from __future__ import annotations

import base64
import binascii
import json
import mimetypes
import secrets
import threading
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from gaojiezou.errors import AppError
from gaojiezou.footprints import search_cities
from gaojiezou.heic import HEIF_MIME, heif_preview
from gaojiezou.resources import artwork, asset_dir, english_strings
from gaojiezou.store import RhythmStore, focus_csv, habit_csv, sleep_csv
from gaojiezou.timeutil import add_days, parse_instant
from gaojiezou.version import VERSION_LABEL


class RhythmServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, store: RhythmStore, host: str = "127.0.0.1", port: int = 0):
        self.store = store
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.shutdown_requested = threading.Event()
        self.desktop = None
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"


class Handler(BaseHTTPRequestHandler):
    server: RhythmServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._page()
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            with self.server.lock:
                self._json(self.server.store.snapshot())
            return
        if parsed.path == "/api/cities":
            if not self._authorized():
                return
            params = parse_qs(parsed.query)
            query = params.get("q", [""])[0]
            country = params.get("country", [None])[0]
            with self.server.lock:
                store = self.server.store.footprints
                cities = store.search(query, country) if store.journal is not None else search_cities(query)
            self._json({"cities": cities})
            return
        if parsed.path == "/api/footprints/photo":
            if not self._authorized():
                return
            params = parse_qs(parsed.query)
            photo_id = params.get("id", [""])[0]
            try:
                with self.server.lock:
                    content, mime = self.server.store.footprints.photo(photo_id)
                if params.get("preview", [""])[0] == "1" and mime in HEIF_MIME:
                    content, mime = heif_preview(content), "image/png"
                self._bytes(content, mime)
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 422 if exc.code in {"codec", "invalid"} else 404)
            return
        if parsed.path == "/localization/en.json":
            self._json(english_strings())
            return
        if parsed.path.startswith("/art/"):
            asset = artwork(parsed.path.removeprefix("/art/"))
            if asset is not None and asset.is_file():
                self._bytes(asset.read_bytes(), "image/png", cache_control="private, max-age=3600")
            else:
                self._json({"error": "没有这张图片。"}, 404)
            return
        if parsed.path == "/api/export/focus.csv":
            self._export(focus_csv)
            return
        if parsed.path == "/api/export/sleep.csv":
            self._export(sleep_csv)
            return
        if parsed.path == "/api/export/habits.csv":
            self._export(habit_csv)
            return
        if parsed.path == "/api/export/diagnostics.txt":
            if not self._authorized():
                return
            with self.server.lock:
                store = self.server.store
                lines = [
                    f"GaoJieZou {VERSION_LABEL} (Windows)",
                    f"Library status: {store.status}",
                    f"Shared sleep: {'available' if store.sleep.available else 'unavailable'}",
                    f"Health: {'available' if store.health.state is not None else 'unavailable'}",
                    f"Footprints: {'available' if store.footprints.journal is not None else 'unavailable'}",
                    f"Desktop integration: {'active' if self.server.desktop is not None else 'unavailable'}",
                ]
            self._bytes(("\r\n".join(lines) + "\r\n").encode("utf-8"), "text/plain; charset=utf-8")
            return
        if parsed.path in {"/api/export/footprints.csv", "/api/export/footprints.json"}:
            if not self._authorized():
                return
            try:
                with self.server.lock:
                    store = self.server.store
                    _need_footprints(store)
                    if parsed.path.endswith(".csv"):
                        content = store.footprints.export_csv()
                        mime = "text/csv; charset=utf-8"
                    else:
                        content = store.footprints.export_json()
                        mime = "application/json; charset=utf-8"
                self._bytes(content.encode("utf-8"), mime)
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
            return
        if parsed.path == "/api/health/export.zip":
            if not self._authorized():
                return
            try:
                with self.server.lock:
                    _need_health(self.server.store)
                    archive = self.server.store.health.export_csv()
            except AppError as exc:
                self._json({"error": exc.message}, 400)
                return
            self._bytes(archive, "application/zip")
            return
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if asset.is_file() and root in asset.parents:
            content = asset.read_bytes()
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(content, mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if not self._authorized():
            return
        if parsed.path == "/api/footprints/photo/preview":
            try:
                payload = self._body()
                content = base64.b64decode(payload.get("contentBase64", ""), validate=True)
                self._bytes(heif_preview(content), "image/png")
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 422)
            except (TypeError, ValueError, binascii.Error):
                self._json({"error": "照片上传数据无效。", "code": "invalid"}, 400)
            return
        if parsed.path == "/api/shutdown":
            try:
                with self.server.lock:
                    self.server.store.prepare_for_exit()
            except (AppError, OSError) as exc:
                self._json({"ok": False, "error": str(exc)}, 500)
                return
            self._json({"ok": True})
            self.server.shutdown_requested.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if parsed.path == "/api/platform/widgets":
            if self.server.desktop is None:
                self._json({"error": "请通过 Windows 桌面程序打开小组件。"}, 400)
                return
            self.server.desktop.show_widgets()
            self._json({"ok": True})
            return
        try:
            payload = self._body()
            with self.server.lock:
                result = dispatch(self.server.store, parsed.path, payload)
                self._json({"ok": True, "result": result, "state": self.server.store.snapshot()})
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
        except (KeyError, ValueError, TypeError, OverflowError, binascii.Error):
            self._json({"ok": False, "error": "请检查输入的内容和格式。", "code": "invalid"}, 400)
        except OSError:
            self._json({"ok": False, "error": "无法写入本地资料。", "code": "storage"}, 500)

    def _export(self, builder) -> None:
        if not self._authorized():
            return
        with self.server.lock:
            if self.server.store.library is None:
                self._json({"error": "资料库尚未创建。"}, 400)
                return
            text = builder(self.server.store)
        self._bytes(text.encode("utf-8"), "text/csv; charset=utf-8")

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _authorized(self) -> bool:
        if self.headers.get("X-Gao-Token") == self.server.token:
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 <= length <= 48 * 1024 * 1024:
            raise AppError("请求超过 48 MiB 或长度无效。", "invalid")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            raise AppError("请求体须为 JSON 对象。", "invalid")
        return data

    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(body, "application/json; charset=utf-8", status)

    def _bytes(self, body: bytes, content_type: str, status: int = 200, cache_control: str = "no-store") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def dispatch(store: RhythmStore, path: str, payload: dict):
    if path == "/api/library/create":
        store.create_library()
        return {"created": True}
    if path == "/api/settings":
        return store.update_settings(payload)
    if path == "/api/focus/start":
        return store.start_focus(payload.get("linkedActionID"))
    if path == "/api/focus/pause":
        store.pause_focus(bool(payload.get("system")))
        return {"paused": True}
    if path == "/api/focus/resume":
        store.resume_focus()
        return {"resumed": True}
    if path == "/api/focus/finish":
        return store.finish_focus()
    if path == "/api/focus/cancel":
        store.cancel_focus()
        return {"cancelled": True}
    if path == "/api/sleep/start":
        return store.start_sleep(payload.get("targetHours"))
    if path == "/api/sleep/finish":
        return store.finish_sleep()
    if path == "/api/sleep/cancel":
        store.cancel_sleep()
        return {"cancelled": True}
    if path == "/api/sleep/manual":
        start, end = _manual_bounds(store, payload)
        return store.add_manual_sleep(start, end, payload.get("targetHours"))
    if path == "/api/sleep/delete":
        store.delete_sleep(payload["id"])
        return {"deleted": True}
    if path == "/api/habits/toggle":
        moment = parse_instant(payload["on"], store.tz) if payload.get("on") else None
        return {"completed": store.toggle_habit(payload["id"], moment)}
    if path == "/api/habits/save":
        return store.save_habit(payload)
    if path == "/api/habits/delete":
        store.delete_habit(payload["id"])
        return {"deleted": True}
    if path == "/api/chores/save":
        return store.save_chore(payload)
    if path == "/api/chores/toggle":
        return store.toggle_chore(payload["id"])
    if path == "/api/chores/delete":
        store.delete_chore(payload["id"])
        return {"deleted": True}
    if path == "/api/goals/save":
        return store.save_goal(payload)
    if path == "/api/goals/delete":
        store.delete_goal(payload["id"])
        return {"deleted": True}
    if path == "/api/actions/save":
        return store.save_action(payload)
    if path == "/api/actions/toggle":
        return store.toggle_action(payload["id"])
    if path == "/api/actions/delete":
        store.delete_action(payload["id"])
        return {"deleted": True}
    if path == "/api/farm/plant":
        return store.plant(payload["plotID"], payload["cropID"])
    if path == "/api/farm/buy-plot":
        return store.buy_plot()
    if path == "/api/farm/water":
        store.water(payload["plotID"])
        return {"ok": True}
    if path == "/api/farm/fertilize":
        store.fertilize(payload["plotID"])
        return {"ok": True}
    if path == "/api/farm/harvest":
        return {"coins": store.harvest(payload["plotID"])}
    if path == "/api/farm/harvest-all":
        count, coins = store.harvest_all()
        return {"count": count, "coins": coins}
    if path == "/api/pasture/shelter":
        return {"cost": store.buy_shelter()}
    if path == "/api/pasture/buy":
        return store.buy_animal(payload["animalID"])
    if path == "/api/pasture/collect":
        return {"coins": store.collect_products(payload.get("id"))}
    if path == "/api/pasture/sell":
        return {"coins": store.sell_animal(payload["id"])}
    if path == "/api/pasture/move":
        store.move_pasture_animal(payload["id"], int(payload["index"]))
        return {"moved": True}
    if path == "/api/fish/cast":
        return store.cast_line()
    if path == "/api/fish/reel":
        return store.reel()
    if path == "/api/fish/cancel":
        store.cancel_cast()
        return {"cancelled": True}
    if path == "/api/fish/sell":
        return {"coins": store.sell_fish(payload.get("fishID"))}
    if path == "/api/fish/sell-one":
        return {"coins": store.sell_one_fish(payload["fishID"])}
    if path == "/api/fish/aquarium":
        return {"moved": store.move_to_aquarium(payload["fishID"])}
    if path == "/api/fish/aquarium-income":
        return {"coins": store.collect_aquarium()}
    if path == "/api/fish/aquarium-return":
        store.return_aquarium_fish(payload["id"])
        return {"returned": True}
    if path == "/api/decorations/buy":
        return {"price": store.buy_decoration(payload["id"])}
    if path == "/api/decorations/upgrade":
        return {"price": store.upgrade_decoration(payload["id"])}
    if path == "/api/health/record":
        _need_health(store)
        return store.health.save_record(payload, store.now())
    if path == "/api/health/record/delete":
        _need_health(store)
        store.health.delete_record(payload["id"], store.now())
        return {"deleted": True}
    if path == "/api/health/sleep/add":
        _need_health(store)
        return store.add_health_sleep(*_manual_bounds(store, payload))
    if path == "/api/health/sleep/delete":
        _need_health(store)
        store.delete_sleep(payload["id"])
        return {"deleted": True}
    if path == "/api/health/event":
        _need_health(store)
        return store.health.save_event(payload, store.now())
    if path == "/api/health/event/delete":
        _need_health(store)
        store.health.delete_event(payload["id"], store.now())
        return {"deleted": True}
    if path == "/api/health/event/type":
        _need_health(store)
        return store.health.save_event_type(payload, store.now())
    if path == "/api/health/template/use":
        _need_health(store)
        return store.health.use_template(payload["id"], store.now())
    if path == "/api/health/template/delete":
        _need_health(store)
        store.health.delete_template(payload["id"], store.now())
        return {"deleted": True}
    if path == "/api/health/undo":
        _need_health(store)
        return {"undone": store.health.undo(store.now())}
    if path == "/api/health/import-csv":
        _need_health(store)
        return store.health.import_csv(payload.get("files"), store.now())
    if path == "/api/health/act":
        _need_health(store)
        return {"message": store.health.act(payload["id"], store.now())}
    if path == "/api/health/build":
        _need_health(store)
        return {"message": store.health.build(payload["id"], store.now())}
    if path == "/api/health/upgrade":
        _need_health(store)
        return {"message": store.health.upgrade(payload["id"], store.now())}
    if path == "/api/health/expand":
        _need_health(store)
        return {"message": store.health.expand(store.now())}
    if path == "/api/health/supply":
        _need_health(store)
        return {"message": store.health.supply(store.now())}
    if path == "/api/health/preferences":
        _need_health(store)
        store.health.set_preferences(payload, store.now())
        return {"ok": True}
    if path == "/api/health/tea":
        _need_health(store)
        return {"message": store.health.brew_tea(store.now())}
    if path == "/api/health/layout":
        _need_health(store)
        return store.health.layout(payload["placements"], store.now())
    if path == "/api/health/island/visit":
        _need_health(store)
        return store.health.visit_island(store.now())
    if path == "/api/footprints/visit":
        _need_footprints(store)
        return store.footprints.save_visit(payload, store.now())
    if path == "/api/footprints/trip":
        _need_footprints(store)
        return store.footprints.save_trip(payload, store.now())
    if path == "/api/footprints/visit/delete":
        _need_footprints(store)
        return store.footprints.delete_visit(payload["id"], store.now())
    if path == "/api/footprints/trip/delete":
        _need_footprints(store)
        return store.footprints.delete_trip(payload["id"], store.now())
    if path == "/api/footprints/undo":
        _need_footprints(store)
        return store.footprints.undo(store.now())
    if path == "/api/footprints/city":
        _need_footprints(store)
        return store.footprints.add_custom_city(payload, store.now())
    if path == "/api/footprints/preferences":
        _need_footprints(store)
        return store.footprints.set_preferences(payload, store.now())
    if path == "/api/footprints/resident":
        _need_footprints(store)
        store.footprints.set_resident(payload.get("cityID"), store.now())
        return {"ok": True}
    if path == "/api/footprints/train/depart":
        _need_footprints(store)
        return {"departed": store.footprints.depart(payload["destinationID"], store.now())}
    if path == "/api/footprints/train/arrive":
        _need_footprints(store)
        return {"arrived": store.footprints.arrive(store.now())}
    if path == "/api/footprints/train/upgrade":
        _need_footprints(store)
        return {"upgraded": store.footprints.upgrade_carriage(payload["carriage"])}
    if path == "/api/footprints/train/route":
        _need_footprints(store)
        return store.footprints.set_train_route(payload.get("destinationID", ""), store.now())
    if path == "/api/footprints/train/reorder":
        _need_footprints(store)
        return store.footprints.reorder_carriage(payload["carriage"], payload["slot"], store.now())
    if path == "/api/footprints/train/sync":
        _need_footprints(store)
        return store.footprints.sync_train(store.now())
    if path == "/api/footprints/photo":
        _need_footprints(store)
        content = base64.b64decode(payload.get("contentBase64") or "", validate=True)
        return store.footprints.add_photo(payload["visitID"], payload.get("filename") or "photo.jpg", content, store.now())
    raise AppError("没有这个操作。", "invalid")


def _need_health(store: RhythmStore) -> None:
    if store.health.state is None:
        raise AppError("健康库未打开。缺失时不会新建空库。", "missing")


def _need_footprints(store: RhythmStore) -> None:
    if store.footprints.journal is None:
        raise AppError("足迹库未打开。缺失时不会新建空库。", "missing")


def _manual_bounds(store: RhythmStore, payload: dict):
    if payload.get("start") and payload.get("end"):
        return parse_instant(payload["start"], store.tz), parse_instant(payload["end"], store.tz)
    night = parse_instant(payload["night"], store.tz)
    minutes = int(payload["minutes"])
    wake = add_days(night, 1, store.tz).replace(hour=7, minute=0, second=0, microsecond=0)
    return wake - timedelta(minutes=minutes), wake


def serve(store: RhythmStore, port: int = 0, open_browser: bool = True) -> RhythmServer:
    server = RhythmServer(store, port=port)
    thread = threading.Thread(target=server.serve_forever, name="gaojiezou-http", daemon=True)
    thread.start()
    if open_browser:
        import webbrowser
        webbrowser.open(server.url)
    return server
