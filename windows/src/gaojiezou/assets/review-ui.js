(() => {
  "use strict";
  const G = window.Gao;
  const {t, localized: L, esc, icon, button, duration, locale} = G;
  const endpoint = "/api/review/week";
  const dateAtNoon = key => new Date(key + "T12:00:00");
  const dash = "—";
  let report = null;
  let selected = "";
  let picked = false;
  let weekDate = "";
  let requested = "";
  let loading = true;
  let failure = "";
  let sourceState = null;
  let requestNumber = 0;

  function offsetDate(key, amount) {
    const value = dateAtNoon(key);
    value.setDate(value.getDate() + amount);
    return G.localDay(value);
  }

  function dayLabel(key, options) {
    return new Intl.DateTimeFormat(locale(), options).format(dateAtNoon(key));
  }

  function dateRange(start, end, options = {year:"numeric",month:"short",day:"numeric"}) {
    const dates = new Intl.DateTimeFormat(locale(), options);
    if (!start || !end || start === end) return start || end ? dates.format(dateAtNoon(start || end)) : dash;
    return dates.formatRange(dateAtNoon(start), dateAtNoon(end));
  }

  function timeLabel(seconds) {
    if (seconds == null) return dash;
    return new Intl.DateTimeFormat(locale(),{
      month:"short",day:"numeric",hour:"numeric",minute:"2-digit"
    }).format(new Date(seconds * 1000));
  }

  function interval(start, end) {
    return start == null && end == null ? dash : timeLabel(start) + " – " + timeLabel(end);
  }

  const s = seconds => seconds > 0 && seconds < 60 ? t("不足 1 分钟","<1 min") : duration(seconds);
  const estimatedTime = (seconds, estimated) => estimated ? t("约 ", "≈ ") + s(seconds) : s(seconds);
  const quantity = (count, zh, en, singular) => count == null ? dash :
    count + t(zh, count === 1 && singular ? singular : en);
  const more = (zh, en, go) => button(t(zh,en),{go,icon:"right",className:"plain review-shortcut"});

  function weekNav() {
    const target = loading || failure === "load" ? requested || report?.currentWeekStart : "";
    const start = target || report?.weekStart;
    const end = target ? offsetDate(target,6) : report?.weekEnd;
    const control = (direction, label, symbol, disabled, visible = false) =>
      '<button type="button" class="secondary review-week-button" data-review-week="'+direction+'" aria-label="'+
      esc(label)+'" title="'+esc(label)+'"'+(disabled?' disabled':'')+'>'+icon(symbol)+
      (visible?'<span>'+esc(label)+'</span>':'')+'</button>';
    return '<header class="review-header"><div><button type="button" class="plain review-back" data-go="today" data-review-back>'+
      icon("left")+'<span>'+L("返回今日","Back to Today")+'</span></button><h1 id="review-title">'+
      L("每周复盘","Weekly review")+'</h1></div><div class="review-week-picker"><p id="review-week-range" tabindex="-1" aria-live="polite">'+
      (start ? '<time datetime="'+esc(start)+'">'+esc(dateRange(start,end))+'</time>' :
        L("当前周","Current week"))+'</p><div class="review-week-controls" role="group" aria-label="'+L("选择周","Choose week")+'">'+
      control("previous",t("上一周","Previous week"),"left",loading || !report)+
      control("current",t("本周","This week"),"sun",loading,true)+
      control("next",t("下一周","Next week"),"right",loading || !report)+'</div></div></header>';
  }

  function metric(label, glyph, planned, actual, note = "") {
    return '<tr><th scope="row"><span class="review-metric-label">'+icon(glyph)+esc(label)+'</span></th><td>'+esc(planned)+
      '</td><td><strong>'+esc(actual)+'</strong>'+(note?'<small>'+esc(note)+'</small>':'')+'</td></tr>';
  }

  function summary(week) {
    const {totals,plan,sleepStatus} = week;
    const sleepReady = sleepStatus === "ready";
    const hist = plan.mode === "historical";
    const nights = totals.sleepNights;
    const sleepAverage = sleepReady && nights > 0 ? s(totals.sleepSeconds/nights) : dash;
    const plannedSleep = plan.sleepTargetHours == null ? dash : s(plan.sleepTargetHours * 3600);
    const sleepNote = sleepReady ? nights > 0 ?
      quantity(nights," 晚记录 · "," nights logged · "," night logged · ") + s(totals.sleepSeconds) :
      t("没有睡眠记录","No sleep entries") : t("睡眠资料暂不可用","Sleep records unavailable");
    const detail = metric(t("专注时长","Focus time"),"timer",plan.focusMinutes == null ? dash : s(plan.focusMinutes*60),
      estimatedTime(totals.focusSeconds,totals.focusEstimated),totals.focusEstimated ?
        t("含跨日估算","Includes cross-day estimates") : "")+
      metric(t("习惯打卡","Habit check-ins"),"check",quantity(totals.habitPlan," 次"," check-ins"," check-in"),
        quantity(totals.habitDone," 次"," check-ins"," check-in"))+
      metric(t("每晚睡眠","Sleep per night"),"moon",plannedSleep,sleepAverage,sleepNote)+
      metric(t("短期行动","Short actions"),"list",quantity(plan.datedActionCount," 项"," actions"," action"),
        quantity(totals.actionDone," 项"," actions"," action"))+
      metric(t("长期目标","Long-term goals"),"flag",quantity(plan.goalCount," 项"," goals"," goal"),
        quantity(totals.goalDone," 项"," goals"," goal"));
    const undated = [
      totals.undatedActions > 0 ? quantity(totals.undatedActions," 项行动"," actions"," action") : "",
      totals.undatedGoals > 0 ? quantity(totals.undatedGoals," 项目标"," goals"," goal") : ""
    ].filter(Boolean).join(t("、"," and "));
    return '<section class="card review-summary" aria-labelledby="review-summary-title"><div class="review-section-heading">'+
      '<h2 id="review-summary-title">'+L("计划与实际","Plan and actuals")+'</h2><p class="muted">'+
      (hist ? L("历史计划未留存，计划栏用 — 表示。","Past plans were not saved. A dash marks unavailable targets.") :
        L("计划来自本周安排和当前设置。","Plans use this week’s schedule and current settings."))+
      '</p></div><table class="review-comparison" aria-labelledby="review-summary-title"><thead><tr><th scope="col">'+
      L("项目","Activity")+'</th><th scope="col">'+L("计划","Plan")+'</th><th scope="col">'+L("实际","Actual")+
      '</th></tr></thead><tbody>'+detail+'</tbody></table>'+
      (undated ? '<p class="review-plan-note muted">'+esc(t(
        "%s已完成，但完成日期无法核实，未计入任何一周。",
        "Weekly totals exclude %s completed without a verifiable date."
      ).replace("%s",undated))+'</p>' : "")+
      '<details class="review-method"><summary>'+L("统计口径","How totals are counted")+
      '</summary><ul class="muted"><li>'+L("专注只计已保存的记录。跨午夜且无法确定各时段的专注按日期所占时长估算。",
        "Focus counts saved sessions. When pauses cannot be assigned to either date, cross-midnight sessions are apportioned by time and marked as estimates.")+
      '</li><li>'+L("睡眠归入按本机时间计算的起床日期。","Sleep is grouped by the local date you woke up.")+
      '</li></ul></details></section>';
  }

  function planItems(plan) {
    const {items,goals = [],mode} = plan;
    const contents = items.length ? '<ul class="review-records">'+items.map(item => {
      const dates = item.startDate || item.endDate ?
        dateRange(item.startDate,item.endDate,{month:"short",day:"numeric"}) : "";
      return recordLine(item.title,[item.goalTitle,dates].filter(Boolean).join(" · "),
        item.estimatedMinutes == null ? "" : s(item.estimatedMinutes*60));
    }).join("")+'</ul>' : '<p class="review-card-empty muted">'+(mode === "historical" ?
      L("这周未留存行动计划。","No action plan was saved for this week.") :
      L("这周没有带日期的行动。","There are no dated actions for this week."))+'</p>';
    const goalItems = goals.length ? '<div class="review-section-heading with-link review-planned-goals"><h3>'+
      L("本周长期目标","Long-term goals this week")+'</h3>'+more("打开目标","Open goals","rhythm/goals")+
      '</div><ul class="review-records">'+goals.map(goal=>recordLine(goal.title,
        goal.startDate || goal.endDate ? dateRange(goal.startDate,goal.endDate,{month:"short",day:"numeric"}) : "")).join("")+'</ul>' : "";
    return '<section class="card review-plan" aria-labelledby="review-plan-title"><div class="review-section-heading with-link">'+
      '<h2 id="review-plan-title">'+L("周内安排","Weekly schedule")+'</h2>'+
      more("打开行动","Open actions","rhythm/actions")+'</div>'+contents+goalItems+'</section>';
  }

  function dayPicker(week) {
    const peak = Math.max(1,...week.days.map(day => day.focusSeconds));
    const days = week.days.map(day => {
      const label = dayLabel(day.date,{weekday:"long",month:"long",day:"numeric"});
      const focus = estimatedTime(day.focusSeconds,day.focusEstimated);
      const checked = day.habitPlan == null ? String(day.habitDone) : day.habitDone+"/"+day.habitPlan;
      const today = day.date === week.today;
      return '<li><button type="button" class="review-day" data-review-day="'+esc(day.date)+'" aria-pressed="'+
        (day.date === selected)+'" aria-controls="review-detail"'+(today?' aria-current="date"':'')+' aria-label="'+
        esc([label,today?t("今天","Today"):"",t("专注","Focus")+" "+focus,t("打卡","Habits")+" "+checked]
          .filter(Boolean).join(", "))+'"><span class="review-day-date" aria-hidden="true"><span>'+
        esc(dayLabel(day.date,{weekday:"short"}))+'</span><strong>'+esc(dateAtNoon(day.date).getDate())+
        '</strong></span><meter min="0" max="'+peak+'" value="'+day.focusSeconds+'" aria-hidden="true"></meter>'+
        '<span class="review-day-stats" aria-hidden="true"><span>'+icon("timer")+esc(focus)+'</span><span>'+
        icon("check")+esc(checked)+'</span></span></button></li>';
    }).join("");
    return '<section class="card review-days" aria-labelledby="review-days-title"><div class="review-section-heading">'+
      '<h2 id="review-days-title">'+L("七日记录","Seven-day activity")+'</h2><p class="muted">'+
      L("选择日期查看当天记录。条形表示专注时长。","Select a date for its records. Bars show focus time.")+
      '</p></div><ol class="review-days-grid" role="list">'+days+'</ol></section>';
  }

  function recordLine(title, description = "", value = "") {
    return '<li><div><strong>'+esc(title)+'</strong>'+(description?'<small>'+esc(description)+'</small>':'')+
      '</div>'+(value?'<span class="review-record-value">'+esc(value)+'</span>':'')+'</li>';
  }

  function recordGroup(label, glyph, key, rows, format, noRecords, shortcut) {
    return '<section class="review-detail-group" data-review-records="'+key+'"><div class="review-group-heading"><h3>'+
      icon(glyph)+esc(label)+'</h3>'+shortcut+'</div>'+
      (rows.length ? '<ul class="review-records">'+rows.map(format).join("")+'</ul>' :
        '<p class="review-card-empty muted">'+esc(noRecords)+'</p>')+'</section>';
  }

  function dayDetail(week) {
    const day = week.days.find(item => item.date === selected);
    if (!day) return "";
    const groups = [
      recordGroup(t("专注","Focus"),"timer","focus",day.focus,row=>recordLine(row.title || t("专注","Focus"),
        interval(row.startedAt,row.endedAt),estimatedTime(row.seconds,row.estimated)),
        t("当天没有已保存的专注记录。","No saved focus sessions for this day."),more("打开专注","Open focus","rhythm/focus")),
      recordGroup(t("打卡","Habit check-ins"),"check","habits",day.habits,row=>recordLine(row.title ||
        t("已移除的打卡习惯","Habit no longer listed")),
        t("当天没有完成打卡。","No habit check-ins for this day."),more("打开打卡","Open habits","rhythm/habits")),
      recordGroup(t("睡眠","Sleep"),"moon","sleep",day.sleep,row=>recordLine(t("睡眠记录","Sleep entry"),
        interval(row.startedAt,row.endedAt),s(row.seconds)),
        week.sleepStatus === "ready" ? t("当天没有睡眠记录。","No sleep entries for this day.") :
          t("睡眠资料暂不可用。","Sleep records are unavailable."),more("打开睡眠","Open sleep","rhythm/sleep")),
      recordGroup(t("短期行动","Short actions"),"list","actions",day.actions,row=>recordLine(row.title,
        [row.goalTitle,timeLabel(row.completedAt)].filter(Boolean).join(" · ")),
        t("当天没有完成短期行动。","No short actions completed on this day."),more("打开行动","Open actions","rhythm/actions")),
      recordGroup(t("长期目标","Long-term goals"),"flag","goals",day.goals,row=>recordLine(row.title,timeLabel(row.completedAt)),
        t("当天没有完成长期目标。","No long-term goals completed on this day."),more("打开目标","Open goals","rhythm/goals"))
    ];
    return '<section id="review-detail" class="card review-detail" data-review-detail="'+esc(day.date)+
      '" aria-labelledby="review-detail-title"><div class="review-section-heading with-link"><div><h2 id="review-detail-title" tabindex="-1">'+
      esc(dayLabel(day.date,{weekday:"long",month:"long",day:"numeric"}))+'</h2><p class="muted">'+
      L("当天记录","Daily records")+'</p></div><button type="button" class="plain review-shortcut" data-review-days="selected">'+
      icon("left")+'<span>'+L("返回日期","Back to dates")+'</span></button></div><div class="review-detail-grid">'+
      groups.join("")+'</div></section>';
  }

  function errorMessage(quiet) {
    return '<section class="card review-status'+(quiet?' review-status-compact':'')+'"><p role="alert">'+
      (quiet ? L("无法刷新，正在显示上次读取的记录。","Could not refresh. Showing the last loaded records.") :
        L("无法读取这周的记录。","Could not load this week’s records."))+
      '</p><button type="button" class="secondary" data-review-retry="week">'+icon("clock")+
      '<span>'+L("重试","Retry")+'</span></button></section>';
  }

  function contents() {
    const header = weekNav();
    if (loading) return header+'<section class="card review-status" role="status"><span class="loading-ring" aria-hidden="true"></span><p>'+
      L("正在读取这周的记录…","Loading weekly records…")+'</p></section>';
    if (failure === "load") return header+errorMessage(false);
    if (!report) return header;
    const {focusSeconds,habitDone,sleepNights,actionDone,goalDone} = report.totals;
    const hasRecords = focusSeconds || habitDone || sleepNights || actionDone || goalDone ||
      report.days.some(day=>day.focus.length);
    const empty = hasRecords ? "" : '<p class="review-empty">'+
      L("这周还没有可显示的记录。","There are no records to show for this week yet.")+'</p>';
    return header+(failure === "refresh" ? errorMessage(true) : "")+empty+'<div class="review-overview">'+summary(report)+planItems(report.plan)+
      '</div>'+dayPicker(report)+dayDetail(report);
  }

  function paint(focusSelector) {
    const root = document.querySelector("[data-review-page]");
    if (!root) return;
    const active = document.activeElement;
    if (!focusSelector && root.contains(active)) {
      for (const name of ["id","data-review-week","data-review-day","data-review-retry","data-review-days","data-go"]) {
        const value = active.getAttribute(name);
        if (value) {
          focusSelector = '['+name+'="'+CSS.escape(value)+'"]';
          break;
        }
      }
    }
    root.innerHTML = contents();
    if (focusSelector) {
      const control = root.querySelector(focusSelector);
      if (control && !control.disabled) control.focus({preventScroll:true});
      else root.querySelector("#review-week-range")?.focus({preventScroll:true});
    }
  }

  async function load(date, {focusSelector,quiet = false} = {}) {
    const number = ++requestNumber;
    requested = date;
    loading = !quiet;
    failure = "";
    if (!quiet) paint();
    try {
      const next = await G.api(endpoint+(date ? "?date="+encodeURIComponent(date) : ""));
      if (number !== requestNumber) return;
      picked = quiet && picked && next.days.some(day => day.date === selected);
      if (!picked) selected = next.days.some(day => day.date === next.today) ? next.today : next.weekStart;
      weekDate = next.weekStart === next.currentWeekStart ? "" : next.weekStart;
      report = next;
      requested = "";
    } catch {
      if (number !== requestNumber) return;
      failure = quiet ? "refresh" : "load";
    }
    loading = false;
    paint(focusSelector && failure ? "[data-review-retry]" : focusSelector);
  }

  function focusPosition(selector, block = "nearest") {
    const target = document.querySelector(selector);
    target?.focus({preventScroll:true});
    target?.scrollIntoView({block});
  }

  document.addEventListener("click", event => {
    const control = event.target.closest("[data-review-page] button");
    if (!control || loading) return;
    const week = control.dataset.reviewWeek;
    const date = control.dataset.reviewDay;
    if (week) {
      const key = week === "current" ? "" : offsetDate(report.weekStart,week === "previous" ? -7 : 7);
      load(key,{focusSelector:'[data-review-week="'+week+'"]'});
    } else if (control.hasAttribute("data-review-retry")) {
      load(requested,{focusSelector:"#review-week-range",quiet:failure === "refresh"});
    } else if (date) {
      selected = date;
      picked = true;
      paint();
      focusPosition("#review-detail-title","start");
    } else if (control.hasAttribute("data-review-days")) {
      focusPosition('[data-review-day="'+CSS.escape(selected)+'"]');
    }
  });

  window.ReviewUI = {
    render() { return '<div class="workspace review-workspace" data-review-page aria-labelledby="review-title">'+contents()+'</div>'; },
    bind() {
      if (sourceState === G.state || (sourceState && (loading || failure))) return;
      sourceState = G.state;
      load(weekDate,{quiet:Boolean(report)});
    },
    leave() {
      requestNumber++;
      report = null;
      selected = requested = weekDate = "";
      loading = true;
      picked = false;
      failure = "";
      sourceState = null;
    }
  };
})();
