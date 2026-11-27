(() => {
  "use strict";
  const G = window.Gao;
  const {t,localized:L,esc,icon,button,card,header,rows,item,tile,empty,date,localDay,fromCocoa,duration,input,select,textarea,checkbox} = G;
  const lib = () => G.state.library;
  const clock = () => fromCocoa(G.state.clock);
  const day = value => value == null ? "" : localDay(value);
  const today = () => day(clock());
  const format = (cn,en,...args) => {
    let at = 0;
    return t(cn,en).replace(/%(?:@|d|g|(?:\.\d+)?f)/g,() => String(args[at++]));
  };
  const time = value => date(value,{hour:"2-digit",minute:"2-digit"});
  const timestamp = value => date(value,{month:"short",day:"numeric",hour:"2-digit",minute:"2-digit"});
  const inDay = key => new Date(key + "T00:00:00");
  const stepDay = (value,n) => new Date(value.getFullYear(),value.getMonth(),value.getDate()+n);
  const cocoa = value => value.getTime()/1000-978307200;
  const sorted = (values,key) => [...values].sort((a,b) => a[key]-b[key]);
  const complete = (habit,key) => {
    const stored = (habit.id + "-" + key.split("-").map(Number).join("-")).toLowerCase();
    return lib().habitCompletionKeys.some(completion => completion.toLowerCase() === stored);
  };
  const actions = () => [...lib().shortActions].sort((a,b) => (a.startDate ?? a.createdAt)-(b.startDate ?? b.createdAt));
  const getHabit = id => lib().habits.find(row => row.id === id);
  const linked = id => lib().shortActions.find(row => row.id === id);
  const focusTitle = record => linked(record?.linkedActionID)?.title || t("其他事件","Other activity");
  const habitats = () => lib().pastureAnimals;
  const shell = (content,variant = "normal") => '<div class="workspace ' + variant + '">' + content + "</div>";
  const group = content => '<div class="form-grid">' + content + "</div>";
  const badge = (value,color="") => '<span class="mini-badge ' + color + '">' + esc(value) + "</span>";
  const go = (label,target,glyph,className = "plain") => button(t(label),{go:target,icon:glyph,className});
  const cmd = (label,action,glyph,className,disabled) => button(t(label),{action:"rhythm:" + action,icon:glyph,className,disabled});
  const smallCmd = (label,action,glyph,className="plain") => button("",{action:"rhythm:" + action,icon:glyph,className:"icon-only " + className,title:t(label)});
  const glyph = (name,color="") => '<span class="glyph ' + color + '">' + icon(name) + "</span>";
  const score = row => format("%d 分","%d points",row.score ?? Math.max(0,Math.round(100-Math.abs(row.durationSeconds/3600-G.state.settings.sleepTargetHours)*18)));
  const due = () => lib().shortActions.filter(row => !row.isCompleted);
  const planned = (habit,key) => (habit.weekdays || [1,2,3,4,5,6,7]).includes(inDay(key).getDay()+1) && (!habit.createdAt || key >= day(habit.createdAt));
  let calendarOffset = 0, choreOffset = 0, actionFilter = "all", backfillDate, statsPeriod = {};

  function scheduled(key) {
    return lib().habits.filter(habit => planned(habit,key)).sort((a,b) => Number(complete(a,key))-Number(complete(b,key)));
  }
  function countDone(key) { return scheduled(key).filter(habit => complete(habit,key)).length; }

  function focusSeconds(on) {
    const active = lib().activeFocus;
    let total = lib().focusRecords.filter(row => day(row.endedAt) === on).reduce((sum,row) => sum + Number(row.durationSeconds || 0),0);
    if (active) {
      if (day(active.startedAt) === on) total += Number(active.accumulatedSeconds || 0);
      if (active.segmentStartedAt != null) {
        total += Math.max(0,Math.min(G.currentClock(),cocoa(stepDay(inDay(on),1)))-Math.max(active.segmentStartedAt,cocoa(inDay(on))));
      }
    }
    return total;
  }
  function nightSleep(on) {
    const candidates = lib().sleepRecords.filter(row => day(row.endedAt) === on && fromCocoa(row.endedAt).getHours() < 18 &&
      (day(row.startedAt) < on || fromCocoa(row.startedAt).getHours() < 12));
    const health = candidates.filter(row => row.origin === "health" || row.id.toLowerCase().startsWith("health-"));
    return (health.length ? health : candidates).sort((a,b) => b.durationSeconds-a.durationSeconds)[0];
  }

  function habitButton(habit,key,extra = "") {
    const checked = complete(habit,key);
    return '<button type="button" class="plain habit-toggle" aria-pressed="' + checked + '" data-action="rhythm:habit-toggle:' +
      esc(habit.id) + ':' + key + '">' + icon(checked ? "check" : "circle") + icon(habit.symbol) +
      '<span>' + esc(t(habit.title)) + '</span><small class="orange">+' + esc(habit.rewardCoins) + '</small>' + extra + '</button>';
  }
  function actionButton(action) {
    return '<button type="button" class="plain habit-toggle" aria-pressed="' + Boolean(action.isCompleted) +
      '" data-action="rhythm:action-toggle:' + esc(action.id) + '">' + icon(action.isCompleted ? "check" : "circle") +
      '<span>' + esc(t(action.title)) + '</span><small class="teal">🎣 +1</small></button>';
  }

  function todayPage() {
    const focus = lib().activeFocus, sleep = lib().activeSleep;
    const pending = scheduled(today());
    const night = nightSleep(today());
    const crops = lib().farmPlots.filter(row => row.cropID);
    const mature = crops.filter(row => row.growthMinutes >= (G.state.catalog.crops.find(crop => crop.id === row.cropID)?.minutes ?? Infinity));
    const intro = '<div class="stack date-intro"><span class="small muted">' + esc(date(clock(),{month:"long",day:"numeric",weekday:"long"})) +
      "</span><h1>" + L("把今天，过成自己的节奏。","Make today your own rhythm.") + "</h1></div>";
    const label = focus ? t("此刻专注") : sleep ? t("正在睡眠计时") : t("今天的第一小步");
    const description = focus ? focusTitle(focus) : sleep ? t("安心休息，记录会在后台继续") :
      t("一段专注、一次打卡，都是今天真实的痕迹。","A focus session or a check-in leaves a real mark on today.");
    const hero = '<section class="hero"><div class="stack"><small>' + esc(label) + "</small>" +
      (focus || sleep ? '<h2 class="timer-number" data-timer="' + (focus ? "focus" : "sleep") + '"></h2>' :
        "<h2>" + L("从一件小事开始","Start with one small thing") + "</h2>") + '<p class="muted">' + esc(description) + '</p><div class="row">' +
      (focus || sleep ? go("查看计时",focus ? "rhythm/focus" : "rhythm/sleep","clock","clay-button") :
        go("开始专注","rhythm/focus",null,"clay-button") + cmd("记录睡眠","sleep-entry",null,"secondary") + go("今日打卡","rhythm/habits",null,"secondary")) +
      '</div></div><div class="hero-symbol">' + icon(focus ? "timer" : sleep ? "moon" : "leaf") + "</div></section>";
    const stats = '<div class="grid tiles">' +
      tile(countDone(today())+"/"+pending.length,t("今日打卡"),"check","teal") +
      tile(duration(focusSeconds(today())),t("今日专注"),"timer") +
      tile(night ? duration(night.durationSeconds) : "—",t("昨夜睡眠"),"moon","purple") +
      tile(lib().coins,t("庄园金币"),"coin","orange") + "</div>";
    const pair = '<div class="grid two today-pair">' +
      card(t("今日打卡"),rows(pending,habit => habitButton(habit,today()),t("今天没有安排打卡目标。","No habits scheduled today.")),{actions:go("全部","rhythm/habits")}) +
      card(t("下一步行动"),rows(actions().filter(row => !row.isCompleted),actionButton,t("所有短期行动都已完成。","All short actions are complete.")),{actions:go("全部","rhythm/actions")}) + "</div>";
    const health = G.state.health;
    const healthCard = health ? card(t("今日健康","Health today"),'<div class="row health-today">' +
      [[String(health.water || 0)+" mL",t("饮水","Water"),"water"],[health.meals || 0,t("饮食","Meals"),"meals"],
        [duration((health.exerciseMinutes || 0)*60),t("运动","Exercise"),"exercise"],...(!health.hideWeight ? [[health.weight == null ? "—" : health.weight + " kg",t("体重","Weight"),"weight"]] : [])]
        .map(([value,label,symbol]) => '<span class="row">' + glyph(symbol) + '<span><strong>' + esc(value) + '</strong><br><small class="muted">' + esc(label) + "</small></span></span>").join("") +
      "</div>",{actions:go("查看","health")}) : "";
    const estate = card(t("节奏庄园"),"<p class=\"muted\">" + esc(format("%d 块农田生长中 · %d 块可收获 · %d 只牲畜 · 已发现 %d/%d 种鱼",
      "%d planted · %d ready · %d animals · %d/%d fish discovered",crops.length,mature.length,habitats().length,
      Object.keys(lib().fishCaught).length,G.state.catalog.fish.length)) + "</p>",{className:"estate-summary",actions:go("进入农场","playground/farm","leaf","primary")});
    const rewards = lib().rewardEvents.length ? card(t("最近奖励"),rows(lib().rewardEvents.slice(0,4),row =>
      item(t(row.title),t(row.detail),row.coins ? badge("+"+row.coins,"orange") : "",row.symbol))) : "";
    return shell(intro+hero+stats+pair+healthCard+monthCard(false)+estate+rewards,"today-workspace");
  }

  function eventRows(key,justChores) {
    const base = lib().chores.filter(chore => key <= day(chore.endDate) && key >= day(chore.startDate) &&
      (justChores || !chore.isCompleted)).map(chore => [chore.title,chore.colorHex]);
    if (justChores) return base;
    return base.concat(actions().filter(row => !row.isCompleted && day(row.startDate) && key >= day(row.startDate) &&
      key <= day(row.endDate ?? row.startDate)).map(action => [action.title,"#54886e"]));
  }
  function monthCard(justChores) {
    const mode = justChores ? "chores-month" : "month";
    const now = clock();
    const first = new Date(now.getFullYear(),now.getMonth() + (justChores ? choreOffset : calendarOffset),1);
    const cols = Array.from({length:7},(_,i) => '<span class="weekday">' +
      esc(date(new Date(2024,0,7+i),{weekday:"short"})) + "</span>").join("");
    const cells = Array.from({length:Math.ceil((first.getDay() + new Date(first.getFullYear(),first.getMonth()+1,0).getDate())/7)*7},(_,i) => {
      const value = stepDay(first,i-first.getDay());
      if (value.getMonth() !== first.getMonth()) return '<span class="day void" aria-hidden="true"></span>';
      const key = day(value), night = nightSleep(key), done = countDone(key), focused = focusSeconds(key);
      const eventLabels = eventRows(key,justChores).slice(0,4).map(([label,color]) =>
        '<small class="calendar-event" title="' + esc(label) + '" style="--event-color:' + (/^#[0-9a-f]{6}$/i.test(color) ? color : "#54886e") +
        '">' + esc(label) + "</small>").join("");
      const tally = justChores ? "" : [
        done ? "✓ " + done : "",focused ? "◷ " + duration(focused) : "",night ? "☾ " + duration(night.durationSeconds) : ""
      ].filter(Boolean).map(text => "<small>" + esc(text) + "</small>").join("");
      return '<div class="day' + (key === today() ? " current" : "") + '"><b>' + value.getDate() + "</b>" + tally + eventLabels + "</div>";
    }).join("");
    const controls = smallCmd("上个月",mode+":previous","left")+ '<b class="small">' + esc(date(first,{month:"long",year:"numeric"})) +
      "</b>" + smallCmd("下个月",mode+":next","right")+cmd("本月",mode+":reset",null,"plain");
    return card(t(justChores ? "琐事月历" : "月度总览","Monthly overview"),'<div class="month">' + cols + cells + "</div>",{actions:controls,
      subtitle: justChores ? "" : t("打卡 · 专注 · 睡眠 · 琐事 · 短期行动","Habits · focus · sleep · chores · actions")});
  }

  function focusPage() {
    const focus = lib().activeFocus;
    const play = focus?.segmentStartedAt != null;
    const paused = focus ? (focus.pausedForSystem ? '<p class="orange row">' + icon("lock") + L("检测到锁屏或休眠，专注已暂停，解锁后会自动继续") +
      "</p>" : !play ? '<p class="muted">' + L("已手动暂停","Paused manually") + "</p>" : "") : "";
    const shortcut = button(t(focus ? play ? "暂停" : "继续" : "开始专注"),{action:"rhythm:focus-" + (focus ? play ? "pause" : "resume" : "start"),
      icon:play ? "pause" : "play",className:focus ? "secondary" : "primary",disabled:!focus && !!lib().activeSleep}).replace("<button ","<button data-focus-shortcut ");
    const control = focus ? card("",'<div class="session stack">' + glyph(play ? "timer" : "pause") +
      "<h2>" + esc(focusTitle(focus)) + '</h2><strong class="timer-number" data-timer="focus"></strong>' + paused +
      '<div class="row">' + shortcut + cmd("结束并保存","focus-finish","check","primary") + cmd("放弃","focus-cancel",null,"danger") + "</div></div>") :
      card("",'<div class="stack"><div class="session-label">' + glyph("timer") + '<div><h2>' + L("开始一段有效专注") +
      '</h2><p class="muted">' + L("锁屏、熄屏或 Windows 睡眠时自动暂停，返回后自动继续。","Focus pauses while Windows is locked, its display is off, or the system sleeps.") +
      "</p></div></div>" + select("focusAction",t("关联短期行动"),[["",t("其他事件")],...actions().filter(a => !a.isCompleted).map(a => [a.id,t(a.title)])]) +
      '<div class="row spaced"><p class="muted small">' + esc(format("每有效专注 %d 分钟获得 1 金币，每次最多 %d 金币；所有已播种作物同时成长。",
        "Earn 1 coin per %d minutes of focus, up to %d coins per session. Planted crops grow as you focus.",15,20)) + "</p>" + shortcut + "</div></div>");
    const planted = lib().farmPlots.map(plot => [plot,G.state.catalog.crops.find(crop => crop.id === plot.cropID)]).filter(([,crop]) => crop);
    const farm = card(t("专注促进作物生长","Focus grows your crops"),rows(planted,([plot,crop]) =>
      item(t(crop.name),format("%d / %d 分钟","%d / %d min",Math.floor(plot.growthMinutes),crop.minutes),
        '<progress max="' + crop.minutes + '" value="' + Math.min(crop.minutes,plot.growthMinutes) + '"></progress>',"leaf"),
      t("农场里还没有播种的作物。","No crops planted in the farm yet.")),{actions:go("进入农场","playground/farm","leaf")});
    return shell(control+farm+card(t("专注记录"),rows(lib().focusRecords.slice(0,30),row =>
      item(focusTitle(row),timestamp(row.startedAt) + " – " + time(row.endedAt),
        badge(duration(row.durationSeconds))+(row.earnedCoins > 0 ? badge("+"+row.earnedCoins,"orange") : ""),"timer"),
      t("完成第一次专注后，记录会出现在这里。","Your first completed focus session will appear here.")),
    {actions:'<span class="muted small">' + esc(format("共 %d 次","%d sessions",lib().focusRecords.length)) + "</span>"}));
  }

  function sleepPage() {
    const sleep = lib().activeSleep;
    const target = sleep?.targetHours ?? G.state.settings.sleepTargetHours;
    const control = sleep ? card("",'<div class="session stack">' + glyph("moon","purple") +
      '<h2>' + L("正在睡眠计时") + '</h2><strong class="timer-number" data-timer="sleep"></strong><p class="muted">' +
      esc(format("睡眠目标 %.1f 小时","Sleep target %.1f hours",target)) + '</p><div class="row">' +
      cmd("起床并保存","sleep-finish","check","primary")+cmd("放弃","sleep-cancel",null,"danger")+"</div></div>") :
      card("",'<div class="stack"><div class="session-label">' + glyph("moon","purple") + '<div><h2>' +
      L("开始睡眠计时","Start sleep timer") + '</h2><p class="muted">' +
      L("锁屏、熄屏和合盖不会中断睡眠记录") + "</p></div></div>" +
      input("targetHours",t("睡眠目标"),target,{type:"number",min:5,max:12,step:.5}) + '<div class="row">' +
      cmd("开始睡眠","sleep-start","moon","primary",!!lib().activeFocus)+cmd("记录睡眠","sleep-entry","plus","secondary")+"</div></div>");
    const animals = card(t("睡眠带动牧场成长","Sleep grows your pasture"),rows(habitats(),resident => {
      const animal = G.state.catalog.animals.find(spec => spec.id === resident.animalID);
      return item(t(animal?.name || resident.animalID),format("%d 份待收取","%d products ready",resident.pendingProducts || 0),"","paw",{color:"clay"});
    },t("牧场里还没有牲畜。","The pasture has no animals yet.")),{actions:go("进入牧场","playground/pasture","paw")});
    return shell(control + animals + card(t("睡眠记录"),rows(lib().sleepRecords.slice(0,60),row =>
      item(timestamp(row.startedAt) + " – " + timestamp(row.endedAt),row.origin === "health" ? t("来自健康","From Health") : row.manualEntry ?
        t("手动录入","Manual entry") : t("睡眠计时"),badge(duration(row.durationSeconds),"purple")+badge(score(row))+
        smallCmd("删除","sleep-delete:"+row.id,"trash","danger"),"moon",{color:"purple"}),t("暂无睡眠记录","No sleep records")),
      {actions:cmd("记录睡眠","sleep-entry","plus","secondary")}));
  }

  function habitPage() {
    const todayHabits = scheduled(today());
    return shell(header(t("日常打卡"),t("完成每天的小事，积累稳定节奏"),cmd("补打卡","habit-backfill","clock","secondary") +
      cmd("新增打卡","habit-edit","plus","primary")) +
      card(t("今日打卡"),rows(todayHabits,habit => habitButton(habit,today()),t("今天没有安排打卡目标。"))) +
      card(t("打卡目标","Habits"),rows(lib().habits,habit => item(t(habit.title),
        (habit.weekdays || []).map(value => date(new Date(2024,0,6+value),{weekday:"short"})).join(" · "),
        badge("+"+habit.rewardCoins,"orange")+smallCmd("编辑","habit-edit:"+habit.id,"edit")+
        smallCmd("删除","habit-delete:"+habit.id,"trash","danger"),habit.symbol),t("还没有打卡目标。","No habits yet."))));
  }
  function chorePage() {
    return shell(header(t("一些琐事"),format("安排跨天琐事，每完成一项获得 %d 金币","Schedule chores across days. Earn %d coins per completed chore.",5),
      cmd("新增琐事","chore-edit","plus","primary")) + monthCard(true) + card(t("琐事清单","Chore list"),rows(lib().chores,chore =>
      item(chore.title,date(chore.startDate)+(day(chore.startDate) !== day(chore.endDate) ? " – "+date(chore.endDate) : ""),
        smallCmd(chore.isCompleted ? "取消完成" : "完成","chore-toggle:"+chore.id,chore.isCompleted ? "check" : "circle")+
        smallCmd("编辑","chore-edit:"+chore.id,"edit")+smallCmd("删除","chore-delete:"+chore.id,"trash","danger"),"tray"))));
  }

  const statusNames = {planned:["未开始","Planned"],active:["进行中","In progress"],paused:["已暂停","Paused"],completed:["已完成","Completed"]};
  const statusName = id => t(...(statusNames[id] || statusNames.planned));
  function progress(goal) {
    const children = lib().shortActions.filter(row => row.goalID === goal.id);
    const metric = goal.targetValue > 0 ? goal.currentValue / goal.targetValue : 0;
    const actionsRatio = children.length ? children.filter(row => row.isCompleted).length / children.length : 0;
    return Math.round(Math.min(1,Math.max(0,metric,actionsRatio))*100);
  }
  function timeline(title,entries,first,last) {
    const span = Math.max(1,last-first);
    const records = entries.map(row => {
      const start = Math.max(first,row.start), end = Math.min(last,row.end);
      if (start > end) return "";
      const left = Math.max(0,100*(start-first)/span);
      const width = Math.max(1,100*(end-start)/span);
      return '<div class="timeline-row"><span title="' + esc(row.title) + '">' + esc(row.title) +
        '</span><div class="timeline-track"><i class="' + esc(row.status || "active") + '" style="--left:' + left + "%;--width:"+
        Math.min(100-left,width) + '%" title="' + esc(date(start)+" – "+date(end)) + '"></i></div></div>';
    }).filter(Boolean).join("");
    return '<div class="timeline-block"><div class="row spaced"><strong>' + esc(title) +
      '</strong><span class="muted small">' + esc(date(first)+" – "+date(last)) + "</span></div>" +
      (records || empty(t("此时间段没有安排。","Nothing scheduled in this period."))) + "</div>";
  }
  function goalPage() {
    const goals = [...lib().longGoals].sort((a,b) => Number(a.status === "completed")-Number(b.status === "completed") || a.targetDate-b.targetDate);
    const yearItems = new Set();
    for (const goal of goals) {
      const first = fromCocoa(goal.startDate).getFullYear(), end = fromCocoa(goal.targetDate).getFullYear();
      for (let year=first; year <= end && year-first < 100; year++) yearItems.add(year);
    }
    const charts = [...yearItems].sort((a,b) => a-b).map(year => timeline(String(year),goals.map(goal =>
      ({title:goal.title,start:goal.startDate,end:goal.targetDate,status:goal.status})),
      cocoa(new Date(year,0,1)),cocoa(new Date(year,11,31,23,59,59)))).join("");
    return shell(header(t("长期目标"),t("用结果、里程碑和进度管理长期方向"),cmd("新增长期目标","goal-edit","plus","primary")) +
      '<div class="grid two">'+tile(goals.filter(row => row.status === "active").length,t("进行中"),"play")+
      tile(goals.filter(row => row.status === "completed").length,t("已完成"),"check","teal")+"</div>" +
      card(t("长期目标时间线","Goal timeline"),charts || empty(t("暂无目标","No goals yet"))) +
      '<div class="grid two">' + goals.map(goal => {
        const value = progress(goal), children = actions().filter(row => row.goalID === goal.id);
        return card(t(goal.title),'<div class="stack"><div class="row spaced"><span class="muted small">' +
          esc(date(goal.startDate)+" – "+date(goal.targetDate)) + "</span>" + badge(statusName(goal.status)) + "</div>" +
          (goal.reason ? "<p>" + esc(t(goal.reason)) + "</p>" : "") + (goal.outcome ? '<p class="muted">' + esc(t(goal.outcome)) + "</p>" : "") +
          '<div class="row spaced"><strong>' + value + "%</strong>" + (goal.targetValue > 0 ?
          '<span class="muted">' + esc(goal.currentValue+" / "+goal.targetValue+" "+(goal.unit || "")) + "</span>" : "") +
          '</div><progress value="' + value + '" max="100"></progress>' + (children.length ? rows(children,actionButton) : "") +
          '<div class="row">' + cmd("新增短期行动","action-add:"+goal.id,"plus","secondary") +
          (goal.status !== "completed" ? cmd("标记完成","goal-complete:"+goal.id,"check","secondary") : "") +
          "</div></div>",{actions:smallCmd("编辑","goal-edit:"+goal.id,"edit")+
          smallCmd("删除","goal-delete:"+goal.id,"trash","danger")});
      }).join("") + "</div>");
  }
  function actionPage() {
    const all = actions();
    const filtered = all.filter(row => actionFilter === "all" || (actionFilter === "done" ? row.isCompleted : !row.isCompleted));
    const now = clock();
    const chartActions = all.filter(row => row.startDate != null).map(row =>
      ({title:t(row.title),start:row.startDate,end:row.endDate ?? row.startDate,status:row.isCompleted ? "completed" : "active"}));
    const twoMonths = [0,1].map(month => {
      const first = new Date(now.getFullYear(),now.getMonth()+month,1);
      return timeline(date(first,{year:"numeric",month:"long"}),chartActions,cocoa(first),
        cocoa(new Date(first.getFullYear(),first.getMonth()+1,0,23,59,59)));
    }).join("");
    const filter = '<div class="row segmented">' + [["all","全部"],["open","待完成"],["done","已完成"]].map(([value,label]) =>
      cmd(label,"action-filter:"+value,null,value === actionFilter ? "primary" : "secondary")).join("") + "</div>";
    return shell(header(t("短期行动"),t("把长期目标拆成下一步可以完成的行动"),cmd("新增短期行动","action-edit","plus","primary")) +
      card(t("近两月行动时间线","Two-month action timeline"),twoMonths +
        '<p class="muted small">' + esc(format("%d 项未安排日期","%d unscheduled",all.length-chartActions.length)) + "</p>") +
      card(t("行动清单","Actions"),rows(filtered,action => {
        const goal = lib().longGoals.find(row => row.id === action.goalID);
        const detail = [goal ? t(goal.title) : "",action.startDate != null ? date(action.startDate) + (action.endDate != null && day(action.endDate) !== day(action.startDate)
          ? " – " + date(action.endDate) : "") : "",format("预计 %d 分钟","%d min estimated",action.estimatedMinutes),
          action.focusedSeconds > 0 ? duration(action.focusedSeconds) : "",action.notes].filter(Boolean).join(" · ");
        return item(t(action.title),detail,smallCmd(action.isCompleted ? "取消完成" : "完成","action-toggle:"+action.id,
          action.isCompleted ? "check" : "circle")+smallCmd("开始专注","focus-for:"+action.id,"timer","plain")+
          smallCmd("编辑","action-edit:"+action.id,"edit")+smallCmd("删除","action-delete:"+action.id,"trash","danger"),"list");
      }),{actions:filter}));
  }

  function statisticsPage() {
    function series(id,label,unit,build) {
      const period = statsPeriod[id] || 7;
      const sequence = Array.from({length:period},(_,i) => day(stepDay(clock(),i+1-period)));
      const values = sequence.map(build);
      const max = Math.max(1,...values);
      return card(t(label),'<div class="chart" role="img" aria-label="' + esc(t(label)+ " · " + period + t(" 天"," days")) + '">' +
        values.map((value,index) => '<div class="chart-col" title="' + esc(sequence[index]+" · "+unit(value)) + '">' +
          (value > 0 ? '<i class="chart-bar" style="--value:' + (value/max*100).toFixed(1) + '%"></i>' : "") + "</div>").join("") +
        '</div><div class="chart-axis"><span>' + esc(date(inDay(sequence[0]))) + "</span><span>" + esc(date(inDay(sequence.at(-1)))) +
        "</span></div>",{actions:[7,30].map(days =>
          button(format("近 %d 天","Last %d days",days),{action:"rhythm:stats-period:"+id+":"+days,className:period === days ? "primary" : "secondary"})).join("")});
    }
    const streak = G.state.habitStreaks || {};
    return shell(header(t("数据统计"),t("回顾连续打卡、专注、睡眠与打卡完成率")) +
      '<div class="grid two">' + tile(streak.current ?? 0,t("当前连续打卡","Current streak"),"bolt","orange")+
      tile(streak.longest ?? 0,t("最长连续打卡","Longest streak"),"check","teal") + "</div>" +
      series("focus","专注趋势",duration,focusSeconds) +
      series("sleep","睡眠趋势",duration,key => nightSleep(key)?.durationSeconds || 0) +
      series("habits","打卡完成率",value => value+"%",key => {
        const total = scheduled(key).length;
        return total ? Math.round(countDone(key)*100/total) : 0;
      }));
  }

  function sleepEditor() {
    const yesterday = day(stepDay(clock(),-1));
    const preview = '<div class="card stack sleep-preview"><h3>' + L("记录预览","Preview") + '</h3><p data-sleep-window></p><p class="muted small" data-score></p></div>';
    const form = G.modal(t("记录睡眠"),group(input("hours",t("小时","Hours"),8,{type:"number",min:0,max:24,required:true})+
      input("minutes",t("分钟","Minutes"),0,{type:"number",min:0,max:59,required:true}))+
      input("night",t("哪一晚","Night"),yesterday,{type:"date",max:today(),required:true})+
      '<p class="muted small">' + L("起床时间为所选夜晚次日 07:00。","Wake time is 07:00 on the morning after the selected date.") +
      "</p>" + preview,async data => {
        const minutes = Number(data.hours)*60+Number(data.minutes);
        if (minutes < 30 || minutes > 1440) throw new Error(t("睡眠时长需在 30 分钟至 24 小时之间，分钟需为 0–59。","Enter a duration between 30 minutes and 24 hours."));
        await G.act("/api/sleep/manual",{night:data.night,minutes},{throw:true});
      });
    const update = () => {
      const ending = stepDay(inDay(form.elements.night.value),1);
      ending.setHours(7);
      const minutes = Number(form.elements.hours.value)*60+Number(form.elements.minutes.value);
      const beginning = new Date(ending.getTime()-minutes*60000);
      form.querySelector("[data-sleep-window]").textContent = timestamp(beginning) + " – " + timestamp(ending);
      form.querySelector("[data-score]").textContent = format("预计睡眠评分 %d 分","Estimated sleep score %d",Math.max(0,
        Math.min(100,Math.trunc(100-Math.abs(minutes/60-G.state.settings.sleepTargetHours)*18))));
    };
    form.addEventListener("input",update,{signal:dialogSignal(form)});
    update();
  }
  function dialogSignal(form) {
    form._rhythmDialogEvents?.abort();
    form._rhythmDialogEvents = new AbortController();
    document.querySelector("#editor").addEventListener("close",() => form._rhythmDialogEvents?.abort(),{once:true});
    return form._rhythmDialogEvents.signal;
  }

  function habitEditor(habit) {
    const days = Array.from({length:7},(_,i) => checkbox("weekdays",date(new Date(2024,0,7+i),{weekday:"short"}),!habit || habit.weekdays.includes(i+1))
      .replace('name="weekdays"','name="weekdays" value="'+(i+1)+'"')).join("");
    const symbols = ["checkmark","drop.fill","book.fill","sparkles","dumbbell.fill","leaf.fill","timer","moon.stars.fill","heart.fill","flame.fill"];
    if (habit?.symbol && !symbols.includes(habit.symbol)) symbols.push(habit.symbol);
    const symbolNames = [t("完成","Done"), t("饮水","Water"), t("阅读","Read"), t("整理","Tidy"), t("运动","Exercise"),
      t("成长","Growth"), t("专注","Focus"), t("睡眠","Sleep"), t("健康","Health"), t("活力","Energy")];
    G.modal(t(habit ? "编辑打卡" : "新增打卡"),input("title",t("名称","Name"),habit?.title,{required:true,maxlength:120})+
      group(select("symbol",t("图标","Icon"),symbols.map((key,index) => [key,symbolNames[index] || key]),habit?.symbol)+
      input("rewardCoins",t("奖励金币","Coin reward"),habit?.rewardCoins ?? 5,{type:"number",min:1,max:10,required:true}))+
      '<fieldset><legend>' + L("重复日","Repeat on") + '</legend><div class="row">' + days + "</div></fieldset>", async (data,form) => {
        const weekdays = new FormData(form).getAll("weekdays").map(Number);
        if (!weekdays.length) throw new Error(t("请至少选择一天。","Choose at least one day."));
        await G.act("/api/habits/save",{...data,id:habit?.id,weekdays},{throw:true});
      });
  }

  function habitBackfill(key) {
    backfillDate = key || day(stepDay(clock(),-1));
    const form = G.modal(t("补打卡"),input("backfillDate",t("补打卡日期","Check-in date"),backfillDate,
      {type:"date",max:today(),required:true}) + '<div data-backfill>' +
      rows(scheduled(backfillDate),habit => habitButton(habit,backfillDate),t("这一天没有安排打卡目标。","No habits were scheduled for this day."))+"</div>");
    form.elements.backfillDate.addEventListener("change",() => {
      if (!form.elements.backfillDate.value || form.elements.backfillDate.value > today()) return;
      backfillDate = form.elements.backfillDate.value;
      form.querySelector("[data-backfill]").innerHTML = rows(scheduled(backfillDate),habit => habitButton(habit,backfillDate),
        t("这一天没有安排打卡目标。","No habits were scheduled for this day."));
    });
  }
  function choreEditor(chore) {
    const palette = ["#EA8733","#3373D1","#2AAA8A","#7B5CC6","#D96186","#4EAB68","#637FE6","#C79A32"];
    G.modal(t(chore ? "编辑琐事" : "新增琐事"),input("title",t("标题","Title"),chore?.title,{required:true})+
      group(input("startDate",t("开始日期","Start date"),day(chore?.startDate)||today(),{type:"date",required:true})+
      input("endDate",t("结束日期","End date"),day(chore?.endDate)||today(),{type:"date",required:true}))+
      input("colorHex",t("颜色","Color"),chore?.colorHex || palette[lib().chores.length%palette.length],{type:"color"}),
      async data => { await G.act("/api/chores/save",{...data,id:chore?.id},{throw:true}); });
  }
  function goalEditor(goal) {
    const next = stepDay(clock(),30);
    G.modal(t(goal ? "编辑长期目标" : "新增长期目标"),input("title",t("目标名称","Goal title"),goal?.title,{required:true})+
      textarea("reason",t("为什么想做","Motivation"),goal?.reason)+textarea("outcome",t("预期结果","Desired outcome"),goal?.outcome)+
      group(input("startDate",t("开始日期","Start date"),day(goal?.startDate)||today(),{type:"date",required:true})+
      input("targetDate",t("目标日期","Target date"),day(goal?.targetDate)||day(next),{type:"date",required:true})+
      input("targetValue",t("目标值","Target value"),goal?.targetValue ?? 0,{type:"number",min:0,step:"any"})+
      input("currentValue",t("当前值","Current value"),goal?.currentValue ?? 0,{type:"number",min:0,step:"any"})+
      input("unit",t("单位","Unit"),goal?.unit)+select("status",t("状态","Status"),Object.keys(statusNames).map(id => [id,statusName(id)]),goal?.status || "active")),
      async data => { await G.act("/api/goals/save",{...data,id:goal?.id},{throw:true}); });
  }
  function actionEditor(action,goalID) {
    G.modal(t(action ? "编辑短期行动" : "新增短期行动"),input("title",t("行动名称","Action title"),action?.title,{required:true})+
      textarea("notes",t("备注","Notes"),action?.notes) + select("goalID",t("关联长期目标","Linked goal"),
        [["",t("不关联","None")],...lib().longGoals.map(goal => [goal.id,goal.title])],action?.goalID ?? goalID)+
      group(input("startDate",t("开始日期","Start date"),day(action?.startDate),{type:"date"})+
      input("endDate",t("结束日期","End date"),day(action?.endDate),{type:"date"}))+
      input("estimatedMinutes",t("预计分钟","Estimated minutes"),action?.estimatedMinutes ?? 25,{type:"number",min:1,step:1,required:true})+
      checkbox("isCompleted",t("已完成","Completed"),action?.isCompleted), async data => {
        await G.act("/api/actions/save",{...data,id:action?.id,goalID:data.goalID || null,isCompleted:data.isCompleted === "on"},{throw:true});
      });
  }

  const views = {today:todayPage,focus:focusPage,sleep:sleepPage,habits:habitPage,chores:chorePage,goals:goalPage,actions:actionPage,statistics:statisticsPage};
  const deletes = {
    "habit-delete":["habits","删除打卡目标？"],"chore-delete":["chores","删除这项琐事？"],
    "goal-delete":["goals","删除长期目标？"],"action-delete":["actions","删除短期行动？"],"sleep-delete":["sleep","删除睡眠记录？"]
  };
  const toggles = {"chore-toggle":"chores","action-toggle":"actions"};
  window.RhythmUI = {
    render(section) { return (views[section] || todayPage)(); },
    bind() {},
    tick() {
      if (!G.state?.library) return;
      const focus = lib().activeFocus, sleep = lib().activeSleep;
      const elapsed = focus ? Number(focus.accumulatedSeconds || 0) + (focus.segmentStartedAt == null ? 0 :
        Math.max(0,G.currentClock()-focus.segmentStartedAt)) : 0;
      document.querySelectorAll("[data-timer]").forEach(node => {
        const value = duration(node.dataset.timer === "focus" ? elapsed : sleep ? Math.max(0,G.currentClock()-sleep.startedAt) : 0,true);
        if (node.textContent !== value) node.textContent = value;
      });
    }
  };
  document.addEventListener("click", async event => {
    const control = event.target.closest('button[data-action^="rhythm:"]');
    if (!control) return;
    const [,action,id,extra] = control.dataset.action.split(":");
    if (deletes[action]) {
      const [kind,title] = deletes[action];
      G.confirm(t(title),t("删除后，这条记录将从列表中移除。","The record will be removed from the list."),"/api/"+kind+"/delete",{id});
    } else if (toggles[action]) {
      await G.act("/api/"+toggles[action]+"/toggle",{id});
    } else if (action === "habit-toggle") {
      const backfill = control.closest("[data-backfill]");
      const result = await G.act("/api/habits/toggle",{id,on:extra});
      if (result && backfill?.isConnected) backfill.innerHTML = rows(scheduled(backfillDate),habit => habitButton(habit,backfillDate));
    } else if (action === "habit-backfill") habitBackfill();
    else if (action === "habit-edit") habitEditor(getHabit(id));
    else if (action === "chore-edit") choreEditor(lib().chores.find(row => row.id === id));
    else if (action === "goal-edit") goalEditor(lib().longGoals.find(row => row.id === id));
    else if (action === "action-edit") actionEditor(linked(id));
    else if (action === "action-add") actionEditor(null,id);
    else if (action === "goal-complete") {
      const goal = lib().longGoals.find(row => row.id === id);
      await G.act("/api/goals/save",{...goal,status:"completed"});
    } else if (action === "focus-for") {
      if (lib().activeFocus || lib().activeSleep) {
        G.notice(t("已有计时正在运行。","A timer is already running."),"error");
      } else if (await G.act("/api/focus/start",{linkedActionID:id})) G.go("rhythm","focus");
    } else if (action === "focus-cancel" || action === "sleep-cancel") {
      const isFocus = action === "focus-cancel";
      G.confirm(t(isFocus ? "放弃这次专注？" : "放弃这次睡眠？"),t(isFocus ?
        "本次专注记录不会保存；已经实时产生的作物成长会保留。" : "本次睡眠记录不会保存。"),
      "/api/"+(isFocus ? "focus" : "sleep")+"/cancel",{});
    } else if (action.startsWith("focus-")) {
      const path = action.substring(6);
      await G.act("/api/focus/"+path,path === "start" ? {linkedActionID:document.querySelector('[name="focusAction"]')?.value || null} : {});
    } else if (action === "sleep-entry") sleepEditor();
    else if (action.startsWith("sleep-")) {
      const path = action.substring(6);
      await G.act("/api/sleep/"+path,path === "start" ? {targetHours:Number(document.querySelector('[name="targetHours"]')?.value)} : {});
    } else if (action === "month" || action === "chores-month") {
      const delta = id === "previous" ? -1 : 1;
      if (action === "month") calendarOffset = id === "reset" ? 0 : calendarOffset+delta;
      else choreOffset = id === "reset" ? 0 : choreOffset+delta;
      G.render();
    } else if (action === "action-filter") { actionFilter = id; G.render(); }
    else if (action === "stats-period") { statsPeriod[id] = Number(extra); G.render(); }
  });
})();
