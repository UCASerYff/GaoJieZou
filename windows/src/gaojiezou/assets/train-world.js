(() => {
  "use strict";
  const G=window.Gao;
  const art=name=>"/art/"+name+".png";
  const materials=art("WorldMaterialsV357");
  const meadow=art("EstateMeadowV352");
  const foliageTexture=art("FoliageV357");
  const brass="#cca154",iron="#1f2e33",ivory="#e0cfa3",wood="#a87047",teal="#408c91";
  const defs={
    sleeper:["卧铺车","Sleeper","每级缩短巡游奖励间隔 2 小时","Each level shortens the cruise reward interval by 2 hours"],
    dining:["餐车","Dining car","每级增加巡游获得的 1 份物资","Each level adds one supply to cruise rewards"],
    observation:["观景车","Observation car","每级增加新城市奖励 1 份物资","Each level adds one supply for a new city"],
    garden:["花园车","Garden car","每级增加新照片奖励 1 份物资","Each level adds one supply for a new photo"],
    library:["书房车","Library car","每级增加回忆文字奖励 1 份物资","Each level adds one supply for a memory note"]
  };
  const {t,esc,button}=G;
  const coords={yaw:34,zoom:6.8};
  const foliageBounds=[
    [.056933,.099211,.146561,.369786,.792683],[.289177,.111612,.183202,.356257,1.028481],
    [.556933,.095829,.136979,.372041,.736364],[.795941,.126268,.155017,.339346,.913621],
    [.042277,.609921,.168546,.269448,1.251046]
  ];
  let selection;
  const capture=(key)=>t(...defs[key].slice(0,2));
  const row=(value)=>'<span class="bold">'+esc(value)+"</span>";
  function detailBox(root,options,quadrant){
    const u=quadrant%2*.5,v=Math.floor(quadrant/2)*.5;
    return root.box({...options,texture:materials,uv:[u,v,.5,.5]});
  }
  function foliage(root,index,x,y,z,h){
    const crop=foliageBounds[index];
    root.plane({x,y:y+h/2,z,w:h*crop[4],h,billboard:"y",cutout:true,texture:foliageTexture,uv:crop.slice(0,4)});
  }
  function pitchedRoof(root,w,d,y){
    for(const side of [-1,1]) detailBox(root,{x:side*w*.24,y,w:w*.58,h:.10,d,rz:side*-.32,color:"#547067"},1);
  }
  function landscape(root,stage,moving){
    const land=["#ccefc2","#aba06f","#cbdedb"][stage];
    root.plane({w:95,h:95,y:-.53,rx:-Math.PI/2,color:land,
      texture:stage===0?meadow:undefined,repeat:[15,15]});
    for(let layer=2;layer>=0;layer--){
      const tint=["#75968b","#86a395","#a5b7ac"][layer];
      const peak=i=>2+layer+Math.sin(i*.8+layer)*1.3+i%3*.4;
      for(let i=0;i<30;i++){
        root.prism({x:i*2.4-33.8,y:-.5,z:-12-layer*5,rx:-Math.PI/2,h:2,color:tint,
          points:[[-1.2,-2],[1.2,-2],[1.2,peak(i+1)],[-1.2,peak(i)]]});
      }
    }
    if(!moving) for(let i=0;i<24;i++)
      foliage(root,stage===2 || i%3===0?2:1,(i*19)%37-18,-.40,(i*13)%5+3.8,2.1+i%4*.36);
    detailBox(root,{w:24,h:.16,d:2.05,y:-.27,color:"#a09a87"},2);
    for(let i=0;i<48;i++){
      const x=i*.5-12;
      const tie=detailBox(root,{w:.15,h:.075,d:1.8,x,y:-.125,color:"#b09870"},1);
      if(moving){
        tie.animate=(node,sec)=>{node.x=-12+(x+12+sec*6)%24;};
        root.scene.isAnimated=true;
      }
    }
    for(const z of [-.56,.56]) root.box({w:24,h:.1,d:.065,y:-.06,z,color:"#808787",shine:.65});
    if(moving){
      for(let i=0;i<16;i++){
        const initial=i*3-24;
        const node=root.group({x:initial,animate:(n,sec)=>{n.x=-24+(initial+24+sec*6)%48;}});
        foliage(node,i%3===0?2:1,0,-.38,i%2===0?-4.7:4.8,2+i%3*.45);
      }
      for(let i=0;i<7;i++) root.sphere({x:-6.14,y:1.98,r:.1,color:[.91,.93,.88,0],segments:10,animate:(n,sec)=>{
        const q=(sec+i*.18)%2.45/1.4;n.hidden=false;
        n.x=-6.14+q*1.8;n.y=1.98+q*1.7;n.scale=1+q*3;
        n.material.color[3]=q<1?.55*(1-q):0;
      }});
      return;
    }
    detailBox(root,{w:19,h:.28,d:2.6,y:-.25,z:-2.8,color:"#ced0b2"},2);
    for(let i=-16;i<=16;i++) root.box({w:.42,h:.015,d:.13,x:i*.53,y:-.09,z:-1.58,color:"#e3c782"});
    for(const x of [-7,0,7]){
      root.cylinder({r:.055,h:1.65,x,y:.71,z:-3.6,color:"#424d42",segments:10});
      root.sphere({r:.12,x,y:1.58,z:-3.6,color:"#f5c67a",lit:false});
      detailBox(root,{w:1.1,h:.085,d:.4,x,y:.27,z:-2.9,color:"#a98458"},1);
      for(const dx of [-.4,.4]) root.cylinder({r:.04,h:.35,x:x+dx,y:.1,z:-2.9,color:"#424d42",segments:10});
    }
    const station=root.group({x:-6,z:-5.3});
    detailBox(station,{w:2.8,h:1.5,d:1.35,y:.65,color:"#ba9c75"},1);
    pitchedRoof(station,3.4,1.7,1.65);
    station.box({w:.48,h:.94,d:.03,y:.4,z:.69,color:"#2b4247"});
    for(const x of [-.91,.91]) station.box({w:.51,h:.56,d:.04,x,y:.8,z:.7,color:"#e0b366",lit:false});
  }

  function wheels(root,active,ghost){
    for(const x of ghost?[-.68,.68]:[-.66,0,.66]) for(const z of [-.54,.54]){
      const wheel=root.group({x,y:.23,z,animate:active?(node,sec)=>{node.rz=sec*Math.PI*2/.8;}:undefined});
      wheel.cylinder({r:ghost?.20:.25,h:.13,rx:Math.PI/2,color:ghost?"#468e8b":iron,shine:.55,segments:18});
      if(ghost) continue;
      wheel.cylinder({r:.12,h:.018,z:Math.sign(z)*.076,rx:Math.PI/2,color:brass,shine:.6,segments:12});
      for(let j=0;j<6;j++){
        const a=j*Math.PI/3,edge=Math.sign(z)*.083;
        wheel.beam({from:[0,0,edge],to:[Math.sin(a)*.21,Math.cos(a)*.21,edge],r:.012,color:brass});
      }
    }
  }
  function blueprint(node){
    const c="#39c7bf";
    for(const x of [-1.02,1.02]) for(const z of [-.62,.62]) node.box({x,y:1.06,z,w:.022,h:1.15,d:.022,color:c,lit:false});
    for(const y of [.485,1.635]) {
      for(const x of [-1.02,1.02]) node.box({x,y,w:.022,h:.022,d:1.24,color:c,lit:false});
      for(const z of [-.62,.62]) node.box({y,z,w:2.04,h:.022,d:.022,color:c,lit:false});
    }
    wheels(node,false,true);
  }
  function locomotive(node){
    node.cylinder({x:-.35,y:.98,r:.41,h:1.27,rz:Math.PI/2,color:iron,shine:.5});
    for(const x of [-.88,-.45,-.05]) node.ring({x,y:.98,r:.418,width:.045,rz:Math.PI/2,color:brass,shine:.6});
    detailBox(node,{x:.60,y:1.04,w:.74,h:1.06,d:1.04,color:"#57756e"},3);
    node.box({x:.6,y:1.63,w:.93,h:.14,d:1.29,color:iron});
    for(const z of [-.53,.53]){
      node.box({x:.62,y:1.22,z,w:.41,h:.43,d:.025,color:ivory,shine:.55});
      node.box({x:-.15,y:.25,z:z*1.17,w:1.25,h:.045,d:.04,color:brass,shine:.6});
    }
    node.cylinder({x:-.64,y:1.56,r:.12,h:.53,color:iron,shine:.55});
    node.cylinder({x:-.64,y:1.84,r:.19,h:.05,color:brass,shine:.6});
    node.cylinder({x:-1.01,y:1.10,r:.12,h:.06,rz:Math.PI/2,color:ivory,lit:false});
    for(let i=0;i<6;i++) node.beam({from:[-1.12,.46,(i-3)*.16],to:[-1.29,.25,(i-3)*.18],r:.019,color:brass});
  }
  function carriage(node,kind,level){
    detailBox(node,{w:1.93,h:.82,d:1.14,y:.98,color:"#75918b"},3);
    for(const z of [-.58,.58]){
      for(const y of [.64,1.37,...(level>=2?[.72]:[])]) node.box({w:1.96,h:.025,d:.028,y,z,color:brass,shine:.5});
      for(const x of [-.66,-.22,.22,.66]){
        node.box({x,y:1.10,z,w:.34,h:.48,d:.035,color:brass,shine:.4});
        node.box({x,y:1.10,z:z*1.06,w:.28,h:.39,d:.023,color:"#7ba6a3",shine:.44});
        if(kind==="sleeper") for(const dx of [-.11,.11]) node.box({x:x+dx,y:1.10,z:z*1.09,w:.06,h:.37,d:.01,color:"#b07854"});
        if(kind==="dining") node.sphere({x,y:.98,z:z*1.09,r:.035,color:ivory,lit:false,segments:8});
        if(kind==="library") for(let j=0;j<4;j++) node.box({x:x+(j-2)*.05,y:.98,z:z*1.09,w:.033,h:.14,d:.014,color:["#664d36","#805942","#995c52","#b1614e"][j]});
      }
    }
    if(kind==="garden"){
      detailBox(node,{w:1.7,h:.13,d:.85,y:1.45,color:"#baa376"},1);
      foliage(node,4,0,1.52,0,.60);
      for(const x of [-.8,.8]) for(const z of [-.5,.5]) node.cylinder({x,y:1.73,z,r:.025,h:.73,color:brass});
      node.box({w:1.9,h:.06,d:1.18,y:2.11,color:ivory});
    } else if(kind==="observation"){
      node.box({w:1.90,h:.34,d:1.1,y:1.63,color:"#5c969e",shine:.7});
      for(const x of [-.72,-.24,.24,.72]) node.box({x,y:1.81,w:.025,h:.035,d:1.07,color:brass});
    } else {
      node.box({w:2.07,h:.22,d:1.3,y:1.5,color:iron,shine:.3});
      for(let i=0;i<10;i++) node.box({x:i*.2-.9,y:1.617,w:.025,h:.024,d:1.17,color:"#596b6b"});
    }
    if(level>=3) for(const x of [-.93,.93]) node.cylinder({x,y:1.05,z:.63,r:.025,h:.95,color:brass,shine:.6});
    if(level>=4) for(const x of [-.91,.91]) node.sphere({x,y:1.48,z:.62,r:.045,color:ivory,lit:false});
  }
  function train(world,items,stage,moving){
    landscape(world.root,stage,moving);
    for(const {id,x,kind,level,title} of items){
      const node=world.group({id,x,movable:kind!=="engine" && kind!=="ghost" && !moving});
      if(kind==="ghost") blueprint(node);
      else{
        node.box({w:2.05,h:.15,d:1.22,y:.44,color:iron,shine:.48});
        wheels(node,moving,false);
        for(const stand of [-1.10,1.10]) node.box({x:stand,y:.41,w:.25,h:.08,d:.16,color:iron,shine:.65});
        if(kind==="engine") locomotive(node); else carriage(node,kind,level);
      }
      world.label(node,{text:title+(kind==="ghost"?" · +":" · "+level),y:2.55,w:1.78,onlySelected:true});
    }
  }

  function interiorModel(world,kind,level){
    const root=world.root,cream="#edd6ab",glass="#70bdd1";
    detailBox(root,{w:7.5,h:.28,d:3,y:-.15,color:"#bea476"},1);
    root.box({w:7.5,h:2.8,d:.13,y:1.25,z:-1.45,color:cream});
    for(const x of [-3.7,3.7]) root.box({x,y:1.25,w:.13,h:2.8,d:3,color:cream});
    for(const x of [-2.35,0,2.35]){
      root.box({x,y:1.65,z:-1.36,w:1.55,h:1.2,d:.08,color:glass,shine:.5});
      root.box({x,y:2.30,z:-1.3,w:1.72,h:.07,d:.15,color:wood});
      for(const dx of [-.83,.83]) root.box({x:x+dx,y:1.65,z:-1.3,w:.07,h:1.25,d:.16,color:wood});
      for(const side of [-.68,.68]) for(let i=0;i<3;i++) root.cylinder({x:x+side+i*.035,y:1.68,z:-1.23,r:.028,h:1.16,color:"#8c5745",segments:8});
      root.box({x,y:1.03,z:-1.2,w:1.52,h:.035,d:.14,color:"#bf8f4f"});
    }
    for(const x of [-2.7,-.9,.9,2.7]) root.cylinder({x,y:2.55,r:.15,h:.10,color:"#fcde8c",lit:false});
    for(const x of [-2.2,0,2.2]){
      if(kind==="sleeper"){
        root.box({x,y:.37,z:.45,w:1.7,h:.28,d:1,color:teal});
        root.box({x:x-.45,y:.59,z:.45,w:.55,h:.12,d:.72,color:cream});
      } else if(kind==="dining"){
        root.box({x,y:.80,z:.05,w:1.35,h:.12,d:.75,color:wood});
        for(const z of [-.55,.55]) root.box({x,y:.29,z,w:.62,h:.32,d:.48,color:teal});
        for(const z of [-.22,.22]){
          root.cylinder({x,y:.88,z,r:.12,h:.015,color:"#ffffff"});
          root.cylinder({x:x+.29,y:.98,z,r:.034,h:.15,color:"#c7d1bd"});
        }
        root.cylinder({x,y:1.02,r:.06,h:.22,color:cream});
        root.sphere({x,y:1.16,r:.038,color:"#f5bd59",lit:false});
      } else if(kind==="observation"){
        root.box({x,y:.3,z:.3,w:1.35,h:.27,d:.75,color:teal});
        root.box({x,y:.75,z:-.12,w:1.35,h:.68,d:.18,color:teal});
      } else if(kind==="garden") {
        root.cylinder({x,y:.18,z:.65,r:.32,h:.28,color:wood});
        root.sphere({x,y:.75,z:.65,r:.39,color:"#479e63"});
        root.sphere({x:x+.15,y:1,z:.65,r:.20,color:"#d67a85"});
        foliage(root,3,x,.22,.3,1);
      } else{
        root.box({x,y:.72,z:.45,w:1.6,h:1.35,d:.45,color:wood});
        for(const y of [.4,.75,1.1]) root.box({x,y,z:.48,w:1.45,h:.07,d:.48,color:cream});
        for(const dx of [-.45,0,.45]) root.box({x:x+dx,y:.95,z:.48,w:.15,h:.26,d:.22,color:teal});
      }
    }
    if(kind==="observation"){
      root.cylinder({y:.63,z:1.03,r:.17,h:1.24,color:"#9eadb5",shine:.6});
      root.sphere({y:1.30,z:1.03,r:.27,color:"#5e94ad",shine:.4});
    }
    root.box({y:.02,z:1.1,w:6.9,h:.015,d:.35,color:"#7d4538"});
    if(level>=3) for(const x of [-3.4,3.4]) root.cylinder({x,y:1.27,z:1.24,r:.06,h:2.5,color:"#deae63",shine:.3});
  }

  function interior(key,level){
    const form=G.modal(capture(key)+" · Lv. "+level,'<div class="fp-train-interior"></div><p>'+esc(t(...defs[key].slice(2)))+'</p>');
    const host=form.querySelector(".fp-train-interior");
    const world=window.GaoWorld?.mount(host,{mode:"train-interior",yaw:30,zoom:3.45,
      camera:{pitch:Math.atan2(13,17),target:[0,.85,0],minimumZoom:2,maximumZoom:7},
      label:t("车厢内部。方向键可调整视角。","Carriage interior. Use the arrow keys to adjust the camera."),
      build:world=>interiorModel(world,key,level)});
    if(!world) host.hidden=true;
  }

  function mount(){
    const host=document.querySelector(".fp-train-world");
    const data=G.state?.footprints;
    if(!host || !data?.train || !window.GaoWorld) return;
    const route=data.train,levels=route.carriageLevels || {};
    const moving=!!(route.journey && !route.journey.completed);
    const itinerary=route.journey?.destination ?? data.plotted.find(place=>place.id===route.routeCityID);
    const latitude=Math.abs(itinerary?.latitude ?? 28),stage=latitude>45?2:latitude<22?1:0;
    const past=[...new Set([...(route.carriageOrder || []),...Object.keys(defs)])].filter(key=>levels[key] && defs[key]);
    const built=past.map((key,index)=>({id:key,kind:key,x:index*2.25-3.25,level:levels[key],title:capture(key)}));
    const ghosts=moving?[]:Object.keys(defs).filter(key=>!levels[key]).map((key,index)=>({
      id:"ghost:"+key,kind:"ghost",x:(past.length+index)*2.25-3.10,level:0,title:capture(key)
    }));
    const items=[{id:"engine",kind:"engine",x:-5.5,level:1,title:t("车头","Locomotive")},...built,...ghosts];
    if(!items.some(item=>item.id===selection)) selection=null;
    host.hidden=false;
    host.insertAdjacentHTML("beforeend",'<div class="fp-train-world-caption"><strong>'+esc(moving?t("列车行驶中","On the move"):t("列车停靠中","At the station"))+
      '</strong><span>'+esc(t("整列连挂 · 点击车厢查看内部","Coupled train · select a car to look inside"))+
      '</span></div><div class="fp-3d-info" hidden></div>');
    const info=host.querySelector(".fp-3d-info");
    function pick(id){
      selection=id;
      const ghost=id?.startsWith("ghost:"),key=ghost?id.slice(6):id;
      if(!defs[key]) {info.hidden=true;return;}
      const level=levels[key] || 0,cost=[6,12,20,30][level];
      info.hidden=false;
      info.innerHTML=row(capture(key)+(level?" · Lv. "+level:" · "+t("施工蓝图","Blueprint")))+
        '<div class="row">'+(!ghost?button(t("查看内部","Interior"),{action:"train-interior"}):"")+
        (level<4?button((ghost?t("建造","Build"):t("升级","Upgrade"))+" · "+cost+" "+t("物资","supplies"),
          {action:"train-upgrade",disabled:route.materials<cost,className:"primary"}):"")+"</div>";
      info.querySelector('[data-action="train-interior"]')?.addEventListener("click",()=>interior(key,level));
      info.querySelector('[data-action="train-upgrade"]')?.addEventListener("click",async()=>{
        const result=await G.act("/api/footprints/train/upgrade",{carriage:key},{render:false});
        if (result?.result?.upgraded) { selection=key;G.render(); }
      });
    }
    const world=window.GaoWorld.mount(host,{mode:"train",items,...coords,selectionRadius:1.08,
      camera:{pitch:Math.atan2(13,19),minimumZoom:4,maximumZoom:16},
      label:t("旅行列车三维场景。方向键调整视角，Page Up 或 Page Down 选择车厢。",
        "Travel train 3D scene. Use arrows for the camera and Page Up or Page Down to select a car."),
      selectedID:selection,onCamera:next=>Object.assign(coords,next),onSelect:pick,dragBoundary:11,onFallback:()=>{host.hidden=true;},
      onMove:async (id,x)=>{
        const index=Math.max(0,Math.min(past.length-1,Math.round((x+3.25)/2.25)));
        return Boolean((await G.act("/api/footprints/train/reorder",{carriage:id,slot:index}))?.result);
      },
      build:(world,items)=>train(world,items,stage,moving)
    });
    if(!world) { host.hidden=true;return; }
    if (selection) pick(selection);
  }
  window.TrainWorld={mount};
})();
