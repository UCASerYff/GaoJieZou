"""Live desktop widgets for Rhythm, Health, and Footprints on Windows."""

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
from typing import NamedTuple

from gaojiezou.desktop import habit_counts, route_index
from gaojiezou.errors import AppError
from gaojiezou.health import ISLAND_LEVEL_MARKS, prosperity
from gaojiezou.resources import artwork, asset_dir
from gaojiezou.timeutil import from_cocoa

TABS = (
    ("今日指标", "Today"), ("月度总览", "Month"), ("长期目标", "Goals"),
    ("健康日常", "Health"), ("事项月历", "Events"), ("足迹地图", "Footprints"),
)
OPEN_TARGETS = (
    ("today", ("打开今天", "Open Today")), ("today", ("打开搞节奏", "Open Rhythm")),
    ("longGoals", ("打开长期目标", "Open goals")), ("health", ("打开健康", "Open Health")),
    ("health/events", ("打开健康事项", "Open events")), ("footprints", ("打开足迹地图", "Open map")),
)


class WidgetColors(NamedTuple):
    surface: str
    panel: str
    ink: str
    muted: str
    border: str
    subtle: str
    accent: str
    accent_on: str
    soft: str
    water: str
    land: str
    visited: str
    coast: str
    marker: str
    heat: tuple[str, ...]


LIGHT = WidgetColors(
    surface="#f3f5f3", panel="#ffffff", ink="#192820", muted="#4d6257", border="#d4dfd7",
    subtle="#ecf1ed", accent="#146a56", accent_on="#ffffff", soft="#deeee6",
    water="#e5eee9", land="#c6d7c9", visited="#91bea9", coast="#78998b", marker="#843f31",
    heat=("#ecf1ed", "#c6e3d5", "#94c4b3", "#568e7b", "#246953"),
)
DARK = WidgetColors(
    surface="#111815", panel="#19241f", ink="#edf4ef", muted="#abc1b2", border="#35473e",
    subtle="#25352d", accent="#84d4b9", accent_on="#10251e", soft="#254137",
    water="#20352d", land="#3e594b", visited="#537d6a", coast="#729884", marker="#f5a88d",
    heat=("#25352d", "#344d42", "#477261", "#729f89", "#a1cdb8"),
)


def _contrast_text(color: str) -> str:
    rgb = [int(color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
    luminance = sum(weight * (channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4)
                    for weight, channel in zip((0.2126, 0.7152, 0.0722), rgb))
    return "#000000" if (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) else "#ffffff"


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
        self.root.bind("<Control-Tab>", lambda event: self._next_tab(1))
        self.root.bind("<Control-Shift-Tab>", lambda event: self._next_tab(-1))
        self.view = 0
        self.topmost = tk.BooleanVar(self.root, True)
        self._pin()
        self.shell = tk.Frame(self.root)
        self.shell.pack(fill="x")
        self.heading = tk.Frame(self.root)
        self.heading.pack(fill="x")
        self.footer = tk.Frame(self.root)
        self.footer.pack(fill="x", side="bottom")
        self.body = tk.Frame(self.root)
        self.body.pack(fill="both", expand=True)
        self.style = ttk.Style(self.root)
        self.style.theme_use("clam")
        self.last = None
        self.chrome = None
        self.brand_image = None
        self.metric_labels = []
        self.tab_buttons = []
        self.action_controls = {}
        self.event_selection = ""
        self.message = ""
        self.footprint_journal = None
        self.footprint_card = None

    def run(self) -> None:
        self._tick()
        self.root.mainloop()

    def _px(self, logical: float) -> int:
        return max(1, round(self.scale * logical))

    def _font(self, size: int = 10, weight: str = "normal") -> tuple:
        return self.font_family, size, weight

    def _pin(self) -> None:
        self.root.wm_attributes("-topmost", self.topmost.get())

    def _next_tab(self, delta: int) -> str:
        index = (self.view + delta) % len(TABS)
        self._switch(index)
        if self.tab_buttons:
            self.tab_buttons[index].focus_set()
        return "break"

    def _switch(self, index: int) -> None:
        if index != self.view:
            self.message = ""
        self.view = index
        self._size_window(index, initial=self.chrome is None)
        self.last = None
        self._update()

    def _size_window(self, index: int, *, initial: bool) -> None:
        minima = ((440, 355), (480, 490), (440, 380), (440, 445), (480, 535), (480, 470))
        minimum = minima[index]
        screen = (self.root.winfo_screenwidth(), self.root.winfo_screenheight())
        available = tuple(round(axis * 0.9) for axis in screen)
        bounds = tuple(min(self._px(size), limit) for size, limit in zip(minimum, available))
        self.root.minsize(*bounds)
        if initial or self.root.winfo_width() == 1:
            preferred = (535, 365) if index == 0 else (640, max(555, minimum[1]))
            requested = tuple(self._px(size) for size in preferred)
        else:
            requested = (self.root.winfo_width(), self.root.winfo_height())
        width, height = (min(max(wanted, needed), limit) for wanted, needed, limit in zip(requested, bounds, available))
        if initial or requested != (width, height):
            self.root.geometry(f"{width}x{height}")

    def _tick(self) -> None:
        if self.stopped.is_set():
            self.root.destroy()
            return
        if self.shown.is_set():
            self.shown.clear()
            if self.chrome is None:
                self._size_window(self.view, initial=True)
                self._update()
            self.root.deiconify()
            self.root.lift()
        if self.root.state() != "withdrawn":
            self._update()
        self.root.after(500, self._tick)

    def _update(self) -> None:
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
        state = self.view, english, _is_dark(appearance), view_data
        if state != self.last:
            self._render(state)
            self.last = state

    def _panel(self, parent):
        return tk.Frame(parent, bg=self.colors.panel, highlightthickness=self._px(1), highlightbackground=self.colors.border)

    def _label(self, parent, text="", *, size=10, weight="normal", color=None, background=None, **options):
        return tk.Label(parent, text=text, font=self._font(size, weight), fg=color or self.colors.ink,
                        bg=background or self.colors.panel, anchor="w", **options)

    def _button(self, parent, text, command, *, primary=False, key=None, width=None):
        palette = self.colors
        background, foreground = (palette.accent, palette.accent_on) if primary else (palette.panel, palette.ink)
        options = {"width": width} if width is not None else {}
        button = tk.Button(parent, text=text, command=command, font=self._font(9, "bold"), relief="flat", borderwidth=0,
                           takefocus=True, cursor="hand2", bg=background, fg=foreground, activebackground=palette.soft,
                           activeforeground=palette.ink, highlightbackground=palette.border, highlightcolor=palette.accent,
                           highlightthickness=self._px(1), padx=self._px(10), pady=self._px(6), **options)
        button.bind("<Return>", lambda event: (button.invoke(), "break")[1])
        if key:
            self.action_controls[key] = button
        return button

    def _route_button(self, parent, text, route, *, primary=False):
        return self._button(parent, text, lambda: self.open_window(self.server.url, route_index("gaojiezou://" + route)),
                            primary=primary, key=route)

    def _build_shell(self, english: bool, dark: bool) -> None:
        self.chrome = english, dark
        self.colors = DARK if dark else LIGHT
        families = set(tkfont.families(self.root))
        self.zh_font_family = "Microsoft YaHei UI" if "Microsoft YaHei UI" in families else "Segoe UI"
        self.font_family = "Segoe UI" if english else self.zh_font_family
        palette = self.colors
        for surface in (self.root, self.shell, self.heading, self.body, self.footer):
            surface.configure(background=palette.surface)
        for child in self.shell.winfo_children():
            child.destroy()
        self.root.title("Rhythm · Desktop widgets" if english else "搞节奏 · 桌面小组件")

        header = tk.Frame(self.shell, bg=palette.surface)
        header.pack(fill="x", padx=self._px(17), pady=(self._px(14), self._px(8)))
        if not self.brand_image:
            icon = artwork("GaoJieZouIcon.png")
            if icon and icon.is_file():
                source = tk.PhotoImage(master=self.root, file=str(icon))
                factor = max(1, math.ceil(source.width() / self._px(32)))
                self.brand_image = source.subsample(factor, factor)
                self.root.iconphoto(False, self.brand_image)
        if self.brand_image:
            tk.Label(header, image=self.brand_image, bg=palette.surface).pack(side="left", padx=(0, self._px(8)))
        self._label(header, "Desktop widgets" if english else "桌面小组件", size=15, weight="bold",
                    background=palette.surface).pack(side="left")
        pin = tk.Checkbutton(header, text="Keep on top" if english else "始终置顶", variable=self.topmost, command=self._pin,
                             font=self._font(9), bg=palette.surface, fg=palette.ink, activebackground=palette.surface,
                             activeforeground=palette.ink, selectcolor=palette.panel, takefocus=True, cursor="hand2",
                             highlightcolor=palette.accent, highlightbackground=palette.surface, highlightthickness=self._px(1))
        pin.bind("<Return>", lambda event: (pin.invoke(), "break")[1])
        pin.pack(side="right")

        tabs = tk.Frame(self.shell, bg=palette.surface)
        tabs.pack(fill="x", padx=self._px(15))
        self.tab_buttons = []
        for column in range(3):
            tabs.columnconfigure(column, weight=1, uniform="widget-tabs")
        for index, titles in enumerate(TABS):
            tab = self._button(tabs, titles[english], lambda index=index: self._switch(index))
            tab.grid(row=index // 3, column=index % 3, sticky="ew", padx=self._px(2), pady=self._px(2))
            tab.bind("<Left>", lambda event: self._next_tab(-1))
            tab.bind("<Right>", lambda event: self._next_tab(1))
            tab.bind("<Up>", lambda event: self._next_tab(-3))
            tab.bind("<Down>", lambda event: self._next_tab(3))
            self.tab_buttons.append(tab)

        line = tk.Frame(self.shell, bg=palette.border, height=self._px(1))
        line.pack(fill="x", padx=self._px(17), pady=(self._px(9), 0))
        self.style.configure("Widget.Treeview", background=palette.panel, fieldbackground=palette.panel, foreground=palette.ink,
                             bordercolor=palette.border, lightcolor=palette.border, darkcolor=palette.border,
                             rowheight=self._px(34), font=self._font())
        self.style.map("Widget.Treeview", background=[("selected", palette.soft)], foreground=[("selected", palette.ink)])
        self.style.configure("Widget.Treeview.Heading", background=palette.subtle, foreground=palette.muted, font=self._font(9, "bold"))
        self.style.configure("Widget.TCombobox", background=palette.panel, fieldbackground=palette.panel, foreground=palette.ink,
                             bordercolor=palette.border, arrowcolor=palette.ink, padding=self._px(4))
        self.style.map("Widget.TCombobox", fieldbackground=[("readonly", palette.panel)], foreground=[("readonly", palette.ink)],
                       bordercolor=[("focus", palette.accent)], selectbackground=[("readonly", palette.panel)],
                       selectforeground=[("readonly", palette.ink)])
        self.root.option_add("*TCombobox*Listbox.background", palette.panel)
        self.root.option_add("*TCombobox*Listbox.foreground", palette.ink)
        self.root.option_add("*TCombobox*Listbox.selectBackground", palette.soft)
        self.root.option_add("*TCombobox*Listbox.selectForeground", palette.ink)
        for orientation in ("Vertical", "Horizontal"):
            self.style.configure(f"Widget.{orientation}.TScrollbar", background=palette.subtle, troughcolor=palette.panel,
                                 bordercolor=palette.border, arrowcolor=palette.ink)

    def _render(self, state) -> None:
        view, english, dark, data = state
        if self.last and view == self.last[0] == 0 and data is not None and self.chrome == (english, dark) and self.metric_labels:
            self._update_metrics(data, english)
            return
        focused = self.root.focus_get()
        focus_key = next((key for key, control in self.action_controls.items() if control == focused), None)
        focused_tab = next((index for index, tab in enumerate(self.tab_buttons) if focused == tab), None)
        self.action_controls = {}
        if self.chrome != (english, dark):
            self._build_shell(english, dark)
        palette = self.colors
        for index, tab in enumerate(self.tab_buttons):
            current = index == view
            tab.configure(bg=palette.soft if current else palette.panel, fg=palette.accent if current else palette.ink,
                          highlightbackground=palette.accent if current else palette.border)
        for section in (self.heading, self.body, self.footer):
            for child in section.winfo_children():
                child.destroy()
        self.metric_labels = []
        self._label(self.heading, TABS[view][english], size=16, weight="bold", background=palette.surface).pack(
            side="left", padx=self._px(17), pady=(self._px(9), self._px(7)))
        if data is not None and view in (1, 4):
            month = data[0] if view == 1 else data["today"]
            date_text = f"{calendar.month_name[month.month]} {month.year}" if english else f"{month.year} 年 {month.month} 月"
            self._label(self.heading, date_text, size=9, color=palette.muted, background=palette.surface).pack(
                side="right", padx=self._px(17), pady=(self._px(9), self._px(7)))

        route, text = OPEN_TARGETS[view]
        self._route_button(self.footer, text[english], route).pack(side="right", padx=self._px(17), pady=self._px(8))
        if self.message:
            self._label(self.footer, self.message, color=palette.accent, background=palette.surface).pack(side="left", padx=self._px(17))
        if data is None:
            panel = self._panel(self.body)
            panel.pack(fill="both", expand=True, padx=self._px(17))
            self._label(panel, "Data unavailable" if english else "资料暂不可读", size=12, weight="bold").pack(
                anchor="w", padx=self._px(14), pady=self._px(15))
        else:
            views = (self._metrics, self._calendar, self._goals, self._health, self._events, self._footprints)
            views[view](data, english)
        if focus_key in self.action_controls:
            self.action_controls[focus_key].focus_set()
        elif focused_tab is not None:
            self.tab_buttons[focused_tab].focus_set()

    def _metric_cards(self, parent, labels, values, *, show_status=False):
        strip = tk.Frame(parent, bg=self.colors.surface)
        strip.pack(fill="x", padx=self._px(14), pady=(0, self._px(5)))
        result = []
        for index, (label, value) in enumerate(zip(labels, values)):
            strip.columnconfigure(index, weight=1, uniform="metric-cards")
            panel = self._panel(strip)
            panel.grid(row=0, column=index, padx=self._px(3), sticky="nsew")
            title = self._label(panel, label, size=9, color=self.colors.muted)
            title.pack(fill="x", padx=self._px(10), pady=(self._px(8), 0))
            number = self._label(panel, value, size=16, weight="bold")
            number.pack(fill="x", padx=self._px(10), pady=(0, self._px(2 if show_status else 8)))
            status = None
            if show_status:
                status = self._label(panel, "", size=8, color=self.colors.accent)
                status.pack(fill="x", padx=self._px(10), pady=(0, self._px(5)))
            result.append((number, status))
        return result

    def _metrics(self, data, english):
        self.metric_labels = self._metric_cards(self.body, ("Check-ins", "Focus today", "Last night's sleep") if english else
                                               ("今日打卡", "今日专注", "昨夜睡眠"), ("", "", ""), show_status=True)
        self._update_metrics(data, english)

    def _update_metrics(self, data, english) -> None:
        complete, habits, focused, running, sleep, asleep = data
        values = (f"{complete}/{habits}", _duration(focused), _duration(sleep))
        states = (f"{habits - complete} left" if english else f"还剩 {habits - complete} 项",
                  ("Running" if english else "进行中") if running else "",
                  ("In progress" if english else "睡眠中") if asleep else "")
        for (value, status), rendered, state in zip(self.metric_labels, values, states):
            value.configure(text=rendered)
            status.configure(text=state)

    def _goals(self, data, english):
        panel = self._panel(self.body)
        panel.pack(fill="both", expand=True, padx=self._px(17))
        if not data:
            self._label(panel, "No long-term goals yet." if english else "还没有长期目标。", color=self.colors.muted).pack(
                anchor="w", padx=self._px(12), pady=self._px(12))
            return
        table = ttk.Treeview(panel, columns=("progress", "status"), style="Widget.Treeview", selectmode="browse", height=4)
        family = self.zh_font_family if any(re.search(r"[\u3400-\u9fff]", row[0]) for row in data) else self.font_family
        font = (family, 10)
        self.style.configure("Widget.Treeview", font=font)
        columns = ("Goal", "Actions", "Status") if english else ("目标", "行动", "状态")
        for column, title in zip(("#0", "progress", "status"), columns):
            table.heading(column, text=title, anchor="w")
        title_font = tkfont.Font(root=self.root, font=font)
        title_width = max(title_font.measure(row[0]) for row in data) + self._px(25)
        table.column("#0", minwidth=max(self._px(134), title_width), width=max(self._px(233), title_width))
        table.column("progress", anchor="center", width=self._px(67), minwidth=self._px(56), stretch=False)
        table.column("status", width=self._px(101), minwidth=self._px(85), stretch=False)
        table.tag_configure("alternate", background=self.colors.subtle)
        for index, (title, done, total, finished) in enumerate(data):
            state = ("Complete" if english else "已完成") if finished else ("Open" if english else "未完成")
            table.insert("", "end", text=title, values=(f"{done}/{total}", state), tags=("alternate",) if index % 2 else ())
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(0, weight=1)
        table.grid(row=0, column=0, sticky="nsew")
        for orientation, command, location, option in (
            ("Vertical", table.yview, {"row": 0, "column": 1, "sticky": "ns"}, "yscrollcommand"),
            ("Horizontal", table.xview, {"row": 1, "column": 0, "sticky": "ew"}, "xscrollcommand"),
        ):
            scroll = ttk.Scrollbar(panel, orient=orientation.lower(), style=f"Widget.{orientation}.TScrollbar", command=command)

            def on_scroll(first, last, scroll=scroll, location=location):
                scroll.set(first, last)
                if float(first) <= 0 and float(last) >= 1:
                    scroll.grid_remove()
                else:
                    scroll.grid(**location)

            table.configure(**{option: on_scroll})
        self.action_controls["goal-table"] = table

    def _log(self, english, event_id=None):
        try:
            with self.server.lock:
                if getattr(self.server, "exiting", False):
                    return
                log_widget_health(self.server.store, event_id)
            self.message = "Recorded" if english else "已记录"
        except (AppError, OSError) as exc:
            self.message = str(exc)
        self.last = None
        self._update()

    def _health(self, data, english):
        p = self.colors
        self._metric_cards(self.body, ("Water logged", "Meals", "Activity") if english else ("今日饮水", "用餐次数", "运动时长"),
                           (f"{data['water']:g} mL", str(data['meals']), f"{data['exercise']:g} min"))
        actions = tk.Frame(self.body, bg=p.surface)
        actions.pack(fill="x", padx=self._px(17), pady=(0, self._px(8)))
        self._button(actions, f"+{data['cup']:g} mL", lambda: self._log(english), primary=True, key="log-water").pack(side="left")
        for text, route in zip(("Log meal", "Log activity", "Log weight") if english else ("记一餐", "记运动", "记体重"),
                               ("health/meal", "health/exercise", "health/weight")):
            self._route_button(actions, text, route).pack(side="left", padx=(self._px(5), 0))
        if data["island"]:
            level, water, food, energy = data["island"]
            panel = self._panel(self.body)
            panel.pack(fill="x", padx=self._px(17))
            self._label(panel, f"Island · Lv. {level}" if english else f"荒岛 · 等级 {level}", weight="bold").pack(
                fill="x", padx=self._px(10), pady=(self._px(5), 0))
            gauges = tk.Frame(panel, bg=p.panel)
            gauges.pack(fill="x", padx=self._px(6), pady=(0, self._px(8)))
            labels = ("Water", "Food", "Energy") if english else ("水分", "饱食", "活力")
            for column, (label, value) in enumerate(zip(labels, (water, food, energy))):
                gauges.columnconfigure(column, weight=1, uniform="island-gauges")
                meter = tk.Frame(gauges, bg=p.panel)
                meter.grid(row=0, column=column, padx=self._px(5), sticky="ew")
                row = tk.Frame(meter, bg=p.panel)
                row.pack(fill="x", pady=(0, self._px(2)))
                self._label(row, label, size=9).pack(side="left")
                self._label(row, f"{value:.0f}", size=9, color=p.muted).pack(side="right")
                gauge = tk.Canvas(meter, bg=p.panel, height=self._px(7), highlightthickness=0, borderwidth=0)
                gauge.pack(fill="x")

                def draw_bar(event, gauge=gauge, value=value):
                    gauge.delete("all")
                    gauge.create_rectangle(0, 0, event.width, event.height, fill=p.subtle, outline="")
                    gauge.create_rectangle(0, 0, event.width * min(100, max(0, value)) / 100, event.height, fill=p.accent, outline="")

                gauge.bind("<Configure>", draw_bar)

    def _events(self, data, english):
        p = self.colors
        filter_row = tk.Frame(self.body, bg=p.surface)
        filter_row.pack(fill="x", padx=self._px(17), pady=(0, self._px(5)))
        choices = [("", "All events" if english else "全部事项")]
        choices += [(key, en if english else zh) for key, zh, en, _ in data["types"]]
        selector = ttk.Combobox(filter_row, state="readonly", values=[title for _, title in choices], width=20,
                                font=self._font(9), style="Widget.TCombobox")
        selector.pack(side="left")
        selector.current(next((i for i, (key, _) in enumerate(choices) if key == data["selected"]), 0))
        self.action_controls["event-filter"] = selector

        def select(_event):
            chosen = selector.current()
            if chosen >= 0:
                self.event_selection = choices[chosen][0]
                self.last = None
                self._update()

        selector.bind("<<ComboboxSelected>>", select)
        today, counts = data["today"], data["days"]
        monthly = f"{sum(counts)} this month" if english else f"本月 {sum(counts)} 次"
        self._label(filter_row, monthly, size=9, color=p.muted, background=p.surface).pack(side="right")
        grid = self._panel(self.body)
        for column, day in enumerate(("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun") if english else tuple("一二三四五六日")):
            grid.columnconfigure(column, weight=1, uniform="event-days")
            self._label(grid, day, size=9, color=p.muted, justify="center").grid(row=0, column=column, pady=self._px(3))
        start = date(today.year, today.month, 1).weekday()
        for row in range(1, math.ceil((start + len(counts)) / 7) + 1):
            grid.rowconfigure(row, weight=1, uniform="event-weeks")
        for value, count in enumerate(counts, start=1):
            row, column = divmod(start + value - 1, 7)
            background = p.heat[min(4, count)]
            day_cell = tk.Label(grid, text=f"{value} · {count}" if count else str(value), bg=background,
                                font=self._font(9, "bold" if value == today.day else "normal"), fg=_contrast_text(background),
                                highlightthickness=self._px(1), highlightbackground=p.accent if value == today.day else p.panel)
            day_cell.grid(row=row + 1, column=column, sticky="nsew", padx=self._px(2), pady=self._px(1))
        shortcuts = tk.Frame(self.body, bg=p.surface)
        shortcuts.pack(side="bottom", fill="x", padx=self._px(15))
        items = [row for row in data["types"] if row[0] == data["selected"] or (not data["selected"] and row[3])]
        for i, (event_id, zh, en, _) in enumerate(items[:8]):
            shortcuts.columnconfigure(i % 4, weight=1, uniform="event-actions")
            button = self._button(shortcuts, f"{en if english else zh} +1", lambda event_id=event_id: self._log(english, event_id), key=event_id)
            button.configure(wraplength=self._px(103), padx=self._px(4), pady=self._px(3))
            button.grid(row=i // 4, column=i % 4, padx=self._px(2), pady=self._px(2), sticky="nsew")
        grid.pack(fill="both", expand=True, padx=self._px(17), pady=(0, self._px(6)))

    def _footprints(self, data, english):
        palette = self.colors
        values = data["metrics"]
        labels = ("Visited cities", "Countries / regions", "Continents") if english else ("到访城市", "国家或地区", "大洲")
        self._metric_cards(self.body, labels, [str(values[key]) for key in ("cities", "countries", "continents")])
        resident = data["resident"]
        subtitle = ("China " if english else "中国城市 ") + f"{values['china']}/{data['chinaTotal']}"
        if resident:
            subtitle += ("  ·  Home: " if english else "  ·  常驻 ") + ((resident.get("english") if english else None) or resident["name"])
        subtitle_label = self._label(self.body, subtitle, size=9, color=palette.muted, background=palette.surface,
                                     justify="left", wraplength=self._px(415))
        subtitle_label.pack(anchor="w", padx=self._px(17), pady=(0, self._px(4)))
        board = tk.Canvas(self.body, bg=palette.water, highlightthickness=self._px(1), highlightbackground=palette.border, borderwidth=0)
        board.pack(fill="both", expand=True, padx=self._px(17))
        board.bind("<Configure>", lambda event: self._draw_map(board, event, data))
        board.bind("<Double-Button-1>", lambda event: self.open_window(self.server.url, route_index("gaojiezou://footprints")))

    def _draw_map(self, board, event, data):
        board.delete("all")
        p = self.colors
        scale = min(max(1, event.width - self._px(14)) / 315, max(1, event.height - self._px(14)) / 171)
        center = event.width / 2, event.height / 2

        def pixel(coordinate):
            return center[0] + scale * coordinate[0], center[1] + scale * coordinate[1]

        visited = {city["countryID"] for city in data["cities"]}
        for country, coordinates in _widget_atlas():
            board.create_polygon(*(value for point in coordinates for value in pixel(point)),
                                 fill=p.visited if country in visited else p.land, outline=p.coast, width=1)
        for city in data["cities"]:
            x, y = pixel(project_widget_map(city["longitude"], city["latitude"]))
            radius = self._px(2.5)
            board.create_oval(x-radius, y-radius, x+radius, y+radius, fill=p.marker, outline=p.panel, width=self._px(1))
        if data["resident"]:
            city = data["resident"]
            x, y = pixel(project_widget_map(city["longitude"], city["latitude"]))
            radius = self._px(4)
            board.create_oval(x-radius, y-radius, x+radius, y+radius, fill=p.accent, outline=p.panel, width=self._px(1))

    def _calendar(self, data, english) -> None:
        p = self.colors
        today, events = data
        board = tk.Canvas(self.body, bg=p.panel, borderwidth=0, highlightthickness=self._px(1), highlightbackground=p.border)
        board.pack(fill="both", expand=True, padx=self._px(17))
        weeks = [[value if value.month == today.month else None for value in week]
                 for week in calendar.Calendar(firstweekday=6).monthdatescalendar(today.year, today.month)]
        day_labels = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat") if english else tuple("日一二三四五六")
        event_font = tkfont.Font(root=self.root, font=self._font(8))
        chinese_font = tkfont.Font(root=self.root, font=(self.zh_font_family, 8))

        def draw(event):
            board.delete("all")
            scale = self.scale
            margin = 4 * scale
            width = (event.width - 2 * margin) / 7
            gutter = 24 * scale
            height = max(16 * scale, (event.height - gutter - margin) / len(weeks))
            bar = 15 * scale
            capacity = max(0, int((height - 21 * scale) / bar))
            for column, label in enumerate(day_labels):
                board.create_text(margin + column * width + width / 2, 12 * scale, text=label, fill=p.muted, font=self._font(8, "bold"))
            for number, week in enumerate(weeks):
                top = gutter + number * height
                for column, day in enumerate(week):
                    if day:
                        left = margin + column * width
                        board.create_rectangle(left + 1, top + 1, left + width - 2, top + height - 2,
                                               fill=p.soft if day == today else p.subtle, outline=p.accent if day == today else p.border)
                        board.create_text(left + 6 * scale, top + 9 * scale, anchor="w", text=str(day.day),
                                          fill=p.accent if day == today else p.ink, font=self._font(8, "bold"))
                for first, last, lane, title, tint in month_segments(week, events, capacity):
                    left = margin + first * width + 4 * scale
                    right = margin + (last + 1) * width - 4 * scale
                    y = top + 20 * scale + lane * bar
                    board.create_rectangle(left, y, right, y + bar - 1, fill=tint, outline="")
                    space = right - left - 6 * scale
                    font = chinese_font if re.search(r"[\u3400-\u9fff]", title) else event_font
                    shortened = title
                    if font.measure(shortened) > space:
                        while shortened and font.measure(shortened + "…") > space:
                            shortened = shortened[:-1]
                        shortened = shortened + "…" if shortened else ""
                    board.create_text(left + 3 * scale, y + bar / 2 - 1, anchor="w", text=shortened,
                                      fill=_contrast_text(tint), font=font)

        board.bind("<Configure>", draw)
