"""Live Windows desktop equivalents of the three WidgetKit cards."""

from __future__ import annotations

import calendar
import gc
import json
import math
import re
import threading
import tkinter as tk
from datetime import date
from functools import lru_cache
from tkinter import font as tkfont, ttk

from gaojiezou.desktop import habit_counts, route_index
from gaojiezou.errors import AppError
from gaojiezou.health import ISLAND_LEVEL_MARKS, prosperity
from gaojiezou.resources import asset_dir
from gaojiezou.timeutil import from_cocoa


def widget_data(store) -> dict | None:
    if store.status != "ready" or store.library is None:
        return None
    doc = store.library
    now = store.now()
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)

    def date(value):
        return from_cocoa(value).astimezone(store.tz).date()

    def today(value):
        return value is not None and date(value) == now.date()

    habits, complete = habit_counts(store, now)
    focused = sum(row.get("durationSeconds", 0) for row in doc.get("focusRecords", ()) if today(row.get("endedAt")))
    active = doc.get("activeFocus") or {}
    focused += float(active.get("accumulatedSeconds") or 0) if today(active.get("startedAt")) else 0
    running = active.get("segmentStartedAt") is not None
    if running:
        segment = from_cocoa(active["segmentStartedAt"])
        focused += max(0, now.timestamp() - max(segment.timestamp(), start.timestamp()))
    sleep = []
    for row in doc.get("sleepRecords", ()):
        if today(row.get("endedAt")) and row.get("startedAt") is not None:
            begin = from_cocoa(row["startedAt"]).astimezone(store.tz)
            end = from_cocoa(row["endedAt"]).astimezone(store.tz)
            if end.hour < 18 and (begin.hour < 12 or begin < start):
                sleep.append((row.get("healthSource") is not None, row.get("durationSeconds", 0)))
    last_sleep = max(sleep)[1] if sleep else None

    actions = doc.get("shortActions", ())
    goals = sorted(enumerate(doc.get("longGoals", ())),
                   key=lambda item: (item[1].get("createdAt") or 0, item[0]), reverse=True)
    rows = []
    for _, goal in goals:
        linked = [row for row in actions if row.get("goalID") == goal["id"]]
        rows.append((goal["title"], sum(bool(row.get("isCompleted")) for row in linked), len(linked), goal.get("status") == "completed"))
    events = []
    for is_action, source in [(False, doc.get("chores", ())), (True, actions)]:
        for sequence, row in enumerate(source):
            begin = row.get("startDate")
            if begin is not None and not row.get("isCompleted"):
                end = row.get("endDate")
                events.append((row.get("createdAt") or begin, sequence, row["id"], row["title"],
                               date(begin), date(max(begin, end if end is not None else begin)),
                               "#477ed1" if is_action else _event_color(row.get("colorHex"))))
    events.sort(key=lambda row: (-row[0], -row[1], row[2]))
    return {"today": now.date(), "metrics": (complete, habits, int(focused), running, last_sleep, bool(doc.get("activeSleep"))),
            "goals": rows, "events": events}


def _event_color(value: str | None) -> str:
    value = str(value or "").lstrip("#")
    return f"#{value}" if re.fullmatch(r"[a-fA-F0-9]{6}", value) else "#a26a34"


def month_segments(week: list, events: list, capacity: int) -> list:
    lanes = [set() for _ in range(capacity)]
    result = []
    for _, _, _, title, begin, end, tint in events:
        cells = {column for column, day in enumerate(week) if day and begin <= day <= end}
        if not cells:
            continue
        for lane, occupied in enumerate(lanes):
            if cells.isdisjoint(occupied):
                occupied.update(cells)
                result.append((min(cells), max(cells), lane, title, tint))
                break
    return result


def health_widget_data(store, view: int, selected: str = "") -> dict | None:
    health = store.health
    state = health.state
    if not state:
        return None
    today = store.now().astimezone(health.tz).date()
    def local_date(row):
        return from_cocoa(row["occurredAt"]).astimezone(health.tz).date()

    if view == 3:
        day = [row for row in state["records"] if local_date(row) == today]
        amount = lambda kind: sum(row["amount"] for row in day if row["kind"] == kind)
        preferences, island = state["preferences"], state["island"]
        level = sum(prosperity(island) >= point for point in ISLAND_LEVEL_MARKS)
        return {"water": amount("water"), "meals": sum(row["kind"] == "meal" for row in day), "exercise": amount("exercise"),
                "cup": preferences["cup"], "island": (level, island["water"], island["food"], island["energy"])
                if preferences.get("gameEnabled", True) else None}
    by_day = [0] * calendar.monthrange(today.year, today.month)[1]
    for row in state["events"]:
        occurred = local_date(row)
        if (occurred.year, occurred.month) == (today.year, today.month) and (not selected or row["typeID"] == selected):
            by_day[occurred.day - 1] += row["count"]
    types = [(row["id"], row["name"], row.get("englishName") or row["name"], row.get("inWidget", True))
             for row in state.get("eventTypes", ()) if not row.get("archived")]
    return {"today": today, "days": by_day, "types": types, "selected": selected}


def footprint_widget_data(store) -> dict | None:
    source = store.footprints.summary()
    if not source["available"]:
        return None
    resident = source["residentCity"]
    return {"metrics": source["metrics"], "chinaTotal": source["chinaTotal"], "resident": resident,
            "cities": source["plotted"]}


def project_widget_map(longitude: float, latitude: float) -> tuple[float, float]:
    p2 = math.radians(latitude) ** 2
    p4 = p2 * p2
    return (longitude * (0.8707 - 0.131979 * p2 + p4 * (-0.013791 + p4 * (0.003971 * p2 - 0.001529 * p4))),
            -latitude * (1.007226 + p2 * (0.015085 + p4 * (-0.044475 + 0.028874 * p2 - 0.005916 * p4))))


@lru_cache(maxsize=1)
def _widget_atlas() -> list:
    with (asset_dir() / "footprints-atlas.json").open(encoding="utf-8") as source:
        regions = json.load(source)["world"]
    result = []
    for region in regions:
        for ring in region["rings"]:
            if len(ring) < 5:
                continue
            piece = []
            before = ring[0][0]
            for lon, lat in ring:
                if abs(lon - before) > 180:
                    if len(piece) >= 3:
                        result.append((region["countryID"], piece))
                    piece = []
                piece.append(project_widget_map(lon, lat))
                before = lon
            if len(piece) >= 3:
                result.append((region["countryID"], piece))
    return result


def log_widget_health(store, event_id: str | None = None) -> None:
    if event_id:
        store.health.save_event({"typeID": event_id, "count": 1, "source": "widget"}, store.now())
    elif store.health.state:
        store.health.save_record({"kind": "water", "amount": store.health.state["preferences"]["cup"], "source": "widget"}, store.now())
    else:
        raise AppError("健康资料暂不可读。", "missing")


def _duration(seconds) -> str:
    if seconds is None:
        return "—"
    hours, rest = divmod(int(seconds), 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _is_dark(setting: str) -> bool:
    if setting != "system":
        return setting == "dark"
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
            return not winreg.QueryValueEx(key, "AppsUseLightTheme")[0]
    except (ImportError, OSError):
        return False


class WidgetHost:
    def __init__(self, server, open_window):
        self.server = server
        self.open_window = open_window
        self.shown = threading.Event()
        self.stopped = threading.Event()
        self.thread = None

    def show(self) -> None:
        self.shown.set()
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self._run, name="gaojiezou-widgets", daemon=True)
            self.thread.start()

    def close(self) -> None:
        self.stopped.set()
        if self.thread is not None:
            self.thread.join(timeout=2)

    def _run(self) -> None:
        widgets = Widgets(self.server, self.open_window, self.shown, self.stopped)
        try:
            widgets.run()
        finally:
            del widgets
            gc.collect()


class Widgets:
    def __init__(self, server, open_window, shown, stopped):
        self.server, self.open_window = server, open_window
        self.shown, self.stopped = shown, stopped
        self.root = tk.Tk()
        self.root.withdraw()
        self.scale = max(1.0, self.root.winfo_fpixels("1i") / 96)
        self.root.protocol("WM_DELETE_WINDOW", self.root.withdraw)
        self.view = 0
        self.topmost = tk.BooleanVar(self.root, True)
        self._pin()
        self.shell = tk.Frame(self.root)
        self.shell.pack(fill="x")
        self.body = tk.Frame(self.root)
        self.body.pack(fill="both", expand=True)
        self.last = None
        self.chrome = None
        self.metric_labels = []
        self.event_selection = ""
        self.message = ""
        self.footprint_journal = None
        self.footprint_card = None

    def run(self) -> None:
        self._tick()
        self.root.mainloop()

    def _pin(self) -> None:
        self.root.wm_attributes("-topmost", self.topmost.get())

    def _switch(self, index) -> None:
        self.view = index
        self.message = ""
        if index in (1, 4, 5):
            minimum, preferred = (480, 390), (620, 460)
        else:
            minimum, preferred = (370, 235), (415, 290)
            if index == 3:
                minimum, preferred = (385, 310), (490, 375)
        screen = (self.root.winfo_screenwidth(), self.root.winfo_screenheight())
        available = tuple(round(axis * 0.9) for axis in screen)
        self.root.minsize(*(min(round(size * self.scale), limit) for size, limit in zip(minimum, available)))
        width, height = (min(round(size * self.scale), limit) for size, limit in zip(preferred, available))
        self.root.geometry(f"{width}x{height}")
        self.last = None

    def _tick(self) -> None:
        if self.stopped.is_set():
            self.root.destroy()
            return
        if self.shown.is_set():
            self.shown.clear()
            self.root.deiconify()
            self.root.lift()
            if self.chrome is None:
                self._switch(0)
        if self.root.state() != "withdrawn":
            with self.server.lock:
                store = self.server.store
                english = store.settings.get("language") == "en"
                appearance = store.settings.get("appearance", "system")
                if self.view < 3:
                    data = widget_data(store)
                    view_data = None if data is None else (data["metrics"], (data["today"], data["events"]), data["goals"])[self.view]
                elif self.view < 5:
                    view_data = health_widget_data(store, self.view, self.event_selection)
                else:
                    if store.footprints.journal is not self.footprint_journal:
                        self.footprint_journal = store.footprints.journal
                        self.footprint_card = footprint_widget_data(store)
                    view_data = self.footprint_card
            dark = _is_dark(appearance)
            state = (self.view, english, dark, view_data)
            if self.last != state:
                self._render(state)
                self.last = state
        self.root.after(500, self._tick)

    def _render(self, state) -> None:
        view, english, dark, data = state
        bg, fg, muted, tile = ("#172521", "#eff6f4", "#b9cbc5", "#22352f") if dark else ("#fffdf9", "#21332e", "#4e625b", "#edf4ed")
        if view == 0 and data is not None and self.chrome == (view, english, dark) and self.metric_labels:
            self._update_metrics(data, english)
            return
        self.root.configure(background=bg)
        self.body.configure(background=bg)
        self.shell.configure(background=bg)
        if self.chrome != (view, english, dark):
            self.chrome = (view, english, dark)
            self.root.title("Rhythm desktop widgets" if english else "搞节奏 · 桌面小组件")
            for child in self.shell.winfo_children():
                child.destroy()
            tabs = ("Today's metrics", "Monthly overview", "Long-term goals", "Health", "Quick events", "Footprints") if english else (
                "今日指标", "月度总览", "长期目标", "健康日常", "健康事项月历", "足迹地图")
            tab_rows = [tk.Frame(self.shell, bg=bg), tk.Frame(self.shell, bg=bg)]
            for row in tab_rows:
                row.pack(fill="x")
            for index, title in enumerate(tabs):
                tk.Button(tab_rows[index // 3], text=title, command=lambda index=index: self._switch(index),
                          relief="sunken" if index == view else "flat", bg=tile, fg=fg,
                          activebackground=bg, activeforeground=fg, padx=5, pady=3).pack(side="left", padx=(3, 0), pady=3)
            tk.Checkbutton(tab_rows[1], text="Pin" if english else "置顶", variable=self.topmost, command=self._pin,
                           bg=bg, fg=fg, activebackground=bg, activeforeground=fg, selectcolor=tile).pack(side="right", padx=5)

        for child in self.body.winfo_children():
            child.destroy()
        self.metric_labels = []
        route = ("today", "today", "longGoals", "health", "health/events", "footprints")[view]
        self._route_button(self.body, "Open Rhythm" if english else "打开搞节奏", route, fg, tile).pack(side="bottom", anchor="e", padx=10, pady=6)
        if self.message:
            tk.Label(self.body, text=self.message, bg=bg, fg=muted).pack(side="bottom", anchor="w", padx=10)
        if data is None:
            tk.Label(self.body, text="Data unavailable" if english else "资料暂不可读", font=("Segoe UI", 13, "bold"),
                     bg=bg, fg=fg).pack(anchor="w", padx=12, pady=8)
        elif view == 0:
            for _metric in range(3):
                row = tk.Frame(self.body, bg=tile, padx=10, pady=5)
                row.pack(fill="x", padx=10, pady=3)
                title = tk.Label(row, fg=muted, bg=tile, font=("Segoe UI", 10))
                value = tk.Label(row, fg=fg, bg=tile, font=("Segoe UI", 13, "bold"))
                title.pack(side="left")
                value.pack(side="right")
                self.metric_labels.append((title, value))
            self._update_metrics(data, english)
        elif view == 1:
            self._calendar(data, english, bg, fg, tile)
        elif view == 2:
            board = tk.Frame(self.body, bg=bg)
            board.pack(fill="both", expand=True, padx=10, pady=5)
            scroll = tk.Scrollbar(board)
            scroll.pack(side="right", fill="y")
            rows = tk.Listbox(board, bg=tile, fg=fg, highlightthickness=0, relief="flat",
                              font=("Segoe UI", 10), height=5, yscrollcommand=scroll.set)
            rows.pack(side="left", fill="both", expand=True)
            scroll.configure(command=rows.yview)
            for title, done, total, finished in data:
                rows.insert("end", f"{'✓' if finished else '□'}  {title}  ({done}/{total})")
            if not data:
                rows.insert("end", "No long-term goals yet." if english else "还没有长期目标。")
        elif view == 3:
            self._health(data, english, bg, fg, tile)
        elif view == 4:
            self._events(data, english, bg, fg, tile)
        else:
            self._footprints(data, english, bg, fg, tile)

    def _route_button(self, parent, text, route, fg, tile):
        return tk.Button(parent, text=text, bg=tile, fg=fg, relief="flat",
                         command=lambda: self.open_window(self.server.url, route_index("gaojiezou://" + route)))

    def _log(self, english, event_id=None):
        try:
            with self.server.lock:
                log_widget_health(self.server.store, event_id)
            self.message = "Logged" if english else "已记录"
        except (AppError, OSError) as exc:
            self.message = str(exc)
        self.last = None

    def _health(self, data, english, bg, fg, tile):
        metrics = f"{data['water']:g} mL   ·   {data['meals']} {'meals' if english else '餐'}   ·   {data['exercise']:g} min"
        tk.Label(self.body, text=metrics, bg=bg, fg=fg, font=("Segoe UI", 14, "bold")).pack(anchor="w", padx=12, pady=5)
        if data["island"]:
            level, water, food, energy = data["island"]
            tk.Label(self.body, text=f"Lv. {level}", bg=bg, fg=fg).pack(anchor="w", padx=12)
            for label, value in zip(("Water", "Food", "Energy") if english else ("水分", "饱食", "活力"), (water, food, energy)):
                row = tk.Frame(self.body, bg=bg)
                row.pack(fill="x", padx=12, pady=2)
                tk.Label(row, text=label, bg=bg, fg=fg, width=8, anchor="w").pack(side="left")
                ttk.Progressbar(row, value=value, maximum=100, mode="determinate").pack(side="left", fill="x", expand=True)
                tk.Label(row, text=f"{value:.0f}", bg=bg, fg=fg, width=4).pack(side="right")
        links = tk.Frame(self.body, bg=bg)
        links.pack(fill="x", padx=12, pady=4)
        tk.Button(links, text=f"+{data['cup']:g} mL", bg=tile, fg=fg, relief="flat",
                  command=lambda: self._log(english)).pack(side="left", padx=2)
        for text, route in zip(("Meal", "Activity", "Weight") if english else ("记一餐", "记运动", "记体重"),
                               ("health/meal", "health/exercise", "health/weight")):
            self._route_button(links, text, route, fg, tile).pack(side="left", padx=2)

    def _events(self, data, english, bg, fg, tile):
        controls = tk.Frame(self.body, bg=bg)
        controls.pack(fill="x", padx=10, pady=3)
        choices = [("", "All events" if english else "全部事项")]
        choices += [(key, en if english else zh) for key, zh, en, _ in data["types"]]
        selector = ttk.Combobox(controls, state="readonly", values=[title for _, title in choices], width=18)
        selector.pack(side="left")
        selector.current(next((i for i, (key, _) in enumerate(choices) if key == data["selected"]), 0))

        def select(_event):
            self.event_selection = choices[selector.current()][0]
            self.last = None

        selector.bind("<<ComboboxSelected>>", select)
        today, counts = data["today"], data["days"]
        monthly = f"{today.strftime('%B')} · {sum(counts)}" if english else f"{today.month} 月 · {sum(counts)} 次"
        tk.Label(controls, text=monthly, bg=bg, fg=fg).pack(side="right")
        grid = tk.Frame(self.body, bg=bg)
        grid.pack(fill="both", expand=True, padx=10, pady=3)
        for column, day in enumerate(("M", "T", "W", "T", "F", "S", "S") if english else tuple("一二三四五六日")):
            grid.columnconfigure(column, weight=1)
            tk.Label(grid, text=day, bg=bg, fg=fg).grid(row=0, column=column, sticky="ew")
        start = date(today.year, today.month, 1).weekday()
        colors = (tile, "#94bdad", "#6e9d8b", "#397c66", "#276353")
        for value, count in enumerate(counts, start=1):
            row, column = divmod(start + value - 1, 7)
            level = min(4, count)
            tk.Label(grid, text=f"{value} · {count}" if count else str(value), bg=colors[level],
                     fg="white" if level >= 3 else fg if level == 0 else "#142b23").grid(row=row+1, column=column, sticky="ew", padx=1, pady=1)
        shortcuts = tk.Frame(self.body, bg=bg)
        shortcuts.pack(fill="x", padx=10, pady=3)
        items = [row for row in data["types"] if row[0] == data["selected"] or (not data["selected"] and row[3])]
        for i, (event_id, zh, en, _) in enumerate(items[:8]):
            tk.Button(shortcuts, text=f"{en if english else zh} +1", bg=tile, fg=fg, relief="flat",
                      command=lambda event_id=event_id: self._log(english, event_id)).grid(row=i//4, column=i%4, padx=2, pady=2, sticky="w")

    def _footprints(self, data, english, bg, fg, tile):
        values = data["metrics"]
        text = (f"{values['cities']} cities   ·   {values['countries']} countries/regions   ·   {values['continents']} continents" if english else
                f"{values['cities']} 城   ·   {values['countries']} 国家/地区   ·   {values['continents']} 大洲")
        tk.Label(self.body, text=text, bg=bg, fg=fg, font=("Segoe UI", 11, "bold")).pack(anchor="w", padx=12)
        resident = data["resident"]
        subtitle = ("China " if english else "中国城市 ") + f"{values['china']}/{data['chinaTotal']}"
        if resident:
            subtitle += ("   ·   Home: " if english else "   ·   常驻 ") + ((resident.get("english") if english else None) or resident["name"])
        tk.Label(self.body, text=subtitle, bg=bg, fg=fg).pack(anchor="w", padx=12)
        board = tk.Canvas(self.body, bg="#eee3cb", highlightthickness=0)
        board.pack(fill="both", expand=True, padx=10, pady=4)
        board.bind("<Configure>", lambda event: self._draw_map(board, event, data))
        board.bind("<Double-Button-1>", lambda _event: self.open_window(self.server.url, route_index("gaojiezou://footprints")))

    def _draw_map(self, board, event, data):
        board.delete("all")
        scale = min(max(1, event.width - 12) / 315, max(1, event.height - 12) / 171)
        center = (event.width / 2, event.height / 2)

        def pixel(coordinate):
            return center[0] + scale * coordinate[0], center[1] + scale * coordinate[1]

        visited = {city["countryID"] for city in data["cities"]}
        for country, coordinates in _widget_atlas():
            board.create_polygon(*(value for point in coordinates for value in pixel(point)),
                                 fill="#d0ad79" if country in visited else "#d9cbb0", outline="#a78b65", width=1)
        for city in data["cities"]:
            x, y = pixel(project_widget_map(city["longitude"], city["latitude"]))
            board.create_oval(x-2.5, y-2.5, x+2.5, y+2.5, fill="#a24e32", outline="#fff7eb")
        if data["resident"]:
            city = data["resident"]
            x, y = pixel(project_widget_map(city["longitude"], city["latitude"]))
            board.create_oval(x-4, y-4, x+4, y+4, fill="#276353", outline="#fff7eb")

    def _update_metrics(self, data, english) -> None:
        complete, habits, focused, running, sleep, asleep = data
        labels = ("Today's goals", "Focus today · running" if running else "Focus today",
                  "Last night · sleeping" if asleep else "Last night's sleep") if english else (
                  "今日目标", "今日专注 · 进行中" if running else "今日专注", "昨夜睡眠 · 睡眠中" if asleep else "昨夜睡眠")
        values = (f"{complete}/{habits}", _duration(focused), _duration(sleep))
        for (title, value), label, rendered in zip(self.metric_labels, labels, values):
            title.configure(text=label)
            value.configure(text=rendered)

    def _calendar(self, data, english, bg, fg, tile) -> None:
        today, events = data
        tk.Label(self.body, text=today.strftime("%B %Y") if english else f"{today.year} 年 {today.month} 月",
                 bg=bg, fg=fg, font=("Segoe UI", 13, "bold")).pack(anchor="w", padx=10)
        board = tk.Canvas(self.body, bg=bg, borderwidth=0, highlightthickness=0)
        board.pack(fill="both", expand=True, padx=10, pady=2)
        weeks = [[value if value.month == today.month else None for value in week]
                 for week in calendar.Calendar(firstweekday=6).monthdatescalendar(today.year, today.month)]
        day_labels = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat") if english else tuple("日一二三四五六")

        def draw(event):
            board.delete("all")
            width = event.width / 7
            scale = self.scale
            gutter = 18 * scale
            height = max(28 * scale, (event.height - gutter) / len(weeks))
            bar = 13 * scale
            capacity = max(0, int((height - 21 * scale) // bar))
            for column, title in enumerate(day_labels):
                board.create_text(column * width + width / 2, 7 * scale, text=title, fill=fg, font=("Segoe UI", 8))
            for number, week in enumerate(weeks):
                top = gutter + number * height
                for column, day in enumerate(week):
                    if day:
                        left = column * width
                        board.create_rectangle(left+1, top+1, left+width-2, top+height-2, fill=tile,
                                               outline="#53a98c" if day == today else bg)
                        board.create_text(left + 6 * scale, top + 9 * scale, anchor="w", text=str(day.day), fill=fg, font=("Segoe UI", 8))
                for first, last, lane, title, tint in month_segments(week, events, capacity):
                    left = first * width + 3
                    right = (last + 1) * width - 5
                    y = top + gutter + lane * bar
                    board.create_rectangle(left, y, right, y + bar - 1, fill=tint, outline="")
                    font = ("Segoe UI", 7)
                    measure = tkfont.Font(root=self.root, font=font).measure
                    shortened = title
                    while shortened and measure(shortened) > right - left - 7:
                        shortened = shortened[:-1]
                    board.create_text(left+3, y+bar/2-1, anchor="w", text=shortened, fill="white", font=font)

        board.bind("<Configure>", draw)
