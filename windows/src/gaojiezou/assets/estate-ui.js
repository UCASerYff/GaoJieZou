(() => {
  "use strict";
  const G = window.Gao;
  const {t,localized:L,esc,icon,button,card,header,rows,item,empty,date}=G;
  const lib = () => G.state.library;
  const cat = () => G.state.catalog;
  const btn = (label,action,glyph,className="secondary",disabled=false) =>
    button(t(label),{action:"estate:"+action,icon:glyph,className,disabled});
  const raw = (label,action,glyph,className="secondary",disabled=false) =>
    button(label,{action:"estate:"+action,icon:glyph,className,disabled});
  const glyph = (name,color="") => '<span class="glyph '+color+'">' + icon(name) + "</span>";
  const shell = body => '<div class="workspace wide">' + body + '</div>';
  const coins = amount => amount + t(" 金币"," coins");
  const asset = name => "/art/" + name + ".png";
  const chip = (symbol,name) => '<span class="scene-chip">' + icon(symbol) + esc(name) + "</span>";
  let aquarium = false;
  let immersive = false;
  let fishingSpot = 0;
  let farmTool = "inspect";
  let selectedPlot;
  let selectedAnimal;
  let selectedFish;
  let castTime = 0;
  let castPending = false;
  let dragged;

  function sprite(kind,data,young=false) {
    if (!data) return "";
    if (kind === "fish") return '<img class="sprite" src="' + asset("Fish-"+data.id+"-V15") + '" alt="">';
    const stock = kind === "crops" ? cat().crops : cat().animals;
    const slot = stock.indexOf(data);
    const image = kind === "crops" ? young ? "CropYoungAtlasV15" : "CropAtlasV15" : young ? "AnimalYoungAtlasV23" : "AnimalAtlasV23";
    const position = (slot%6 / 5*100) + "% " + (Math.floor(slot/6) / 3*100) + "%";
    return '<span class="sprite" style="background-image:url(' + asset(image) + ');background-position:' +
      position + ';background-size:600% 400%" aria-hidden="true"></span>';
  }

  function scene(image,chips,surface,tools,classes="") {
    return '<div class="game-scene '+classes+'" data-estate-mode="'+classes.replace("-scene","")+'"><img src="' + asset(image) + '" alt="">' +
      (chips ? '<div class="row scene-hud">' + chips + '</div>' : "") +
      surface + (tools ? '<div class="row scene-toolbar">' + tools + "</div>" : "") + "</div>";
  }
  function index() {
    const info = [
      ["farm","农场","leaf","teal","在场景中播种、浇水、施肥，让专注推动作物生长",
        lib().farmPlots.filter(row => row.cropID).length+t(" 块农田生长中"," planted plots")],
      ["pasture","牧场","paw","clay","在场景中搭窝、饲养与收取，让规律睡眠带来产出",
        lib().pastureAnimals.length+t(" 只牲畜"," animals")],
      ["fishing","渔场","fish","teal","在湖边抛竿、管理鱼篓，并进入水族馆照料收藏",
        Object.keys(lib().fishCaught).length+t(" 种鱼已发现"," fish species found")],
      ["island","荒岛生活","tree","teal","照料小岛，管理活力与物资",t("活力、物资与小岛建设","Energy, supplies and island building")],
      ["train","旅行列车","train","orange","规划列车线路，管理车厢与物资",t("线路、车厢与旅行物资","Routes, carriages and supplies")]
    ];
    return shell(header(t("乐园"),t("认真生活，也尽情生长。")) + '<div class="grid game-index">' +
      info.map(([id,title,name,color,detail,status]) => '<button type="button" class="card game-entry" data-go="playground/' + id +
        '"><span class="row">' + glyph(name,color) + icon("diagonal","muted") + '</span><h2>' + L(title) + '</h2><p class="muted">' +
        L(detail) + '</p><span class="row"><strong class="' + color + ' small">' + esc(status) +
        '</strong><span class="muted small">' + L("进入","Open") + "</span></span></button>").join("") + "</div>");
  }
  function farm() {
    const plots = lib().farmPlots;
    const planted = plots.filter(plot => plot.cropID).length;
    const grid = '<div class="scene-plot-row">' + plots.map((plot,index) => {
      const crop = cat().crops.find(spec => spec.id === plot.cropID);
      const fraction = crop ? Math.min(1,(plot.growthMinutes || 0)/crop.minutes) : 0;
      const label = crop ? t(crop.name) + " " + Math.round(fraction*100) + "%" : t("空农田","Empty plot") + " " + (index+1);
      return '<button type="button" class="'+(crop ? "" : "empty-plot")+'" data-action="estate:plot:'+esc(plot.id)+
        '" title="' + esc(label) + '" aria-label="' + esc(label) + '">' +
        (crop ? sprite("crops",crop,fraction<1) + "<small>" + Math.round(fraction*100) + "%</small>" : icon("plus")) + "</button>";
    }).join("") + "</div>";
    const cost = G.state.estate.nextPlotCost;
    const ready = plots.some(plot => plot.cropID && plot.growthMinutes >= (cat().crops.find(spec => spec.id === plot.cropID)?.minutes ?? Infinity));
    const tools = [["inspect","查看","Inspect","eye"],["seed","播种","Plant","leaf"],["water","浇水","Water","water"],
      ["fertilize","施肥","Fertilize","sun"],["harvest","收获","Harvest","tray"]];
    const controls = tools.map(([key,zh,en,icon]) => raw(t(zh,en),"farm-tool:"+key,icon,key===farmTool?"estate-button-active":"secondary")).join("") +
      raw(t("开垦","Expand") + " · " + coins(cost),"buy-plot","plus","secondary",plots.length >= 25) +
      raw(t("收获全部","Harvest all"),"harvest-all","coin","secondary",!ready) +
      btn("装饰商店","decorations","leaf") + btn("作物图鉴","collection:crops","list");
    const owned = lib().decorations.length ? '<div class="owned-decoration-strip">' +
      lib().decorations.map(decoration => {
        const spec = cat().decorations.find(row=>row.id===decoration.definitionID);
        return spec ? raw("Lv. "+decoration.level,"decoration:"+decoration.id,"leaf","secondary").replace(
          "<button ",'<button title="'+esc(t(spec.name))+'" ') : "";
      }).join("")+"</div>" : "";
    return shell(scene("FarmGameSceneV15",chip("coin",coins(lib().coins))+chip("leaf",planted+"/"+plots.length+t(" 块农田"," plots")),grid+owned,controls,"farm-scene"));
  }

  function pasture() {
    const animals = lib().pastureAnimals;
    const capacity = lib().animalShelterCapacity;
    const slots = '<div class="scene-plot-row">' + Array.from({length:capacity},(_,index) => {
      const resident = animals[index];
      if (!resident) return '<button type="button" aria-label="'+L("购买牲畜","Buy animal")+
        '" class="empty-plot" data-action="estate:animal-shop">' + icon("plus") + "</button>";
      const spec = cat().animals.find(value => value.id === resident.animalID);
      const label = t(spec?.name || resident.animalID);
      return '<button type="button" draggable="true" data-resident="' + esc(resident.id) + '" data-index="' + index +
        '" data-action="estate:animal:' + esc(resident.id) + '" title="' + esc(label) + '" aria-label="' + esc(label) + '">' +
        sprite("animals",spec,resident.growthHours < (spec?.maturity || 0)) +
        (resident.pendingProducts ? "<small>+"+resident.pendingProducts+"</small>" : "") + "</button>";
    }).join("") + "</div>";
    const cost = G.state.estate.nextShelterCost;
    const controls = raw(t("搭窝","Buy shelter") + " · " + coins(cost),"shelter","home","primary",capacity >= 25) +
      btn("购买牲畜","animal-shop","plus","secondary",animals.length >= capacity) +
      btn("收取全部","collect-all","coin","secondary",!animals.some(row => row.pendingProducts)) +
      btn("牲畜图鉴","collection:animals","list");
    return shell(scene("PastureGameSceneV15",chip("coin",coins(lib().coins))+chip("paw",animals.length+"/"+capacity+t(" 窝位"," shelters")),slots,controls,"pasture-scene"));
  }

  function fishing() {
    const aquariumResidents = lib().aquariumFish;
    const stock = Object.values(lib().fishInventory).reduce((a,b) => a + Number(b),0);
    if (aquarium) {
      const fish = '<div class="scene-plot-row aquarium-positions">' + aquariumResidents.map(row => {
        const spec = cat().fish.find(value => value.id === row.fishID);
        return '<button type="button" title="' + esc(t(spec?.name || row.fishID)) + '" aria-label="' +
          esc(t(spec?.name || row.fishID)) + '" data-action="estate:aquarium-resident:' + esc(row.id) + '">' + sprite("fish",spec) + "</button>";
      }).join("") + "</div>";
      const income = G.state.estate.aquariumIncome;
      const title = immersive ? '<div class="estate-exit-immersive">'+raw(t("退出观赏","Exit viewing"),"immersive","left")+'</div>' :
        '<div class="estate-overlay"><h2>'+L("水下花园","Underwater garden")+'</h2><small>'+L("自由巡游 · 点击鱼儿查看档案","Watch them swim or select a fish")+'</small></div>';
      const guide = aquariumResidents.length ? "" : '<p class="estate-overlay estate-empty-aquarium">'+
        L("从鱼篓邀请第一位住客","Invite the first fish from your basket")+"</p>";
      const controls=immersive?"":btn("返回渔场","pond","left","primary")+btn("管理鱼篓","basket","fish")+
        btn("领取收益","aquarium-income","coin","secondary",!income)+raw(t("观赏","Watch"),"immersive","eye");
      return shell(scene("AquariumGameSceneV15",immersive?"":chip("fish",aquariumResidents.length+"/25")+chip("coin",t("待领取","Pending")+" "+coins(income)),
        fish+title+guide,controls,"aquarium-scene"));
    }
    const active = G.state.cast && G.currentClock() < G.state.cast.biteAt + 5;
    const indicator = '<div class="fishing-gauge" data-fishing-gauge' + (active ? "" : " hidden") +
      '><strong data-fishing-caption></strong><div class="fishing-meter"><i data-fishing-marker></i></div></div>';
    const spotButtons=(window.EstateWorld?.spots || []).map(([zh,en],index)=>
      raw(t(zh,en),"fishing-spot:"+index,"water",fishingSpot===index?"estate-button-active":"secondary",active)).join("");
    const spotControls='<div class="estate-overlay"><h2>'+L("湖畔垂钓","Lakeside fishing")+
      '</h2><div class="row">'+spotButtons+"</div></div>";
    const tools = btn("抛竿","cast","play","primary",!lib().bait || active) +
      btn("收竿","reel","check","primary",!active)+ btn("放下鱼竿","cancel-cast",null,"secondary",!active) +
      raw(t("鱼篓","Fish basket") + " · " + stock,"basket","fish") +
      raw(t("水族馆","Aquarium") + " · " + aquariumResidents.length,"aquarium","water") + btn("鱼类图鉴","collection:fish","list");
    return shell(scene("FishingGameSceneV15",chip("coin",coins(lib().coins))+chip("fish",lib().bait+" "+t("鱼饵","bait")),
      indicator+spotControls,tools,"fishing-scene"));
  }

  function collection(kind) {
    const names = {crops:"作物图鉴",animals:"牲畜图鉴",fish:"鱼类图鉴"};
    const unlocked = kind === "crops" ? lib().harvestedCrops : kind === "fish" ? lib().fishCaught :
      Object.fromEntries(lib().pastureAnimals.map(row => [row.animalID,true]));
    const body = '<div class="collection-grid">' + cat()[kind].map(entry => {
      const visible = Boolean(unlocked[entry.id]);
      return '<div class="collection-entry'+(visible ? "" : " locked")+'">' + sprite(kind,entry) + '<strong>' +
        esc(visible ? t(entry.name) : t("未发现","Undiscovered")) + "</strong><span>" +
        (visible && typeof unlocked[entry.id] === "number" ? esc(unlocked[entry.id]) : icon(visible ? "check" : "lock")) + "</span></div>";
    }).join("") + "</div>";
    G.modal(t(names[kind]),body,null,{className:"collection"});
  }

  function plotDialog(id) {
    const plot = lib().farmPlots.find(row => row.id === id);
    if (!plot) return;
    const crop = cat().crops.find(data => data.id === plot.cropID);
    if (!crop) {
      G.modal(t("挑选种子","Choose a seed"),'<div class="collection-grid">' + cat().crops.map(seed =>
        '<div class="collection-entry">' + sprite("crops",seed) + "<strong>" + L(seed.name) +
        '</strong><span class="muted">' + esc(G.duration(seed.minutes*60)) + '</span>' +
        raw(coins(seed.seed),"plant:"+id+":"+seed.id,"leaf","secondary",lib().coins < seed.seed) + "</div>").join("") + "</div>",
      null,{className:"collection"});
      return;
    }
    const mature = plot.growthMinutes >= crop.minutes;
    G.modal(t(crop.name),'<div class="row">' + sprite("crops",crop,!mature) + '<div class="stack"><span>' +
      esc(G.duration(Math.floor(plot.growthMinutes)*60)+" / "+G.duration(crop.minutes*60)) +
      '</span><span class="muted">' + L("下次专注成长加成","Next focus growth boost") + " " +
      Math.round(Number(plot.nextFocusBoost || 0)*100) + "%</span></div></div><progress value='" + Math.min(crop.minutes,plot.growthMinutes) + "' max='" + crop.minutes +
      "'></progress><div class=\"row\">" + raw(t("浇水","Water") + " · " + coins(1),"water:"+id,"water","secondary",mature || lib().coins<1)+
      raw(t("施肥","Fertilize") + " · " + coins(4),"fertilize:"+id,"leaf","secondary",mature || lib().coins<4)+
      raw(t("收获并出售","Harvest and sell") + " · +" + coins(crop.sell),"harvest:"+id,"coin","primary",!mature) + "</div>");
  }

  function animalStore() {
    G.modal(t("购买牲畜","Buy animal"),'<div class="collection-grid">' + cat().animals.map(spec =>
      '<div class="collection-entry">' + sprite("animals",spec,true) + "<strong>" + L(spec.name) + "</strong>" +
      raw(coins(spec.buy),"buy-animal:"+spec.id,"paw","secondary",lib().coins<spec.buy) + "</div>").join("") + "</div>",null,{className:"collection"});
  }
  function inspectAnimal(id) {
    const index = lib().pastureAnimals.findIndex(row => row.id === id);
    if (index < 0) return;
    const resident = lib().pastureAnimals[index], spec = cat().animals.find(row => row.id === resident.animalID);
    if (!spec) return;
    const hours = Math.min(spec.maturity,Number(resident.growthHours || 0));
    G.modal(t(spec.name),'<div class="row">' + sprite("animals",spec,hours < spec.maturity) +
      '<div><strong>' + esc(hours.toFixed(1) + " / " + spec.maturity + t(" 小时"," h")) +
      '</strong><p class="muted">' + L(spec.product) + " × " + (resident.pendingProducts || 0) +
      '</p></div></div><progress value="' + hours + '" max="' + spec.maturity +
      '"></progress><div class="row">' + btn("收取产物","collect:"+id,"coin","primary",!resident.pendingProducts) +
      btn("出售牲畜","sell-animal:"+id,"trash","danger") + btn("前移","move-animal:"+id+":"+(index-1),"left","secondary",index===0) +
      btn("后移","move-animal:"+id+":"+(index+1),"right","secondary",index===lib().pastureAnimals.length-1) + "</div>");
  }

  function decorations() {
    G.modal(t("装饰商店","Decorations"),rows(cat().decorations,definition => {
      const owned = lib().decorations.find(row => row.definitionID === definition.id);
      const next = definition.price * 2 ** Math.min(40, Number(owned?.level || 0));
      return item(t(definition.name),owned ? "Lv. "+owned.level : "",raw((owned ? t("升级","Upgrade") : t("购买","Buy"))+
        " · "+coins(next),(owned ? "upgrade-decoration:"+owned.id : "buy-decoration:"+definition.id),"coin","secondary",lib().coins<next),"leaf");
    }),null,{className:"collection"});
  }

  function basket() {
    const stock = cat().fish.filter(spec => lib().fishInventory[spec.id] > 0);
    G.modal(t("鱼篓","Fish basket"),rows(stock,spec => '<div class="data-row">' + sprite("fish",spec) +
      '<div class="data-copy"><strong>' + L(spec.name) + " × " + lib().fishInventory[spec.id] +
      '</strong><p class="muted">' + "★".repeat(spec.rarity) + "</p></div>" +
      raw(t("出售一条","Sell one")+" · +"+coins(spec.sell),"sell-fish:"+spec.id,"coin") +
      btn("移入水族馆","move-fish:"+spec.id,"water","secondary",lib().aquariumFish.length >= 25) + "</div>",
      t("鱼篓为空。","The fish basket is empty.")) +
      (stock.length ? btn("出售全部渔获","sell-all","coin","primary") : ""));
  }
  function aquariumResident(id) {
    const row = lib().aquariumFish.find(entry => entry.id === id);
    if (!row) return;
    const spec = cat().fish.find(entry => entry.id === row.fishID);
    G.modal(t(spec?.name || row.fishID),'<div class="row">' + sprite("fish",spec) +
      '<span class="muted">' + L("入馆","Added") + " " + esc(date(row.addedAt)) + '</span></div><div class="row">' +
      btn("取回鱼篓","return-fish:"+id,"fish","primary") + "</div>");
  }

  async function choosePlot(id) {
    if (id==="expand") { await G.act("/api/farm/buy-plot"); return; }
    const plot=lib().farmPlots.find(row=>row.id===id);
    if(!plot) return;
    selectedPlot=id;
    if(!plot.cropID) {
      farmTool="seed";
      G.render();
      plotDialog(id);
    } else if (farmTool==="inspect") plotDialog(id);
    else if (farmTool==="seed") G.notice(t("这块田已经种有作物","A crop is already planted here"));
    else await G.act("/api/farm/"+farmTool,{plotID:id},{message:farmTool==="water"?t("已浇水","Watered"):farmTool==="fertilize"?
      t("已施肥","Fertilized"):t("已收获","Harvested")});
  }

  async function chooseAnimal(id) {
    if(id==="expand") await G.act("/api/pasture/shelter");
    else if(id?.startsWith("shelter:")) animalStore();
    else if(id) { selectedAnimal=id;inspectAnimal(id); }
  }

  function showCatch(spec) {
    G.modal(t("钓到","Caught")+" "+t(spec.name),'<div class="row">'+sprite("fish",spec)+
      '<strong class="orange">'+"★".repeat(spec.rarity)+'</strong></div><div class="row">'+
      raw(t("出售一条","Sell one")+" · +"+coins(spec.sell),"sell-fish:"+spec.id,"coin")+
      btn("移入水族馆","move-fish:"+spec.id,"water","primary",lib().aquariumFish.length>=25)+"</div>");
  }

  const paths = {
    "buy-plot":["/api/farm/buy-plot"],"plant":["/api/farm/plant","plotID","cropID"],
    "water":["/api/farm/water","plotID"],"fertilize":["/api/farm/fertilize","plotID"],"harvest":["/api/farm/harvest","plotID"],
    "harvest-all":["/api/farm/harvest-all"],
    "shelter":["/api/pasture/shelter"],"buy-animal":["/api/pasture/buy","animalID"],"collect":["/api/pasture/collect","id"],
    "collect-all":["/api/pasture/collect"],"move-animal":["/api/pasture/move","id","index"],"cast":["/api/fish/cast"],
    "reel":["/api/fish/reel"],"cancel-cast":["/api/fish/cancel"],"sell-fish":["/api/fish/sell-one","fishID"],
    "move-fish":["/api/fish/aquarium","fishID"],"aquarium-income":["/api/fish/aquarium-income"],
    "return-fish":["/api/fish/aquarium-return","id"],"buy-decoration":["/api/decorations/buy","id"],
    "upgrade-decoration":["/api/decorations/upgrade","id"]
  };
  document.addEventListener("click",async event => {
    const control = event.target.closest('button[data-action^="estate:"]');
    if (!control) return;
    const [,action,id,value] = control.dataset.action.split(":");
    if (action === "plot") await choosePlot(id);
    if (action === "animal-shop") animalStore();
    if (action === "animal") inspectAnimal(id);
    if (action === "collection") collection(id);
    if (action === "decorations") decorations();
    if (action === "decoration") {
      const decoration=lib().decorations.find(row=>row.id===id);
      const spec=cat().decorations.find(row=>row.id===decoration?.definitionID);
      if (spec) G.confirm(t("升级装饰","Upgrade decoration"),t(spec.name)+" · "+coins(spec.price*2**Math.min(40,decoration.level)),
        "/api/decorations/upgrade",{id});
    }
    if (action === "basket") basket();
    if (action === "aquarium-resident") aquariumResident(id);
    if (action === "pond" || action === "aquarium") {
      aquarium = action === "aquarium";
      immersive = false;
      aquarium && G.state.cast ? await G.act("/api/fish/cancel") : G.render();
    }
    if (action==="fishing-spot" && !G.state.cast) { fishingSpot=Number(id);G.render(); }
    if (action==="immersive") { immersive=!immersive;G.render(); }
    if (action==="farm-tool") {
      farmTool=id;G.render();
      if(id==="seed" && lib().farmPlots.some(row=>row.id===selectedPlot && !row.cropID)) plotDialog(selectedPlot);
    }
    if (action === "sell-animal") G.confirm(t("出售牲畜？","Sell this animal?"),t("动物与待收取产物将结算为金币。","The animal and pending products will be exchanged for coins."),"/api/pasture/sell",{id});
    if (action === "sell-all") G.confirm(t("出售全部渔获？","Sell all fish?"),t("鱼篓中的鱼将结算为金币。","Fish in the basket will be exchanged for coins."),"/api/fish/sell",{});
    if (!paths[action]) return;
    const [path,key,anotherKey] = paths[action];
    const payload = key ? {[key]: id} : {};
    if (anotherKey) payload[anotherKey] = value;
    control.disabled = true;
    if (action === "cast") castPending = true;
    const response = await G.act(path,payload);
    if (action === "cast") castPending = false;
    if (!response) { control.disabled = false; return; }
    if (["water","fertilize"].includes(action)) plotDialog(id);
    if (["collect","move-animal"].includes(action)) inspectAnimal(id);
    if (["buy-decoration","upgrade-decoration"].includes(action)) decorations();
    if (["sell-fish","move-fish"].includes(action)) basket();
    if (["plant","harvest","buy-animal","return-fish"].includes(action)) G.closeModal();
    if (action === "reel" && response.result?.hooked) {
      const caught=cat().fish.find(spec=>spec.id===response.result.fishID);
      if(caught) showCatch(caught);
    }
    if (response.result?.coins > 0) G.notice("+"+coins(response.result.coins));
  });

  function tick() {
    const gauge = document.querySelector("[data-fishing-gauge]");
    const cast = G.state?.cast;
    if (!gauge || !cast || castPending) return;
    const phase = G.currentClock()-cast.biteAt;
    if (phase > 5) {
      if (castTime !== cast.biteAt) {
        castTime = cast.biteAt;
        let hint = t("鱼游走了，鱼饵未消耗。","The fish swam away. No bait was used.");
        G.act("/api/fish/cancel",{}, {message:hint});
      }
      return;
    }
    gauge.hidden = false;
    const caption = gauge.querySelector("[data-fishing-caption]");
    const text = phase < 0 ? t("等待咬钩…","Waiting for a bite…") : t("咬钩了，在绿色区间收竿！","A bite! Reel in while the marker is green.");
    if (caption.textContent !== text) caption.textContent = text;
    const marker = phase < 0 ? 0 : (Math.sin(phase*2.4-Math.PI/2)+1)/2;
    gauge.querySelector("[data-fishing-marker]").style.left = (marker*100)+"%";
  }
  window.EstateUI = {
    render(section) { return ({farm,pasture,fishing,index}[section] || index)(); },
    bind(section) {
      const host=document.querySelector("[data-estate-mode]");
      const mode=host?.dataset.estateMode;
      if(mode) window.EstateWorld?.mount(host,mode,{
        selectedID:{farm:selectedPlot,pasture:selectedAnimal,aquarium:selectedFish}[mode],spot:fishingSpot,
        label:t("乐园三维场景。方向键调整视角，Page Up 或 Page Down 选择物件，回车打开。",
          "Playground 3D world. Use arrow keys for the camera, Page Up or Page Down to select, and Enter to open."),
        onSelect:id=>{
          if(!id) return;
          if(mode==="farm") choosePlot(id);
          else if(mode==="pasture") chooseAnimal(id);
          else if(mode==="aquarium") { selectedFish=id;aquariumResident(id); }
          else if(id==="bobber" && G.state.cast?.biteAt<=G.currentClock()) document.querySelector('[data-action="estate:reel"]')?.click();
        },
        onMove:async (id,x,z)=>mode==="pasture" && lib().pastureAnimals.length>0 && Boolean(await G.act("/api/pasture/move",{
          id,index:window.EstateWorld.targetIndex(x,z,lib().pastureAnimals.length)
        }))
      });
      if (section !== "pasture") return;
      document.querySelectorAll("[data-resident]").forEach(slot => {
        slot.addEventListener("dragstart",event => {
          dragged = slot.dataset.resident;
          event.dataTransfer.setData("text/plain",dragged);
          event.dataTransfer.effectAllowed = "move";
        });
        slot.addEventListener("dragover",event => { if (dragged) event.preventDefault(); });
        slot.addEventListener("dragend",() => { dragged = null; });
        slot.addEventListener("drop",event => {
          event.preventDefault();
          const id = dragged;
          dragged = null;
          if (id && id !== slot.dataset.resident) G.act("/api/pasture/move",{id,index:Number(slot.dataset.index)});
        });
      });
    },
    leave(oldPage,oldSection,page,section) {
      if (oldPage === "playground" && oldSection === "fishing" && (page !== "playground" || section !== "fishing")) {
        aquarium = false;
        immersive = false;
        if (G.state.cast) G.act("/api/fish/cancel",{},{render:false});
      }
    },
    tick
  };
})();
