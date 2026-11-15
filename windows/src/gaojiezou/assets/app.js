const token = document.querySelector('meta[name="gao-token"]').content;
const app = document.querySelector("#app");
const workspaces = document.querySelector("#workspaces");
let state = null;
let page = "today";
let sub = "focus";

const pages = [
  ["today", "今天"],
  ["rhythm", "节奏"],
  ["health", "健康"],
  ["footprints", "足迹"],
  ["play", "乐园"],
];

async function api(path, body) {
  const response = await fetch(path, {
    method: body ? "POST" : "GET",
    headers: { "X-Gao-Token": token, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) throw new Error(data.error || "请求失败");
  if (data.state) state = data.state;
  return data.result ?? data;
}

function cocoa(value) {
  return new Date((Number(value) + 978307200) * 1000);
}
function stamp(value) {
  if (value == null) return "";
  return cocoa(value).toLocaleString();
}
function hours(seconds) {
  return (Number(seconds) / 3600).toFixed(2);
}

function renderNav() {
  workspaces.innerHTML = pages.map(([id, name]) =>
    `<button type="button" data-page="${id}" class="${page === id ? "active" : ""}">${name}</button>`
  ).join("");
  workspaces.querySelectorAll("button").forEach((button) => {
    button.onclick = () => { page = button.dataset.page; render(); };
  });
  const theme = state && state.settings ? state.settings.appearance : "system";
  document.body.dataset.theme = theme === "system" ? "" : theme;
}

async function refresh() {
  const response = await fetch("/api/state", { headers: { "X-Gao-Token": token } });
  state = await response.json();
  render();
}

function render() {
  renderNav();
  if (!state || state.status === "missing") {
    app.innerHTML = `<section class="card"><h1>创建我的资料库</h1><p>目录是空的。确认后才会写入 schema 11 的 library.json，以及本机的健康、足迹和共享睡眠库。</p><button class="primary" id="create">创建我的资料库</button></section>`;
    document.querySelector("#create").onclick = () => api("/api/library/create", {}).then(render).catch(showError);
    return;
  }
  if (state.status !== "ready") {
    app.innerHTML = `<section class="card notice"><h1>资料已保护</h1><p>${escapeHtml(state.notice || "未写入。")}</p><p class="muted">原文件保留。这里没有备份、恢复或用空库覆盖的操作。</p></section>`;
    return;
  }
  const views = { today: renderToday, rhythm: renderRhythm, health: renderHealth, footprints: renderFootprints, play: renderPlay };
  app.innerHTML = views[page]();
  bind();
}

function renderToday() {
  const lib = state.library;
  const focus = lib.activeFocus;
  const sleep = lib.activeSleep;
  const health = state.health || {};
  return `<section class="grid">
    <article class="card"><h2>专注</h2><p>${focus ? (focus.segmentStartedAt ? "计时中" : "已暂停") : "未开始"} · ${Math.round(state.elapsedFocus / 60)} 分钟</p><button data-action="/api/focus/start">开始</button></article>
    <article class="card"><h2>睡眠</h2><p>${sleep ? "计时中" : "未开始"}</p><button data-action="/api/sleep/start">开始睡眠</button></article>
    <article class="card"><h2>庄园</h2><p>${lib.coins} 金币 · ${lib.bait} 鱼饵</p></article>
    <article class="card"><h2>健康今日</h2><p>${health.available ? `饮水 ${Math.round(health.water || 0)} / ${health.waterGoal ?? "未设目标"} mL` : "健康库未打开"}</p></article>
  </section>
  <section class="card"><h2>今日打卡</h2>${habitList(new Date())}<p class="muted">${state.settings.habitReminderEnabled ? `提醒时间记为 ${state.settings.habitReminderHour}:00。Windows 不弹系统通知。` : "系统通知未启用。"}</p></section>
  ${state.notice ? `<p class="notice">${escapeHtml(state.notice)}</p>` : ""}`;
}

function renderRhythm() {
  const tabs = [["focus", "专注"], ["sleep", "睡眠"], ["habits", "习惯"], ["chores", "琐事"], ["goals", "目标"], ["stats", "统计"]];
  return `<div class="row">${tabs.map(([id, name]) => `<button data-sub="${id}" class="${sub === id ? "active" : ""}">${name}</button>`).join("")}</div>${rhythmBody()}`;
}

function rhythmBody() {
  const lib = state.library;
  if (sub === "focus") {
    return `<section class="card"><h2>专注</h2><p>已进行 ${Math.round(state.elapsedFocus)} 秒。关闭浏览器不会停止本进程里的计时；点「退出」才会暂停并保存。Windows 收不到锁屏事件，需要时用「系统暂停」。</p>
      <div class="row"><button data-action="/api/focus/start">开始</button><button data-action="/api/focus/pause">暂停</button><button data-post="/api/focus/pause" data-body='{"system":true}'>系统暂停</button><button data-action="/api/focus/resume">继续</button><button data-action="/api/focus/finish">完成</button><button data-action="/api/focus/cancel">取消</button></div>
      <ul>${(lib.focusRecords || []).slice(0, 8).map((row) => `<li>${escapeHtml(row.title)} · ${Math.round(row.durationSeconds / 60)} 分钟 · ${row.earnedCoins} 金币</li>`).join("")}</ul></section>`;
  }
  if (sub === "sleep") {
    return `<section class="card"><h2>睡眠</h2><div class="row"><button data-action="/api/sleep/start">开始</button><button data-action="/api/sleep/finish">结束</button><button data-action="/api/sleep/cancel">取消</button></div>
      <form id="manual-sleep" class="row"><label>哪一晚<input name="night" type="date" required></label><label>分钟<input name="minutes" type="number" min="30" max="1440" value="480"></label><button class="primary">补记</button></form>
      <ul>${(lib.sleepRecords || []).slice(0, 8).map((row) => `<li>${hours(row.durationSeconds)} 小时 · ${row.score} 分 · 牧场 ${row.pastureYield}</li>`).join("")}</ul></section>`;
  }
  if (sub === "habits") {
    return `<section class="card"><h2>习惯</h2><form id="habit-form" class="row"><input name="title" placeholder="打卡名称" required><input name="rewardCoins" type="number" min="1" max="10" value="5"><button class="primary">添加</button></form>${habitList(new Date())}</section>`;
  }
  if (sub === "chores") {
    return `<section class="card"><h2>琐事</h2><form id="chore-form" class="row"><input name="title" placeholder="标题" required><button class="primary">添加</button></form><ul>${(lib.chores || []).map((row) => `<li><button data-post="/api/chores/toggle" data-body='${JSON.stringify({ id: row.id })}'>${row.isCompleted ? "已完成" : "完成"}</button> ${escapeHtml(row.title)} ${row.rewardClaimed ? "· 已领 5 金币" : ""}</li>`).join("")}</ul></section>`;
  }
  if (sub === "goals") {
    return `<section class="card"><h2>长期目标</h2><form id="goal-form" class="row"><input name="title" placeholder="目标" required><button class="primary">添加</button></form><ul>${(lib.longGoals || []).map((row) => `<li>${escapeHtml(row.title)} · ${row.status}</li>`).join("")}</ul>
      <h3>短期行动</h3><form id="action-form" class="row"><input name="title" placeholder="行动" required><input name="estimatedMinutes" type="number" min="1" value="25"><button class="primary">添加</button></form>
      <ul>${(lib.shortActions || []).map((row) => `<li><button data-post="/api/actions/toggle" data-body='${JSON.stringify({ id: row.id })}'>${row.isCompleted ? "撤销完成" : "完成"}</button> ${escapeHtml(row.title)}</li>`).join("")}</ul></section>`;
  }
  return `<section class="card"><h2>统计</h2><p>连续打卡请在今天全部完成已安排项目后累计。导出使用 UTF-8 BOM。</p>
    <div class="row"><a href="#" id="csv-focus">专注 CSV</a><a href="#" id="csv-sleep">睡眠 CSV</a><a href="#" id="csv-habits">打卡 CSV</a></div>
    <p>近 7 条专注：${(lib.focusRecords || []).slice(0, 7).map((row) => Math.round(row.durationSeconds / 60)).join("、") || "无"}</p></section>`;
}

function habitList(day) {
  const lib = state.library;
  const items = (lib.habits || []).map((habit) => {
    const key = `${habit.id}-${day.getFullYear()}-${day.getMonth() + 1}-${day.getDate()}`;
    const done = (lib.habitCompletionKeys || []).includes(key);
    return `<li><button data-post="/api/habits/toggle" data-body='${JSON.stringify({ id: habit.id })}'>${done ? "已打卡" : "打卡"}</button> ${escapeHtml(habit.title)} · ${habit.rewardCoins} 金币</li>`;
  });
  return `<ul>${items.join("")}</ul>`;
}

function renderHealth() {
  const health = state.health;
  if (!health || !health.available) return `<section class="card"><p>健康库没有打开。程序不会在缺失时新建空库。</p></section>`;
  const island = health.island || {};
  const points = (health.trends && health.trends.points) || [];
  const max = Math.max(1, ...points.map((point) => point.water || 0));
  return `<section class="card"><h2>今日</h2><p>饮水 ${Math.round(health.water || 0)} mL · 饮食 ${health.meals || 0} · 运动 ${Math.round(health.exerciseMinutes || 0)} 分钟 · 连续记录 ${health.streak || 0} 天</p>
    <form id="water-form" class="row"><label>喝水 mL<input name="amount" type="number" value="${health.preferences.cup || 250}"></label><button class="primary">记录</button></form></section>
    <section class="card"><h2>近 7 天饮水</h2><div class="bars">${points.map((point) => `<span title="${point.day}" style="height:${Math.max(4, (point.water / max) * 100)}%"></span>`).join("") || "<p>这几天没有饮水记录。</p>"}</div></section>
    <section class="card"><h2>快速事项</h2><div class="row">${(health.eventTypes || []).map((item) => `<button data-event="${item.id}">${escapeHtml(item.name)}</button>`).join("")}</div></section>
    <section class="card"><h2>荒岛</h2><p>水分 ${Math.round(island.water)} · 饱食 ${Math.round(island.food)} · 活力 ${Math.round(island.energy)} · 繁荣 ${island.prosperity}</p>
      <p class="muted">这是计量和采集，不是 SceneKit 场景。</p>
      <div class="row">${(state.catalog.islandActions || []).map((item) => `<button data-post="/api/health/act" data-body='${JSON.stringify({ id: item.id })}'>${escapeHtml(item.name)}</button>`).join("")}</div>
      <div class="row">${(state.catalog.islandRecipes || []).slice(0, 8).map((item) => `<button data-post="/api/health/build" data-body='${JSON.stringify({ id: item.id })}'>${escapeHtml(item.name)}</button>`).join("")}<button data-post="/api/health/supply" data-body="{}">食用干粮</button></div></section>`;
}

function renderFootprints() {
  const data = state.footprints;
  if (!data || !data.available) return `<section class="card"><p>足迹库没有打开。程序不会在缺失时新建空库。</p></section>`;
  const metrics = data.metrics || {};
  return `<section class="card"><h2>到过的城市</h2><p>${metrics.cities || 0} 城 · ${metrics.countries || 0} 国家或地区 · 中国 ${metrics.china || 0}</p>
    <canvas id="map" width="960" height="420"></canvas>
    <form id="city-search" class="row"><input name="q" placeholder="搜索离线城市" required><button>搜索</button></form>
    <div id="city-results"></div>
    <p class="muted">坐标点来自离线城市表。没有 MapKit、在线瓦片和行政区多边形。</p></section>
    <section class="card"><h2>旅行</h2><form id="trip-form" class="row"><input name="name" placeholder="旅行名称" required><button class="primary">添加</button></form>
      <ul>${(data.trips || []).map((trip) => `<li>${escapeHtml(trip.name)}</li>`).join("")}</ul>
      <ul>${(data.visits || []).slice(0, 12).map((visit) => `<li>${escapeHtml(visit.cityID)} · ${(visit.date && visit.date.precision) || "unknown"}</li>`).join("")}</ul></section>
    <section class="card"><h2>旅行列车</h2><p>物资 ${data.train.materials || 0}。物资不换成节奏金币。</p>
      <form id="depart-form" class="row"><input name="destinationID" placeholder="目的地城市 ID"><button>出发</button></form>
      <button data-action="/api/footprints/train/arrive">到达</button></section>`;
}

function renderPlay() {
  const lib = state.library;
  return `<section class="card"><h2>农场</h2><p>${lib.coins} 金币</p><div class="row"><button data-action="/api/farm/buy-plot">买地</button></div>
    ${(lib.farmPlots || []).map((plot) => `<p>田 ${plot.id.slice(0, 8)} · ${plot.cropID || "空"} · 成长 ${Math.round(plot.growthMinutes || 0)}
      <button data-post="/api/farm/plant" data-body='${JSON.stringify({ plotID: plot.id, cropID: "carrot" })}'>种胡萝卜</button>
      <button data-post="/api/farm/water" data-body='${JSON.stringify({ plotID: plot.id })}'>浇水</button>
      <button data-post="/api/farm/harvest" data-body='${JSON.stringify({ plotID: plot.id })}'>收获</button></p>`).join("")}</section>
    <section class="card"><h2>牧场</h2><p>窝位 ${lib.animalShelterCapacity} · 动物 ${(lib.pastureAnimals || []).length}</p>
      <button data-action="/api/pasture/shelter">加窝</button>
      <button data-post="/api/pasture/buy" data-body='{"animalID":"chicken"}'>买母鸡</button>
      <button data-action="/api/pasture/collect">收产物</button></section>
    <section class="card"><h2>渔场</h2><p>鱼饵 ${lib.bait}。抛竿后在咬钩的 5 秒窗口收线才会扣饵。</p>
      <button data-action="/api/fish/cast">抛竿</button>
      <button data-action="/api/fish/reel">收线</button>
      <button data-action="/api/fish/sell">卖掉鱼篓</button>
      <button data-action="/api/fish/aquarium-income">领水族馆</button></section>
    <section class="card"><p class="muted">乐园里的画面是操作面板。Mac 版的贴图场景、菜单栏常驻和 WidgetKit 不在 Windows 上假装运行。</p></section>`;
}

function bind() {
  document.querySelectorAll("[data-sub]").forEach((button) => { button.onclick = () => { sub = button.dataset.sub; render(); }; });
  document.querySelectorAll("[data-action]").forEach((button) => { button.onclick = () => api(button.dataset.action, {}).then(render).catch(showError); });
  document.querySelectorAll("[data-post]").forEach((button) => {
    button.onclick = () => api(button.dataset.post, JSON.parse(button.dataset.body || "{}")).then(render).catch(showError);
  });
  const habit = document.querySelector("#habit-form");
  if (habit) habit.onsubmit = (event) => submit(event, habit, "/api/habits/save");
  const chore = document.querySelector("#chore-form");
  if (chore) chore.onsubmit = (event) => {
    event.preventDefault();
    const today = new Date().toISOString().slice(0, 10);
    api("/api/chores/save", { title: chore.title.value, startDate: today, endDate: today }).then(render).catch(showError);
  };
  const goal = document.querySelector("#goal-form");
  if (goal) goal.onsubmit = (event) => {
    event.preventDefault();
    const today = new Date().toISOString().slice(0, 10);
    api("/api/goals/save", { title: goal.title.value, startDate: today, targetDate: today, status: "active" }).then(render).catch(showError);
  };
  const action = document.querySelector("#action-form");
  if (action) action.onsubmit = (event) => submit(event, action, "/api/actions/save");
  const manual = document.querySelector("#manual-sleep");
  if (manual) manual.onsubmit = (event) => {
    event.preventDefault();
    api("/api/sleep/manual", { night: manual.night.value, minutes: Number(manual.minutes.value) }).then(render).catch(showError);
  };
  const water = document.querySelector("#water-form");
  if (water) water.onsubmit = (event) => {
    event.preventDefault();
    api("/api/health/record", { kind: "water", amount: Number(water.amount.value), title: "喝水", slot: 0, note: "" }).then(render).catch(showError);
  };
  document.querySelectorAll("[data-event]").forEach((button) => {
    button.onclick = () => api("/api/health/event", { typeID: button.dataset.event, count: 1 }).then(render).catch(showError);
  });
  const search = document.querySelector("#city-search");
  if (search) search.onsubmit = async (event) => {
    event.preventDefault();
    const data = await api(`/api/cities?q=${encodeURIComponent(search.q.value)}`);
    document.querySelector("#city-results").innerHTML = (data.cities || []).map((city) =>
      `<button data-city="${city.id}" data-name="${escapeHtml(city.name)}">${escapeHtml(city.name)} ${escapeHtml(city.province || "")}</button>`
    ).join(" ");
    document.querySelectorAll("[data-city]").forEach((button) => {
      button.onclick = () => api("/api/footprints/visit", { cityID: button.dataset.city, date: { precision: "unknown" }, note: "" }).then(render).catch(showError);
    });
  };
  const trip = document.querySelector("#trip-form");
  if (trip) trip.onsubmit = (event) => submit(event, trip, "/api/footprints/trip");
  const depart = document.querySelector("#depart-form");
  if (depart) depart.onsubmit = (event) => {
    event.preventDefault();
    api("/api/footprints/train/depart", { destinationID: depart.destinationID.value }).then(render).catch(showError);
  };
  drawMap();
  ["focus", "sleep", "habits"].forEach((name) => {
    const link = document.querySelector(`#csv-${name}`);
    if (!link) return;
    link.onclick = async (event) => {
      event.preventDefault();
      const response = await fetch(`/api/export/${name}.csv`, { headers: { "X-Gao-Token": token } });
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = `${name}.csv`;
      anchor.click();
    };
  });
}

function drawMap() {
  const canvas = document.querySelector("#map");
  if (!canvas || !state.footprints) return;
  const context = canvas.getContext("2d");
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.strokeStyle = "#9bbfb4";
  context.strokeRect(8, 8, canvas.width - 16, canvas.height - 16);
  (state.footprints.plotted || []).forEach((city) => {
    const x = ((Number(city.longitude) + 180) / 360) * canvas.width;
    const y = ((90 - Number(city.latitude)) / 180) * canvas.height;
    context.fillStyle = "#c46b2d";
    context.beginPath();
    context.arc(x, y, 5, 0, Math.PI * 2);
    context.fill();
    context.fillStyle = "#2a241c";
    context.fillText(city.name, x + 8, y + 4);
  });
}

function submit(event, form, path) {
  event.preventDefault();
  const body = Object.fromEntries(new FormData(form).entries());
  if (body.rewardCoins) body.rewardCoins = Number(body.rewardCoins);
  if (body.estimatedMinutes) body.estimatedMinutes = Number(body.estimatedMinutes);
  api(path, body).then(render).catch(showError);
}

function showError(error) {
  alert(error.message || String(error));
}
function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
}

document.querySelector("#quit").onclick = () => api("/api/shutdown", {}).catch(() => {});
refresh().catch(showError);
