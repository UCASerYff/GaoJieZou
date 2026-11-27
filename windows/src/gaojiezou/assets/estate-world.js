(() => {
  "use strict";
  const G=window.Gao;
  const art=name=>"/art/"+name+".png";
  const TAU=Math.PI*2;
  const meadow=art("EstateMeadowV352");
  const plots=25;
  const rowSize=5;
  const pitch=Math.atan2(24,17);
  const spots=[["芦苇湾","Reed Bay",-0.8,3.3],["湖心","Lake Center",2,.8],["静水岸","Stillwater Bank",5.4,3.7]];
  const camera={farm:{yaw:0,zoom:7.6},pasture:{yaw:0,zoom:7.6},fishing:{yaw:0,zoom:8.2},aquarium:{yaw:0,zoom:5.9}};
  // Per-tile alpha bounds from the original 6×4 atlases, using Swift's alpha threshold and margin.
  const atlasBounds={
    CropAtlasV15:[
      [0.010367,0.027911,0.1563,0.213716,0.7313],[0.181021,0.043062,0.152313,0.200957,0.7579],[0.333333,0.026316,0.160287,0.216906,0.739],[0.508772,0.012759,0.150718,0.236842,0.6364],
      [0.674641,0.029506,0.155502,0.212121,0.7331],[0.838915,0.088517,0.14992,0.157097,0.9543],[0.009569,0.26236,0.157097,0.224083,0.7011],[0.166667,0.267145,0.15311,0.222488,0.6882],
      [0.34689,0.26874,0.145136,0.220893,0.657],[0.507974,0.26874,0.158692,0.219298,0.7236],[0.682616,0.259968,0.145933,0.22807,0.6399],[0.833333,0.285486,0.1563,0.192982,0.8099],
      [0.005582,0.526316,0.161085,0.1874,0.8596],[0.166667,0.514354,0.166667,0.235247,0.7085],[0.333333,0.50638,0.157097,0.208931,0.7519],[0.504785,0.542265,0.1563,0.207337,0.7538],
      [0.677831,0.503987,0.141946,0.245614,0.5779],[0.834928,0.519936,0.157097,0.201754,0.7787],[0.007177,0.749601,0.15949,0.216108,0.738],[0.166667,0.749601,0.160287,0.224083,0.7153],
      [0.342105,0.750399,0.1563,0.210526,0.7424],[0.50638,0.749601,0.160287,0.215311,0.7444],[0.667464,0.749601,0.164274,0.217703,0.7546],[0.834928,0.751994,0.15949,0.211324,0.7547]
    ],
    CropYoungAtlasV15:[
      [0.035807,0.073242,0.114583,0.176758,0.9724],[0.201823,0.082031,0.121745,0.167969,1.0872],[0.365885,0.089844,0.111328,0.160156,1.0427],[0.522786,0.077148,0.119141,0.172852,1.0339],
      [0.688802,0.077148,0.120443,0.172852,1.0452],[0.854818,0.107422,0.11263,0.142578,1.1849],[0.033854,0.290039,0.115885,0.195312,0.89],[0.215495,0.25,0.091146,0.236328,0.5785],
      [0.36849,0.25,0.108724,0.237305,0.6872],[0.52474,0.25,0.120443,0.236328,0.7645],[0.684896,0.25,0.130859,0.236328,0.8306],[0.858073,0.25,0.108724,0.236328,0.6901],
      [0.035156,0.532227,0.11849,0.217773,0.8161],[0.19987,0.532227,0.125651,0.217773,0.8655],[0.357422,0.521484,0.117188,0.228516,0.7692],[0.526042,0.544922,0.115234,0.15625,1.1062],
      [0.692708,0.515625,0.111979,0.234375,0.7167],[0.844401,0.544922,0.130859,0.205078,0.9571],[0.025391,0.75,0.141276,0.19043,1.1128],[0.201823,0.75,0.114583,0.189453,0.9072],
      [0.356771,0.75,0.125,0.19043,0.9846],[0.522135,0.75,0.124349,0.189453,0.9845],[0.683594,0.75,0.130208,0.19043,1.0256],[0.849609,0.75,0.120443,0.192383,0.9391]
    ],
    AnimalAtlasV23:[
      [0.036458,0.036133,0.09375,0.178711,0.7869],[0.201823,0.036133,0.095703,0.178711,0.8033],[0.374349,0.036133,0.084635,0.178711,0.7104],[0.540365,0.036133,0.085938,0.178711,0.7213],
      [0.703776,0.036133,0.091797,0.178711,0.7705],[0.871745,0.056641,0.089844,0.137695,0.9787],[0.038411,0.286133,0.089844,0.178711,0.7541],[0.19987,0.286133,0.10026,0.178711,0.8415],
      [0.371094,0.303711,0.090495,0.143555,0.9456],[0.529948,0.291016,0.10612,0.168945,0.9422],[0.697917,0.326172,0.103516,0.098633,1.5743],[0.866536,0.286133,0.099609,0.178711,0.8361],
      [0.039062,0.536133,0.087891,0.178711,0.7377],[0.214193,0.536133,0.070964,0.178711,0.5956],[0.374349,0.536133,0.084635,0.178711,0.7104],[0.541667,0.536133,0.083333,0.178711,0.6995],
      [0.699219,0.539062,0.101562,0.172852,0.8814],[0.866536,0.540039,0.10026,0.170898,0.88],[0.03776,0.786133,0.091146,0.178711,0.765],[0.210938,0.786133,0.077474,0.178711,0.6503],
      [0.365885,0.786133,0.100911,0.178711,0.847],[0.533854,0.786133,0.098307,0.178711,0.8251],[0.711589,0.789062,0.076172,0.171875,0.6648],[0.867188,0.790039,0.098958,0.170898,0.8686]
    ],
    AnimalYoungAtlasV23:[
      [0.033203,0.036133,0.099609,0.178711,0.8361],[0.196615,0.039062,0.10612,0.172852,0.9209],[0.36849,0.036133,0.096354,0.178711,0.8087],[0.533854,0.036133,0.098958,0.178711,0.8306],
      [0.699219,0.036133,0.101562,0.178711,0.8525],[0.863281,0.038086,0.10612,0.174805,0.9106],[0.029948,0.286133,0.10612,0.177734,0.8956],[0.196615,0.286133,0.10612,0.177734,0.8956],
      [0.363281,0.292969,0.10612,0.164062,0.9702],[0.529948,0.293945,0.10612,0.162109,0.9819],[0.696615,0.321289,0.10612,0.108398,1.4685],[0.863281,0.287109,0.10612,0.176758,0.9006],
      [0.035156,0.536133,0.096354,0.178711,0.8087],[0.205729,0.536133,0.087891,0.178711,0.7377],[0.367839,0.536133,0.097005,0.178711,0.8142],[0.539062,0.536133,0.087891,0.178711,0.7377],
      [0.696615,0.546875,0.10612,0.15625,1.0188],[0.863281,0.543945,0.10612,0.163086,0.976],[0.032552,0.786133,0.100911,0.178711,0.847],[0.19987,0.786133,0.099609,0.178711,0.8361],
      [0.363281,0.792969,0.10612,0.164062,0.9702],[0.529948,0.796875,0.10612,0.157227,1.0124],[0.702474,0.786133,0.094401,0.178711,0.7923],[0.863281,0.797852,0.10612,0.154297,1.0316]
    ]
  };
  const t=G.t;
  const at=(index)=>[(index%rowSize-2)*2.12,(Math.floor(index/rowSize)-2)*2.45];
  const soil=()=> {
    const texture=document.createElement("canvas");
    texture.width=texture.height=256;
    const ctx=texture.getContext("2d");
    ctx.fillStyle="#4a301f";ctx.fillRect(0,0,256,256);
    for(let i=0;i<2600;i++){
      const x=(i*137+19)%256,y=(i*83+i*i*7)%256;
      ctx.fillStyle=i%3 ? "rgba(196,150,108,.12)" : "rgba(17,11,10,.25)";
      ctx.fillRect(x,y,1+i%2,2+i%5);
    }
    return texture;
  };
  let soilTexture;

  function tree(root,x,z,scale,leaves) {
    const node=root.group({x,z,scale});
    node.cylinder({r:.12,h:1.08,y:.21,color:"#61452f"});
    for(let i=0;i<5;i++) {
      const a=i*TAU/5,dx=Math.sin(a)*.36,dz=Math.cos(a)*.34;
      node.cylinder({r:.045,h:.64,x:dx*.43,y:.71,z:dz*.43,rz:-dx*.55,color:"#61452f",segments:8});
      node.sphere({r:.42,x:dx,y:1.06+(i%2)*.18,z:dz,sx:1.15,sy:.92,sz:.88,color:leaves,segments:10});
    }
    node.sphere({r:.43,y:1.51,color:leaves,segments:10});
  }

  function barn(root,farm) {
    const house=root.group({x:farm?8.1:8.6,z:farm?-5.8:-5.7});
    house.box({w:farm?2:2.7,h:farm?1.35:1.60,d:farm?1.5:2,y:farm?.35:.45,color:farm?"#ad7a4d":"#a94a34"});
    for(const side of [-1,1]) {
      house.box({x:side*(farm?.48:.65),y:farm?1.30:1.61,w:farm?1.42:1.9,h:.12,d:farm?1.9:2.4,rz:-side*.43,
        color:farm?"#4d6d5f":"#4f5b57",texture:art("WorldMaterialsV357"),uv:[.5,0,.5,.5]});
    }
    if(farm) {
      house.box({w:.60,h:.86,d:.036,y:.13,z:.77,color:"#6e4633"});
      for(let i=0;i<3;i++) house.cylinder({x:-.6+i*.55,y:-.06,z:1.2,r:.22,h:.40,color:"#995232",segments:12});
    } else {
      house.box({w:.9,h:1.2,d:.05,y:.2,z:1.02,color:"#543b29"});
      root.box({x:-8,z:-1,w:1.8,h:.35,d:.68,color:"#946438"});
      root.box({x:-8,y:.2,z:-1,w:1.55,h:.035,d:.5,color:"#4da1b0",shine:.6});
      for(let i=0;i<3;i++) root.cylinder({x:7.8+i*.8,y:.1,z:3.9,r:.42,h:.68,rz:Math.PI/2,color:"#c7a652",segments:16});
    }
  }

  function grounds(root,farm) {
    soilTexture ||= soil();
    root.plane({w:60,h:60,rx:-Math.PI/2,y:-.32,texture:meadow,repeat:[12,12],color:farm?"#ccefc2":"#ffd17a"});
    for(let i=0;i<18;i++){
      const x=i<10?(i-5)*2.7:i%2===0?-12.5:12.5;
      const z=i<10?-10.5:(i-14)*2.5;
      tree(root,x,z,.85+i%3*.16,!farm && i%3===0?"#948a40":"#2e6e3d");
    }
    for(const x of [-6.45,6.45]) {
      for(let i=0;i<9;i++) root.cylinder({x,y:.03,z:(i-4)*1.55,r:.055,h:.58,color:"#946438",segments:10});
      for(const y of [.02,.28]) root.box({x,y,w:.07,h:.07,d:12.5,color:"#946438"});
    }
    for(let i=0;i<17;i++) root.box({x:(i-8)*.87,y:-.23,z:6.1,w:.72,h:.025,d:.43,color:"#a8a17a"});
    for(let i=0;i<95;i++){
      const x=(i*19)%180/10-9,z=(i*31)%170/10-8.5;
      if(Math.abs(x)<6.7 && Math.abs(z)<6.6) continue;
      for(let j=0;j<3;j++) root.box({x:x+j*.045,y:-.18,z,w:.025,h:.12+j*.055,d:.022,rz:(j-1)*.28,color:"#457840"});
      if(i%4===0) root.sphere({x,y:-.02,z,r:.055,color:i%2===0?"#fae38f":"#ebb0c4",segments:8});
    }
    if(farm) {
      for(let i=0;i<plots;i++){
        const [x,z]=at(i);
        root.box({x,y:-.16,z,w:1.88,h:.13,d:1.82,texture:soilTexture});
        for(let row=0;row<5;row++) root.box({x,y:-.075,z:z+(row-2)*.31,w:1.7,h:.045,d:.028,color:"#422b1a"});
      }
      root.box({x:-6,y:-.19,w:.34,h:.07,d:12.3,color:"#3091ad",shine:.55});
      for(const x of [-6.25,-5.77]) root.box({x,y:-.16,w:.1,h:.1,d:12.5,color:"#96966e"});
    }
    barn(root,farm);
  }

  function specimen(node,item,mode){
    const farm=mode==="farm",young=item.level===1;
    const texture=farm ? young?"CropYoungAtlasV15":"CropAtlasV15" : young?"AnimalYoungAtlasV23":"AnimalAtlasV23";
    const tall=farm ? ["apple","peach","corn","sunflower"] : ["horse","ostrich","camel","yak","peacock"];
    const maxHeight=tall.includes(item.species)?1.66:1.38;
    const size=farm?(young?.60:item.level===2?.82:1):young?.74:1;
    const crop=atlasBounds[texture][item.atlas];
    const ratio=crop[4];
    const h=Math.min(.86,maxHeight*size*.84*.68,1.4/ratio);
    const uv=crop.slice(0,4);
    node.cylinder({r:.38,y:.068,h:.004,color:[.13,.09,.05,.32],segments:18,lit:false,ignorePick:true});
    node.plane({y:(farm?.12:.07)+h/2,z:.42,w:h*ratio,h,billboard:true,texture:art(texture),uv,cutout:true});
    if(!farm && item.level===3) node.sphere({r:.07,x:.66,y:.64,z:.42,color:"#ffc94a",shine:.3});
  }
  function estate(world,items,mode){
    const farm=mode==="farm";
    const root=world.root;
    grounds(root,farm);
    for(const item of items){
      const {id,kind,level,x,z}=item;
      const node=root.group({id:kind==="locked"?undefined:id,x,z,movable:item.movable,animate:kind==="animal"?(n,now)=>{
        const motion=(1-Math.cos(now*TAU/5))/2;
        n.x=x+.09*motion;n.z=z+.05*motion;
      }:undefined});
      if(farm){
        node.box({w:1.67,h:.14,d:1.56,color:kind==="locked"?"#827d69":undefined,texture:kind==="locked"?undefined:soilTexture,ignorePick:kind==="locked"});
        if(kind!=="locked"){
          for(let row=0;row<5;row++) node.box({y:.079,z:(row-2)*.29,w:1.51,h:.015,d:.024,color:"#40291a"});
        }
        if(kind==="unlock"){
          node.box({y:.4,w:.13,h:.63,d:.13,color:"#946b4a"});
          node.box({y:.72,w:.76,h:.46,d:.06,color:"#e6c57a"});
        } else if(kind==="crop") specimen(node,item,mode);
      } else if(kind==="animal") specimen(node,item,mode);
      else{
        node.box({y:.04,w:1.44,h:.12,d:1.39,color:"#b58c5c"});
        if(kind==="unlock") node.cylinder({r:.68,top:0,h:1.1,y:.65,color:"#edbd5c",segments:8});
        else for(const x of [-.54,.54]) node.cylinder({x,y:.16,z:.45,r:.035,h:.22,color:"#b08c57",segments:10});
      }
      if(item.title) world.label(node,{text:item.title,y:1.30,z:.45,detail:item.detail,progress:item.progress});
    }
  }

  function worldItems(mode,state){
    if(mode==="farm"){
      const crops=state.catalog.crops, rows=state.library.farmPlots;
      return Array.from({length:plots},(_,index)=>{
        const [x,z]=at(index),row=rows[index];
        if(!row) return index===rows.length ? {id:"expand",kind:"unlock",x,z,title:t("开垦","Expand"),detail:state.estate.nextPlotCost+" "+t("金币","coins")} :
          {kind:"locked",x,z};
        const atlas=crops.findIndex(crop=>crop.id===row.cropID), crop=crops[atlas];
        const progress=crop ? Math.min(1,row.growthMinutes/crop.minutes) : 0;
        return {id:row.id,kind:crop?"crop":"plot",x,z,level:Math.min(3,Math.floor(progress*3)+1),species:crop?.id,
          atlas,title:crop?t(crop.name):"",detail:progress>=1?t("可收获","Ready to harvest"):t("生长","Growth")+" "+Math.floor(progress*100)+"%",
          progress:crop?progress:null};
      });
    }
    const animals=state.catalog.animals, rows=state.library.pastureAnimals, capacity=state.library.animalShelterCapacity;
    return Array.from({length:plots},(_,index)=>{
      const [x,z]=at(index),row=rows[index];
      if(!row) return index===capacity ? {id:"expand",kind:"unlock",x,z,title:t("扩建","Expand"),detail:state.estate.nextShelterCost+" "+t("金币","coins")} :
        {id:index<capacity?"shelter:"+index:undefined,kind:"shelter",x,z};
      const atlas=animals.findIndex(entry=>entry.id===row.animalID), animal=animals[atlas];
      const adulthood=Math.min(1,row.growthHours/(animal?.maturity || 12));
      const pending=row.pendingProducts||0;
      const target=state.library.activeSleep?.targetHours || state.settings.sleepTargetHours;
      const sleep=state.library.activeSleep ? Math.max(0,(G.currentClock()-state.library.activeSleep.startedAt)/3600) : 0;
      const cycle=Math.max(0,sleep/target-Math.floor(sleep/target));
      const progress=adulthood<1?adulthood:pending?1:cycle;
      return {id:row.id,kind:animal?"animal":"shelter",x,z,movable:true,level:adulthood<1?1:pending?3:2,
        species:row.animalID,atlas,title:t(animal?.name || row.animalID),
        detail:pending ? t("可收取","Ready")+" ×"+pending : adulthood<1 ? t("成长","Growth")+" "+Math.floor(adulthood*100)+"%" :
          state.library.activeSleep?t("产出","Production")+" "+Math.floor(cycle*100)+"%":t("睡眠恢复产出","Sleep restores production"),progress};
    });
  }

  function aquarium(world,items) {
    const root=world.root;
    for(let i=0;i<17;i++) {
      const x=(i%7-3)*2.6,z=(i%4-3),duration=11+i%4;
      root.sphere({x,y:-2,z,r:.025+(i%3)*.012,color:[.6,.90,.92,.3],segments:8,animate:(node,time)=>{
        const progress=Math.max(0,((time+duration-i*.35)%duration)/duration);
        node.x=x+.5*progress;node.y=-2+12*progress;
      }});
    }
    for(const {id,fishID,name,rarity} of items){
      const seed=[...id].reduce((n,c)=>(n*31+c.charCodeAt(0))%10007,0);
      const start=(seed*353)%997/997*TAU,depth=seed%5*.6-1.4,y=1.4+seed%7*.63,duration=22+seed%17;
      let fish;
      const node=root.group({id,scale:.80+seed%5*.08,animate:(n,seconds)=>{
        const phase=start+seconds/duration*TAU;
        n.x=Math.sin(phase)*7.6;n.y=y+Math.sin(phase*2+start)*.40;n.z=depth+Math.cos(phase)*.42;
        if(fish) fish.flipX=Math.cos(phase)<0;
      }});
      const scale=rarity>=4?1.18:rarity===1?.88:1;
      fish=node.plane({y:.78,w:1.4*scale,h:.98*scale,texture:art("Fish-"+fishID+"-V15"),billboard:"y",cutout:true});
      world.label(node,{text:name,y:1.54,w:1.64,onlySelected:true});
    }
  }

  function lake(world,cast,spotIndex) {
    const root=world.root;
    const rodTip=[-3,2.3,1.5];
    root.beam({from:[-5.3,.4,4],to:rodTip,r:.028,color:"#4a3829"});
    for(let i=0;i<16;i++) root.ring({r:.10+i%4*.12,width:.012,z:(i*17)%90/10-2,x:(i*37)%95/10,y:-.1,
      color:[.67,.87,.85,.18],animate:(node,seconds)=>{
        const phase=(((seconds-i%7*.7)%5)+5)%5/5;
        node.scale=.6+phase*1.7;
        node.material.color[3]=.18*Math.sin(phase*Math.PI);
      }});
    if(!cast) return;
    const [, ,x,z]=spots[spotIndex];
    const float=root.group({id:"bobber",x,z,animate:node=>{
      const now=G.currentClock(),age=now-cast.castAt,phase=now-cast.biteAt;
      const ratio=Math.min(1,Math.max(0,age/.7));
      node.x=rodTip[0]*(1-ratio)+x*ratio;
      node.z=rodTip[2]*(1-ratio)+z*ratio;
      node.y=ratio<1?rodTip[1]*(1-ratio)+Math.sin(ratio*Math.PI)*.65:
        -Math.abs(Math.sin(age*(phase>=0?7:1.4)))*(phase>=0?.20:.035);
    }});
    float.cylinder({r:.065,h:.33,y:.14,color:"#f5e8c4",segments:12});
    float.sphere({r:.1,y:.12,color:"#e3422e",segments:12});
    for(let i=0;i<3;i++) root.ring({x,z,y:-.1,r:.15,width:.024,color:[.75,.94,.88,0],animate:node=>{
      const now=G.currentClock();
      const age=now-cast.castAt-.7;
      const phase=age<0 ? 0 : ((age+i*.5)%1.6)/1.6;
      node.scale=1+phase*(now>=cast.biteAt?4:2);
      node.material.color[3]=age<0 ? 0 : .7*(1-phase);
    }});
    const endGroup=root.group({animate:node=>{
      const from=rodTip,to=[float.x,float.y+.18,float.z];
      const v=to.map((value,i)=>value-from[i]),length=Math.hypot(...v);
      if(!length) return;
      // The line is a unit-long cylinder scaled between the rod and the float.
      node.x=(from[0]+to[0])/2;node.y=(from[1]+to[1])/2;node.z=(from[2]+to[2])/2;
      node.rx=Math.atan2(v[2],v[1]);node.rz=-Math.asin(v[0]/length);node.scale=length;
    }});
    endGroup.cylinder({r:.002,h:1,color:"#c4d4bd",segments:8,lit:false});
  }

  function mount(host,mode,options){
    if(!host) return null;
    const worldOptions=camera[mode];
    const grid=mode==="farm" || mode==="pasture";
    const cameraOptions=grid?{pitch,minimumZoom:4,maximumZoom:15}:mode==="aquarium"?{target:[0,4,0],pitch:0,minimumZoom:3.5,maximumZoom:10}:
      {minimumZoom:4.5,maximumZoom:13};
    const state=G.state;
    const items=grid?worldItems(mode,state):mode==="aquarium"?state.library.aquariumFish.map(row=>{
      const fish=state.catalog.fish.find(spec=>spec.id===row.fishID);
      return {id:row.id,fishID:row.fishID,name:t(fish?.name || row.fishID),rarity:fish?.rarity || 1};
    }):[];
    return window.GaoWorld?.mount(host,{mode,items,...worldOptions,camera:cameraOptions,selectedID:options.selectedID,
      dragBoundary:5,selectionRing:grid,label:options.label,rotate:grid,onSelect:options.onSelect,onMove:options.onMove,
      onCamera:next=>Object.assign(worldOptions,next),build:(world,items)=>{
        if(grid) estate(world,items,mode);
        else if(mode==="aquarium") aquarium(world,items);
        else lake(world,state.cast,options.spot);
      }});
  }
  function targetIndex(x,z,count) {
    const col=Math.max(0,Math.min(4,Math.round(x/2.12)+2));
    const row=Math.max(0,Math.min(4,Math.round(z/2.45)+2));
    return Math.max(0,Math.min(count-1,row*5+col));
  }
  window.EstateWorld={mount,spots,targetIndex};
})();
