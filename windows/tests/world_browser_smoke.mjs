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
      const pending=inflight.get(reply.id);inflight.delete(reply.id);
      if(reply.error) pending.reject(Error(reply.error.message)); else pending.resolve(reply.result);
    } else if(reply.method==="Runtime.exceptionThrown") {
      errors.push(reply.params.exceptionDetails.exception?.description || reply.params.exceptionDetails.text);
    }
  };
  function cdp(method,params={}){
    return new Promise((resolve,reject)=>{
      inflight.set(++next,{resolve,reject});
      channel.send(JSON.stringify({id:next,method,params}));
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
  console.log("Offline map export and WebGL farm, pasture, fishing, aquarium, island, train, interiors and fallback passed.");
} finally {
  await cleanup();
}
