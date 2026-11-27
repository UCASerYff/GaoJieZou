(() => {
  "use strict";

  const api = "/api/health/";
  const KINDS = {
    water: ["喝水", "Water", "drop.fill", "blue", "mL"],
    sleep: ["睡眠", "Sleep", "moon.stars.fill", "purple", ""],
    meal: ["饮食", "Meals", "fork.knife", "orange", ""],
    exercise: ["运动", "Activity", "figure.walk", "green", "min"],
    weight: ["体重", "Weight", "scalemass.fill", "purple", "kg"],
  };
  const SOURCES = {
    home: ["家里", "Home"], canteen: ["食堂", "Canteen"], takeout: ["外卖", "Takeout"],
    snack: ["零食", "Snack"], restaurant: ["餐馆", "Restaurant"], hotel: ["酒店", "Hotel"],
  };
  const MATERIALS = {
    wood: ["木材", "Wood"], stone: ["石材", "Stone"], fiber: ["纤维", "Fiber"],
    ration: ["干粮", "Rations"], iron: ["铁矿", "Iron"], herb: ["药材", "Herbs"],
  };
  const EVENT_SYMBOLS = ["cup.and.saucer.fill", "mug.fill", "waterbottle.fill", "brain.head.profile",
    "toilet.fill", "pills.fill", "heart.fill", "moon.fill", "figure.walk", "checkmark.circle"];
  const EVENT_COLORS = ["blue", "teal", "orange", "purple", "pink", "green"];
  const ISLAND_MARKS = [0, 20, 60, 100, 140, 190, 260, 340, 430, 520];
  const PAGE_SIZE = 100;
  const ui = { filter: null, query: "", range: 7, page: 0, sleepCount: 30, days: 7,
    eventMonth: "", eventFilter: "", eventDay: "", eventPage: 0, section: "" };
  const g = () => window.Gao;
  const h = () => g().state.health;
  const t = (cn, en) => g().t(cn, en);
  const e = (value) => g().esc(value ?? "");
  const icon = (name) => g().icon(name);
  const num = (value) => Number(value || 0).toLocaleString(undefined, { maximumFractionDigits: 1 });
  const amount = (value, unit) => value == null ? `— ${unit}` : `${num(value)} ${unit}`;
  const kindName = (kind) => KINDS[kind] ? t(...KINDS[kind].slice(0, 2)) : kind;
  const eventName = (eventType) => eventType ? t(eventType.name, eventType.englishName || eventType.name) : t("事项", "Event");
  const materialName = (key) => MATERIALS[key] ? t(...MATERIALS[key]) : key;
  const dayLabel = (day) => new Date(`${day}T12:00:00`).toLocaleDateString();
  const cocoaDate = (seconds) => new Date((Number(seconds) + 978307200) * 1000);
  const reportDay = (seconds) => {
    const date = cocoaDate(seconds);
    try {
      const fields = new Intl.DateTimeFormat("en", {
        timeZone: h().preferences.timezone, year: "numeric", month: "2-digit", day: "2-digit",
      }).formatToParts(date);
      return ["year", "month", "day"].map((field) => fields.find((part) => part.type === field).value).join("-");
    } catch {
      return g().localDay(date);
    }
  };
  const card = (title, body, options) => g().card(title, body, options);
  const empty = (title, description, glyph) => g().empty(title, description, glyph);
  const header = (title, description, controls = "") => g().header(title, description, controls);
  const go = (label, section, glyph) => g().button(label, { go: section === "island" ? "playground/island" : `health/${section}`, icon: glyph });
  const dateTime = (value) => g().date(value, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  const formFields = (form) => Object.fromEntries(new FormData(form));
  const byNewest = (rows, key = "occurredAt") => [...rows].sort((a, b) => b[key] - a[key]);
  const button = (label, action, value = "", options = {}) => `<button type="button"
    class="${e(options.className || "")}${options.iconOnly ? " health-icon-button" : ""}" data-health-action="${e(action)}" data-value="${e(value)}"
    ${options.title ? `title="${e(options.title)}" aria-label="${e(options.title)}"` : ""}
    ${options.pressed == null ? "" : `aria-pressed="${options.pressed}"`}
    ${options.disabled ? "disabled" : ""}>${options.icon ? icon(options.icon) : ""}${options.iconOnly ? "" : e(label)}</button>`;
  const primary = (label, action, value, glyph) => button(label, action, value, { icon: glyph, className: "primary" });
  const caption = (text) => `<p class="health-caption">${e(text)}</p>`;
  const post = (path, body = {}, options) => g().act(api + path, body, options);
  const confirm = (title, text, path, data) => g().confirm(title, text, api + path, data);

  function normalize(section) {
    return {
      water: "records-water", sleep: "records-sleep", meals: "records-meal", meal: "records-meal",
      "records-meals": "records-meal", exercise: "records-exercise", weight: "records-weight",
    }[section] || section || "overview";
  }

  function recordSection(section) {
    return section === "records" ? "all" : section.split("-")[1];
  }

  function actions(section) {
    section = normalize(section);
    if (!h()?.available) return "";
    const undo = h().canUndo ? button(t("撤销", "Undo"), "undo", "", { icon: "arrow.uturn.backward" }) : "";
    if (section === "overview") return undo + button(t("健康设置", "Health settings"), "preferences", "", { icon: "gearshape" });
    if (section === "events") return undo + primary(t("自定义事项", "New event type"), "event-type", "", "plus");
    if (section === "island") return !h().preferences.gameEnabled ? "" :
      button(h().island.paused ? t("结束休整", "Resume island") : t("让岛屿休整", "Rest island"), "island-pause");
    if (!section.startsWith("records")) return "";
    const kind = (ui.section === section && ui.filter) || recordSection(section);
    if (kind === "weight" && h().hideWeight) return "";
    if (kind === "sleep") {
      const sync = section === "records-sleep" ? button(t("同步记录", "Sync records"), "sync", "", { icon: "arrow.triangle.2.circlepath" }) : "";
      return sync + button(t("补记", "Backfill"), "sleep-add", "past", { icon: "clock.arrow.circlepath" })
        + primary(t("记录睡眠", "Record sleep"), "sleep-add", "", "plus");
    }
    const recordKind = kind === "all" ? "meal" : kind;
    return undo + button(t("补记", "Backfill"), "record-backdate", recordKind, { icon: "clock.arrow.circlepath" })
      + primary(t("记一笔", "Record"), "record-new", recordKind, "plus");
  }

  function render(section) {
    section = normalize(section);
    if (section !== ui.section) {
      Object.assign(ui, { filter: null, query: "", range: 7, page: 0, sleepCount: 30, section });
    }
    if (!h()?.available) return header(t("健康", "Health"), "") +
      empty(t("暂时无法读取数据", "Data unavailable"), t("健康资料未打开。", "The health journal could not be opened."), "externaldrive");
    const pages = { overview, events, trends, island };
    const color = String(h().preferences.backgroundHex || "").replace(/^#/, "");
    const custom = /^[\da-f]{6}$/i.test(color) ? ` style="--health-tint:#${color}"` : "";
    return `<div class="health-content" data-health-page="${e(section)}" data-health-theme="${e(h().preferences.appearance || "system")}"${custom}>${pages[section] ? pages[section]() : recordsPage(section)}</div>`;
  }

  function recordValue(row) {
    if (row.kind !== "meal") return amount(row.amount, KINDS[row.kind]?.[4] || "");
    const source = SOURCES[row.mealSource];
    const details = [source ? t(...source) : "", row.fullnessPercent != null ? `${row.fullnessPercent}%` : ""];
    if (!h().hideCalories && row.calories != null) details.push(amount(row.calories, "kcal"));
    return details.filter(Boolean).join(" · ");
  }

  function row(title, detail, value, controls, glyph = "", color = "teal") {
    return `<div class="health-row"><span class="health-glyph" data-color="${e(color)}">${glyph ? icon(glyph) : ""}</span>
      <div class="health-row-main"><strong>${e(title)}</strong><small>${e(detail)}</small></div>
      <span class="health-value">${e(value)}</span><div class="health-controls">${controls || ""}</div></div>`;
  }

  function recordTable(records, label) {
    const tableRows = records.map((record) => {
      const kind = KINDS[record.kind];
      const name = record.title || kindName(record.kind);
      return `<tr><th scope="row"><div class="health-log-entry">
        <span class="health-glyph" data-color="${e(kind?.[3] || "teal")}">${icon(kind?.[2] || "list")}</span>
        <span class="health-log-copy"><strong>${e(name)}</strong>
        <small>${e([name === kindName(record.kind) ? "" : kindName(record.kind), record.note].filter(Boolean).join(" · "))}</small></span>
        </div></th><td class="health-log-time"><time datetime="${e(cocoaDate(record.occurredAt).toISOString())}">${e(dateTime(record.occurredAt))}</time></td>
        <td class="health-log-value">${e(recordValue(record))}</td><td class="health-log-actions">
        ${button(t("编辑", "Edit"), "record-edit", record.id, { icon: "edit", iconOnly: true, title: t(`编辑 ${name}`, `Edit ${name}`) })}
        ${button(t("删除", "Delete"), "record-delete", record.id, { icon: "trash", iconOnly: true, title: t(`删除 ${name}`, `Delete ${name}`) })}
        </td></tr>`;
    }).join("");
    return `<table class="health-log-table" aria-label="${e(label)}"><colgroup><col><col class="health-col-time">
      <col class="health-col-value"><col class="health-col-actions"></colgroup><thead><tr>
      <th scope="col">${e(t("记录", "Entry"))}</th><th scope="col">${e(t("时间", "Time"))}</th>
      <th scope="col">${e(t("数值", "Value"))}</th><th scope="col">${e(t("操作", "Actions"))}</th>
      </tr></thead><tbody>${tableRows}</tbody></table>`;
  }

  function quick(kind, value, detail, action, actionLabel, progress) {
    const config = KINDS[kind];
    return `<button class="health-quick" type="button" data-health-action="${action}" data-value="${kind}">
      <span class="health-quick-heading"><span class="health-glyph" data-color="${config[3]}">${icon(config[2])}</span>
      <span>${e(kindName(kind))}</span></span><strong>${e(value)}</strong>
      ${progress != null ? `<progress value="${Math.max(0, Math.min(1, progress))}" max="1"></progress>` : ""}
      <span class="health-quick-footer"><small>${e(detail)}</small>
      <span class="health-quick-action">${icon("plus")}${e(actionLabel)}</span></span></button>`;
  }

  function sleepSummary() {
    const health = h();
    const today = health.sleepRecords.filter((item) => reportDay(item.endedAt) === health.today);
    const total = today.reduce((sum, item) => sum + item.durationSeconds, 0);
    const recent = today.at(0);
    const controls = button(t("记睡眠", "Log sleep"), "sleep-add", "", { icon: "plus" });
    const detail = recent ? `${dateTime(recent.startedAt)} → ${dateTime(recent.endedAt)}` : t("今天还没有睡眠记录", "No sleep recorded today");
    return card(t("今日睡眠", "Today’s sleep"), `<div class="health-sleep-summary">
      <span class="health-glyph" data-color="purple">${icon(KINDS.sleep[2])}</span>
      <div><strong>${e(today.length ? g().duration(total) : "—")}</strong><p class="health-caption">${e(health.sleepSyncError || detail)}</p></div>
      </div>`, { className: "health-sleep-card", actions: controls + go(t("查看", "View"), "records-sleep") });
  }

  function reserves() {
    return `<div class="health-grid health-three health-reserves">${[
      ["水分", "Water", "water", "drop.fill", "blue"], ["饱食", "Food", "food", "fork.knife", "orange"],
      ["活力", "Energy", "energy", "bolt.fill", "green"],
    ].map(([cn, en, key, glyph, color]) => `<div class="health-reserve" data-color="${color}">
      <span>${icon(glyph)}${e(t(cn, en))}</span><strong>${num(h().island[key])}</strong>
      <progress value="${Number(h().island[key] || 0)}" max="100"></progress></div>`).join("")}</div>`;
  }

  function islandArt(withPlacements = false) {
    if (window.IslandWorld) return window.IslandWorld.render(!withPlacements);
    const labels = Object.fromEntries((g().state.catalog.islandRecipes || []).map((item) => [item.id, item.name]));
    const pins = !withPlacements ? "" : Object.entries(h().island.placements || {}).map(([key, point]) =>
      `<span class="island-pin" style="left:${50 + Number(point.x) * 6}%;top:${52 + Number(point.z) * 5}%">${g().localized(labels[key] || key)}</span>`).join("");
    return `<div class="health-island-art"><img src="/art/IslandSceneArt.png" alt="${e(t("荒岛", "Island"))}">${pins}</div>`;
  }

  function overview() {
    const health = h();
    const latest = byNewest(health.records.filter((record) => reportDay(record.occurredAt) === health.today &&
      (!health.hideWeight || record.kind !== "weight")));
    const stats = [
      quick("water", amount(health.water, "mL"), health.waterGoal ? t(`目标 ${num(health.waterGoal)} mL`, `Goal ${num(health.waterGoal)} mL`) : "",
        "water", `${num(health.preferences.cup)} mL`, health.waterGoal ? health.water / health.waterGoal : null),
      quick("meal", t(`${health.meals} 笔`, `${health.meals} entries`), "", "record-new", t("记一餐", "Log meal")),
      quick("exercise", amount(health.exerciseMinutes, "min"), "", "record-new", t("记运动", "Log activity")),
      health.hideWeight ? "" : quick("weight", amount(health.weight, "kg"), "", "record-new", t("记体重", "Log weight")),
    ].join("");
    const welcome = health.preferences.onboarding ? "" : card(t("欢迎来到你的岛", "Welcome to your island"),
      caption(t("记一杯水，或到荒岛点起第一堆篝火。", "Record a glass of water or build your first campfire.")),
      { actions: primary(t("开始记录", "Let’s begin"), "welcome", "", "sparkles") + button(t("关闭", "Dismiss"), "welcome-dismiss") });
    const preview = !health.preferences.gameEnabled ? "" : card(t("荒岛生活", "Island life"),
      `<div class="health-island-preview">${islandArt()}</div>
        ${caption(health.island.paused ? t("岛屿正在休整。", "Your island is resting.") :
          t(`Lv.${health.island.level} · ${health.island.buildings.length} 座建筑`, `Lv.${health.island.level} · ${health.island.buildings.length} buildings`))}
        ${reserves()}`,
      { className: "health-island-card", actions: go(t("进入荒岛", "Open island"), "island", "right") });
    const templates = health.templates.filter((item) => !health.hideWeight || item.record.kind !== "weight");
    templates.sort((a, b) => b.uses - a.uses);
    const logs = latest.length ? recordTable(latest, t("今日记录", "Today’s records")) : empty(t("还没有今日记录", "No entries today"));
    const favorites = templates.length ? card(t("常用模板", "Favorites"), `<div class="health-inline">${templates.slice(0, 8).map((item) =>
        button(item.name, "template-use", item.id, { icon: KINDS[item.record.kind]?.[2] })).join("")}</div>`,
        { actions: button(t("管理模板", "Manage templates"), "template-manage") }) : "";
    return header(t("健康今日", "Health today"), dayLabel(health.today), health.streak > 1 ?
      `<span class="health-streak">${icon("flame.fill")}${e(t(`已连续记录 ${health.streak} 天`, `${health.streak}-day streak`))}</span>` : "")
      + welcome + `<div class="health-metric-strip">${stats}</div><div class="health-dashboard">
        ${card(t("今日记录", "Today’s records"), logs, { subtitle: t(`共 ${latest.length} 笔`, `${latest.length} entries`),
          className: "health-log-card", actions: button(t("补记", "Backfill"), "backfill-menu", "", { icon: "clock" }) +
          go(t("查看全部", "View all"), "records", "right") })}
        <aside class="health-dashboard-aside" aria-label="${e(t("睡眠、模板和荒岛", "Sleep, favorites and island"))}">
        ${sleepSummary()}${favorites}${preview}</aside></div>`;
  }

  function startOfRange(days) {
    if (!days) return "";
    const date = new Date(`${h().today}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() - days + 1);
    return date.toISOString().slice(0, 10);
  }

  function pageBar(total, page, action) {
    const count = Math.ceil(total / PAGE_SIZE);
    if (count <= 1) return "";
    return `<div class="health-inline health-pager">${button(t("上一页", "Previous"), action, page - 1, { disabled: page === 0 })}
      <span>${page + 1} / ${count}</span>${button(t("下一页", "Next"), action, page + 1, { disabled: page + 1 >= count })}</div>`;
  }

  function sleepRows(embedded, query = "", range = 0) {
    const since = startOfRange(range);
    const health = h();
    const originName = (record) => record.origin === "health" ? t("来自健康记录", "From the health page") : t("来自睡眠计时", "From the sleep timer");
    const matches = health.sleepRecords.filter((record) => (!since || reportDay(record.endedAt) >= since) &&
      (!query || `${reportDay(record.endedAt)} ${originName(record)}`.toLocaleLowerCase().includes(query)));
    return (health.sleepSyncError ? card(t("共同睡眠同步", "Shared sleep sync"), caption(health.sleepSyncError)) : "")
      + (!embedded ? card(t("睡眠也能恢复活力", "Sleep restores energy"),
        caption(t("每小时恢复 3 点活力，每日最多 24 点。最近 36 小时内结束、时长 30 分钟至 24 小时的睡眠可领取一次。",
          "Restore 3 energy per hour, up to 24 per day. Sleep lasting 30 minutes to 24 hours can be rewarded once within 36 hours."))) : "")
      + card(t("共同睡眠记录", "Shared sleep journal"), !matches.length ? empty(t("没有睡眠记录", "No sleep records"),
        t("记录已结束的睡眠。", "Record a completed sleep."), KINDS.sleep[2]) :
        matches.slice(0, ui.sleepCount).map((record) => row(dayLabel(reportDay(record.endedAt)),
          `${dateTime(record.startedAt)} → ${dateTime(record.endedAt)} · ${originName(record)}`,
          g().duration(record.durationSeconds), button(t("删除", "Delete"), "sleep-delete", record.id, { icon: "trash" }), KINDS.sleep[2], "purple")).join("")
        + (matches.length > ui.sleepCount ? button(t("显示更多", "Show more"), "sleep-more") : ""));
  }

  function recordsPage(section) {
    if (section === "records-sleep") {
      return header(t("睡眠记录", "Sleep records"), t("与睡眠计时同步", "Synced with the sleep timer"))
        + sleepSummary() + sleepRows(false);
    }
    const kind = ui.filter || recordSection(section);
    if (kind === "weight" && h().hideWeight) return header(t("体重记录", "Weight records"), "")
      + empty(t("体重记录已隐藏", "Weight records hidden"), t("可在健康设置中重新显示。", "Show weight records again in Health settings."), "eye.slash");
    const query = ui.query.trim().toLocaleLowerCase();
    const since = startOfRange(ui.range);
    const visible = byNewest(h().records.filter((record) => (kind === "all" || record.kind === kind)
      && (!h().hideWeight || record.kind !== "weight") && (!since || reportDay(record.occurredAt) >= since)
      && (!query || `${record.title} ${record.note}`.toLocaleLowerCase().includes(query))));
    const filters = [["all", t("全部", "All")], ...Object.keys(KINDS).filter((key) => !h().hideWeight || key !== "weight").map((key) => [key, kindName(key)])];
    const name = kind === "all" ? t("全部记录", "All records") : t(`${kindName(kind)}记录`, `${kindName(kind)} records`);
    const logPanel = kind === "sleep" ? "" : card(name,
      visible.length ? recordTable(visible.slice(ui.page * PAGE_SIZE, (ui.page + 1) * PAGE_SIZE), name)
        + pageBar(visible.length, ui.page, "record-page") : empty(t("还没有匹配的记录", "No matching records")),
      { subtitle: t(`共 ${visible.length} 笔`, `${visible.length} entries`), className: "health-log-card" });
    return header(t("健康记录", "Health records"), "")
      + `<div class="card health-record-toolbar">
        <div class="health-inline health-filters" role="group" aria-label="${e(t("记录类型", "Record type"))}">
          ${filters.map(([key, label]) => button(label, "record-filter", key, { pressed: key === kind, icon: KINDS[key]?.[2] })).join("")}
        </div>
        <form id="health-record-search" class="health-search" role="search">
          ${g().input("query", t("搜索名称或备注", "Search names or notes"), ui.query, { type: "search", placeholder: t("搜索名称或备注", "Search names or notes") })}
          ${g().select("range", t("时间范围", "Date range"), [["7", t("近 7 天", "7 days")], ["30", t("近 30 天", "30 days")], ["0", t("全部时间", "All time")]], String(ui.range))}
          <button type="submit">${e(t("搜索", "Search"))}</button>
          ${ui.query || ui.range !== 7 ? button(t("清除", "Clear"), "record-reset", "", { title: t("清除筛选", "Clear filters") }) : ""}
        </form></div>`
      + logPanel
      + (kind === "all" || kind === "sleep" ? sleepRows(true, query, ui.range) : "");
  }

  function dateSpan(start, end) {
    const result = [];
    const cursor = new Date(`${start}T12:00:00Z`);
    while (cursor.toISOString().slice(0, 10) <= end) {
      result.push(cursor.toISOString().slice(0, 10));
      cursor.setUTCDate(cursor.getUTCDate() + 1);
    }
    return result;
  }

  function trendChart(points, days, key, title, unit, color) {
    const byDay = new Map(points.map((point) => [point.day, point]));
    const values = points.map((point) => point[key]).filter((value) => value != null);
    if (!values.length) return card(title, `<div class="health-chart-empty">${icon("chart")}
      ${e(t("还没有记录", "No data yet"))}</div>`, { className: "health-trend-card", actions: caption(unit) });
    const weight = key === "weight";
    const maximum = Math.max(...values);
    const minimum = weight ? Math.max(0, Math.min(...values) - 0.4) : 0;
    const raw = (maximum - minimum || 1) / 4;
    const decimal = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].find((value) => value * decimal >= raw) * decimal;
    const base = weight ? Math.floor(minimum / step) * step : 0;
    const top = Math.max(base + step, Math.ceil(maximum / step) * step);
    const scale = top - base;
    const tick = Math.max(1, Math.ceil(days.length / 6));
    const chart = days.map((day, index) => {
      const value = byDay.get(day)?.[key];
      const past = days.slice(Math.max(0, index - 6), index + 1).map((date) => byDay.get(date)?.[key]).filter((item) => item != null);
      const average = weight && value != null && past.length ? past.reduce((sum, item) => sum + item, 0) / past.length : null;
      const point = value == null ? "" : `<span class="${weight ? "health-point" : "health-bar"}"
        style="--value:${Math.max(0, (value - base) / scale * 100)}%" title="${e(`${day}: ${num(value)} ${unit}`)}"></span>`;
      return `<div class="health-chart-day">${point}${average != null ? `<span class="health-average"
        style="--value:${(average - base) / scale * 100}%" title="${e(t("七日均值", "7-day average"))} ${num(average)} ${unit}"></span>` : ""}
        ${index % tick === 0 ? `<small>${e(day.slice(5))}</small>` : ""}</div>`;
    }).join("");
    const lines = Array.from({ length: Math.round(scale / step) + 1 }, (_, index) =>
      `<span class="health-chart-tick" style="--value:${index * step / scale * 100}%"><small>${e(num(base + index * step))}</small></span>`).join("");
    const legend = weight ? `<div class="health-chart-legend" data-color="${color}">
      <span><i></i>${e(t("实测", "Measured"))}</span><span><i></i>${e(t("7 日均值", "7-day average"))}</span></div>` : "";
    const details = `<details class="health-chart-details"><summary>${e(t("查看数值", "View values"))}</summary>
      <div class="health-chart-data">${points.filter((point) => point[key] != null).map((point) =>
        `<span><time datetime="${e(point.day)}">${e(point.day.slice(5))}</time> <strong>${e(amount(point[key], unit))}</strong></span>`).join("")}</div></details>`;
    return card(title, `<div class="health-chart" data-color="${color}" style="--points:${days.length}" aria-hidden="true">${lines}${chart}</div>
      ${legend}${details}`, { className: "health-trend-card", actions: caption(unit) });
  }

  function trends() {
    const report = h().trendsByDays[ui.days];
    const points = report.points;
    const days = dateSpan(report.start, report.end);
    const total = (key) => points.reduce((sum, point) => sum + (point[key] || 0), 0);
    const controls = `<div class="health-inline health-filters health-trend-filters" role="group" aria-label="${e(t("趋势范围", "Trend range"))}">
      ${[1, 7, 30].map((value) => button(value === 1 ? t("今日", "Today") : t(`近 ${value} 天`, `${value} days`),
        "trend-range", value, { pressed: value === ui.days })).join("")}</div>`;
    const metrics = [["water", "饮水量", "Water", "mL", "blue"], ["exercise", "运动时长", "Activity", "min", "green"]];
    if (!h().hideCalories) metrics.push(["intakeCalories", "已记录摄入", "Recorded intake", "kcal", "orange"],
      ["exerciseCalories", "已记录运动消耗", "Recorded activity energy", "kcal", "purple"]);
    if (!h().hideWeight) metrics.push(["weight", "体重", "Weight", "kg", "purple"]);
    const nutrition = h().hideCalories ? "" : card(t("营养汇总", "Nutrition totals"),
      ["protein", "carbs", "fat"].map((key, index) => {
        const available = points.some((point) => point[key] != null);
        return row(t(...[["蛋白质", "Protein"], ["碳水", "Carbs"], ["脂肪", "Fat"]][index]), "",
          available ? amount(total(key), "g") : "—", "", "meals", "orange");
      }).join(""));
    const range = `${dayLabel(report.start)} – ${dayLabel(report.end)}`;
    return header(t("健康趋势", "Health trends"), range, controls)
      + `<div class="health-grid health-three health-trend-summary">${g().tile(amount(total("water"), "mL"), t("饮水总量", "Water logged"), "water", "blue")}
        ${g().tile(amount(total("exercise"), "min"), t("活动总时长", "Active minutes"), "exercise", "green")}
        ${g().tile(`${points.length} / ${ui.days}`, t("记录天数", "Days with entries"), "calendar", "teal")}</div>
      <div class="health-grid health-two">${metrics.map(([key, cn, en, unit, color]) => trendChart(points, days, key, t(cn, en), unit, color)).join("")}${nutrition}</div>`
      + card("", caption(report.configuredDays ? t(`饮水达标：${report.waterGoalHits} / ${report.configuredDays} 天`,
        `Water goal: ${report.waterGoalHits} / ${report.configuredDays} days`) : t("尚未设置饮水目标。", "No water goal set."))
        + caption(t(`统计日期时区：${h().preferences.timezone}`, `Reporting timezone: ${h().preferences.timezone}`)));
  }

  function events() {
    const types = h().eventTypes;
    const active = types.filter((item) => !item.archived);
    const todayMonth = h().today.slice(0, 7);
    const month = ui.eventMonth || todayMonth;
    const date = new Date(`${month}-01T12:00:00Z`);
    const offset = date.getUTCDay();
    date.setUTCMonth(date.getUTCMonth() + 1, 0);
    const last = date.getUTCDate();
    const counts = new Map();
    const all = byNewest(h().events.filter((event) => (!ui.eventFilter || event.typeID === ui.eventFilter)
      && reportDay(event.occurredAt).startsWith(month)));
    for (const event of all) {
      const day = reportDay(event.occurredAt);
      counts.set(day, (counts.get(day) || 0) + event.count);
    }
    const typeById = new Map(types.map((item) => [item.id, item]));
    const selected = all.filter((event) => !ui.eventDay || reportDay(event.occurredAt) === ui.eventDay);
    const calendar = ["日", "一", "二", "三", "四", "五", "六"].map((name, index) =>
      `<small>${e(t(name, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][index]))}</small>`).join("")
      + "<span></span>".repeat(offset) + Array.from({ length: last }, (_, index) => {
        const day = `${month}-${String(index + 1).padStart(2, "0")}`;
        const count = counts.get(day) || 0;
        return `<button type="button" data-health-action="event-day" data-value="${day}" data-count="${Math.min(count, 4)}"
          aria-pressed="${ui.eventDay === day}" title="${e(t(`${day} · ${count} 次`, `${day} · ${count} entries`))}">${index + 1}</button>`;
      }).join("");
    const monthControls = button(t("上个月", "Previous month"), "event-month", -1, { icon: "left" })
      + button(t("本月", "This month"), "event-month", 0)
      + button(t("下个月", "Next month"), "event-month", 1, { icon: "right", disabled: month >= todayMonth });
    const title = new Date(`${month}-01T12:00:00`).toLocaleString(g().locale(), { year: "numeric", month: "long" });
    return header(t("快速事项", "Quick events"), t("点一下，留住日常中的小事。", "One tap for the little things in your day."))
      + `<div class="health-grid health-auto">${active.map((type) => card(eventName(type),
        `<div class="health-inline">${primary(t("记一次", "Log one"), "event-quick", type.id, type.symbol)}
          ${button(t("补记", "Backfill"), "event-add", type.id)}${button(t("编辑", "Edit"), "event-type", type.id, { icon: "edit" })}</div>`)).join("")}</div>`
      + card(t("事项活动", "Event activity"), `<div class="health-inline"><strong>${e(title)}</strong>${monthControls}
        ${g().select("event-filter", t("事项", "Type"), [["", t("全部事项", "All events")], ...types.map((item) => [item.id, eventName(item)])], ui.eventFilter)}</div>
        <div class="health-calendar">${calendar}</div>${caption(t(`本月 ${all.reduce((sum, item) => sum + item.count, 0)} 次 · ${counts.size} 天有记录`,
        `${all.reduce((sum, item) => sum + item.count, 0)} events · ${counts.size} active days`))}`)
      + card(ui.eventDay ? dayLabel(ui.eventDay) : t("本月明细", "This month’s entries"),
        selected.length ? selected.slice(ui.eventPage * PAGE_SIZE, (ui.eventPage + 1) * PAGE_SIZE).map((item) => {
          const type = typeById.get(item.typeID);
          return row(eventName(type), [dateTime(item.occurredAt), item.note].filter(Boolean).join(" · "), `×${item.count}`,
            button(t("编辑", "Edit"), "event-edit", item.id, { icon: "edit" }) + button(t("删除", "Delete"), "event-delete", item.id, { icon: "trash" }),
            type?.symbol || "check", type?.color);
        }).join("") + pageBar(selected.length, ui.eventPage, "event-page") : empty(t("还没有记录", "No entries yet")),
        { actions: (ui.eventDay ? button(t("显示整月", "Show month"), "event-day") : "")
          + (active.length ? button(t("补记事项", "Add past entry"), "event-menu") : "") })
      + `<details class="card"><summary>${e(t("已停用事项", "Archived types"))}</summary>${types.filter((item) => item.archived).map((type) =>
        row(eventName(type), "", "", button(t("恢复使用", "Restore"), "event-type-restore", type.id), type.symbol, type.color)).join("")}</details>`;
  }

  function island() {
    const health = h();
    const scene = health.island;
    const catalog = g().state.catalog;
    const title = header(t("荒岛生活", "Island life"), "", actions("island"));
    if (!health.preferences.gameEnabled) return title + empty(t("正在使用纯记录模式", "Journal-only mode"));
    const supplyGain = 5 + 3 * (scene.buildings.includes("kitchen") ? scene.buildingLevels.kitchen || 1 : 0);
    const ledger = health.dailyLedger;
    const owned = new Set([...scene.tools, ...scene.buildings]);
    const recipes = catalog.islandRecipes;
    const actionCards = catalog.islandActions.map((action) => {
      const problem = scene.actionProblems[action.id];
      const cost = [[action.energy, "bolt"], [action.food, "meals"], [action.water, "water"]].filter(([value]) => value > 0)
        .map(([value, glyph]) => `<span>${icon(glyph)} −${num(value)}</span>`).join("");
      return card(t(action.name, action.englishName), `<div class="health-inline">${cost}</div>`
        + caption(action.output ? `+${action.yield} ${materialName(action.output)}` : "")
        + button(problem ? t(problem) : t("出发", "Go"), "island-act", action.id, { disabled: Boolean(problem) }));
    }).join("");
    const recipeCards = recipes.map((recipe) => {
      const problem = scene.buildProblems[recipe.id];
      return card(t(recipe.name, recipe.englishName), caption(costText(recipe.cost))
        + button(problem ? t(problem) : recipe.tool ? t("打造", "Craft") : t("建造", "Build"),
          "island-build", recipe.id, { disabled: Boolean(problem) }));
    }).join("");
    const upgradeCards = recipes.filter((item) => !item.tool && owned.has(item.id)).map((recipe) => {
      const level = scene.buildingLevels[recipe.id] || 1;
      const problem = scene.upgradeProblems?.[recipe.id];
      return card(`${t(recipe.name, recipe.englishName)} · Lv.${level} / 4`,
        (level < 4 ? caption(costText(recipe.cost, level + 1)) : "")
        + button(problem ? t(problem) : level < 4 ? t(`升级至 ${level + 1} 级`, `Upgrade to level ${level + 1}`) : t("已升至最高级", "Maximum level"),
          "island-upgrade", recipe.id, { disabled: scene.paused || level >= 4 || Boolean(problem) }));
    }).join("");
    const conversion = [
      ["water", 80, "喝水 → 水分", "Water → reserves", "blue"],
      ["food", 75, "三餐 → 饱食", "Meals → food", "orange"],
      ["activity", 18 + Math.max(0, (scene.buildingLevels.training || 1) - 1) * 3, "运动 → 活力", "Activity → energy", "green"],
      ["sleepEnergy", 24, "睡眠 → 活力", "Sleep → energy", "purple"],
    ].map(([key, cap, cn, en, color]) => `<div class="health-reserve" data-color="${color}"><span>${e(t(cn, en))}</span>
      <strong>${num(ledger[key])} / ${cap}</strong><progress value="${Number(ledger[key] || 0)}" max="${cap}"></progress></div>`).join("");
    const inventory = Object.keys(MATERIALS).map((key) => g().tile(num(scene.inventory[key]), materialName(key), "tray", "teal")).join("");
    const requirement = scene.expansionRequirement || [100, 240, 370][scene.expansionLevel];
    const next = scene.nextThreshold;
    const base = ISLAND_MARKS[scene.level - 1] || 0;
    const legacyControls = window.IslandWorld ? "" : `<div class="health-inline">
      ${button(t("布置建筑", "Arrange buildings"), "island-layout", "", { disabled: !scene.buildings.length, icon: "grid" })}
      ${scene.buildings.includes("teaHouse") ? button(t("茶亭休憩", "Tea break"), "island-tea", "", { disabled: scene.paused }) : ""}</div>`;
    return title + reserves() + `<div class="health-island-wrapper">${islandArt(true)}${legacyControls}</div>`
      + card(next ? `Lv.${scene.level}` : t("传奇之岛", "Legendary island"), caption(next ?
        t(`繁荣度 ${scene.prosperity} · 距下一级还需 ${next - scene.prosperity}`, `${scene.prosperity} prosperity · ${next - scene.prosperity} to next level`) :
        t(`繁荣度 ${scene.prosperity}`, `${scene.prosperity} prosperity`))
        + (next ? `<progress value="${scene.prosperity - base}" max="${next - base}"></progress>` : ""))
      + card(t("今日健康转化", "Powered by today’s records"), `<div class="health-grid health-four">${conversion}</div>`)
      + `<div class="health-grid health-auto">${inventory}</div>`
      + `<div class="health-inline">${button(t(`食用补给 +${supplyGain} 饱食`, `Eat supplies +${supplyGain} food`), "island-supply", "", {
        icon: "meals", disabled: scene.paused || !scene.inventory.ration || scene.food >= 100 || (ledger.supplies || 0) >= 3,
      })}</div>`
      + `<h2>${e(t("到岛上忙一会儿", "A little island work"))}</h2><div class="health-grid health-three">${actionCards}</div>
        <h2>${e(t("建造一个家", "Build a place to stay"))}</h2><div class="health-grid health-three">${recipeCards}</div>`
      + card(t("扩建岛屿", "Expand the island"), scene.expansionLevel >= 3 ? caption(t("海岸已全部开拓", "All shores opened")) :
        caption(t(`第 ${scene.expansionLevel + 1} 阶段 · 需要繁荣度 ${requirement}`, `Stage ${scene.expansionLevel + 1} · Requires ${requirement} prosperity`))
        + caption(costText(scene.expansionCost)) + button(scene.expansionProblem ? t(scene.expansionProblem) : t("开拓海岸", "Expand shore"),
          "island-expand", "", { disabled: scene.paused || Boolean(scene.expansionProblem) }))
      + (upgradeCards ? `<h2>${e(t("升级设施", "Upgrade buildings"))}</h2><div class="health-grid health-two">${upgradeCards}</div>` : "")
      + (scene.logs.length ? card(t("岛屿日志", "Island journal"), scene.logs.slice(-8).reverse().map((item) =>
        row(item.description, dateTime(item.date), "", "", "list")).join("")) : "");
  }

  function costText(cost, multiplier = 1) {
    return Object.entries(cost || {}).map(([key, value]) => `${materialName(key)} ${value * multiplier}`).join(" · ");
  }

  function localInput(date = new Date()) {
    return `${g().localDay(date)}T${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }

  function displayDay(backfill) {
    const start = new Date();
    if (backfill) start.setDate(start.getDate() - 1);
    return start;
  }

  function hidden(name, value) {
    return `<input type="hidden" name="${e(name)}" value="${e(value)}">`;
  }

  function showRecord(kind, existing, backfill = false) {
    const record = existing || {};
    const preferences = h().preferences;
    const defaultDate = displayDay(backfill);
    const dateValue = record.occurredAt != null ? cocoaDate(record.occurredAt) : defaultDate;
    const { input, textarea, select, checkbox } = g();
    const hour = dateValue.getHours();
    const mealSlots = h().dailyConfig.slots || 3;
    const mealItems = [t("早餐", "Breakfast"), t("午餐", "Lunch"), t("晚餐", "Dinner"), t("加餐", "Extra meal")];
    const baseValue = kind === "water" ? preferences.cup : kind === "exercise" ? 30 : kind === "weight" ?
      (byNewest(h().records.filter((item) => item.kind === "weight"))[0]?.amount ?? 60) : 1;
    const addMeal = kind === "meal" ? select("slot", t("餐次", "Meal slot"), mealItems.slice(0, mealSlots).map((name, index) => [index, name]),
      record.slot ?? Math.min(mealSlots - 1, hour < 11 ? 0 : hour < 16 ? 1 : 2))
      + select("mealSource", t("饮食方式", "Meal source"), Object.entries(SOURCES).map(([key, value]) => [key, t(...value)]), record.mealSource || "canteen")
      + input("fullnessPercent", t("饱食程度 (%)", "Fullness (%)"), record.fullnessPercent ?? 75, { type: "number", min: 0, max: 100, required: true }) : "";
    const unit = KINDS[kind][4];
    const amountField = kind === "meal" ? hidden("amount", record.amount ?? 1) :
      input("amount", unit ? `${t("数量", "Amount")} (${unit})` : t("数量", "Amount"), record.amount ?? baseValue,
        { type: "number", min: 0.01, max: { water: 10000, exercise: 1440, weight: 1000 }[kind], step: "any", required: true });
    const energyField = kind === "exercise" && !h().hideCalories ?
      input("calories", t("估计消耗 (kcal)", "Estimated energy (kcal)"), record.calories ?? "", { type: "number", min: 0, max: 100000, step: "any" }) : "";
    const title = existing ? t("编辑记录", "Edit record") : backfill ? t("补记", "Backfill") : t("记一笔", "Record");
    g().modal(`${title} · ${kindName(kind)}`, `<div class="health-form health-editor">
      <div class="health-editor-grid">${input("occurredAt", t("时间", "Date and time"), localInput(dateValue),
      { type: "datetime-local", required: true })}
      ${input("title", t("名称", "Name"), record.title ?? (kind === "exercise" ? t("步行", "Walking") : ""),
        { maxlength: 200 })}</div>
      <div class="health-editor-grid${kind === "meal" ? " health-editor-meal" : ""}">${amountField}${addMeal}${energyField}</div>
      ${textarea("note", t("备注", "Notes"), record.note || "")}
      <div class="health-editor-template">${checkbox("saveTemplate", t("存为常用模板", "Save as favorite"), false)}</div></div>`,
    async (_, form) => {
      const formData = formFields(form);
      const payload = { kind, occurredAt: formData.occurredAt, title: formData.title, amount: Number(formData.amount),
        note: formData.note, saveTemplate: Boolean(formData.saveTemplate) };
      if (existing) payload.id = record.id;
      if (kind === "meal") Object.assign(payload, { slot: Number(formData.slot), mealSource: formData.mealSource, fullnessPercent: Number(formData.fullnessPercent) });
      if ("calories" in formData) payload.calories = formData.calories === "" ? null : Number(formData.calories);
      await post("record", payload, { throw: true, message: t("记录已保存。", "Record saved.") });
    }, { className: "health-record-editor" });
  }

  function showSleep(backfill = false) {
    const now = new Date();
    const night = new Date(now);
    night.setDate(night.getDate() - (backfill || night.getHours() < 7 ? 2 : 1));
    const { input } = g();
    const initialEnd = new Date(night);
    initialEnd.setDate(initialEnd.getDate() + 1);
    initialEnd.setHours(7, 0, 0, 0);
    const initialStart = new Date(initialEnd.getTime() - 8 * 60 * 60 * 1000);
    const form = g().modal(t("记录睡眠", "Record sleep"), `<div class="health-form health-editor">
      <div class="health-editor-grid health-editor-meal">${input("night", t("哪一晚", "Night"), g().localDay(night), { type: "date", required: true })}
      ${input("hours", t("小时", "Hours"), 8, { type: "number", min: 0, max: 24, step: 1, required: true })}
      ${input("minutes", t("分钟", "Minutes"), 0, { type: "number", min: 0, max: 59, step: 1, required: true })}</div>
      <output id="health-sleep-estimate" class="health-caption health-sleep-estimate"></output>
      <details><summary>${e(t("填写确切的就寝和起床时间", "Enter exact bed and wake times"))}</summary>
      ${g().checkbox("exact", t("使用以下时间", "Use these times"), false)}
      <div class="health-editor-grid">${input("start", t("就寝", "Bedtime"), localInput(initialStart), { type: "datetime-local" })}
      ${input("end", t("起床", "Wake time"), localInput(initialEnd), { type: "datetime-local" })}</div></details></div>`,
    async (_, currentForm) => {
      const values = formFields(currentForm);
      const minutes = Number(values.hours) * 60 + Number(values.minutes);
      const body = values.exact ? { start: values.start, end: values.end } : { night: values.night, minutes };
      await post("sleep/add", body, { throw: true, message: t("睡眠已保存到共同记录。", "Sleep saved in the shared journal.") });
    }, { className: "health-record-editor" });
    const estimate = () => {
      const values = formFields(form);
      const output = form.querySelector("#health-sleep-estimate");
      if (!values.night) { output.textContent = ""; return; }
      const end = new Date(`${values.night}T07:00:00`);
      end.setDate(end.getDate() + 1);
      const start = new Date(end.getTime() - (Number(values.hours) * 60 + Number(values.minutes)) * 60000);
      output.textContent = `${dateTime(start)} → ${dateTime(end)}`;
    };
    form.querySelector(".dialog-body").addEventListener("input", estimate);
    estimate();
  }

  function showPreferences() {
    const { input, select, checkbox } = g();
    const prefs = h().preferences;
    const config = h().dailyConfig;
    const palettes = [["system", t("跟随系统", "System")], ["light", t("浅色", "Light")], ["dark", t("深色", "Dark")]];
    g().modal(t("健康设置", "Health settings"), `<div class="health-form">
      ${input("cup", t("每杯饮水量 (mL)", "Cup size (mL)"), prefs.cup, { type: "number", min: 1, max: 10000, required: true })}
      ${input("waterGoal", t("每日饮水目标 (mL)", "Daily water goal (mL)"), config.waterGoal ?? "", { type: "number", min: 1, max: 10000 })}
      ${input("slots", t("每日餐次", "Meals per day"), config.slots, { type: "number", min: 1, max: 4, required: true })}
      ${input("restHour", t("休息开始小时", "Rest starts at hour"), config.restHour, { type: "number", min: 0, max: 23, required: true })}
      ${input("timezone", t("统计时区（如 Asia/Shanghai）", "Reporting timezone (e.g. Asia/Shanghai)"), prefs.timezone, { required: true })}
      ${select("appearance", t("健康外观", "Health appearance"), palettes, prefs.appearance)}
      ${input("backgroundHex", t("健康背景色（十六进制）", "Health background color (hex)"), prefs.backgroundHex, { maxlength: 7 })}
      ${checkbox("hideWeight", t("隐藏体重", "Hide weight"), prefs.hideWeight)}
      ${checkbox("hideCalories", t("隐藏热量和营养", "Hide calories and nutrition"), prefs.hideCalories)}
      ${checkbox("gameEnabled", t("开启荒岛生活", "Enable island life"), prefs.gameEnabled)}
      <div class="health-inline">${button(t("导出健康 CSV", "Export health CSVs"), "health-download", "", { icon: "download" })}
      ${button(t("导入健康 CSV", "Import health CSVs"), "health-import", "", { icon: "tray" })}</div></div>`,
    async (_, form) => {
      const values = formFields(form);
      for (const key of ["hideWeight", "hideCalories", "gameEnabled"]) values[key] = Boolean(values[key]);
      for (const key of ["cup", "slots", "restHour"]) values[key] = Number(values[key]);
      values.waterGoal = values.waterGoal ? Number(values.waterGoal) : null;
      await post("preferences", values, { throw: true });
    });
  }

  function showImport() {
    const allowed = ["water.csv", "meal.csv", "exercise.csv", "weight.csv", "custom-events.csv"];
    g().modal(t("导入健康 CSV", "Import health CSVs"), `<div class="health-form">
      ${caption(t("解压导出的 ZIP 文件后，选择其中的 CSV 文件。", "Unzip the exported archive and select its CSV files."))}
      ${g().input("csv", t("健康 CSV 文件", "Health CSV files"), "", { type: "file", accept: ".csv,text/csv", multiple: true, required: true })}</div>`,
    async (_, form) => {
      const files = [...form.elements.csv.files];
      if (files.some((item) => !allowed.includes(item.name)) || new Set(files.map((item) => item.name)).size !== files.length) {
        throw Error(t("请选择健康导出的 CSV 文件，每种文件只选一份。", "Select one file per type from a Health CSV export."));
      }
      if (files.reduce((sum, item) => sum + item.size, 0) > 16 * 1024 * 1024) {
        throw Error(t("一次导入的文件须小于 16 MiB。", "Select fewer than 16 MiB of CSV files per import."));
      }
      const entries = await Promise.all(files.map(async (item) => [item.name, await item.text()]));
      const { result } = await post("import-csv", { files: Object.fromEntries(entries) }, { throw: true });
      g().notice(t(`已导入 ${result.added} 条 · 重复 ${result.skipped} 条 · 无效 ${result.invalid} 条`,
        `Imported ${result.added} · ${result.skipped} duplicates · ${result.invalid} invalid`));
    }, { submitLabel: t("导入", "Import") });
  }

  function showEventType(id) {
    const { input, select, checkbox } = g();
    const type = h().eventTypes.find((item) => item.id === id) || {};
    const symbolLabels = [t("咖啡杯", "Cup and saucer"), t("马克杯", "Mug"), t("水瓶", "Bottle"), t("头脑", "Head"),
      t("洗手间", "Toilet"), t("药片", "Pills"), t("心", "Heart"), t("月亮", "Moon"), t("步行", "Walk"), t("完成", "Check")];
    const colorLabels = [t("蓝色", "Blue"), t("青色", "Teal"), t("橙色", "Orange"), t("紫色", "Purple"), t("粉色", "Pink"), t("绿色", "Green")];
    g().modal(id ? t("编辑事项类型", "Edit event type") : t("自定义事项", "New event type"), `<div class="health-form">
      ${input("name", t("事项名称", "Name"), type.name, { maxlength: 24, required: true })}
      ${input("englishName", t("英文名称", "English name"), type.englishName, { maxlength: 40 })}
      ${select("symbol", t("图标", "Icon"), EVENT_SYMBOLS.map((key, index) => [key, symbolLabels[index]]), type.symbol || "checkmark.circle")}
      ${select("color", t("颜色", "Color"), EVENT_COLORS.map((key, index) => [key, colorLabels[index]]), type.color || "blue")}
      ${checkbox("inWidget", t("显示在小组件", "Show in widget"), type.inWidget ?? true)}
      ${id ? checkbox("archived", t("停用此事项", "Archive event type"), type.archived) : ""}</div>`,
    async (_, form) => {
      const values = formFields(form);
      if (id) values.id = id;
      for (const key of ["inWidget", "archived"]) values[key] = Boolean(values[key]);
      await post("event/type", values, { throw: true });
    });
  }

  function showEvent(typeID, id) {
    const existing = h().events.find((item) => item.id === id);
    const item = existing || { typeID, count: 1, note: "" };
    const types = h().eventTypes.filter((type) => !type.archived || type.id === item.typeID);
    const date = item.occurredAt != null ? cocoaDate(item.occurredAt) : ui.eventDay ?
      new Date(`${ui.eventDay}T12:00:00`) : displayDay(true);
    const { select, input, textarea } = g();
    g().modal(id ? t("编辑事项", "Edit event") : t("补记事项", "Add past entry"), `<div class="health-form">
      ${select("typeID", t("事项", "Type"), types.map((type) => [type.id, eventName(type)]), item.typeID)}
      ${input("occurredAt", t("时间", "Date and time"), localInput(date), { required: true, type: "datetime-local" })}
      ${input("count", t("次数", "Count"), item.count, { required: true, type: "number", min: 1, max: 999 })}
      ${textarea("note", t("备注", "Notes"), item.note)}</div>`, async (_, form) => {
      const values = formFields(form);
      if (id) values.id = id;
      values.count = Number(values.count);
      await post("event", values, { throw: true });
    });
  }

  function showLayout() {
    const scene = h().island;
    const recipes = g().state.catalog.islandRecipes;
    const titleOf = (key) => {
      const recipe = recipes.find((item) => item.id === key);
      return recipe ? t(recipe.name, recipe.englishName) : key;
    };
    const fields = scene.buildings.map((building) => {
      const point = scene.placements[building] || { x: 0, z: 0 };
      return `<fieldset><legend>${e(titleOf(building))}</legend><div class="health-grid health-two">
        ${g().input(`${building}-x`, t("东西", "East–west"), point.x, { type: "number", min: -8, max: 8, step: "any", required: true })}
        ${g().input(`${building}-z`, t("南北", "North–south"), point.z, { type: "number", min: -8, max: 8, step: "any", required: true })}
        </div></fieldset>`;
    }).join("");
    g().modal(t("布置建筑", "Arrange buildings"), `<div class="health-form">${islandArt(true)}${fields}</div>`, async (_, form) => {
      const values = formFields(form);
      const placements = Object.fromEntries(scene.buildings.map((id) => [id, { x: Number(values[`${id}-x`]), z: Number(values[`${id}-z`]) }]));
      await post("layout", { placements }, { throw: true });
    });
  }

  function pick(title, choices) {
    const form = g().modal(title, `<div class="health-inline">${choices.map(([label, action, value, glyph]) =>
      button(label, action, value, { icon: glyph })).join("")}</div>`);
    for (const choice of form.querySelectorAll("[data-health-action]")) {
      choice.addEventListener("click", () => g().closeModal(), { once: true });
    }
  }

  function manageTemplates() {
    g().modal(t("管理模板", "Manage templates"), h().templates.map((item) => row(item.name,
      t(`已使用 ${item.uses} 次`, `Used ${item.uses} times`), "",
      button(t("删除", "Delete"), "template-delete", item.id, { icon: "trash" }),
      KINDS[item.record.kind]?.[2], KINDS[item.record.kind]?.[3])).join(""));
  }

  function plusWater() {
    return post("record", { kind: "water", amount: h().preferences.cup, title: kindName("water") },
      { message: t("已记录喝水。", "Water logged.") });
  }

  async function handle(action, value) {
    switch (action) {
      case "preferences": showPreferences(); break;
      case "health-download": await g().download(api + "export.zip", "GaoJieZou-Health-CSV.zip"); break;
      case "health-import": showImport(); break;
      case "welcome":
        if (await post("preferences", { onboarding: true })) await plusWater();
        break;
      case "welcome-dismiss": await post("preferences", { onboarding: true }); break;
      case "water": await plusWater(); break;
      case "record-new": showRecord(value); break;
      case "record-backdate": showRecord(value, null, true); break;
      case "record-edit": {
        const found = h().records.find((item) => item.id === value);
        if (found) showRecord(found.kind, found);
        break;
      }
      case "backfill-menu":
        pick(t("补记", "Backfill"), Object.keys(KINDS).filter((key) => !h().hideWeight || key !== "weight").map((key) =>
          [kindName(key), key === "sleep" ? "sleep-add" : "record-backdate", key === "sleep" ? "past" : key, KINDS[key][2]]));
        break;
      case "record-delete":
        confirm(t("删除记录？", "Delete record?"), t("删除后可撤销。", "You can undo this deletion."), "record/delete", { id: value });
        break;
      case "record-filter":
        Object.assign(ui, { filter: value, page: 0, sleepCount: 30 }); g().render();
        document.querySelector('.health-filters [aria-pressed="true"]')?.focus({ preventScroll: true });
        break;
      case "record-reset":
        Object.assign(ui, { query: "", range: 7, page: 0, sleepCount: 30 }); g().render();
        document.querySelector("#health-record-search input")?.focus({ preventScroll: true });
        break;
      case "record-page": ui.page = Number(value); g().render(); break;
      case "sleep-add": showSleep(value === "past"); break;
      case "sleep-more": ui.sleepCount += 30; g().render(); break;
      case "sleep-delete":
        confirm(t("删除这条睡眠记录？", "Delete this sleep record?"),
          t("健康与睡眠计时页面都会移除此记录，已获得的游戏奖励保留。", "The entry will be removed from Health and the sleep timer. Earned rewards are retained."),
          "sleep/delete", { id: value });
        break;
      case "sync": await g().refresh(); g().notice(h().sleepSyncError || t("睡眠记录已同步。", "Sleep journal synced."), h().sleepSyncError ? "error" : "success"); break;
      case "undo": await post("undo", {}, { message: t("已撤销。", "Undone.") }); break;
      case "template-use": await post("template/use", { id: value }, { message: t("记录已保存。", "Record saved.") }); break;
      case "template-manage": manageTemplates(); break;
      case "template-delete":
        confirm(t("删除模板？", "Delete template?"), t("历史记录保留。", "Saved entries are retained."), "template/delete", { id: value });
        break;
      case "trend-range":
        ui.days = Number(value); g().render();
        document.querySelector('.health-trend-filters [aria-pressed="true"]')?.focus({ preventScroll: true });
        break;
      case "event-type": showEventType(value); break;
      case "event-type-restore": await post("event/type", { id: value, archived: false }); break;
      case "event-quick": await post("event", { typeID: value, count: 1 }, { message: t("已记录。", "Event logged.") }); break;
      case "event-add": showEvent(value); break;
      case "event-edit": showEvent("", value); break;
      case "event-delete":
        confirm(t("删除事项？", "Delete entry?"), t("删除后可撤销。", "You can undo this deletion."), "event/delete", { id: value });
        break;
      case "event-menu":
        pick(t("补记事项", "Add past entry"), h().eventTypes.filter((item) => !item.archived)
          .map((item) => [eventName(item), "event-add", item.id, item.symbol]));
        break;
      case "event-day": Object.assign(ui, { eventDay: ui.eventDay === value ? "" : value, eventPage: 0 }); g().render(); break;
      case "event-page": ui.eventPage = Number(value); g().render(); break;
      case "event-month": {
        const date = new Date(`${ui.eventMonth || h().today.slice(0, 7)}-01T12:00:00Z`);
        date.setUTCMonth(date.getUTCMonth() + Number(value));
        Object.assign(ui, { eventMonth: Number(value) ? date.toISOString().slice(0, 7) : "", eventDay: "", eventPage: 0 });
        g().render();
        break;
      }
      case "island-pause": await post("preferences", { paused: !h().island.paused }); break;
      case "island-layout": showLayout(); break;
      case "island-act": await post("act", { id: value }); break;
      case "island-build": await post("build", { id: value }); break;
      case "island-upgrade": await post("upgrade", { id: value }); break;
      case "island-expand": await post("expand"); break;
      case "island-supply": await post("supply"); break;
      case "island-tea": await post("tea"); break;
    }
  }

  let mounted = false;
  let visited = false;
  function bind(section) {
    if (!mounted) {
      document.addEventListener("click", (event) => {
        const target = event.target.closest("[data-health-action]");
        if (target) handle(target.dataset.healthAction, target.dataset.value).catch((error) => g().notice(error.message, "error"));
      });
      mounted = true;
    }
    document.querySelector("#health-record-search")?.addEventListener("submit", (event) => {
      event.preventDefault();
      const { query, range } = formFields(event.currentTarget);
      Object.assign(ui, { query, range: Number(range), page: 0, sleepCount: 30 });
      g().render();
      document.querySelector("#health-record-search input")?.focus({ preventScroll: true });
    });
    document.querySelector('[name="event-filter"]')?.addEventListener("change", (event) => {
      Object.assign(ui, { eventFilter: event.target.value, eventPage: 0 });
      g().render();
    });
    window.IslandWorld?.bind(h()?.island, g().state.catalog);
    if (section === "island" && !visited && h()?.preferences.gameEnabled) {
      visited = true;
      void post("island/visit");
    }
  }

  function leave(oldPage, oldSection, nextPage, nextSection) {
    if (oldPage !== nextPage || oldSection !== nextSection) {
      visited = false;
      window.IslandWorld?.leave();
    }
  }

  window.HealthUI = { render, bind, actions, leave };
})();
