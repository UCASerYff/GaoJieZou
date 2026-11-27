(() => {
  "use strict";
  const token = document.querySelector('meta[name="gao-token"]').content;
  const app = document.querySelector("#app");
  const editor = document.querySelector("#editor");
  const sections = {
    today: ["今天", "sun"],
    rhythm: ["节奏", "timer", "专注、习惯与每一个小目标", [
      ["focus", "工作专注", "timer"], ["sleep", "睡眠计时", "moon"], ["habits", "日常打卡", "check"],
      ["chores", "一些琐事", "tray"], ["goals", "长期目标", "flag"], ["actions", "短期行动", "list"], ["statistics", "数据统计", "chart"]
    ]],
    health: ["健康", "heart", "照顾身体，不必成为负担。", [
      ["overview", "今日", "heart"], ["records", "全部记录", "list"], ["trends", "统计趋势", "chart"], ["events", "快速事项", "grid"]
    ]],
    footprints: ["足迹", "map", "走过的地方，都有故事。", [
      ["map", "地图", "map"], ["trips", "旅行", "case"], ["timeline", "时间轴", "clock"]
    ]],
    playground: ["乐园", "leaf", "认真生活，也尽情生长。", [
      ["farm", "农场", "leaf"], ["pasture", "牧场", "paw"], ["fishing", "渔场", "fish"],
      ["island", "荒岛生活", "tree"], ["train", "旅行列车", "train"]
    ]]
  };
  const shapes = {
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l2 2m10 10 2 2M5 19l2-2M17 7l2-2"/>',
    timer: '<circle cx="12" cy="13" r="8"/><path d="M10 2h4m-2 0v3m0 4v5l3 2m3-10 2-2"/>',
    moon: '<path d="M20 15A9 9 0 0 1 9 4a9 9 0 1 0 11 11ZM16 3v6m-3-3h6m1 2v4m-2-2h4"/>',
    heart: '<path d="M21 9a4.5 4.5 0 0 0-9-1A4.5 4.5 0 0 0 3 9c0 4.5 9 11 9 11s9-6.5 9-11Z"/>',
    map: '<path d="m3 6 6-3 6 3 6-3v15l-6 3-6-3-6 3Zm6-3v15m6-12v15"/>',
    leaf: '<path d="M21 3C12 3 6 7 6 13a5 5 0 0 0 5 5c6 0 10-6 10-15ZM3 21l12-11"/>',
    check: '<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>',
    circle: '<circle cx="12" cy="12" r="8"/>',
    tray: '<path d="M3 12l3-7h12l3 7v7H3Zm0 0h5l1.5 3h5l1.5-3h5"/>',
    flag: '<path d="M5 22V3m0 1c5-4 9 4 15 0v11c-6 4-10-4-15 0"/>',
    list: '<rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 4V2h6v2m-6 6h6m-6 4h6m-6 4h6"/>',
    chart: '<path d="M3 3v18h19M7 17v-4m4 4V9m4 8v-5m4 5V6"/>',
    grid: '<path d="M3 3h7v7H3zm11 0h7v7h-7zM3 14h7v7H3zm11 0h7v7h-7z"/>',
    case: '<rect x="3" y="7" width="18" height="13" rx="2"/><path d="M8 7V4h8v3M8 7v13m8-13v13"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l4 2"/>',
    home: '<path d="m3 11 9-8 9 8m-16-1v11h14V10m-9 11v-6h4v6"/>',
    paw: '<ellipse cx="5" cy="9" rx="2" ry="3"/><ellipse cx="9" cy="5" rx="2" ry="3"/><ellipse cx="15" cy="5" rx="2" ry="3"/><ellipse cx="19" cy="9" rx="2" ry="3"/><path d="M12 11c3 0 7 5 7 7 0 3-4 3-7 1-3 2-7 2-7-1 0-2 4-7 7-7Z"/>',
    fish: '<path d="M2 12s4-5 9-5 7 5 7 5l4-4v8l-4-4s-2 5-7 5-9-5-9-5Z"/><circle cx="7" cy="11" r=".6"/>',
    tree: '<path d="m12 2 5 7h-2l5 6h-3l4 4H3l4-4H4l5-6H7Zm0 17v3"/>',
    train: '<rect x="5" y="3" width="14" height="15" rx="3"/><path d="M5 11h14m-12 7-3 4m13-4 3 4M8 15h1m6 0h1M12 3v8"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    bolt: '<path d="m13 2-9 12h7l-1 8 10-12h-7Z"/>',
    water: '<path d="M12 2S5 11 5 15a7 7 0 0 0 14 0c0-4-7-13-7-13Z"/>',
    meals: '<path d="M5 3v7m3-7v7m3-7v7a3 3 0 0 1-6 0m3 3v8m10-18v18m0-18c-3 2-4 5-4 9h4"/>',
    exercise: '<circle cx="15" cy="4" r="2"/><path d="m10 22 3-6-3-3m6 9-1-6m-7-5 4-4 4 4h4m-8-4-2 6-4 2"/>',
    weight: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M7 11c0-4 10-4 10 0m-5 0 2-3"/>',
    coin: '<circle cx="12" cy="12" r="9"/><path d="M12 6v12m-3-9h5a1.5 1.5 0 0 1 0 3h-4a1.5 1.5 0 0 0 0 3h5"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="m10 2-1 3-2 1-3-1-2 4 2 2v2l-2 2 2 4 3-1 2 1 1 3h4l1-3 2-1 3 1 2-4-2-2v-2l2-2-2-4-3 1-2-1-1-3Z"/>',
    play: '<path d="m7 4 13 8-13 8Z"/>', pause: '<path d="M9 5v14m6-14v14"/>',
    left: '<path d="m15 5-7 7 7 7"/>', right: '<path d="m9 5 7 7-7 7"/>',
    diagonal: '<path d="M5 19 19 5M8 5h11v11"/>',
    lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 1 1 8 0v3"/>',
    download: '<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
    edit: '<path d="m4 16-1 5 5-1L20 8l-4-4-12 12Zm10-10 4 4"/>',
    trash: '<path d="M4 6h16m-11 0V3h6v3M6 6l1 15h10l1-15m-8 3v8m4-8v8"/>',
    more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    eye: '<path d="M2 12s4-6 10-6 10 6 10 6-4 6-10 6-10-6-10-6Z"/><circle cx="12" cy="12" r="2.5"/>'
  };
  const aliases = {
    "sun.max.fill": "sun", "checkmark.circle.fill": "check", "flag.checkered": "flag", "tray.full.fill": "tray",
    "heart.fill": "heart", "moon.stars.fill": "moon", "leaf.fill": "leaf", "drop.fill": "water", "fork.knife": "meals",
    "figure.walk": "exercise", "pawprint.fill": "paw", "fish.fill": "fish", "tram.fill": "train", "map.fill": "map",
    "chart.bar.xaxis": "chart", "chevron.left": "left", "chevron.right": "right", "arrow.up.right": "diagonal",
    "book.fill": "list", "bolt.fill": "bolt", "checkmark": "check", "circle.fill": "coin", "house.fill": "home",
    "calendar": "grid", "bed.double.fill": "moon", "location.fill": "map", "plus.circle.fill": "plus",
    "dumbbell.fill": "exercise", "flame.fill": "bolt", "water.waves": "water", "sparkles": "sun",
    "drop": "water", "bed.double": "moon", "clock.arrow.circlepath": "clock", "gearshape": "settings",
    "arrow.uturn.backward": "left", "arrow.triangle.2.circlepath": "clock", "pencil": "edit",
    "square.stack.3d.up.fill": "list", "square.grid.3x3.fill": "grid", "chart.xyaxis.line": "chart",
    "scalemass.fill": "weight", "figure.run": "exercise", "circle.dashed": "circle", "arrow.up.right": "diagonal"
  };
  const english = {
    "节奏":"Rhythm", "健康":"Health", "足迹":"Footprints", "乐园":"Playground", "今日":"Today",
    "全部记录":"All records", "统计趋势":"Trends", "快速事项":"Quick events", "地图":"Map", "旅行":"Trips",
    "时间轴":"Timeline", "常驻城市":"Home city", "记下足迹":"Record a visit", "健康记录":"Health records",
    "把今天，过成自己的节奏。":"Make today your own rhythm.", "认真生活，也尽情生长。":"Live well and enjoy growing.",
    "此刻专注":"Focus in progress", "正在睡眠计时":"Sleep timer running", "今天的第一小步":"Today’s first step",
    "安心休息，记录会在后台继续":"Rest easy. The timer will continue in the background.",
    "锁屏、熄屏和合盖不会中断睡眠记录":"The sleep timer continues when the display is off or Windows sleeps.",
    "每日打卡提醒":"Daily habit reminder", "提醒时间":"Reminder time", "创建我的资料库":"Create my library",
    "喝够八杯水":"Drink eight glasses of water", "整理桌面":"Tidy your desk", "阅读二十分钟":"Read for 20 minutes",
    "完成第一次 25 分钟专注":"Complete your first 25-minute focus session",
    "建立稳定的工作与休息节奏":"Build a steady work and rest routine",
    "让每天的精力更可控，也为长期目标留出空间。":"Manage your energy and make time for longer-term goals.",
    "连续四周保持规律专注与睡眠":"Keep a regular focus and sleep routine for four weeks",
    "抛竿":"Cast", "收竿":"Reel in", "放下鱼竿":"Put down the rod", "水族馆":"Aquarium",
    "取回鱼篓":"Return to fish basket", "收取全部":"Collect all", "收取产物":"Collect products",
    "收获并出售":"Harvest and sell", "购买牲畜":"Buy an animal", "出售牲畜":"Sell animal", "搭窝":"Buy shelter",
    "新增打卡":"New habit", "编辑打卡":"Edit habit", "新增琐事":"New chore", "编辑琐事":"Edit chore",
    "新增长期目标":"New long-term goal", "编辑长期目标":"Edit long-term goal",
    "新增短期行动":"New short action", "编辑短期行动":"Edit short action", "琐事月历":"Chore calendar",
    "取消完成":"Mark incomplete", "标记完成":"Mark complete", "删除打卡目标？":"Delete this habit?",
    "删除这项琐事？":"Delete this chore?", "删除长期目标？":"Delete this goal?", "删除短期行动？":"Delete this action?",
    "删除睡眠记录？":"Delete this sleep record?", "前移":"Move earlier", "后移":"Move later",
    "睡眠记录":"Sleep records", "起床并保存":"Wake and save", "开始睡眠":"Start sleep",
    "待领取":"Pending", "装饰商店":"Decorations", "领取收益":"Collect earnings", "移入水族馆":"Move to aquarium"
  };

  let state, translations = {}, page = "today", section = "today";
  let dialogSubmit, confirmClose, clockReference, revision = 0, pending = 0, toastTimer, previousData, background;
  const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"})[c]);
  const t = (zh, en) => state?.settings.language === "en" ? translations[zh] || en || english[zh] || zh : zh;
  const localized = (zh, en) => esc(t(zh, en));
  const locale = () => state?.settings.language === "en" ? "en-US" : "zh-CN";
  const fromCocoa = value => new Date((Number(value) + 978307200) * 1000);
  const instant = value => typeof value === "number" ? fromCocoa(value) : new Date(value);
  const date = (value, options = {month: "short", day: "numeric"}) =>
    value != null && Number.isFinite(instant(value).getTime()) ? instant(value).toLocaleString(locale(), options) : "—";
  const localDay = (value = new Date()) => {
    const d = instant(value);
    return Number.isFinite(d.getTime()) ? [d.getFullYear(), d.getMonth()+1, d.getDate()].map(n => String(n).padStart(2,"0")).join("-") : "";
  };
  const currentClock = () => (state?.clock || Date.now() / 1000 - 978307200) + (performance.now() - clockReference) / 1000;
  function duration(seconds, showSeconds = false) {
    const s = Math.floor(Math.max(0, Number(seconds) || 0));
    const hours = Math.floor(s / 3600), minutes = Math.floor(s / 60) % 60;
    if (showSeconds) return [hours, minutes, s % 60].map(n => String(n).padStart(2,"0")).join(":");
    return (hours ? hours + t(" 小时 ", " h ") : "") + minutes + t(" 分钟", " min");
  }

  function icon(name, className = "") {
    return '<svg class="icon ' + esc(className) + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      (shapes[aliases[name] || name] || shapes.circle) + '</svg>';
  }

  function button(label, {icon: glyph, className = "", action, go, type = "button", disabled = false, title} = {}) {
    return '<button type="' + type + '" class="' + esc(className) + '"' +
      (action ? ' data-action="' + esc(action) + '"' : "") + (go ? ' data-go="' + esc(go) + '"' : "") +
      (title ? ' title="' + esc(title) + '" aria-label="' + esc(title) + '"' : "") + (disabled ? " disabled" : "") + ">" +
      (glyph ? icon(glyph) : "") + (label ? "<span>" + esc(label) + "</span>" : "") + "</button>";
  }

  function card(title, body, {className = "", subtitle, actions} = {}) {
    return '<section class="card ' + esc(className) + '">' + (title || actions ? '<div class="card-head"><div>' +
      (title ? "<h2>" + esc(title) + "</h2>" : "") + (subtitle ? '<p class="muted">' + esc(subtitle) + "</p>" : "") +
      '</div>' + (actions ? '<div class="row card-actions">' + actions + "</div>" : "") + "</div>" : "") + body + "</section>";
  }
  const header = (title, subtitle = "", actions = "") => '<div class="page-head row"><div><h1>' + esc(title) + "</h1>" +
    (subtitle ? '<p class="muted">' + esc(subtitle) + "</p>" : "") + "</div>" +
    (actions ? '<div class="row">' + actions + "</div>" : "") + "</div>";
  const empty = text => '<p class="empty">' + esc(text) + "</p>";
  const rows = (items, format, message = t("暂无记录", "No records yet")) =>
    items?.length ? '<div class="rows">' + items.map(format).join("") + "</div>" : empty(message);
  const item = (label, details = "", actions = "", glyph = "list", {color = ""} = {}) => '<div class="data-row"><span class="glyph ' +
    esc(color) + '">' + icon(glyph) + '</span><div class="data-copy"><strong>' + esc(label) + '</strong>' +
    (details ? '<div class="muted">' + esc(details) + "</div>" : "") + '</div><div class="row data-actions">' + actions + "</div></div>";
  const tile = (value, text, glyph, color = "") => '<div class="card tile"><span class="glyph ' + esc(color) + '">' + icon(glyph) +
    '</span><div><strong>' + esc(value) + '</strong><span class="muted">' + esc(text) + "</span></div></div>";
  const field = (label, contents) => '<label class="field"><span>' + esc(label) + "</span>" + contents + "</label>";
  const input = (name, label, value = "", attributes = {}) => field(label, '<input name="' + esc(name) + '" value="' +
    esc(value) + '"' + Object.entries(attributes).map(([key, val]) => val === true ? " " + key : val === false ? "" :
      " " + key + '="' + esc(val) + '"').join("") + ">");
  const select = (name, label, choices, value = "") => field(label, '<select name="' + esc(name) + '">' +
    choices.map(([key, labelText]) => '<option value="' + esc(key) + '"' + (String(key) === String(value) ? " selected" : "") +
      ">" + esc(labelText) + "</option>").join("") + "</select>");
  const textarea = (name, label, value = "") => field(label, '<textarea name="' + esc(name) + '" rows="3">' + esc(value) + "</textarea>");
  const checkbox = (name, label, checked) => '<label class="check-field"><input type="checkbox" name="' + esc(name) +
    '"' + (checked ? " checked" : "") + "><span>" + esc(label) + "</span></label>";

  function authorizedFetch(path, options = {}) {
    return fetch(path, {...options, headers: {...options.headers, "X-Gao-Token": token}});
  }
  function applyState(next) {
    state = next;
    clockReference = performance.now();
    document.documentElement.lang = state.settings.language;
    document.documentElement.dataset.theme = state.settings.appearance;
    document.documentElement.style.setProperty("--custom-paper", /^#[0-9a-f]{6}$/i.test(state.settings.backgroundHex)
      ? state.settings.backgroundHex : "var(--base-paper)");
    document.title = t("搞节奏", "Rhythm");
  }
  async function api(path, body) {
    const post = body !== undefined;
    if (post) { pending++; revision++; }
    const requested = revision;
    try {
      const response = await authorizedFetch(path, post ? {
        method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(body)
      } : {});
      const data = await response.json();
      if (!response.ok || data.ok === false) {
        throw Object.assign(new Error(data.error || response.statusText),{code:data.code,status:response.status});
      }
      if (requested === revision) {
        if (data.state) applyState(data.state);
        if (path === "/api/state" && !pending) applyState(data);
      }
      return data;
    } finally {
      if (post) pending--;
    }
  }
  function notice(message, type = "success") {
    if (!message) return;
    const toast = document.querySelector("#notice");
    toast.textContent = message;
    toast.dataset.type = type;
    toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.hidden = true; }, type === "error" ? 8500 : 4500);
  }
  async function act(path, body = {}, options = {}) {
    try {
      const data = await api(path, body);
      if (options.render !== false) render();
      notice(data.result?.message || data.result?.reason || options.message);
      return data;
    } catch (error) {
      if (options.throw) throw error;
      notice(error.message, "error");
      return null;
    }
  }
  const formBody = form => Object.fromEntries(new FormData(form));
  function focusedControl() {
    const control = document.activeElement;
    if (!control || control === document.body || editor.contains(control)) return null;
    for (const name of ["id","data-go","data-action","data-health-action","data-fp-action","name"]) {
      const value = control.getAttribute(name);
      if (!value) continue;
      const detail = control.getAttribute("data-value") || control.getAttribute("data-fp-value");
      const key = control.hasAttribute("data-value") ? "data-value" : "data-fp-value";
      const region = control.closest("#workspaces,.subtabs,#rail-actions,#toolbar,main");
      const prefix = region?.id ? "#"+CSS.escape(region.id)+" " : region?.classList.contains("subtabs") ? ".subtabs " : "";
      return prefix+"["+name+'="'+CSS.escape(value)+'"]'+(detail ? "["+key+'="'+CSS.escape(detail)+'"]' : "");
    }
    return null;
  }
  function restoreControl(selector) {
    if (selector && !editor.open) {
      const control = [...document.querySelectorAll(selector)].find(element => !element.disabled && element.getClientRects().length);
      control?.focus({preventScroll:true});
    }
  }
  let dialogControl;
  function modal(title, html, onSubmit, options = {}) {
    const form = editor.querySelector("form");
    if (!editor.open) dialogControl = focusedControl();
    window.GaoWorld?.releaseWithin(form);
    editor.querySelector("h2").textContent = title;
    editor.querySelector("[data-close]").setAttribute("aria-label",t("关闭","Close"));
    editor.querySelector(".dialog-body").innerHTML = html;
    editor.querySelector(".dialog-error").hidden = true;
    editor.querySelector(".dialog-footer").innerHTML = button(onSubmit ? t("取消","Cancel") : t("关闭","Close"), {action:"close", className:"secondary"}) +
      (onSubmit ? button(options.submitLabel || t("保存", "Save"), {type:"submit", className:options.danger ? "danger" : "primary"}) : "");
    dialogSubmit = onSubmit;
    confirmClose = options.confirmClose;
    editor.dataset.variant = options.className || "";
    if (!editor.open) editor.showModal();
    const first = form.querySelector(".dialog-body :is(input:not([type=hidden]), select, textarea):not([disabled])");
    (first || form.querySelector("[data-close]"))?.focus({preventScroll:true});
    return form;
  }
  const closeModal = () => {
    if (!confirmClose || confirmClose()) editor.close();
  };
  const confirm = (title, details, path, payload) => modal(title, "<p>" + esc(details) + "</p>",
    async () => { await act(path, payload, {throw:true}); }, {danger:true, submitLabel:t("确认","Confirm")});

  async function download(path, filename) {
    try {
      const response = await authorizedFetch(path);
      if (!response.ok) throw new Error(t("导出失败。","Export failed."));
      const url = URL.createObjectURL(await response.blob());
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filename;
      anchor.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (error) { notice(error.message, "error"); }
  }
  function go(nextPage, nextSection) {
    if (!sections[nextPage]) return;
    const oldPage = page, oldSection = section;
    page = nextPage;
    section = nextSection || ({today:"today",playground:"index"}[page] || sections[page][3][0][0]);
    window.EstateUI?.leave?.(oldPage, oldSection, page, section);
    window.HealthUI?.leave?.(oldPage, oldSection, page, section);
    render();
    if (oldPage !== page || oldSection !== section) window.scrollTo(0, 0);
  }
  function route(raw) {
    if (!raw) return;
    let url;
    try { url = new URL(raw); } catch { return; }
    const host = url.hostname.toLowerCase();
    const leadingPath = url.pathname.split("/").filter(Boolean)[0]?.toLowerCase();
    const target = leadingPath || host;
    if (url.protocol === "gaojiankang:" || host === "health") {
      const kind = ["water","sleep","meal","exercise","weight"].includes(target);
      if (["island","game"].includes(target)) go("playground", "island");
      else go("health", kind ? "records-" + target : ["records","events","trends"].includes(target) ? target : "overview");
    } else if (url.protocol === "gaozuji:" || host === "footprints") {
      if (["train","game"].includes(target)) go("playground","train");
      else go("footprints", ["trips","timeline"].includes(target) ? target :
        ["resident-city","residentcity","home"].includes(target) ? "resident" : "map");
    } else if (url.protocol === "gaojiezou:") {
      const rhythm = {longgoals:"goals",shortactions:"actions",focus:"focus",sleep:"sleep",habits:"habits",chores:"chores",statistics:"statistics"};
      if (rhythm[host]) go("rhythm",rhythm[host]);
      else if (["farm","pasture","fishing"].includes(host)) go("playground",host);
      else go("today");
    }
  }
  function menu(glyph, label, actions) {
    return '<details class="menu"><summary class="' + (glyph === "plus" ? "record-button" : "more-button") + '" aria-label="' +
      esc(label) + '">' + icon(glyph) + (glyph === "plus" ? "<span>" + esc(label) + "</span>" : "") +
      '</summary><div class="menu-panel">' + actions + "</div></details>";
  }
  function navButton(id, label, glyph, current, type) {
    return '<button type="button" data-go="' + id + '" class="' + type + (current ? " selected" : "") +
      '"' + (current ? ' aria-current="page"' : "") + ">" + icon(glyph) + "<span>" + localized(label) + "</span></button>";
  }
  function navigation() {
    document.querySelector("#brand-title").textContent = t("搞节奏","Rhythm");
    document.querySelector(".skip").textContent = t("跳至内容","Skip to content");
    document.querySelector("#workspaces").innerHTML = Object.entries(sections).map(([id,[label,glyph]]) =>
      navButton(id,label,glyph,id === page,"nav-link")).join("");
    const settingsButton = button(t("设置","Settings"),{action:"settings",icon:"settings",className:"rail-utility"});
    const widgetsButton = button(t("桌面小组件","Desktop widgets"),{action:"widgets",icon:"grid",className:"rail-utility"});
    document.querySelector("#rail-actions").innerHTML = widgetsButton + settingsButton;
    const active = state.library?.activeFocus || state.library?.activeSleep;
    const currentTimer = state.library?.activeFocus ? "focus" : "sleep";
    const timerTitle = currentTimer==="focus" ? t("专注计时","Focus timer") : t("睡眠计时","Sleep timer");
    const workspace = sections[page];
    document.querySelector("#workspace-context").innerHTML = '<span class="context-icon">'+icon(workspace[1])+'</span><strong>' +
      localized(workspace[0]) + '</strong>' +
      (active && page !== "today" && !(page==="rhythm" && section===currentTimer) ?
        '<button type="button" class="context-timer" data-go="rhythm/'+currentTimer+'" aria-label="'+esc(timerTitle)+'">' +
        icon(currentTimer==="focus"?"timer":"moon")+'<span data-timer="'+currentTimer+'"></span></button>' : "");
    const quick = button(t("工作专注","Focus"),{go:"rhythm/focus",icon:"play"}) +
      button(t("记录睡眠","Log sleep"),{action:"rhythm:sleep-entry",icon:"moon"}) +
      button(t("日常打卡","Habits"),{go:"rhythm/habits",icon:"check"}) +
      button(t("健康记录","Health records"),{go:"health",icon:"heart"}) +
      button(t("记下足迹","Record a visit"),{action:"quick-visit",icon:"map"});
    document.querySelector("#toolbar").innerHTML = (state.status === "ready" ? menu("plus",t("记录","Record"),quick) : "") +
      menu("more",t("更多","More"),'<div class="compact-tools">'+settingsButton+widgetsButton+'</div>'+
        button(t("退出","Quit"),{action:"quit",icon:"right"}));
    const bar = document.querySelector("#subbar");
    bar.hidden = page === "today" || (page === "playground" && section === "index");
    if (bar.hidden) { bar.innerHTML = ""; return; }
    const tabs = [...sections[page][3]];
    if (page === "footprints" && section === "resident") tabs.push(["resident","常驻城市","home"]);
    const trailing = page === "footprints" ? window.FootprintsUI?.actions?.(section) :
      page === "health" ? window.HealthUI?.actions?.(section) : "";
    bar.innerHTML = (page === "playground" ? button(t("乐园"),{go:"playground",icon:"left",className:"plain sub-back"}) : "") +
      '<nav class="subtabs" aria-label="' + localized("工作台栏目","Workspace sections") + '">' + tabs.map(([id,label,glyph]) =>
        navButton(page + "/" + id,label,glyph,section === id || section.startsWith(id + "-"),"tab")).join("") +
      '</nav>'+(trailing ? '<div class="row sub-actions">' + trailing + "</div>" : "");
  }
  function fingerprint() {
    const localClock = state?.clock ? localDay(state.clock) : "";
    return JSON.stringify([state.status,state.notice,state.sleepSyncError,state.library,state.settings,state.health,state.footprints,state.cast,localClock]);
  }
  function render() {
    if (!state) return;
    const focused = focusedControl();
    window.GaoWorld?.releaseWithin(app);
    navigation();
    app.dataset.workspace = page;
    app.dataset.section = section;
    app.removeAttribute("aria-busy");
    if (state.status !== "ready") {
      const fresh = state.status === "missing";
      const title = fresh ? t("创建本机资料库","Create a local library") : t("资料库暂不可用","Library unavailable");
      app.innerHTML = statusPanel(title,state.notice || t("记录将保存在此电脑。","Records are stored on this PC."),fresh ? "list" : "lock",
        fresh ? button(t("创建资料库","Create library"),{action:"create",className:"primary",icon:"plus"}) :
          button(t("重试","Retry"),{action:"retry-load",icon:"clock",className:"secondary"}),!fresh);
    } else {
      let module = window.RhythmUI;
      if (page === "footprints" || section === "train") module = window.FootprintsUI;
      else if (page === "health" || section === "island") module = window.HealthUI;
      else if (page === "playground") module = window.EstateUI;
      const integrated = module === window.HealthUI || module === window.FootprintsUI;
      const content = module?.render(section) || empty(t("该页面暂不可用。","This page is unavailable."));
      app.innerHTML = (state.notice ? '<aside class="workspace-warning">' + esc(state.notice) + "</aside>" : "") +
        (integrated ? '<div class="integrated-workspace">' + content + "</div>" : content);
      module?.bind?.(section);
      tick();
    }
    restoreControl(focused);
    previousData = fingerprint();
  }
  function statusPanel(title, description, glyph, action, error = false) {
    return '<div class="workspace"><section class="status-panel" role="'+(error?"alert":"status")+'"><span class="glyph">'+icon(glyph)+
      "</span><h1>"+esc(title)+"</h1><p class=\"muted\">"+esc(description)+'</p><div class="row">'+action+"</div></section></div>";
  }
  function tick() {
    window.RhythmUI?.tick?.();
    window.EstateUI?.tick?.();
    window.FootprintsUI?.tick?.();
  }
  async function refresh({onlyChange = false} = {}) {
    if (pending) return;
    await api("/api/state");
    if (!state) return;
    if (!onlyChange || (fingerprint() !== previousData && !editor.open &&
      !document.querySelector("details[open], main :is(input,textarea,select):focus"))) render();
    else tick();
  }
  function baseColor(appearance) {
    return appearance === "dark" || (appearance === "system" && matchMedia("(prefers-color-scheme: dark)").matches)
      ? "#111815" : "#f3f5f3";
  }
  function settings() {
    const p = state.settings;
    background = p.backgroundHex;
    const labels = [["focus","专注 CSV","Focus CSV"],["sleep","睡眠 CSV","Sleep CSV"],["habits","打卡 CSV","Habit CSV"]];
    const body = '<div class="settings-grid"><section class="settings-section"><h3>' + icon("settings") + localized("外观与语言","Appearance and language") + '</h3><div class="form-grid">' +
      select("appearance",t("界面模式"),[["system",t("跟随系统")],["light",t("浅色")],["dark",t("深色")]],p.appearance) +
      select("language",t("语言","Language"),[["zh-Hans","简体中文"],["en","English"]],p.language) + '</div><div class="row">' +
      input("backgroundHex",t("背景颜色"),p.backgroundHex || baseColor(p.appearance),{type:"color"}) +
      button(t("恢复系统颜色"),{action:"reset-color",className:"secondary"}) + '</div></section><section class="settings-section"><h3>' +
      icon("clock") + localized("计时与提醒","Timers and reminders") + '</h3><div class="form-grid">' +
      input("sleepTargetHours",t("睡眠目标（小时）","Sleep target (hours)"),p.sleepTargetHours,{type:"number",min:5,max:12,step:.5,required:true}) +
      input("reminderTime",t("提醒时间"),[p.habitReminderHour,p.habitReminderMinute || 0].map(n => String(n).padStart(2,"0")).join(":"),{type:"time",required:true}) +
      '</div>' + checkbox("habitReminderEnabled",t("每日打卡提醒"),p.habitReminderEnabled) +
      '</section><section class="settings-section settings-data"><h3>' + icon("list") + localized("资料与版本","Data and version") +
      '</h3><dl><div><dt>'+localized("资料路径","Data location")+'</dt><dd><code>%APPDATA%\\GaoSeries\\Rhythm</code></dd></div><div><dt>'+
      localized("版本","Version")+'</dt><dd>Windows '+esc(state.version)+'</dd></div></dl><div class="row">' + labels.map(([key,zh,en]) =>
        button(t(zh,en),{action:"csv:" + key,icon:"download",className:"secondary",disabled:state.status !== "ready"})).join("") +
      button(t("导出诊断信息","Export diagnostics"),{action:"diagnostics",icon:"download",className:"secondary"}) + "</div></section></div>";
    const form = modal(t("设置"),body,async data => {
      const [hour,minute] = data.reminderTime.split(":").map(Number);
      await act("/api/settings",{...data,habitReminderEnabled:data.habitReminderEnabled === "on",
        habitReminderHour:hour,habitReminderMinute:minute,backgroundHex:background},{throw:true});
    },{className:"workbench-settings"});
    form.elements.backgroundHex.addEventListener("input",event => { background = event.target.value; });
    form.elements.appearance.addEventListener("change",event => {
      if (!background) form.elements.backgroundHex.value = baseColor(event.target.value);
    });
  }
  function closeMenus() {
    document.querySelectorAll(".menu[open]").forEach(menu => { menu.open = false; });
  }

  window.Gao = {
    get state() { return state; }, get page() { return page; }, get section() { return section; },
    sections,t,esc,localized,locale,icon,button,card,header,rows,item,tile,empty,date,localDay,fromCocoa,duration,currentClock,
    input,select,textarea,checkbox,authorizedFetch,api,act,refresh,render,go,modal,closeModal,confirm,notice,formBody,download
  };
  editor.addEventListener("click",event => {
    if ((event.target === editor || event.target.closest("[data-close]")) && !editor.querySelector("form").dataset.saving) closeModal();
  });
  editor.addEventListener("close", () => {
    window.GaoWorld?.releaseWithin(editor);
    restoreControl(dialogControl);
  });
  editor.addEventListener("cancel",event => {
    event.preventDefault();
    if (!editor.querySelector("form").dataset.saving) closeModal();
  });
  editor.querySelector("form").addEventListener("input",() => {
    editor.querySelector(".dialog-error").hidden = true;
  });
  editor.querySelector("form").addEventListener("submit",async event => {
    event.preventDefault();
    const form = event.currentTarget;
    if (!dialogSubmit || form.dataset.saving) return;
    const submit = form.querySelector("[type=submit]");
    const message = form.querySelector(".dialog-error");
    const caption = submit.textContent;
    form.dataset.saving = "true";
    form.setAttribute("aria-busy","true");
    message.hidden = true;
    submit.disabled = true;
    submit.textContent = t("处理中…","Working…");
    try {
      if (await dialogSubmit(formBody(form),form) !== false) editor.close();
    } catch (error) {
      message.hidden = false;
      message.textContent = error.message;
    } finally {
      delete form.dataset.saving;
      form.removeAttribute("aria-busy");
      submit.disabled = false;
      submit.textContent = caption;
    }
  });
  document.addEventListener("click",async event => {
    const target = event.target.closest("button");
    if (!event.target.closest(".menu") || target) closeMenus();
    if (!target?.matches("[data-go],[data-action]")) return;
    if (target.dataset.go) {
      go(...target.dataset.go.split("/"));
      if (event.detail === 0 && !target.closest(".workspaces,.subtabs")) app.focus({preventScroll:true});
      return;
    }
    const action = target.dataset.action;
    if (action === "close" && !editor.querySelector("form").dataset.saving) closeModal();
    if (action === "create") await act("/api/library/create");
    if (action === "settings") settings();
    if (action === "quick-visit" && state?.status==="ready") {
      go("footprints","map");
      window.FootprintsUI?.openVisit?.();
    }
    if (action === "retry-load") bootstrap();
    if (action === "widgets") await act("/api/platform/widgets",{},{render:false});
    if (action === "diagnostics") await download("/api/export/diagnostics.txt","Rhythm-diagnostics.txt");
    if (action === "quit") modal(t("退出搞节奏？","Quit Rhythm?"),"<p>" +
      localized("应用将保存记录并暂停正在运行的专注。","Rhythm will save records and pause any running focus session.") + "</p>",async () => {
        await act("/api/shutdown",{},{throw:true,render:false});
        finishExit();
      },{submitLabel:t("退出","Quit")});
    if (action === "reset-color") {
      background = "";
      const fields = editor.querySelector("form").elements;
      fields.backgroundHex.value = baseColor(fields.appearance.value);
    }
    if (action.startsWith("csv:")) {
      const key = action.split(":")[1];
      const filenames = {focus:"focus-records.csv",sleep:"sleep-records.csv",habits:"habit-completions.csv"};
      await download("/api/export/" + key + ".csv",filenames[key]);
    }
  });
  document.addEventListener("keydown",event => {
    if (event.key === "Escape" && !editor.open) closeMenus();
    const navigation = event.target.closest?.("#workspaces,.subtabs");
    if (navigation && ["ArrowLeft","ArrowRight","ArrowUp","ArrowDown","Home","End"].includes(event.key)) {
      const entries = [...navigation.querySelectorAll("button")];
      const index = entries.indexOf(event.target);
      if (index >= 0 && entries.length) {
        event.preventDefault();
        const next = event.key === "Home" ? 0 : event.key === "End" ? entries.length - 1 :
          (index + (["ArrowLeft","ArrowUp"].includes(event.key) ? -1 : 1) + entries.length) % entries.length;
        entries[next].focus();
      }
      return;
    }
    if (editor.open || event.altKey || event.metaKey || event.target.closest?.("input,textarea,select,button,a,summary")) return;
    if (event.ctrlKey && /^[0-5]$/.test(event.key)) {
      event.preventDefault();
      go(Object.keys(sections)[Math.max(0,Number(event.key)-1)]);
    } else if (event.code === "Space" && page === "rhythm" && section === "focus") {
      event.preventDefault();
      app.querySelector("[data-focus-shortcut]")?.click();
    }
  });
  let closing = false;
  const poll = setInterval(() => {
    if (!document.hidden) refresh({onlyChange:true}).catch(() => {});
  },5000);
  const timer = setInterval(tick,125);
  document.addEventListener("visibilitychange",() => {
    if (!closing && !document.hidden) refresh({onlyChange:true}).catch(() => {});
  });
  function finishExit() {
    if (closing) return;
    closing = true;
    clearInterval(poll);
    clearInterval(timer);
    if (editor.open) editor.close();
    document.querySelector(".chrome").hidden = true;
    document.querySelector(".navigation-rail").hidden = true;
    app.innerHTML = empty(t("搞节奏已退出。","Rhythm has quit."));
    window.close();
  }
  async function watchDesktop(serial) {
    while (!closing) {
      try {
        const update = await api("/api/platform/window?after="+serial);
        if (update.exiting) {
          finishExit();
        } else if (update.revision !== serial) {
          serial = update.revision;
          route(update.route);
        }
      } catch {
        if (!closing) await new Promise(resolve => setTimeout(resolve,1000));
      }
    }
  }
  async function bootstrap() {
    try {
      translations = await fetch("/localization/en.json").then(response => response.json()).catch(() => ({}));
      await refresh();
      route(new URLSearchParams(location.search).get("route"));
    } catch (error) {
      app.removeAttribute("aria-busy");
      app.innerHTML = statusPanel(t("无法打开搞节奏","Couldn't open Rhythm"),error.message,"lock",
        button(t("重试","Retry"),{action:"retry-load",icon:"clock",className:"secondary"}),true);
    }
  }
  document.addEventListener("DOMContentLoaded",async () => {
    await bootstrap();
    const desktop = new URLSearchParams(location.search).get("desktop");
    if (desktop !== null && /^\d+$/.test(desktop)) watchDesktop(Number(desktop));
  });
})();
