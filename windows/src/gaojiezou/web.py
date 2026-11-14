"""只监听 127.0.0.1 的本地页面。个人资料不离开这台电脑。"""

from __future__ import annotations

import base64
import json
import mimetypes
import secrets
import threading
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from gaojiezou.errors import AppError
from gaojiezou.footprints import search_cities
from gaojiezou.resources import asset_dir
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
            query = parse_qs(parsed.query).get("q", [""])[0]
            self._json({"cities": search_cities(query)})
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
        if parsed.path == "/api/shutdown":
            if not self._authorized():
                return
            self._json({"ok": True})
            self.server.shutdown_requested.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not self._authorized():
            return
        payload = self._body()
        try:
            with self.server.lock:
                result = dispatch(self.server.store, parsed.path, payload)
            self._json({"ok": True, "result": result, "state": self.server.store.snapshot()})
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)

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
        if length > 32 * 1024 * 1024:
            raise AppError("上传超过 32 MiB。", "invalid")
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

    def _bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
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
    if path == "/api/goals/save":
        return store.save_goal(payload)
    if path == "/api/actions/save":
        return store.save_action(payload)
    if path == "/api/actions/toggle":
        return store.toggle_action(payload["id"])
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
    if path == "/api/pasture/shelter":
        return {"cost": store.buy_shelter()}
    if path == "/api/pasture/buy":
        return store.buy_animal(payload["animalID"])
    if path == "/api/pasture/collect":
        return {"coins": store.collect_products(payload.get("id"))}
    if path == "/api/pasture/sell":
        return {"coins": store.sell_animal(payload["id"])}
    if path == "/api/fish/cast":
        return store.cast_line()
    if path == "/api/fish/reel":
        return store.reel(payload.get("roll"))
    if path == "/api/fish/sell":
        return {"coins": store.sell_fish(payload.get("fishID"))}
    if path == "/api/fish/aquarium":
        return {"moved": store.move_to_aquarium(payload["fishID"])}
    if path == "/api/fish/aquarium-income":
        return {"coins": store.collect_aquarium()}
    if path == "/api/decorations/buy":
        return {"price": store.buy_decoration(payload["id"])}
    if path == "/api/decorations/upgrade":
        return {"price": store.upgrade_decoration(payload["id"])}
    if path == "/api/health/record":
        _need_health(store)
        return store.health.save_record(payload, store.now())
    if path == "/api/health/record/delete":
        _need_health(store)
        store.health.delete_record(payload["id"])
        return {"deleted": True}
    if path == "/api/health/event":
        _need_health(store)
        return store.health.save_event(payload, store.now())
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
        store.health.set_preferences(payload)
        return {"ok": True}
    if path == "/api/footprints/visit":
        _need_footprints(store)
        return store.footprints.save_visit(payload, store.now())
    if path == "/api/footprints/trip":
        _need_footprints(store)
        return store.footprints.save_trip(payload, store.now())
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
