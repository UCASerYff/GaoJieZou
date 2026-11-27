(function () {
  "use strict";
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const ui = {
    scope: "china", selected: null, country: "", province: "", query: "", year: "", trip: "", trainTrip: "",
    zoom: 1, panX: 0, panY: 0, point: null, atlas: null, atlasPending: null, mapFrame: null,
  };
  const cache = { city: new Map(), photo: new Map() };
  const epoch = 978307200;
  const photoLimit = 20;
  const uploadLimit = 30 * 1024 * 1024;
  const carriageRows = [
    ["sleeper", "▣", "卧铺车", "Sleeper", "每级缩短虚拟巡游等待 2 小时", "Each level shortens the reward cooldown by 2 hours"],
    ["dining", "◈", "餐车", "Dining car", "每级增加巡游获得的 1 份物资", "Each level adds one supply to a cruise"],
    ["observation", "◉", "观景车", "Observation car", "每级增加新城市奖励 1 份物资", "Each level adds one supply for a new city"],
    ["garden", "❋", "花园车", "Garden car", "每级增加新照片奖励 1 份物资", "Each level adds one supply for a new photo"],
    ["library", "▤", "书房车", "Library car", "每级增加回忆文字奖励 1 份物资", "Each level adds one supply for a memory note"],
  ];
  const text = (...args) => window.Gao.t(...args);
  const escape = value => window.Gao.esc(value ?? "");
  const data = () => window.Gao.state?.footprints;
  const action = (key, label, value = "", style = "secondary") =>
    `<button type="button" class="${style}" data-fp-action="${key}" data-fp-value="${escape(value)}">${escape(label)}</button>`;
  const option = (value, label, selected = "") =>
    `<option value="${escape(value)}" ${String(value) === String(selected) ? "selected" : ""}>${escape(label)}</option>`;
  const panel = (title, body, css = "") =>
    `<section class="card fp-panel ${css}">${title ? `<h3>${escape(title)}</h3>` : ""}${body}</section>`;
  const empty = value => `<p class="empty">${escape(value)}</p>`;
  const api = (method, payload) => window.Gao.api(`/api/footprints/${method}`, payload);
  const update = () => window.Gao.render();
  const notice = (message, style) => window.Gao.notice(message, style);
  const showError = error => notice(error.message || String(error), "error");
  const visitKey = visit => (visit.date?.year || 0) * 10000 + (visit.date?.month || 0) * 100 + (visit.date?.day || 0);
  const sortVisits = visits => [...visits].sort((a, b) => visitKey(b) - visitKey(a) || b.createdAt - a.createdAt);
  const cityByID = id => cache.city.get(id);
  const cityName = id => cityByID(id)?.name ?? text("未知地点", "Unknown place");
  const countryName = id => data()?.countries?.find(country => country.id === id)?.name ?? id;
  const cityLocation = city => [countryName(city.countryID), city.province].filter(Boolean).join(" · ");
  const visitDate = visit => {
    const { year, month, day } = visit.date || {};
    if (!year) return text("时间未详", "Date unknown");
    if (!month) return text(`${year} 年`, String(year));
    if (!day) return text(`${year} 年 ${month} 月`, `${year}-${String(month).padStart(2, "0")}`);
    return text(`${year} 年 ${month} 月 ${day} 日`, `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`);
  };
  function rememberCities(places) {
    for (const city of places.filter(Boolean)) cache.city.set(city.id, city);
    return places;
  }
  function mapPlaces() {
    const ids = new Set(data().visits.filter(visit => (!ui.year || Number(ui.year) === visit.date?.year) &&
      (!ui.trip || ui.trip === visit.tripID)).map(visit => visit.cityID));
    return data().plotted.filter(city => ids.has(city.id));
  }
  function numberCards(entries) {
    return `<div class="fp-metrics">${entries.map(([count, label]) =>
      `<div><strong>${escape(count)}</strong><span>${escape(label)}</span></div>`).join("")}</div>`;
  }
  function metricSet(cities) {
    return [
      [cities.filter(city => city.countryID !== "ATA").length, text("座城市", "Cities")],
      [new Set(cities.filter(city => city.countryID !== "ATA").map(city => city.countryID)).size, text("个国家 / 地区", "Countries / regions")],
      [`${cities.filter(city => city.countryID === "CHN").length} / ${data().chinaTotal}`, text("中国城市收集", "Cities in China")],
      [new Set(cities.map(city => city.continent).filter(continent => !["南极洲", "其他", ""].includes(continent))).size, text("个大洲 · 不含南极", "Continents")],
    ];
  }
  function heading(title, subtitle, buttons = "") {
    return `<div class="fp-heading"><div><h2>${escape(title)}</h2><p class="muted">${escape(subtitle)}</p></div>${buttons}</div>`;
  }
  function photoTile(id) {
    return `<button type="button" class="fp-photo" data-fp-action="open-photo" data-fp-value="${escape(id)}" aria-label="${escape(text("查看照片", "View photo"))}"><span aria-hidden="true">▧</span><img alt="" data-fp-photo="${escape(id)}" hidden></button>`;
  }
  function visitRow(visit, withCity = true) {
    const trip = data().trips.find(item => item.id === visit.tripID);
    return `<article class="fp-journal-row">
      <span class="fp-pin" aria-hidden="true">●</span>
      <div class="fp-journal-text">${withCity ? action("city", cityName(visit.cityID), visit.cityID, "fp-text-button") : ""}
        <span class="muted">${escape(visitDate(visit))}${trip ? ` · ${escape(trip.name)}` : ""}</span>
        ${visit.note ? `<p>${escape(visit.note)}</p>` : ""}
        ${visit.photoIDs?.length ? `<div class="fp-photo-strip">${visit.photoIDs.map(photoTile).join("")}</div>` : ""}
      </div>
      <details class="fp-more"><summary aria-label="${escape(text("操作", "Options"))}">···</summary><div>
        ${action("edit-visit", text("编辑足迹", "Edit footprint"), visit.id)}
        ${action("delete-visit", text("删除足迹", "Delete footprint"), visit.id, "danger")}
      </div></details>
    </article>`;
  }
  function mapSide() {
    if (ui.query || ui.country || ui.province) {
      return panel(ui.province || (ui.country ? countryName(ui.country) : text("寻找一个地方", "Find a place")),
        `<div id="fp-map-results" class="fp-city-results" aria-live="polite"></div>
         <p class="muted">${escape(text("显示前 80 个结果", "Showing up to 80 results"))}</p>
         <div class="row">${action("new-place", text("找不到？添加地点", "Add a place"))}
           ${ui.country || ui.province ? action("clear-country", text("关闭区域", "Close region")) : ""}</div>`, "fp-atlas-side");
    }
    const selected = cityByID(ui.selected);
    if (selected) {
      const visits = sortVisits(data().visits.filter(visit => visit.cityID === selected.id));
      const home = data().residentCityID === selected.id;
      return panel("", `<div class="fp-city-heading"><div><h3>${escape(selected.name)}</h3>
        <p class="muted">${escape(cityLocation(selected))}</p></div>${action("clear-city", "×", "", "fp-square")}</div>
        <div class="row">${action("new-visit", text("我去过这里", "I've been here"), selected.id, "primary")}
          ${action("direct-resident", home ? text("清除常驻", "Clear home city") : text("设为常驻", "Set as home"), home ? "" : selected.id)}</div>
        <p class="muted">${escape(`${Number(selected.latitude).toFixed(2)}°, ${Number(selected.longitude).toFixed(2)}°`)}</p>
        ${visits.length ? visits.map(visit => visitRow(visit, false)).join("") : empty(text("尚未留下足迹", "No visits recorded"))}`, "fp-atlas-side");
    }
    const recent = [...data().visits].sort((a, b) => b.createdAt - a.createdAt).slice(0, 4);
    return panel(text("田野笔记", "Field notes"),
      `<h3>${escape(recent.length ? text("每颗图钉，都有一段故事。", "Every pin has a story.") :
        text("第一颗图钉，留给哪里？", "Where will your first pin go?"))}</h3>
       ${recent.length ? recent.map(visit => `<div class="fp-recent">${action("city", cityName(visit.cityID), visit.cityID, "fp-text-button")}
         <span class="muted">${escape(visitDate(visit))}</span></div>`).join("") :
        action("new-visit", text("写下第一个足迹", "Write your first footprint"))}`, "fp-atlas-side");
  }
  function renderMap() {
    const places = mapPlaces();
    const filter = ui.trip ? data().trips.find(trip => trip.id === ui.trip) : null;
    return `<section class="fp-workspace">
      ${heading(text("走过的地方，都算数。", "Every place you’ve been counts."), text("不赶路，不打卡。把记忆，一点一点留在地图上。", "Keep your memories on a map, one at a time."),
      action("new-visit", text("点亮一个地方", "Light up a place"), "", "primary"))}
      ${numberCards(metricSet(places))}
      <div class="fp-map-toolbar">
        <div class="fp-map-scopes" aria-label="${escape(text("地图范围", "Map coverage"))}">
          ${action("scope", text("中国", "China"), "china", ui.scope === "china" ? "active" : "")}
          ${action("scope", text("世界", "World"), "world", ui.scope === "world" ? "active" : "")}
        </div>
        <input id="fp-map-search" type="search" value="${escape(ui.query)}" placeholder="${escape(text("搜索城市、中英文或拼音", "Search by city name or pinyin"))}" aria-label="${escape(text("搜索地点", "Search places"))}">
        <select id="fp-map-year" aria-label="${escape(text("年份", "Year"))}">
          ${option("", text("一生足迹", "All years"), ui.year)}${data().years.map(year => option(year, text(`${year} 年`, String(year)), ui.year)).join("")}
        </select>
        ${filter ? `<span class="fp-chip">${escape(filter.name)}</span>` : ""}
        ${ui.year || ui.trip ? action("clear-filters", text("清除筛选", "Clear filters")) : ""}
        ${action("export", text("导出地图", "Export map"))}
      </div>
      <div class="fp-atlas-grid">
        <div class="fp-map-region">
          <canvas id="fp-atlas" aria-label="${escape(text("足迹离线地图，使用搜索查找地点", "Offline atlas. Use search to find a place."))}"></canvas>
          <div id="fp-map-status" class="fp-map-status" aria-live="polite"></div>
          <div class="fp-map-controls" aria-label="${escape(text("缩放", "Zoom"))}">
            ${action("zoom", "＋", "in", "fp-square")}${action("zoom", "－", "out", "fp-square")}
            <button type="button" data-fp-action="zoom" data-fp-value="reset" class="fp-square" aria-label="${escape(text("重置地图", "Reset map"))}">⌖</button>
          </div>
        </div>
        <aside id="fp-map-side">${mapSide()}</aside>
      </div>
      <p class="fp-map-hint muted">${escape(text("拖动平移 · 滚轮缩放 · 点击区域查看 · 地图资料保存在这台电脑", "Drag to pan · Wheel to zoom · Select a region · Map data stays on this computer"))}</p>
    </section>`;
  }
  function renderTrips() {
    const trips = [...data().trips].sort((a, b) => b.createdAt - a.createdAt);
    return `<section class="fp-workspace">${heading(text("旅行手记", "Travel journals"), text("把同一次走过的地方，整理成一段旅程。", "Group visits from the same journey."),
      action("new-trip", text("新建旅行", "New trip"), "", "primary"))}
      ${trips.length ? trips.map(trip => {
        const visits = sortVisits(data().visits.filter(visit => visit.tripID === trip.id));
        const count = new Set(visits.map(visit => visit.cityID)).size;
        const photo = visits.find(visit => visit.photoIDs?.length)?.photoIDs[0];
        return panel("", `<div class="fp-trip-head">${photo ? photoTile(photo) : `<span class="fp-carriage-icon" aria-hidden="true">▣</span>`}
          <div><h3>${escape(trip.name)}</h3><p class="muted">${escape(text(`${count} 座城市 · ${visits.length} 次到访`, `${count} cities · ${visits.length} visits`))}</p></div>
          <div class="row">${action("edit-trip", text("编辑旅行", "Edit trip"), trip.id)}${action("delete-trip", text("删除旅行", "Delete trip"), trip.id, "danger")}</div></div>
          ${trip.note ? `<p>${escape(trip.note)}</p>` : ""}
          <div class="row">${action("trip-map", text("在地图查看", "View on map"), trip.id)}
            ${action("trip-visit", text("记录到访", "Record a visit"), trip.id)}</div>
          ${visits.length ? visits.map(visit => visitRow(visit)).join("") : empty(text("还没有关联到访", "No linked visits"))}`, "fp-trip");
      }).join("") : panel("", empty(text("你可以为下一段旅程建立一份旅行手记。", "Create a journal for your next trip.")))}
    </section>`;
  }
  function renderTimeline() {
    const groups = new Map();
    for (const visit of sortVisits(data().visits)) {
      const key = visit.date?.year || 0;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(visit);
    }
    const cards = [...groups].map(([year, visits]) => panel(year ? text(`${year} 年`, String(year)) : text("时间未详", "Date unknown"),
      visits.map(visit => visitRow(visit)).join("")));
    return `<section class="fp-workspace">${heading(text("足迹时间轴", "Footprint timeline"), text("按到访时间回顾走过的地方。", "Revisit the places you've been in chronological order."),
      action("new-visit", text("记录到访", "Record visit"), "", "primary"))}
      ${cards.length ? cards.join("") : panel("", empty(text("这里会显示你留下的到访记录。", "Your recorded visits will appear here.")))}</section>`;
  }
  function renderResident() {
    const city = data().residentCity;
    return `<section class="fp-workspace">${heading(text("常驻城市", "Home city"), text("给旅行地图一个常驻参照。", "Give your travel map a home base."))}
      ${panel(city?.name || text("还没有设置常驻城市", "No home city set"),
        `${city ? `<p class="muted">${escape(cityLocation(city))}</p>` : ""}
          <div class="row">${action("resident", city ? text("更换常驻城市", "Change home city") : text("设置常驻城市", "Set home city"), "", "primary")}
          ${city ? `${action("city", text("在地图查看", "View on map"), city.id)}${action("direct-resident", text("清除常驻城市", "Clear home city"))}` : ""}</div>`)}
    </section>`;
  }
  function render(section) {
    if (!data()?.available) return panel("", empty(text("足迹资料库未能打开。", "The footprints library could not be opened.")));
    rememberCities([...data().plotted, ...data().customCities, data().residentCity]);
    return ({ map: renderMap, trips: renderTrips, timeline: renderTimeline, resident: renderResident, train: renderTrain }[section] || renderMap)();
  }
  function actions(section) {
    if (!data()?.available || section === "train") return "";
    return `${action("new-visit", text("点亮一个地方", "Light up a place"), "", "fp-text-button")}
      ${action("resident-page", text("常驻城市", "Home city"), "", "fp-text-button")}
      ${action("settings", text("足迹设置", "Footprint settings"), "", "fp-text-button")}
      ${data().undoAvailable ? action("undo", text("撤销", "Undo"), "", "fp-text-button") : ""}`;
  }
  function renderTrain() {
    const train = data().train;
    const journey = train.journey;
    const moving = journey && !journey.completed;
    const filter = ui.trainTrip ? data().visits.filter(visit => visit.tripID === ui.trainTrip) : data().visits;
    const stations = new Map();
    const orderedVisits = [...filter].sort((a, b) => (visitKey(a) || Infinity) - (visitKey(b) || Infinity) || a.createdAt - b.createdAt);
    for (const visit of orderedVisits) stations.set(visit.cityID, 1 + (stations.get(visit.cityID) || 0));
    const destinations = data().plotted.filter(city => city.id !== train.currentStation?.id);
    const levels = train.carriageLevels || {};
    const order = [...new Set([...(train.carriageOrder || []), ...carriageRows.map(row => row[0])])].filter(key => levels[key]);
    const visualCars = order.map(key => {
      const [, symbol, chinese, english] = carriageRows.find(row => row[0] === key);
      return `<span class="fp-train-car" draggable="true" data-fp-drag="${key}" title="${escape(text(chinese, english))}">${symbol}</span>`;
    });
    const memories = [...new Set(orderedVisits.flatMap(visit => visit.photoIDs || []))].slice(0, 8);
    return `<section class="fp-workspace">
      ${heading(text("旅行列车", "Travel train"), text("真实足迹铺成线路，旅途回忆装满车厢。", "Real visits make routes, and travel memories fill the cars."),
        `<span class="fp-chip">${escape(text(`${train.materials} 旅途物资`, `${train.materials} supplies`))}</span>`)}
      <div class="fp-train-scene"><div class="fp-train-track" aria-hidden="true"></div>
        <div class="fp-train-consist" aria-label="${escape(text("当前车厢", "Current cars"))}"><span class="fp-engine" aria-label="${escape(text("车头", "Engine"))}">◆</span>
        ${visualCars.join("")}</div></div>
      <div class="fp-train-columns">
        ${panel(text("虚拟巡游", "Virtual cruise"), `<p>${escape(text("当前位置", "Current station"))} · ${escape(train.currentStation?.name || "—")}</p>
          ${moving ? `<p class="muted">${escape(journey.origin.name)} → ${escape(journey.destination.name)}</p><progress id="fp-train-progress" max="1" value="0"></progress><p class="muted" id="fp-train-countdown"></p>` :
          `<div class="row"><select id="fp-train-destination" aria-label="${escape(text("巡游目的地", "Cruise destination"))}" ${destinations.length ? "" : "disabled"}>
          ${option("", text("选择下一站", "Choose a station"), train.routeCityID)}${destinations.map(city => option(city.id, city.name, train.routeCityID)).join("")}
          </select><button type="button" class="primary" data-fp-action="depart" ${destinations.length && train.routeCityID ? "" : "disabled"}>${escape(text("发车", "Depart"))}</button></div>`}
          ${!destinations.length && !moving ? empty(text("记录两座到访城市后即可巡游。", "Record two visited cities to start a cruise.")) : ""}`)}
        ${panel(text("旅途图鉴", "Travel collection"), numberCards([[data().plotted.length, text("车站", "Stations")],
          [train.claimedTripIDs?.length || 0, text("旅行册", "Trips")], [train.claimedPhotoIDs?.length || 0, text("照片", "Photos")],
          [train.claimedNoteIDs?.length || 0, text("回忆", "Notes")]]) +
          `<p class="muted">${escape(text(`累计 ${train.lifetimeMaterials} 份物资 · 巡游 ${train.cruiseCount} 次`, `${train.lifetimeMaterials} lifetime supplies · ${train.cruiseCount} cruises`))}</p>`)}
      </div>
      ${journey ? `<div class="fp-map-region fp-train-map"><canvas id="fp-train-atlas" aria-label="${escape(text("巡游路线地图", "Journey route map"))}"></canvas></div>` : ""}
      ${panel(text("沿途车站", "Stations on the route"), `<select id="fp-train-trip" aria-label="${escape(text("旅行线路", "Trip route"))}">
        ${option("", text("全部足迹", "All visits"), ui.trainTrip)}${data().trips.map(trip => option(trip.id, trip.name, ui.trainTrip)).join("")}</select>
        ${stations.size ? `<div class="fp-stations">${[...stations].map(([id, count]) => `<div class="fp-station">${action("city", cityName(id), id, "fp-text-button")}
          <small>${escape(text(`${count} 次到访 · ${Math.min(count, 3)} 级站`, `${count} visits · Level ${Math.min(count, 3)}`))}</small></div>`).join("")}</div>` :
        empty(text("添加第一条足迹后，列车就有第一座车站。", "Add a footprint to unlock your first station."))}`)}
      <h3>${escape(text("列车改装", "Upgrade your train"))}</h3>
      <div class="fp-carriages">${carriageRows.map(([key, symbol, chinese, english, effectCN, effectEN]) => {
        const level = levels[key] || 0;
        const cost = [6, 12, 20, 30][level];
        const slot = order.indexOf(key);
        return panel("", `<div class="fp-carriage-heading"><span class="fp-carriage-icon" aria-hidden="true">${symbol}</span><div><h3>${escape(text(chinese, english))}</h3>
          <span class="muted">${escape(text(`等级 ${level} / 4`, `Level ${level} / 4`))}</span></div></div>
          <progress max="4" value="${level}"></progress><p class="muted">${escape(text(effectCN, effectEN))}</p>
          <div class="row">${level < 4 ? `<button type="button" data-fp-action="upgrade" data-fp-value="${key}" ${train.materials >= cost ? "" : "disabled"}>${escape(text(`升级 · ${cost} 物资`, `Upgrade · ${cost} supplies`))}</button>` :
          `<span class="fp-chip">${escape(text("已满级", "Max level"))}</span>`}
          ${slot > 0 ? action("reorder", text("前移", "Move forward"), `${key}:${slot - 1}`, "fp-text-button") : ""}
          ${slot >= 0 && slot < order.length - 1 ? action("reorder", text("后移", "Move back"), `${key}:${slot + 1}`, "fp-text-button") : ""}</div>`);
      }).join("")}</div>
      ${panel(text("车厢里的回忆", "Memories on board"),
        memories.length ? `<div class="fp-photo-strip">${memories.map(photoTile).join("")}</div>` :
          empty(text("在足迹中添加照片，这里就会出现旅行照片墙。", "Attach photos to visits to fill the carriage photo wall.")), "fp-memory")}
    </section>`;
  }

  let lastTrainPage = false;
  let trainSyncPending = false;
  let lastTrainFrame = 0;

  function bindTrain() {
    const canvas = $("#fp-train-atlas");
    if (!lastTrainPage) {
      lastTrainPage = true;
      syncTrain(true);
    }
    if (canvas) {
      loadAtlas().then(() => {
        if (canvas.isConnected) renderAtlas(canvas, { journey: data().train.journey });
      }).catch(showError);
      ui.mapSize = new ResizeObserver(() => renderAtlas(canvas, { journey: data().train.journey }));
      ui.mapSize.observe(canvas);
    }
    const trip = $("#fp-train-trip");
    if (trip) trip.onchange = () => {
      ui.trainTrip = trip.value;
      update();
    };
    const destination = $("#fp-train-destination");
    if (destination) destination.onchange = () =>
      commit("train/route", { destinationID: destination.value }).catch(showError);
    for (const [slot, car] of $$(".fp-train-car").entries()) {
      car.ondragstart = event => {
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("application/x-gao-carriage", car.dataset.fpDrag);
      };
      car.ondragover = event => {
        if (!event.dataTransfer.types.includes("application/x-gao-carriage")) return;
        event.preventDefault();
        car.classList.add("fp-drag-over");
      };
      car.ondragleave = () => car.classList.remove("fp-drag-over");
      car.ondrop = event => {
        event.preventDefault();
        car.classList.remove("fp-drag-over");
        const carriage = event.dataTransfer.getData("application/x-gao-carriage");
        if (carriage && carriage !== car.dataset.fpDrag) commit("train/reorder", { carriage, slot }).catch(showError);
      };
    }
  }

  async function syncTrain(onOpen = false) {
    if (trainSyncPending) return;
    trainSyncPending = true;
    try {
      const previous = JSON.stringify(data()?.train);
      const result = await api("train/sync", {});
      if ((onOpen && previous !== JSON.stringify(result.state?.footprints?.train)) || result.result) update();
    } catch (error) {
      showError(error);
    } finally {
      trainSyncPending = false;
    }
  }

  function tick() {
    if (window.Gao.section !== "train") {
      lastTrainPage = false;
      return;
    }
    const journey = data()?.train?.journey;
    if (!journey || journey.completed) return;
    const time = Date.now();
    const progress = journeyProgress(journey);
    const meter = $("#fp-train-progress");
    const countdown = $("#fp-train-countdown");
    if (meter) meter.value = progress;
    if (countdown) {
      const remaining = Math.max(0, Math.ceil(journey.arrivesAt - (time / 1000 - epoch)));
      countdown.textContent = escape(text(`剩余 ${Math.floor(remaining / 60)} 分 ${remaining % 60} 秒`,
        `${Math.floor(remaining / 60)}m ${remaining % 60}s remaining`));
    }
    if (time - lastTrainFrame >= 500) {
      lastTrainFrame = time;
      renderAtlas($("#fp-train-atlas"), { journey });
      if (progress >= 1) syncTrain();
    }
  }
  const radians = Math.PI / 180;
  const albersN = (Math.sin(25 * radians) + Math.sin(47 * radians)) / 2;
  const albersC = Math.cos(25 * radians) ** 2 + 2 * albersN * Math.sin(25 * radians);
  const albersRho = phi => Math.sqrt(Math.max(albersC - 2 * albersN * Math.sin(phi), 0)) / albersN;
  const albersRho0 = albersRho(18 * radians);

  function project(lon, lat, scope) {
    if (scope === "china") {
      const rho = albersRho(lat * radians);
      const theta = albersN * (lon - 105) * radians;
      return [rho * Math.sin(theta) * 100, (rho * Math.cos(theta) - albersRho0) * 100];
    }
    const p2 = (lat * radians) ** 2;
    const p4 = p2 * p2;
    return [lon * (0.8707 - 0.131979 * p2 + p4 * (-0.013791 + p4 * (0.003971 * p2 - 0.001529 * p4))),
      -lat * (1.007226 + p2 * (0.015085 + p4 * (-0.044475 + 0.028874 * p2 - 0.005916 * p4)))];
  }

  function unproject(x, y, scope) {
    if (scope === "china") {
      const theta = Math.atan2(x / 100, albersRho0 + y / 100);
      const rho = Math.hypot(x / 100, albersRho0 + y / 100);
      const sinLat = (albersC - (rho * albersN) ** 2) / (2 * albersN);
      return [105 + theta / (albersN * radians), Math.asin(Math.max(-1, Math.min(1, sinLat))) / radians];
    }
    let lower = -90;
    let upper = 90;
    for (let i = 0; i < 30; i++) {
      const lat = (lower + upper) / 2;
      if (project(0, lat, "world")[1] > y) lower = lat;
      else upper = lat;
    }
    const lat = (lower + upper) / 2;
    return [x / project(1, lat, "world")[0], lat];
  }

  function compileBasemap(rows, scope, keepRing = () => true) {
    const bounds = [Infinity, Infinity, -Infinity, -Infinity];
    const regions = [];
    for (const { rings, ...meta } of rows) {
      const path = new Path2D();
      let hasRing = false;
      for (const ring of rings.filter(keepRing)) {
        let previousLon;
        for (const [lon, lat] of ring) {
          const [x, y] = project(lon, lat, scope);
          if (previousLon === undefined || Math.abs(lon - previousLon) > 180) path.moveTo(x, y);
          else path.lineTo(x, y);
          previousLon = lon;
          bounds[0] = Math.min(bounds[0], x);
          bounds[1] = Math.min(bounds[1], y);
          bounds[2] = Math.max(bounds[2], x);
          bounds[3] = Math.max(bounds[3], y);
        }
        if (previousLon !== undefined) {
          path.closePath();
          hasRing = true;
        }
      }
      if (hasRing) regions.push({ ...meta, path });
    }
    return { bounds, regions };
  }

  async function loadAtlas() {
    if (ui.atlas) return ui.atlas;
    if (!ui.atlasPending) {
      ui.atlasPending = fetch("/footprints-atlas.json").then(response => {
        if (!response.ok) throw new Error(text("无法打开离线地图。", "Could not open offline map."));
        return response.json();
      }).then(atlas => {
        const south = compileBasemap(atlas.china, "china", ring => ring.every(([, lat]) => lat <= 20.5));
        if (south.regions.length) {
          for (const [lon, lat] of [[108, 15], [114, 15], [108, 20.5], [114, 20.5]]) {
            const [x, y] = project(lon, lat, "china");
            south.bounds[0] = Math.min(south.bounds[0], x);
            south.bounds[1] = Math.min(south.bounds[1], y);
            south.bounds[2] = Math.max(south.bounds[2], x);
            south.bounds[3] = Math.max(south.bounds[3], y);
          }
        }
        ui.atlas = {
          world: compileBasemap(atlas.world, "world"),
          china: compileBasemap(atlas.china, "china", ring => ring.some(([, lat]) => lat >= 17.8)),
          south,
        };
        return ui.atlas;
      }).finally(() => {
        ui.atlasPending = null;
      });
    }
    return ui.atlasPending;
  }

  function atlasTransform(bounds, width, height, zoom = 1, panX = 0, panY = 0, inset = 40) {
    const [x0, y0, x1, y1] = bounds;
    const scale = Math.min(Math.max(1, width - inset) / (x1 - x0), Math.max(1, height - inset) / (y1 - y0)) * zoom;
    return {
      scale,
      dx: width / 2 - (x0 + x1) / 2 * scale + panX,
      dy: height / 2 - (y0 + y1) / 2 * scale + panY,
    };
  }

  function toPixel([x, y], transform) {
    return [x * transform.scale + transform.dx, y * transform.scale + transform.dy];
  }

  function fromPixel(x, y, transform) {
    return [(x - transform.dx) / transform.scale, (y - transform.dy) / transform.scale];
  }

  function mapPalette(element) {
    const css = getComputedStyle(element);
    return Object.fromEntries(["water", "land", "edge", "visited", "dot", "green", "label", "sheet"].map(key =>
      [key, css.getPropertyValue(`--fp-map-${key}`).trim()]));
  }

  function drawRegions(ctx, map, transform, color, visited, selected, scope) {
    ctx.save();
    ctx.transform(transform.scale, 0, 0, transform.scale, transform.dx, transform.dy);
    ctx.lineWidth = 0.65 / transform.scale;
    ctx.strokeStyle = color.edge;
    for (const region of map.regions) {
      const id = scope === "china" ? region.id : region.countryID;
      ctx.fillStyle = visited.has(id) ? color.visited : color.land;
      ctx.fill(region.path, "evenodd");
      ctx.stroke(region.path);
      if (id === selected) {
        ctx.save();
        ctx.lineWidth = 1.5 / transform.scale;
        ctx.strokeStyle = color.green;
        ctx.stroke(region.path);
        ctx.restore();
      }
    }
    ctx.restore();
  }

  function drawGrid(ctx, scope, transform, color) {
    ctx.save();
    ctx.strokeStyle = color.edge;
    ctx.globalAlpha = 0.25;
    ctx.lineWidth = 0.6;
    const span = scope === "china" ? [70, 138, 15, 55, 10] : [-180, 180, -80, 80, 20];
    const [lonMin, lonMax, latMin, latMax, step] = span;
    for (let lon = lonMin; lon <= lonMax; lon += step) {
      ctx.beginPath();
      for (let lat = latMin; lat <= latMax; lat += 2) {
        const point = toPixel(project(lon, lat, scope), transform);
        if (lat === latMin) ctx.moveTo(...point);
        else ctx.lineTo(...point);
      }
      ctx.stroke();
    }
    for (let lat = latMin; lat <= latMax; lat += step) {
      ctx.beginPath();
      for (let lon = lonMin; lon <= lonMax; lon += 2) {
        const point = toPixel(project(lon, lat, scope), transform);
        if (lon === lonMin) ctx.moveTo(...point);
        else ctx.lineTo(...point);
      }
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawPin(ctx, x, y, city, color, opts = {}) {
    const highlight = city.id === ui.selected;
    const radius = opts.home ? 6 : highlight ? 5 : 3.8;
    ctx.save();
    ctx.beginPath();
    ctx.arc(x, y, radius, 0, 2 * Math.PI);
    ctx.fillStyle = opts.home ? color.green : color.dot;
    if (opts.outline) ctx.strokeStyle = color.dot;
    else ctx.fill();
    ctx.lineWidth = 1.3;
    if (!opts.outline) ctx.strokeStyle = color.sheet;
    ctx.stroke();
    if (opts.home) {
      ctx.fillStyle = color.sheet;
      ctx.beginPath();
      ctx.moveTo(x - 3.5, y);
      ctx.lineTo(x, y - 3.3);
      ctx.lineTo(x + 3.5, y);
      ctx.lineTo(x + 2.4, y);
      ctx.lineTo(x + 2.4, y + 2.8);
      ctx.lineTo(x - 2.4, y + 2.8);
      ctx.lineTo(x - 2.4, y);
      ctx.closePath();
      ctx.fill();
    }
    if (opts.label) {
      ctx.font = "11px 'Segoe UI', sans-serif";
      ctx.lineWidth = 3;
      ctx.strokeStyle = color.sheet;
      ctx.strokeText(city.name, x + 8, y - 5);
      ctx.fillStyle = color.label;
      ctx.fillText(city.name, x + 8, y - 5);
    }
    ctx.restore();
  }

  function journeyProgress(journey) {
    const seconds = Date.now() / 1000 - epoch;
    return Math.max(0, Math.min(1, (seconds - journey.startedAt) / Math.max(1, journey.arrivesAt - journey.startedAt)));
  }

  function journeyPoint(journey, t) {
    const vector = city => {
      const phi = city.latitude * radians;
      const lambda = city.longitude * radians;
      return [Math.cos(phi) * Math.cos(lambda), Math.cos(phi) * Math.sin(lambda), Math.sin(phi)];
    };
    const a = vector(journey.origin);
    const b = vector(journey.destination);
    const angle = Math.acos(Math.max(-1, Math.min(1, a.reduce((sum, value, index) => sum + value * b[index], 0))));
    if (Math.abs(Math.sin(angle)) < 0.000001) {
      const delta = (journey.destination.longitude - journey.origin.longitude + 540) % 360 - 180;
      return [(journey.origin.longitude + delta * t + 540) % 360 - 180,
        journey.origin.latitude + (journey.destination.latitude - journey.origin.latitude) * t];
    }
    const [x, y, z] = a.map((value, index) => (Math.sin((1 - t) * angle) * value + Math.sin(t * angle) * b[index]) / Math.sin(angle));
    return [Math.atan2(y, x) / radians, Math.atan2(z, Math.hypot(x, y)) / radians];
  }

  function drawJourney(ctx, journey, scope, transform, color) {
    ctx.save();
    ctx.strokeStyle = color.green;
    ctx.lineWidth = 2;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    let previousLon;
    for (let step = 0; step <= 100; step++) {
      const [lon, lat] = journeyPoint(journey, step / 100);
      const point = toPixel(project(lon, lat, scope), transform);
      if (previousLon === undefined || Math.abs(lon - previousLon) > 180) ctx.moveTo(...point);
      else ctx.lineTo(...point);
      previousLon = lon;
    }
    ctx.stroke();
    ctx.restore();
    for (const city of [journey.origin, journey.destination]) {
      drawPin(ctx, ...toPixel(project(city.longitude, city.latitude, scope), transform), city, color, { label: true });
    }
    const point = toPixel(project(...journeyPoint(journey, journeyProgress(journey)), scope), transform);
    ctx.fillStyle = color.green;
    ctx.fillRect(point[0] - 5, point[1] - 3, 10, 6);
  }

  function renderAtlas(canvas, settings = {}) {
    if (!canvas || !ui.atlas) return;
    const { journey = null, labels = true, imprint = "", output = false } = settings;
    const scope = journey ? (journey.origin.countryID === "CHN" && journey.destination.countryID === "CHN" ? "china" : "world") : ui.scope;
    const width = output ? 760 : Math.round(canvas.clientWidth);
    const height = output ? 465 : Math.round(canvas.clientHeight);
    if (width < 1 || height < 1) return;
    const ratio = output ? 3 : Math.min(window.devicePixelRatio || 1, 3);
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
    }
    const palette = settings.palette || mapPalette(canvas);
    const ctx = canvas.getContext("2d");
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = palette.water;
    ctx.fillRect(0, 0, width, height);
    ctx.save();
    ctx.fillStyle = palette.label;
    ctx.globalAlpha = 0.08;
    for (let i = 0; i < 1000; i++) ctx.fillRect((i * 7919 % 10007) / 10007 * width, (i * 3571 % 10009) / 10009 * height, 1, 1);
    ctx.restore();
    const atlas = ui.atlas[scope];
    const transform = atlasTransform(atlas.bounds, width, height, journey || output ? 1 : ui.zoom,
      journey || output ? 0 : ui.panX, journey || output ? 0 : ui.panY, width < 450 ? 34 : 58);
    const places = journey ? [] : mapPlaces().filter(city => scope === "world" || city.countryID === "CHN");
    const visited = new Set(places.map(city => scope === "china" ? city.provinceID : city.countryID));
    const selectedRegion = scope === "china" ? atlas.regions.find(region => region.name === ui.province)?.id : ui.country;
    drawGrid(ctx, scope, transform, palette);
    drawRegions(ctx, atlas, transform, palette, visited, selectedRegion, scope);
    const home = data().residentCity;
    const selected = cityByID(ui.selected);
    const pins = places.map(city => ({ city, opts: {} }));
    if (!journey && selected && !pins.some(item => item.city.id === selected.id)) {
      pins.push({ city: selected, opts: { outline: true } });
    }
    if (!journey && home) pins.push({ city: home, opts: { home: true } });
    const mainPins = [];
    for (const { city, opts } of pins) {
      if (scope === "china" && (city.countryID !== "CHN" || city.latitude < 17.8)) continue;
      const [x, y] = toPixel(project(city.longitude, city.latitude, scope), transform);
      drawPin(ctx, x, y, city, palette, { ...opts, label: labels && (places.length < 14 || ui.zoom >= 2 || city.id === ui.selected || opts.home) });
      mainPins.push({ city, x, y });
    }
    let inset;
    if (!journey && scope === "china" && width > 340 && height > 230 && ui.atlas.south.regions.length) {
      const insetWidth = Math.min(132, width * 0.24);
      const x = 12;
      const y = height - 107;
      const h = 82;
      const south = ui.atlas.south;
      const local = atlasTransform(south.bounds, insetWidth, h - 12, 1, x, y + 4, 14);
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, y, insetWidth, h);
      ctx.fillStyle = palette.water;
      ctx.fill();
      ctx.strokeStyle = palette.edge;
      ctx.stroke();
      ctx.clip();
      drawRegions(ctx, south, local, palette, visited, "", scope);
      for (const { city, opts } of pins) {
        if (city.countryID !== "CHN" || city.latitude >= 17.8) continue;
        const [px, py] = toPixel(project(city.longitude, city.latitude, scope), local);
        drawPin(ctx, px, py, city, palette, opts);
        if (px >= x && px <= x + insetWidth && py >= y && py <= y + h) mainPins.push({ city, x: px, y: py });
      }
      ctx.fillStyle = palette.label;
      ctx.font = "9px 'Segoe UI', sans-serif";
      ctx.fillText(text("南部海域", "Southern coastal area"), x + 7, y + h - 7);
      ctx.restore();
      inset = { x, y, width: insetWidth, height: h, transform: local, atlas: south };
    }
    if (journey) drawJourney(ctx, journey, scope, transform, palette);
    ctx.fillStyle = palette.label;
    ctx.font = "19px 'Noto Serif SC', 'SimSun', Georgia, serif";
    const title = journey ? text("巡游线路", "Cruise route") : scope === "china" ? text("神州行记", "China atlas") : text("世界航海志", "World atlas");
    ctx.fillText(output ? text(`我的足迹 · ${title}`, `My footprints · ${title}`) : title, 17, 28);
    ctx.font = "9px 'Segoe UI', sans-serif";
    const allPlaces = output ? mapPlaces() : [];
    const regionCount = new Set(allPlaces.filter(city => city.countryID !== "ATA").map(city => city.countryID)).size;
    const atlasSubtitle = output ? text(`${allPlaces.length} 座城市 · ${regionCount} 个国家 / 地区`, `${allPlaces.length} cities · ${regionCount} countries / regions`) :
      `A PERSONAL ATLAS · ${scope.toUpperCase()}`;
    ctx.fillText(journey ? `${journey.origin.name} → ${journey.destination.name}` : atlasSubtitle, 18, 43);
    ctx.fillStyle = palette.dot;
    ctx.beginPath();
    ctx.arc(18, height - 13, 3, 0, 2 * Math.PI);
    ctx.fill();
    ctx.fillStyle = palette.label;
    ctx.fillText(scope === "china" ? text("去过 · 省级轮廓", "Visited · Provincial outlines") :
      text("去过 · 国家或地区", "Visited · Countries or regions"), 25, height - 10);
    if (imprint) {
      ctx.textAlign = "right";
      ctx.font = "16px 'Segoe UI', sans-serif";
      ctx.fillText(imprint, width - 17, 28, width / 3);
      ctx.textAlign = "left";
    }
    if (!journey && !output) ui.mapFrame = { pins: mainPins, scope, transform, inset, atlas, context: ctx };
  }

  function zoomMap(value) {
    const canvas = $("#fp-atlas");
    if (value === "reset") {
      ui.zoom = 1;
      ui.panX = ui.panY = 0;
    } else {
      const prior = ui.zoom;
      ui.zoom = Math.max(1, Math.min(8, prior * (value === "in" ? 1.4 : 1 / 1.4)));
      if (ui.zoom === 1) ui.panX = ui.panY = 0;
    }
    renderAtlas(canvas);
  }

  function selectMapPoint(x, y) {
    const frame = ui.mapFrame;
    if (!frame) return;
    const { pins, scope, inset } = frame;
    const nearest = [...pins].reverse().find(pin => Math.hypot(pin.x - x, pin.y - y) < 12);
    if (nearest) {
      showCity(nearest.city.id);
      return;
    }
    const inInset = inset && x >= inset.x && x <= inset.x + inset.width && y >= inset.y && y <= inset.y + inset.height;
    const target = inInset ? inset : frame;
    const projected = fromPixel(x, y, target.transform);
    const [lon, lat] = unproject(...projected, scope);
    if (Number.isFinite(lon) && Number.isFinite(lat) && Math.abs(lon) <= 180 && Math.abs(lat) <= 90) ui.point = { lon, lat };
    const ctx = frame.context;
    ctx.save();
    ctx.resetTransform();
    const region = [...target.atlas.regions].reverse().find(item => ctx.isPointInPath(item.path, ...projected, "evenodd"));
    ctx.restore();
    if (region) {
      ui.selected = null;
      ui.query = "";
      ui.country = region.countryID || "CHN";
      ui.province = scope === "china" ? region.name : "";
      const search = $("#fp-map-search");
      if (search) search.value = "";
      refreshMapSide();
      renderAtlas($("#fp-atlas"));
    }
  }

  function bindMap() {
    const canvas = $("#fp-atlas");
    if (!canvas) return;
    const status = $("#fp-map-status");
    let drag;
    canvas.addEventListener("pointerdown", event => {
      if (event.button !== 0) return;
      drag = { x: event.clientX, y: event.clientY, panX: ui.panX, panY: ui.panY, moved: false };
      canvas.setPointerCapture(event.pointerId);
    });
    canvas.addEventListener("pointermove", event => {
      if (!drag) return;
      const dx = event.clientX - drag.x;
      const dy = event.clientY - drag.y;
      drag.moved ||= Math.hypot(dx, dy) > 4;
      if (!drag.moved) return;
      const xMax = canvas.clientWidth * ui.zoom / 2;
      const yMax = canvas.clientHeight * ui.zoom / 2;
      ui.panX = Math.max(-xMax, Math.min(xMax, drag.panX + dx));
      ui.panY = Math.max(-yMax, Math.min(yMax, drag.panY + dy));
      renderAtlas(canvas);
    });
    canvas.addEventListener("pointerup", event => {
      if (drag && !drag.moved) {
        const rect = canvas.getBoundingClientRect();
        selectMapPoint(event.clientX - rect.left, event.clientY - rect.top);
      }
      drag = null;
    });
    canvas.addEventListener("pointercancel", () => { drag = null; });
    canvas.addEventListener("wheel", event => {
      event.preventDefault();
      zoomMap(event.deltaY < 0 ? "in" : "out");
    }, { passive: false });
    ui.mapSize?.disconnect();
    ui.mapSize = new ResizeObserver(() => renderAtlas(canvas));
    ui.mapSize.observe(canvas);
    if (!ui.atlas) status.textContent = text("正在打开离线地图…", "Opening offline map…");
    loadAtlas().then(() => {
      if (!canvas.isConnected) return;
      status.textContent = "";
      renderAtlas(canvas);
    }).catch(error => {
      if (canvas.isConnected) status.textContent = error.message;
    });
  }
  function loaderMessage(element, message) {
    element.textContent = message;
  }

  async function lookup(query, country = "") {
    const params = new URLSearchParams({ q: query });
    if (country) params.set("country", country);
    const response = await window.Gao.api(`/api/cities?${params}`);
    return rememberCities(response.cities || []);
  }

  function cityChoices(container, cities, choose) {
    const visited = new Set(data().plotted.map(city => city.id));
    container.innerHTML = cities.length ? cities.map(city =>
      `<button type="button" class="fp-choice" data-fp-choose="${escape(city.id)}">
        <span><strong>${escape(city.name)}</strong><small>${escape(cityLocation(city))}</small></span>
        ${visited.has(city.id) ? `<span class="fp-choice-visited" title="${escape(text("去过", "Visited"))}">✓</span>` : ""}
      </button>`).join("") : empty(text("没有找到匹配的地点。", "No matching places."));
    for (const button of $$("[data-fp-choose]", container)) button.onclick = () => choose(cityByID(button.dataset.fpChoose));
  }

  function connectSearch(input, results, choose, suggestions = false) {
    let serial = 0;
    let timer;
    input.oninput = () => {
      const current = ++serial;
      clearTimeout(timer);
      const query = input.value.trim();
      if (!query && !suggestions) {
        results.innerHTML = "";
        return;
      }
      timer = setTimeout(async () => {
        try {
          const matches = await lookup(query);
          if (results.isConnected && current === serial) cityChoices(results, matches, choose);
        } catch (error) {
          if (results.isConnected && current === serial) loaderMessage(results, error.message);
        }
      }, 130);
    };
    if (suggestions) input.oninput();
  }

  function downloadBlob(blob, name) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 3000);
  }

  function photoEntry(id) {
    const existing = cache.photo.get(id);
    if (existing) return existing;
    if (cache.photo.size >= 24) {
      const used = new Set($$("img").map(image => image.src));
      for (const [oldID, pending] of cache.photo) {
        pending.then(({ url }) => {
          if (!used.has(url) && !$$("img").some(image => image.src === url)) {
            cache.photo.delete(oldID);
            URL.revokeObjectURL(url);
          }
        }).catch(() => cache.photo.delete(oldID));
        if (cache.photo.size < 24) break;
      }
    }
    const promise = window.Gao.authorizedFetch(`/api/footprints/photo?id=${encodeURIComponent(id)}`).then(async response => {
      if (!response.ok) {
        const failure = await response.json().catch(() => ({}));
        throw new Error(failure.error || text("照片无法读取。", "Could not open the photo."));
      }
      const blob = await response.blob();
      return { blob, url: URL.createObjectURL(blob) };
    }).catch(error => {
      cache.photo.delete(id);
      throw error;
    });
    cache.photo.set(id, promise);
    return promise;
  }

  function bindPhotos(root = document) {
    for (const image of $$("[data-fp-photo]", root)) {
      if (image.dataset.bound) continue;
      image.dataset.bound = "1";
      image.addEventListener("load", () => {
        image.hidden = false;
        if (image.previousElementSibling) image.previousElementSibling.hidden = true;
      });
      photoEntry(image.dataset.fpPhoto).then(({ blob, url }) => {
        if (image.isConnected && blob.type.startsWith("image/")) image.src = url;
      }).catch(() => {});
    }
  }

  async function openPhoto(id) {
    const photo = await photoEntry(id);
    const file = data().attachments.find(item => item.id === id)?.filename || "footprint-photo";
    const form = window.Gao.modal(text("足迹照片", "Footprint photo"), `<div class="fp-photo-preview">
      <p id="fp-photo-fallback" hidden>${escape(text("可下载原文件并使用 Windows 照片查看。", "Download the file to open it in Windows Photos."))}</p>
      <img id="fp-photo-full" alt="${escape(text("足迹附件", "Footprint attachment"))}" hidden>
      <button id="fp-save-original" type="button">${escape(text("下载原照片", "Download original"))}</button></div>`, null,
    { className: "fp-wide-dialog" });
    const image = $("#fp-photo-full", form);
    image.onload = () => { image.hidden = false; };
    image.onerror = () => { $("#fp-photo-fallback", form).hidden = false; };
    if (photo.blob.type.startsWith("image/")) image.src = photo.url;
    else $("#fp-photo-fallback", form).hidden = false;
    $("#fp-save-original", form).onclick = () => downloadBlob(photo.blob, file);
  }

  async function photoPayload(file) {
    if (!file.size || file.size > uploadLimit) throw new Error(text("单张照片必须小于或等于 30 MB。", "Each photo must be 30 MB or smaller."));
    let output = file;
    let filename = file.name;
    let bitmap;
    try {
      bitmap = await createImageBitmap(file);
      const factor = Math.min(1, 2400 / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.floor(bitmap.width * factor));
      canvas.height = Math.max(1, Math.floor(bitmap.height * factor));
      const ctx = canvas.getContext("2d");
      ctx.fillStyle = "#fff";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      for (const quality of [0.88, 0.73, 0.58, 0.43]) {
        output = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", quality));
        if (output && output.size <= 1.7 * 1024 * 1024) break;
      }
      if (!output) throw new Error("JPEG");
      filename = file.name.replace(/\.[^.]+$/, "") + ".jpg";
    } catch {
      if (!/\.(heic|heif)$/i.test(file.name)) {
        throw new Error(text("无法读取此照片，请检查 JPEG、PNG 或 HEIC 文件。", "Could not read this photo. Check the JPEG, PNG or HEIC file."));
      }
      output = file;
      filename = file.name;
    } finally {
      bitmap?.close();
    }
    const contentBase64 = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(",")[1]);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(output);
    });
    return { filename, contentBase64 };
  }

  function chips(group, rows, remove) {
    group.innerHTML = rows.map(({ id, name }) => `<span class="fp-chip">${escape(name)}
      <button type="button" class="fp-text-button" data-fp-remove="${escape(id)}" aria-label="${escape(text("移除", "Remove"))}">×</button></span>`).join("");
    for (const button of $$("[data-fp-remove]", group)) button.onclick = () => remove(button.dataset.fpRemove);
  }

  function openVisit(visit = null, presetCity = "", presetTrip = "") {
    if (!data()?.available) return;
    const selected = new Set([visit?.cityID || presetCity].filter(Boolean));
    const savedPhotos = new Set(visit?.photoIDs || []);
    let photos = [];
    let dirty = false;
    const [input, select, textarea] = [window.Gao.input, window.Gao.select, window.Gao.textarea];
    const date = visit?.date || {};
    const now = new Date();
    const trips = [["", text("不归入旅行", "No trip")], ["new", text("新建旅行", "New trip")],
      ...data().trips.map(trip => [trip.id, trip.name])];
    const title = visit ? text("编辑足迹", "Edit footprint") : text("记录到访", "Record a visit");
    const form = window.Gao.modal(title, `<div class="fp-editor">
      <section class="fp-editor-group"><h3>${escape(text("地点", "Places"))}</h3>
      <input id="fp-editor-search" type="search" placeholder="${escape(text("搜索城市、中英文或拼音", "Search by city name or pinyin"))}">
      <div id="fp-selected-cities" class="row fp-chip-list" aria-live="polite"></div><div id="fp-editor-results" class="fp-city-results"></div></section>
      <section class="fp-editor-group"><h3>${escape(text("到访时间与旅行", "Visit time and trip"))}</h3>
        ${select("precision", text("日期精度", "Date precision"), [
          ["unknown", text("记不清", "Can't recall")], ["year", text("只记得年份", "Year only")],
          ["month", text("记得月份", "Year and month")], ["day", text("具体日期", "Exact date")]], date.precision || "unknown")}
        <div class="fp-form-columns" id="fp-date-fields">
          ${input("year", text("年", "Year"), date.year || now.getFullYear(), { type: "number", min: 1, max: now.getFullYear() })}
          ${input("month", text("月", "Month"), date.month || now.getMonth() + 1, { type: "number", min: 1, max: 12 })}
          ${input("day", text("日", "Day"), date.day || now.getDate(), { type: "number", min: 1, max: 31 })}</div>
        ${select("tripID", text("所属旅行", "Trip"), trips, visit?.tripID || presetTrip)}
        ${input("newTripName", text("旅行名称", "Trip name"), "")}</section>
      <section class="fp-editor-group"><h3>${escape(text("笔记与照片", "Notes and photos"))}</h3>
        ${textarea("note", text("回忆", "Memory"), visit?.note || "")}
        <label>${escape(text("添加照片", "Add photos"))}<input id="fp-new-photos" type="file" accept="image/jpeg,image/png,image/heic,.heic,.heif" multiple></label>
        <p class="muted" id="fp-photo-count"></p><div class="row fp-chip-list" id="fp-photo-chips"></div>
        <div class="fp-photo-strip" id="fp-editor-saved-photos"></div>
        <p class="muted">${escape(text("照片保存在本机。多城市保存时，共享这次笔记与照片。", "Photos stay on this device. Cities recorded together share these notes and photos."))}</p></section>
      </div>`, async values => {
      if (!selected.size) throw new Error(text("请选择至少一个地点。", "Choose at least one place."));
      if (values.tripID === "new" && !values.newTripName?.trim()) throw new Error(text("请填写旅行名称。", "Enter a trip name."));
      const payload = {
        cityIDs: [...selected], date: { precision: values.precision }, note: values.note,
        tripID: values.tripID === "new" ? null : values.tripID || null,
        newTripName: values.tripID === "new" ? values.newTripName : "",
        photoIDs: [...savedPhotos], photos: [],
      };
      if (visit) payload.id = visit.id;
      if (values.precision !== "unknown") payload.date.year = Number(values.year);
      if (["month", "day"].includes(values.precision)) payload.date.month = Number(values.month);
      if (values.precision === "day") payload.date.day = Number(values.day);
      let bytes = 0;
      for (const file of photos) {
        const photo = await photoPayload(file);
        bytes += photo.contentBase64.length;
        if (bytes > 46 * 1024 * 1024) throw new Error(text("所选照片总大小超过单次上传限制。", "The selected photos exceed the upload limit."));
        payload.photos.push(photo);
      }
      try {
        await api("visit", payload);
      } catch (error) {
        if (error.code !== "duplicate" && !error.message.includes("相同城市、日期和旅行")) throw error;
        if (!window.confirm(text("相同城市、日期和旅行已有记录。仍要保存这次到访吗？", "The same city, date and trip already has a record. Save this visit anyway?"))) {
          throw new Error(text("请检查相似足迹。", "Review the similar footprint before saving."));
        }
        await api("visit", { ...payload, allowDuplicate: true });
      }
      dirty = false;
      if (window.Gao.page === "footprints" && window.Gao.section === "map") showCity(payload.cityIDs[0]);
      else update();
      notice(text("足迹已保存", "Footprint saved"));
      playSaveSound();
    }, { className: "fp-wide-dialog", confirmClose: () => !dirty || window.confirm(text("放弃未保存的足迹修改？", "Discard unsaved changes?")) });

    const renderCities = () => chips($("#fp-selected-cities", form),
      [...selected].map(id => ({ id, name: cityName(id) })), id => {
        selected.delete(id);
        dirty = true;
        renderCities();
      });
    const renderPhotos = () => {
      $("#fp-photo-count", form).textContent = text(`照片 ${savedPhotos.size + photos.length} / ${photoLimit}`,
        `Photos ${savedPhotos.size + photos.length} / ${photoLimit}`);
      chips($("#fp-photo-chips", form), [...photos.map((file, index) => ({ id: `new:${index}`, name: file.name })),
        ...[...savedPhotos].map((id, index) => ({ id, name: text(`已保存照片 ${index + 1}`, `Saved photo ${index + 1}`) }))], id => {
        if (id.startsWith("new:")) photos.splice(Number(id.split(":")[1]), 1);
        else savedPhotos.delete(id);
        dirty = true;
        renderPhotos();
      });
      $("#fp-editor-saved-photos", form).innerHTML = [...savedPhotos].map(photoTile).join("");
      bindPhotos(form);
      for (const button of $$('button[data-fp-action="open-photo"]', form)) button.onclick = () => {
        photoEntry(button.dataset.fpValue).then(({ blob }) => {
          const filename = data().attachments.find(item => item.id === button.dataset.fpValue)?.filename || "footprint-photo";
          downloadBlob(blob, filename);
        }).catch(showError);
      };
    };
    const dateFields = () => {
      const precision = form.elements.precision.value;
      const shown = ["year", "month", "day"].indexOf(precision) + 1;
      ["year", "month", "day"].forEach((field, index) => {
        const control = form.elements[field];
        control.closest("label").hidden = index >= shown;
        control.disabled = index >= shown;
        control.required = index < shown;
      });
      const newTrip = form.elements.newTripName;
      const creating = form.elements.tripID.value === "new";
      newTrip.closest("label").hidden = !creating;
      newTrip.disabled = !creating;
      newTrip.required = creating;
    };
    const search = $("#fp-editor-search", form);
    connectSearch(search, $("#fp-editor-results", form), city => {
      if (visit) selected.clear();
      selected.add(city.id);
      dirty = true;
      renderCities();
      search.value = "";
      search.oninput();
    }, true);
    form.elements.precision.onchange = dateFields;
    form.elements.tripID.onchange = dateFields;
    $(".fp-editor", form).oninput = event => {
      if (event.target !== search) dirty = true;
    };
    $("#fp-new-photos", form).onchange = event => {
      const files = [...event.target.files];
      event.target.value = "";
      if (photos.length + savedPhotos.size + files.length > photoLimit) {
        notice(text("每条足迹最多 20 张照片。", "Each footprint allows at most 20 photos."), "error");
        return;
      }
      if (files.some(file => file.size > uploadLimit || !file.size)) {
        notice(text("单张照片必须小于或等于 30 MB。", "Each photo must be 30 MB or smaller."), "error");
        return;
      }
      photos = photos.concat(files);
      dirty = true;
      renderPhotos();
    };
    renderCities();
    renderPhotos();
    dateFields();
  }

  function editTrip(trip = null) {
    const form = window.Gao.modal(trip ? text("编辑旅行", "Edit trip") : text("新建旅行", "New trip"),
      `<div class="fp-editor">${window.Gao.input("name", text("旅行名称", "Trip name"), trip?.name || "", { required: true })}
       ${window.Gao.textarea("note", text("旅行手记", "Travel notes"), trip?.note || "")}</div>`,
      async values => {
        await commit("trip", trip ? { ...values, id: trip.id } : values, text("旅行已保存", "Trip saved"));
      });
    return form;
  }

  function editResident() {
    let choice = data().residentCity;
    const form = window.Gao.modal(text("设置常驻城市", "Set home city"),
      `<div class="fp-editor"><input id="fp-resident-search" type="search" placeholder="${escape(text("搜索城市", "Search for a city"))}">
       <p id="fp-resident-choice" aria-live="polite"></p><div id="fp-resident-results" class="fp-city-results"></div></div>`,
      async () => {
        if (!choice) throw new Error(text("请选择一个地点。", "Choose a place."));
        await commit("resident", { cityID: choice.id }, text("常驻城市已更新", "Home city updated"));
      });
    const showChoice = () => { $("#fp-resident-choice", form).textContent = choice ? `${choice.name} · ${cityLocation(choice)}` : ""; };
    connectSearch($("#fp-resident-search", form), $("#fp-resident-results", form), city => {
      choice = city;
      showChoice();
    }, true);
    showChoice();
  }

  function editCustomPlace() {
    const countries = data().countries.map(country => [country.id, text(country.name, country.english)]);
    const point = ui.point;
    const form = window.Gao.modal(text("添加自定义地点", "Add a custom place"), `<div class="fp-editor">
      ${window.Gao.input("name", text("地点名称", "Place name"), "", { required: true })}
      ${window.Gao.select("countryID", text("国家 / 地区", "Country or region"), countries, ui.country || "CHN")}
      ${window.Gao.input("province", text("省或州", "Province or state"), ui.province)}
      <div class="fp-form-columns">${window.Gao.input("longitude", text("经度", "Longitude"), point?.lon.toFixed(5) || "", { type: "number", step: "any", min: -180, max: 180, required: true })}
      ${window.Gao.input("latitude", text("纬度", "Latitude"), point?.lat.toFixed(5) || "", { type: "number", step: "any", min: -90, max: 90, required: true })}</div>
      <p class="muted">${escape(text("点击地图可带入那个位置的经纬度。", "Select a point on the atlas to fill in its coordinates."))}</p></div>`,
      async values => {
        const response = await api("city", values);
        rememberCities([response.result]);
        showCity(response.result.id);
      });
    return form;
  }

  async function exportMap() {
    const current = $("#fp-atlas");
    if (!current) return;
    await loadAtlas();
    const palette = mapPalette(current);
    const draw = canvas => renderAtlas(canvas, { output: true, palette, labels: form.elements.labels.checked,
      imprint: form.elements.imprint.checked ? data().preferences?.ownerName || "" : "" });
    const form = window.Gao.modal(text("导出这张地图", "Export this atlas"),
      `<div class="fp-editor fp-export"><canvas id="fp-export-map" aria-label="${escape(text("地图预览", "Map preview"))}"></canvas><div class="row">
        ${window.Gao.checkbox("labels", text("显示城市名称", "Show city names"), false)}
        ${window.Gao.checkbox("imprint", text("显示个人铭牌", "Show personal nameplate"), false)}
        <span class="muted">PNG · 2280 × 1395</span></div></div>`,
      async () => {
        const canvas = document.createElement("canvas");
        draw(canvas);
        const file = await new Promise(resolve => canvas.toBlob(resolve, "image/png"));
        if (!file) throw new Error(text("无法导出地图。", "Could not export the atlas."));
        downloadBlob(file, `GaoJieZou-${ui.scope}.png`);
      }, { submitLabel: text("保存 PNG", "Save PNG"), className: "fp-wide-dialog" });
    const canvas = $("#fp-export-map", form);
    draw(canvas);
    $(".fp-export", form).onchange = () => draw(canvas);
  }

  function playSaveSound() {
    if (!data().preferences?.soundEnabled || !window.AudioContext) return;
    try {
      const audio = new AudioContext();
      const tone = audio.createOscillator();
      const volume = audio.createGain();
      const now = audio.currentTime;
      tone.frequency.setValueAtTime(530, now);
      tone.frequency.exponentialRampToValueAtTime(310, now + 0.1);
      volume.gain.setValueAtTime(0.08, now);
      volume.gain.exponentialRampToValueAtTime(0.001, now + 0.13);
      tone.connect(volume).connect(audio.destination);
      tone.onended = () => audio.close();
      tone.start(now);
      tone.stop(now + 0.14);
    } catch {}
  }

  function openSettings() {
    const gao = window.Gao;
    const prefs = data()?.preferences;
    if (!prefs) return;
    const form = gao.modal(text("足迹设置", "Footprint settings"), `<div class="fp-editor">
      <section class="fp-editor-group"><h3>${escape(text("个人与外观", "Personal and appearance"))}</h3>
        ${gao.input("ownerName", text("地图铭牌", "Map nameplate"), prefs.ownerName, { maxlength: 100 })}
        ${gao.checkbox("soundEnabled", text("保存时播放轻音效", "Play a soft sound on save"), prefs.soundEnabled)}
        ${gao.checkbox("animationEnabled", text("界面过渡动画", "Interface transitions"), prefs.animationEnabled)}
      </section>
      <section class="fp-editor-group"><h3>${escape(text("足迹资料", "Footprint data"))}</h3>
        <p class="muted">${escape(text(`${data().visits.length} 条足迹 · ${data().trips.length} 次旅行 · ${data().attachments.length} 张照片副本`,
          `${data().visits.length} footprints · ${data().trips.length} trips · ${data().attachments.length} photo copies`))}</p>
        <div class="row"><button type="button" id="fp-export-csv">${escape(text("导出 CSV", "Export CSV"))}</button>
          <button type="button" id="fp-export-json">${escape(text("导出 JSON", "Export JSON"))}</button></div>
      </section>
      <section class="fp-editor-group"><h3>${escape(text("地图与统计口径", "Map and statistics"))}</h3>
        <p class="muted">${escape(text(`内置 ${data().chinaTotal} 个中国城市收集单元，南极不参与城市、国家与大洲计数。`,
          `${data().chinaTotal} built-in China city collection units. Antarctica is excluded from city, country and continent counts.`))}</p>
        <details id="fp-source-details"><summary>${escape(text("地图来源与许可", "Map sources and licenses"))}</summary><pre class="fp-license"></pre></details>
      </section></div>`, async values => {
      await commit("preferences", { ownerName: values.ownerName, soundEnabled: values.soundEnabled === "on",
        animationEnabled: values.animationEnabled === "on" }, text("足迹设置已保存", "Footprint settings saved"));
    });
    $("#fp-export-csv", form).onclick = () => gao.download("/api/export/footprints.csv", text("足迹记录.csv", "Footprints.csv"));
    $("#fp-export-json", form).onclick = () => gao.download("/api/export/footprints.json", text("足迹记录.json", "Footprints.json"));
    const details = $("#fp-source-details", form);
    details.ontoggle = async () => {
      const content = $("pre", details);
      if (!details.open || content.textContent) return;
      try {
        const response = await fetch("/THIRD_PARTY_NOTICES.txt");
        if (!response.ok) throw new Error(text("无法读取许可说明。", "Could not read licenses."));
        content.textContent = await response.text();
      } catch (error) {
        content.textContent = error.message;
      }
    };
  }
  async function commit(method, payload, message) {
    const response = await api(method, payload);
    update();
    if (message) notice(message);
    return response.result;
  }

  function showCity(id) {
    const city = cityByID(id);
    if (!city) return;
    const scope = city.countryID === "CHN" ? "china" : "world";
    if (scope !== ui.scope) {
      ui.zoom = 1;
      ui.panX = ui.panY = 0;
    }
    ui.scope = scope;
    ui.selected = id;
    ui.query = ui.country = ui.province = "";
    window.Gao.go("footprints", "map");
  }

  let mapSearchSerial = 0;
  let mapSearchTimer;

  function refreshMapSide() {
    const side = $("#fp-map-side");
    if (!side) return;
    side.innerHTML = mapSide();
    bindButtons(side);
    bindPhotos(side);
    const results = $("#fp-map-results", side);
    const serial = ++mapSearchSerial;
    clearTimeout(mapSearchTimer);
    if (!results) return;
    const query = ui.query || ui.province;
    const country = ui.country;
    mapSearchTimer = setTimeout(async () => {
      try {
        let choices = await lookup(query, country);
        if (ui.province) choices = choices.filter(city => city.province === ui.province);
        if (results.isConnected && serial === mapSearchSerial) cityChoices(results, choices, city => showCity(city.id));
      } catch (error) {
        if (results.isConnected && serial === mapSearchSerial) loaderMessage(results, error.message);
      }
    }, ui.query ? 130 : 0);
  }

  function changeScope(scope) {
    if (scope === ui.scope) return;
    ui.scope = scope;
    ui.country = ui.province = "";
    ui.zoom = 1;
    ui.panX = ui.panY = 0;
    update();
  }

  function bindButtons(root = document) {
    for (const button of $$("[data-fp-action]", root)) {
      if (root === document && button.closest("#editor")) continue;
      button.onclick = async () => {
        const { fpAction: key, fpValue: value = "" } = button.dataset;
        const gao = window.Gao;
        try {
          switch (key) {
            case "scope": changeScope(value); break;
            case "zoom": zoomMap(value); break;
            case "search": search(); break;
            case "city": showCity(value); break;
            case "clear-city": ui.selected = null; refreshMapSide(); renderAtlas($("#fp-atlas")); break;
            case "clear-country":
              ui.country = ui.province = "";
              refreshMapSide();
              renderAtlas($("#fp-atlas"));
              break;
            case "clear-filters": ui.year = ui.trip = ""; update(); break;
            case "new-place": editCustomPlace(); break;
            case "new-visit": openVisit(null, value); break;
            case "edit-visit": {
              const visit = data().visits.find(item => item.id === value);
              if (visit) openVisit(visit);
              break;
            }
            case "delete-visit":
              gao.confirm(text("删除足迹？", "Delete footprint?"),
                text("本次到访将被移除，之后可撤销。", "This visit will be removed. You can undo afterwards."),
                "/api/footprints/visit/delete", { id: value });
              break;
            case "new-trip": editTrip(); break;
            case "edit-trip": {
              const trip = data().trips.find(item => item.id === value);
              if (trip) editTrip(trip);
              break;
            }
            case "delete-trip":
              gao.confirm(text("删除这次旅行？", "Delete this trip?"),
                text("只移除旅行分组，全部足迹与照片仍保留。", "Only the trip group will be removed. Footprints and photos are kept."),
                "/api/footprints/trip/delete", { id: value });
              break;
            case "trip-map": ui.trip = value; ui.year = ""; gao.go("footprints", "map"); break;
            case "trip-visit": openVisit(null, "", value); break;
            case "resident-page": gao.go("footprints", "resident"); break;
            case "resident": editResident(); break;
            case "settings": openSettings(); break;
            case "direct-resident":
              await commit("resident", { cityID: value || null }, value ? text("常驻城市已更新", "Home city updated") :
                text("已清除常驻城市", "Home city cleared"));
              break;
            case "open-photo": await openPhoto(value); break;
            case "export": await exportMap(); break;
            case "undo": await commit("undo", {}, text("已撤销上一次足迹修改", "Last footprint change undone")); break;
            case "depart": {
              const target = $("#fp-train-destination")?.value;
              if (target) {
                const result = await commit("train/depart", { destinationID: target });
                if (!result?.departed) notice(text("当前无法发车。", "The train cannot depart yet."), "error");
              }
              break;
            }
            case "upgrade": {
              const result = await commit("train/upgrade", { carriage: value });
              if (!result?.upgraded) notice(text("当前无法升级这节车厢。", "This car cannot be upgraded yet."), "error");
              break;
            }
            case "reorder": {
              const [carriage, slot] = value.split(":");
              await commit("train/reorder", { carriage, slot: Number(slot) });
              break;
            }
          }
        } catch (error) {
          showError(error);
        }
      };
    }
  }

  function bind(section) {
    ui.mapSize?.disconnect();
    if (!data()?.available) return;
    const workspace = $(".fp-workspace");
    if (workspace) workspace.dataset.fpMotion = String(Boolean(data().preferences?.animationEnabled));
    if (ui.trip && !data().trips.some(trip => trip.id === ui.trip)) ui.trip = "";
    if (ui.trainTrip && !data().trips.some(trip => trip.id === ui.trainTrip)) ui.trainTrip = "";
    bindButtons();
    bindPhotos();
    if (section === "map") {
      const searchBox = $("#fp-map-search");
      searchBox.oninput = () => { ui.query = searchBox.value.trim(); refreshMapSide(); };
      $("#fp-map-year").onchange = event => { ui.year = event.target.value; update(); };
      refreshMapSide();
      bindMap();
    } else if (section === "train") {
      bindTrain();
    }
  }

  function search() {
    const gao = window.Gao;
    if (gao.page !== "footprints" || gao.section !== "map") gao.go("footprints", "map");
    $("#fp-map-search")?.focus();
  }

  window.FootprintsUI = { render, actions, bind, tick, search, openVisit, openSettings };
})();
