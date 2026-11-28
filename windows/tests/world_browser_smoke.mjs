// Exercises the Windows workbench publicly rendered paths with disposable data.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"../..");
const python=process.argv[2] || "python";
const edge=process.argv[3] || path.join(process.env["ProgramFiles(x86)"] || "C:/Program Files (x86)","Microsoft","Edge","Application","msedge.exe");
const workspace=path.join(repo,"build.noindex");
await mkdir(workspace,{recursive:true});
const folder=await mkdtemp(path.join(workspace,"world-smoke-"));
const profile=path.join(folder,"profile"),dataDir=path.join(folder,"synthetic-data");
const keep=process.env.GAOJIEZOU_TEST_SCREENSHOTS==="1";
const children=[];
let channel;

function processChild(executable,args,options={}){
  const child=spawn(executable,args,{cwd:repo,windowsHide:true,...options});
  children.push(child);
  return child;
}
function exited(child){
  return new Promise((resolve,reject)=>{
    child.once("error",reject);
    child.once("exit",code=>code===0?resolve():reject(Error("Child process exited with "+code)));
  });
}
async function waitFor(callback,message,timeout=10000){
  const deadline=Date.now()+timeout;
  do {
    if(await callback()) return;
    await delay(80);
  } while(Date.now()<deadline);
  throw Error(message);
}
async function reservePort(){
  const socket=net.createServer();
  await new Promise((ok,fail)=>socket.listen(0,"127.0.0.1",ok).on("error",fail));
  const {port}=socket.address();
  await new Promise((ok,fail)=>socket.close(error=>error?fail(error):ok()));
  return port;
}
async function cleanup(){
  channel?.close();
  for(const child of children.reverse()) if(child.exitCode===null) child.kill();
  if(keep){ console.log("Synthetic screenshots: "+folder);return; }
  const resolved=await realpath(folder);
  const allowed=await realpath(workspace);
  const relative=path.relative(allowed,resolved);
  assert(relative.startsWith("world-smoke-") && !relative.includes(path.sep),"Unexpected cleanup path");
  const childrenExited=children.filter(child=>child.exitCode===null).map(child=>new Promise(ok=>child.once("exit",ok)));
  await Promise.race([Promise.all(childrenExited),delay(1000)]);
  await rm(resolved,{recursive:true,force:true,maxRetries:5,retryDelay:250});
}
const fixture=[
  "import sys",
  "from pathlib import Path",
  "sys.path.insert(0, str(Path('windows/src').resolve()))",
  "from gaojiezou.store import RhythmStore",
  "from gaojiezou.footprints import search_cities",
  "r=RhythmStore(Path(sys.argv[1]))",
  "r.create_library()",
  "r.library['coins']=4000",
  "r.buy_shelter()",
  "r.buy_animal('chicken')",
  "r.buy_animal('rabbit')",
  "r.library['fishInventory']['crucian']=1",
  "r.move_to_aquarium('crucian')",
  "places=[search_cities(query)[0] for query in ('beijing','shanghai')]",
  "for city in places:",
  "    r.footprints.save_visit({'cityID':city['id'],'note':'synthetic world fixture'},r.now())",
  "wuhan=next(city for city in search_cities('wuhan') if city['id']=='cn-420100')",
  "r.footprints.save_visit({'cityID':wuhan['id'],'date':{'precision':'year','year':2002}},r.now())",
  "r.footprints.set_resident(places[0]['id'],r.now())",
  "r.footprints.set_train_route(places[1]['id'],r.now())",
  "r.footprints.upgrade_carriage('sleeper')",
  "r.save()"
].join("\n");

try {
  await exited(processChild(python,["-c",fixture,dataDir],{stdio:"inherit"}));
  const appPort=await reservePort(),base="http://127.0.0.1:"+appPort;
  processChild(python,["windows/launch.py","--serve","--no-browser","--port",String(appPort),"--data-dir",dataDir],
    {stdio:["ignore","ignore","inherit"]});
  processChild(edge,["--headless=new","--no-first-run","--no-default-browser-check","--no-sandbox","--disable-crash-reporter",
    "--disable-background-networking","--enable-unsafe-swiftshader","--use-angle=swiftshader",
    "--remote-debugging-port=0","--user-data-dir="+profile,"about:blank"],{stdio:"ignore"});
  let target;
  await waitFor(async()=>{
    try{
      const [port]=(await readFile(path.join(profile,"DevToolsActivePort"),"utf8")).split(/\r?\n/);
      target=(await fetch("http://127.0.0.1:"+port+"/json/list").then(res=>res.json())).find(tab=>tab.type==="page");
      return target && (await fetch(base)).ok;
    }catch{return false;}
  },"Chromium or the local test application could not start",17000);

  channel=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((ok,fail)=>{channel.onopen=ok;channel.onerror=fail;});
  let next=0;
  const inflight=new Map(),errors=[];
  channel.onmessage=({data})=>{
    const reply=JSON.parse(data);
    if(reply.id){
      const pending=inflight.get(reply.id);
      if(!pending) return;
      clearTimeout(pending.deadline);
      inflight.delete(reply.id);
      if(reply.error) pending.reject(Error(reply.error.message)); else pending.resolve(reply.result);
    } else if(reply.method==="Runtime.exceptionThrown") {
      errors.push(reply.params.exceptionDetails.exception?.description || reply.params.exceptionDetails.text);
    }
  };
  channel.onclose=()=>{
    for(const pending of inflight.values()){
      clearTimeout(pending.deadline);
      pending.reject(Error("Edge closed the DevTools session."));
    }
    inflight.clear();
  };
  function cdp(method,params={}){
    return new Promise((resolve,reject)=>{
      const id=++next;
      const deadline=setTimeout(()=>{
        inflight.delete(id);
        reject(Error("Edge did not answer "+method+" within 45 seconds."));
      },45000);
      inflight.set(id,{resolve,reject,deadline});
      channel.send(JSON.stringify({id,method,params}));
    });
  }
  async function js(expression){
    const reply=await cdp("Runtime.evaluate",{expression,returnByValue:true,awaitPromise:true});
    if(reply.exceptionDetails) throw Error(reply.exceptionDetails.exception?.description || reply.exceptionDetails.text);
    return reply.result.value;
  }
  const until=expression=>waitFor(()=>js(expression),"Timed out waiting for "+expression);
  const click=selector=>js("document.querySelector("+JSON.stringify(selector)+").click()");
  const key=(selector,value)=>js("document.querySelector("+JSON.stringify(selector)+").dispatchEvent(new KeyboardEvent('keydown',{key:"+JSON.stringify(value)+",bubbles:true,cancelable:true}))");
  async function nativeKey(key,windowsVirtualKeyCode) {
    await cdp("Input.dispatchKeyEvent",{type:"rawKeyDown",key,code:key,windowsVirtualKeyCode});
    await cdp("Input.dispatchKeyEvent",{type:"keyUp",key,code:key,windowsVirtualKeyCode});
  }
  const canvasMode=mode=>'canvas[data-world-mode="'+mode+'"][data-world-ready=true]';
  const modeReady=mode=>until("Boolean(document.querySelector("+JSON.stringify(canvasMode(mode))+"))");
  const go=section=>js("Gao.go('playground',"+JSON.stringify(section)+")");
  async function screenshot(name) {
    const frame=Buffer.from((await cdp("Page.captureScreenshot",{format:"png"})).data,"base64");
    if(keep) await writeFile(path.join(folder,name+".png"),frame);
    return frame;
  }
  async function mouse(type,x,y){
    await cdp("Input.dispatchMouseEvent",{type,x,y,button:type==="mouseMoved"?"none":"left",
      buttons:type==="mouseReleased"?0:1,clickCount:1});
  }
  async function planePoint(mode,x,y,z){
    const bounds=await js("document.querySelector("+JSON.stringify(canvasMode(mode))+").getBoundingClientRect().toJSON()");
    const pitch=Math.atan2(24,17),aspect=bounds.width/bounds.height;
    return [bounds.x+bounds.width*(.5+x/(7.6*aspect*2)),bounds.y+bounds.height*(.5-(y*Math.cos(pitch)-z*Math.sin(pitch))/(7.6*2))];
  }
  await Promise.all(["Runtime.enable","Page.enable"].map(method=>cdp(method)));
  await cdp("Emulation.setDeviceMetricsOverride",{width:1280,height:840,deviceScaleFactor:1.5,mobile:false});
  await cdp("Page.navigate",{url:base+"/"});
  await until("window.Gao?.state?.status==='ready'");

  assert.equal(await js("Gao.state.version"),"4.12+6");
  assert.equal(await js("document.querySelector('.navigation-rail [aria-current=page]').dataset.go"),"today");
  for (const [width, markSize] of [[1280, 34], [605, 28]]) {
    for (const deviceScaleFactor of [1, 1.25, 1.5, 1.75, 2]) {
      await cdp("Emulation.setDeviceMetricsOverride",{width,height:840,deviceScaleFactor,mobile:false});
      const mark=await js(`(async () => {
        const image=document.querySelector('.brand img');
        await image.decode();
        const box=image.getBoundingClientRect();
        return [devicePixelRatio,box.width,box.height,image.naturalWidth,document.querySelector('link[rel=icon]').href];
      })()`);
      assert.deepEqual(mark,[deviceScaleFactor,markSize,markSize,128,base+"/GaoJieZou.ico"]);
    }
  }
  await cdp("Emulation.setDeviceMetricsOverride",{width:1280,height:840,deviceScaleFactor:1.5,mobile:false});
  await screenshot("core-today-light");
  await click('main [data-action="rhythm:focus-start"]');
  await until("!!Gao.state.library.activeFocus");
  await click("#toolbar .more-button");
  await click('#toolbar [data-action="quit"]');
  await until("document.querySelector('#editor').open");
  await click("#editor .dialog-footer [data-action=close]");
  await until("!document.querySelector('#editor').open && Gao.state.library.activeFocus.segmentStartedAt!=null");
  await click('main [data-action="rhythm:focus-pause"]');
  await until("Gao.state.library.activeFocus.segmentStartedAt==null");
  await click('main [data-action="rhythm:focus-resume"]');
  await until("Gao.state.library.activeFocus.segmentStartedAt!=null");
  await click('main [data-action="rhythm:focus-finish"]');
  await until("!Gao.state.library.activeFocus && Gao.state.library.focusRecords.length===1");
  await click('main [data-action^="rhythm:habit-toggle:"]');
  await until("Gao.state.library.habitCompletionKeys.length===1");

  await click('main [data-action="rhythm:sleep-entry"]');
  const setField=(selector,value)=>js("(()=>{const field=document.querySelector("+JSON.stringify(selector)+");field.value="+
    JSON.stringify(value)+";field.dispatchEvent(new Event('input',{bubbles:true}));})()");
  const testNight=await js("(()=>{const now=new Date();now.setDate(now.getDate()-(now.getHours()<7?2:1));return Gao.localDay(now);})()");
  await setField("#editor [name=night]",testNight);
  await setField("#editor [name=hours]","0");
  await setField("#editor [name=minutes]","10");
  await click("#editor [type=submit]");
  await until("!document.querySelector('.dialog-error').hidden");
  await screenshot("core-sleep-validation-light");
  await setField("#editor [name=hours]","7");
  await setField("#editor [name=minutes]","45");
  await screenshot("core-sleep-form-light");
  await click("#editor [type=submit]");
  await until("!document.querySelector('#editor').open && Gao.state.library.sleepRecords.some(row=>row.manualEntry)");
  await js("Gao.go('rhythm','focus')");
  await screenshot("core-focus-light");
  await js("Gao.go('rhythm','habits')");
  await screenshot("core-habits-light");
  async function editorTitle(action,title) {
    await click(action);
    await until("document.querySelector('#editor').open");
    await setField("#editor [name=title]",title);
    await click("#editor [type=submit]");
    await until("!document.querySelector('#editor').open");
  }
  await click('[data-go="rhythm/chores"]');
  await editorTitle('[data-action="rhythm:chore-edit"]',"安装回归合成琐事");
  await until("Gao.state.library.chores.some(row=>row.title==='安装回归合成琐事')");
  await click('[data-action^="rhythm:chore-toggle:"]');
  await until("Gao.state.library.chores.some(row=>row.title==='安装回归合成琐事'&&row.isCompleted)");
  await click('[data-go="rhythm/goals"]');
  await editorTitle('[data-action="rhythm:goal-edit"]',"安装回归合成目标");
  await until("Gao.state.library.longGoals.some(row=>row.title==='安装回归合成目标')");
  const goalID=await js("Gao.state.library.longGoals.find(row=>row.title==='安装回归合成目标').id");
  await editorTitle('[data-action="rhythm:action-add:'+goalID+'"]',"安装回归合成行动");
  await until("Gao.state.library.shortActions.some(row=>row.title==='安装回归合成行动'&&row.goalID==="+JSON.stringify(goalID)+")");
  await click('[data-go="rhythm/actions"]');
  await click('[data-action="rhythm:action-filter:open"]');
  assert(await js("document.querySelector('main').textContent.includes('安装回归合成行动')"));
  const actionID=await js("Gao.state.library.shortActions.find(row=>row.title==='安装回归合成行动').id");
  await click('[data-action="rhythm:action-toggle:'+actionID+'"]');
  await until("Gao.state.library.shortActions.some(row=>row.title==='安装回归合成行动'&&row.isCompleted)");
  await click('[data-go="rhythm/goals"]');
  await click('[data-action="rhythm:goal-complete:'+goalID+'"]');
  await until("Gao.state.library.longGoals.some(row=>row.title==='安装回归合成目标'&&row.completedAt!=null)");
  await click('[data-go="rhythm/statistics"]');
  await click('[data-action="rhythm:stats-period:sleep:30"]');
  assert(await js("Array.from(document.querySelectorAll('.chart')).some(chart=>chart.children.length===30)"));

  const reviewEntry='[data-go="today/review"]';
  await click('#workspaces [data-go="today"]');
  await click(reviewEntry);
  await until("document.querySelectorAll('[data-review-day]').length===7");
  const firstOfWeek=await js("document.querySelector('[data-review-day]').dataset.reviewDay");
  await screenshot("weekly-review-light");
  const currentDay=await js("Gao.localDay(Gao.state.clock)");
  await click('[data-review-day="'+currentDay+'"]');
  await until("document.activeElement.id==='review-detail-title'");
  const detail='[data-review-detail="'+currentDay+'"]';
  assert(await js("document.querySelector("+JSON.stringify(detail)+").textContent.includes('安装回归合成行动')"));
  assert(await js("document.querySelector("+JSON.stringify(detail)+").textContent.includes('安装回归合成目标')"));
  await screenshot("weekly-review-day-light");
  await click('[data-review-week="previous"]');
  await until("document.querySelector('[data-review-day]')?.dataset.reviewDay!=="+JSON.stringify(firstOfWeek)+" && !!document.querySelector('#review-summary-title')");
  assert(await js("document.querySelector('.review-summary').textContent.includes('历史计划')"));
  await click('[data-review-week="next"]');
  await until("document.querySelector('[data-review-day]')?.dataset.reviewDay==="+JSON.stringify(firstOfWeek));
  await click("[data-review-back]");

  // Verify the toolbar emits the native request while the integration installer
  // separately verifies window creation on an isolated Windows desktop.
  await js("window.testWidgetCalls=0;const widgetFetch=window.fetch;window.fetch=(url,options)=>{if(url==='/api/platform/widgets'){testWidgetCalls++;return Promise.resolve(Response.json({ok:true}));}return widgetFetch(url,options);};");
  await click('#rail-actions [data-action="widgets"]');
  await until("testWidgetCalls===1");
  await click('#rail-actions [data-action="settings"]');
  await setField("#editor [name=appearance]","dark");
  await click("#editor [type=submit]");
  await until("!document.querySelector('#editor').open && document.documentElement.dataset.theme==='dark'");
  await cdp("Emulation.setDeviceMetricsOverride",{width:605,height:780,deviceScaleFactor:1.5,mobile:false});
  await js("Gao.go('today')");
  assert(await js("document.documentElement.scrollWidth <= innerWidth"),"Small dashboard overflows.");
  await screenshot("core-today-dark-small");
  await click("#toolbar .more-button");
  await click('#toolbar .compact-tools [data-action="settings"]');
  await screenshot("core-settings-dark-small");
  await click("#editor [data-close]");
  await until("!document.querySelector('#editor').open");
  await js("document.querySelector('.brand').focus()");
  await nativeKey("Tab",9);
  assert.equal(await js("document.activeElement.dataset.go"),"today");
  await nativeKey("ArrowRight",39);
  assert.equal(await js("document.activeElement.dataset.go"),"rhythm");
  assert(await js("document.activeElement.matches(':focus-visible')"),"Keyboard destination has no visible focus.");
  await click(reviewEntry);
  await until("document.querySelectorAll('[data-review-day]').length===7");
  assert(await js("document.documentElement.scrollWidth <= innerWidth"),"Small weekly review overflows.");
  await screenshot("weekly-review-dark-small");
  await click("[data-review-back]");
  await cdp("Emulation.setDeviceMetricsOverride",{width:1280,height:840,deviceScaleFactor:1.5,mobile:false});
  await js("Gao.act('/api/settings',{appearance:'light'})");
  await go("index");
  await screenshot("core-playground-light");

  await js("Gao.go('footprints','map')");
  await until("document.querySelector('#fp-atlas')?.width > 300");
  await js("const year=document.querySelector('#fp-map-year');year.value='2002';year.dispatchEvent(new Event('change'));");
  await js("const query=document.querySelector('#fp-map-search');query.value='wuhan';query.dispatchEvent(new Event('input',{bubbles:true}));");
  await until("!!document.querySelector('[data-fp-choose=cn-420100]')");
  await click('[data-fp-choose="cn-420100"]');
  await click('[data-fp-action="export"]');
  await until("document.querySelector('#fp-export-map')?.width===2280");
  const ochrePixels=await js([
    "const canvas=document.querySelector('#fp-export-map');",
    "const bytes=canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;",
    "const hex=getComputedStyle(canvas).getPropertyValue('--fp-map-visited').trim();",
    "const [r,g,b]=[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16));",
    "let matching=0;for(let i=0;i<bytes.length;i+=4)if(bytes[i]===r&&bytes[i+1]===g&&bytes[i+2]===b)matching++;matching;"
  ].join(""));
  assert(ochrePixels>40,"The exported visit pin obscured Wuhan's prefecture fill.");
  await click("#editor [data-close]");

  await go("farm");await modeReady("farm");
  let point=await planePoint("farm",-4.24,0,-4.90);
  await mouse("mousePressed",...point);await mouse("mouseReleased",...point);
  await until('document.querySelector("#editor").open');
  await click('[data-action^="estate:plant:"]');
  await until('!!Gao.state.library.farmPlots[0].cropID && !document.querySelector("#editor").open');
  await modeReady("farm");
  const before=await screenshot("farm-before-rotation");
  await key(canvasMode("farm"),"ArrowRight");await delay(150);
  assert(!before.equals(await screenshot("farm-after-rotation")),"Farm camera did not rotate.");

  await go("pasture");await modeReady("pasture");
  const prior=await js("Gao.state.library.pastureAnimals.map(a=>a.id)");
  await screenshot("pasture-before-drag");
  point=await planePoint("pasture",-4.24,.31,-4.48);
  const targetPoint=await planePoint("pasture",-2.10,.31,-4.48);
  await mouse("mousePressed",...point);
  assert.equal(await js("document.querySelector('[data-world-mode=pasture]').dataset.worldSelection"),prior[0],"The first animal was not selected.");
  await mouse("mouseMoved",...targetPoint);await mouse("mouseReleased",...targetPoint);
  await until("Gao.state.library.pastureAnimals[0].id==="+JSON.stringify(prior[1]));
  await modeReady("pasture");await screenshot("pasture-150");

  await go("fishing");await modeReady("fishing");
  await click('[data-action="estate:fishing-spot:1"]');
  await click('[data-action="estate:cast"]');await until("!!Gao.state.cast");
  await modeReady("fishing");await screenshot("lake-bobber");
  await click('[data-action="estate:aquarium"]');await modeReady("aquarium");
  const swim=await screenshot("aquarium-150");
  await delay(650);
  assert(!swim.equals(await screenshot("aquarium-after-swimming")),"Aquarium fish did not swim.");
  await key(canvasMode("aquarium"),"PageDown");await key(canvasMode("aquarium"),"Enter");
  await until('document.querySelector("#editor").open');
  await click("#editor [data-close]");

  await go("island");await modeReady("island");await screenshot("island-150");
  await go("train");await modeReady("train");
  await key(canvasMode("train"),"PageDown");await key(canvasMode("train"),"PageDown");await key(canvasMode("train"),"Enter");
  await until('!!document.querySelector(".fp-3d-info [data-action=train-interior]")');
  await click('[data-action="train-interior"]');await modeReady("train-interior");await screenshot("train-carriage-150");
  await click("#editor [data-close]");await until('!document.querySelector("#editor").open');
  await screenshot("train-station-150");
  await click('[data-fp-action="depart"]');
  await until("Gao.state.footprints.train.journey?.completed===false");await modeReady("train");
  const moving=await screenshot("train-motion-150");
  await delay(400);
  assert(!moving.equals(await screenshot("train-motion-next")),"Train did not move.");

  await cdp("Page.addScriptToEvaluateOnNewDocument",{source:"const old=HTMLCanvasElement.prototype.getContext;HTMLCanvasElement.prototype.getContext=function(type,...args){return type==='webgl'?null:old.call(this,type,...args)};"});
  await cdp("Page.navigate",{url:base+"/?route=gaojiezou://farm"});
  await until("window.Gao?.section==='farm' && !!document.querySelector('.scene-plot-row button')");
  assert.equal(await js("!!document.querySelector('.gao-world-canvas')"),false,"3D fallback was not exercised.");
  assert.deepEqual(errors,[]);
  await js('Gao.api("/api/shutdown",{})');
  console.log("Desktop workbench, focus, check-ins, sleep, chores, goals, linked actions, trends, weekly review, preferences, widget routing, offline map export and six WebGL scenes passed.");
} finally {
  await cleanup();
}
