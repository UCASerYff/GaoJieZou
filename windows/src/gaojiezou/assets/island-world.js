(() => {
  "use strict";

  const tau = 2 * Math.PI;
  const yaw = 42;
  const initialZoom = 8.5;
  const zoomLimits = [6, 25];
  const art = {
    island: "/art/IslandSceneArt.png",
    meadow: "/art/EstateMeadowV352.png",
    materials: "/art/WorldMaterialsV357.png",
    foliage: "/art/FoliageV357.png",
  };
  const palette = {
    wood: "#664a30", timber: "#755037", stone: "#aaa48b", cream: "#e0d4ad", brass: "#bd8940",
    roof: "#2e615c", sage: "#3d6e5c", soil: "#4f3b26", amber: "#f9c464", water: "#2e9eb8",
  };
  const foliageCuts = {
    0: [101, 88, 260, 328],
    1: [513, 99, 325, 316],
    4: [75, 541, 299, 239],
    5: [514, 525, 312, 275],
    6: [961, 509, 305, 294],
  };
  const buildings = {
    campfire: ["Campfire", "解锁叉鱼 · 繁荣度 +20", "Unlock fishing · +20 prosperity", "flame.fill"],
    shelter: ["Shelter", "休息时段衰减降低 25%", "25% less decay during rest", "house.fill"],
    well: ["Well", "水分衰减降低 25%", "25% less water decay", "drop.fill"],
    garden: ["Garden", "每日首次到岛收获干粮", "Rations on the first daily visit", "leaf"],
    farm: ["Farm", "每日首次到岛收获干粮", "Rations on the first daily visit", "grid"],
    herbGarden: ["Herb garden", "解锁采药", "Unlock herb gathering", "leaf"],
    clinic: ["Clinic", "每日首次到岛恢复活力", "Energy on the first daily visit", "heart"],
    training: ["Training ground", "提高运动奖励", "Improve activity rewards", "exercise"],
    rainCollector: ["Rain collector", "每日首次到岛恢复水分", "Restore water on the first daily visit", "water"],
    orchard: ["Orchard", "每日首次到岛收获干粮", "Rations on the first daily visit", "tree"],
    workshop: ["Workshop", "每级降低 5% 采集活力消耗", "Gathering uses 5% less energy per level", "settings"],
    windmill: ["Windmill", "每级额外产出 1 份纤维", "Gather one extra fiber per level", "leaf"],
    kitchen: ["Kitchen", "每级让干粮额外恢复 3 点饱食", "Each level adds 3 food to a ration", "meals"],
    teaHouse: ["Tea pavilion", "消耗 2 药材恢复活力，每日最多 2 次", "Two herbs restore energy, twice per day", "heart"],
  };
  const actionNames = {
    chop: "Chop wood", fiber: "Gather fiber", pebble: "Break pebbles", quarry: "Quarry stone",
    mine: "Mine ore", fish: "Spearfish", coconut: "Gather fruit", herb: "Gather herbs",
  };
  const problemNames = {
    已拥有: "Already owned", 岛屿休整中: "The island is resting", 需要先获得前置: "Requires an earlier structure or tool",
    材料尚不足: "Not enough materials", 繁荣度尚不足: "Not enough prosperity", 请先建造: "Build it first",
    已升至最高级: "Maximum level", 请先恢复岛屿经营: "Resume island life first", 需要先获得对应工具或建筑: "Requires a tool or structure",
    活力不足: "Not enough energy", 饱食不足: "Not enough food", 水分不足: "Not enough water",
    海岸已全部开拓: "All shores opened", 请调整建筑位置后再建造: "Make room for the building first",
  };

  const box = (at, x, y, z, w, h, d, color, extra = {}) => at.box({ x, y, z, w, h, d, color, ...extra });
  const cylinder = (at, x, y, z, r, h, color, extra = {}) => at.cylinder({ x, y, z, r, h, color, ...extra });
  const sphere = (at, x, y, z, r, color, extra = {}) => at.sphere({ x, y, z, r, color, ...extra });
  const cone = (at, x, y, z, r, top, h, color, extra = {}) => cylinder(at, x, y, z, r, h, color, { top, segments: 10, ...extra });
  const ring = (at, x, y, z, r, width, color) => at.ring({ x, y, z, r, width, color });
  const swatch = (id) => [id % 2 * 0.5, Math.floor(id / 2) * 0.5, 0.5, 0.5];

  function materialBox(at, x, y, z, w, h, d, material) {
    return box(at, x, y, z, w, h, d, "#ffffff", {
      texture: art.materials, uv: swatch(material), repeat: [Math.max(0.25, w / 2), Math.max(0.25, Math.max(h, d) / 2)],
    });
  }

  function foliage(at, index, x, base, z, height) {
    const [u, v, w, h] = foliageCuts[index];
    at.plane({ x, y: base + height / 2, z, w: height * w / h, h: height, texture: art.foliage,
      uv: [u / 1774, v / 887, w / 1774, h / 887], color: "#ffffff", billboard: "y", cutout: true });
  }

  function distanceBeam(at, start, end, radius, color) {
    return at.beam({ from: start, to: end, r: radius, color });
  }

  function roof(at, width, depth, y, color) {
    for (const side of [-1, 1]) {
      const half = at.group({ x: side * width * 0.25, y, rz: -side * 0.48 });
      box(half, 0, 0, 0, width * 0.61, 0.095, depth, color);
      for (let i = 0; i < 8; i++) {
        box(half, 0, 0.057, (i - 4) * depth / 8, width * 0.61, 0.035, 0.035, color === palette.sage ? "#567e68" : "#48786c");
      }
    }
    cylinder(at, 0, y + width * 0.13, 0, 0.065, depth, color, { rx: Math.PI / 2 });
  }

  function shoreRadius(radius, angle) {
    return radius + 0.32 * Math.sin(angle * 3 + 0.7) + 0.18 * Math.cos(angle * 7);
  }

  function shore(at, radius, height, y, color, surface = false) {
    const points = Array.from({ length: 96 }, (_, i) => {
      const angle = i / 96 * tau;
      const r = shoreRadius(radius, angle);
      return [Math.sin(angle) * r, Math.cos(angle) * r];
    });
    at.prism({ points, y, h: height, color, ...(surface ? { texture: art.meadow, repeat: [3, 3] } : {}) });
  }

  function terrain(at, stage) {
    const radius = 7.1 + stage * 0.7;
    box(at, 0, -0.56, 0, 100, 0.08, 100, "#1a7087");
    shore(at, radius + 1.15, 0.16, -0.50, "#4da19c");
    shore(at, radius + 0.70, 0.45, -0.34, "#c9ba8f");
    shore(at, radius, 0.20, 0.03, "#ccefc2", true);
    for (let i = 0; i < 72; i++) {
      const angle = i / 72 * tau;
      const r = shoreRadius(radius, angle) + 0.20 + i % 3 * 0.15;
      const size = 0.28 + i % 4 * 0.04;
      sphere(at, Math.sin(angle) * r, -0.05, Math.cos(angle) * r, size, ["#a8a17f", "#aaa383", "#bab396"][i % 3],
        { sx: 1.4, sy: 0.6, sz: 0.85 });
    }
    for (let i = 0; i < 11; i++) {
      const angle = i / 11 * tau + 0.14 * Math.sin(i * 2.7);
      foliage(at, 0, Math.sin(angle) * (radius - 0.5), 0.18, Math.cos(angle) * (radius - 0.5), (0.85 + i % 3 * 0.18) * 2.5);
    }
    for (let i = -6; i <= 6; i++) {
      const z = i * 0.88, x = Math.sin(z * 0.55) * 0.55;
      box(at, x, 0.245, z, 0.62, 0.025, 0.65, palette.stone,
        { texture: art.materials, uv: swatch(2), ry: Math.sin(z) * 0.15 });
    }
    for (let i = 0; i < 9; i++) {
      const angle = i * 0.19 + 1.1, r = radius - 0.15, size = 0.32 + i % 3 * 0.12;
      sphere(at, Math.sin(angle) * r, 0.1, Math.cos(angle) * r, size, "#7a826e", { sx: 1.3, sy: 0.8 });
    }
    for (let i = 0; i < 18; i++) {
      const angle = i * 0.73, r = radius + 1.2 + i % 5 * 0.65;
      at.ring({
        x: Math.sin(angle) * r, y: -0.47, z: Math.cos(angle) * r,
        r: 0.28 + i % 3 * 0.14, scaleZ: 0.25, width: 0.026, color: [0.55, 0.80, 0.76, 0.42],
        animate: (node, time) => {
          const fade = 2 + i % 3, phase = time % (fade + 3);
          node.material.color[3] = phase < fade ? 0.42 - 0.30 * phase / fade : 0.12 + 0.30 * (phase - fade) / 3;
        },
      });
    }
    const dock = at.group({ z: radius + 0.90 });
    for (let i = 0; i < 13; i++) materialBox(dock, 0, -0.05, i * 0.22 - 1.1, 2.1, 0.08, 0.19, 1);
    for (const x of [-0.9, 0.9]) for (const z of [-1, 1]) cylinder(dock, x, -0.17, z, 0.08, 0.90, palette.wood);
  }

  function cropBeds(at, kind, level) {
    materialBox(at, 0, 0.47, 0, 1.60, 0.25, 1.35, 1);
    box(at, 0, 0.61, 0, 1.45, 0.03, 1.2, palette.soil);
    const index = { garden: 4, farm: 6, herbGarden: 5 }[kind];
    for (const [x, z] of [[-0.23, -0.26], [0.26, 0.25]]) {
      foliage(at, index, x, 0.62, z, 0.73);
    }
    if (level >= 2) {
      for (const z of [-0.70, 0.70]) {
        for (let i = 0; i < 7; i++) cylinder(at, (i - 3) * 0.23, 0.71, z, 0.022, 0.40, palette.wood);
        box(at, 0, 0.89, z, 1.65, 0.035, 0.035, palette.wood);
      }
    }
    if (level >= 3) {
      for (const x of [-0.78, 0.78]) cylinder(at, x, 1.05, -0.50, 0.025, 1.1, palette.cream);
      box(at, 0, 1.60, -0.50, 1.62, 0.035, 0.07, palette.cream);
    }
    if (level >= 4) {
      cylinder(at, 0.72, 0.60, 0.75, 0.18, 0.45, "#477a7d");
      distanceBeam(at, [0.72, 0.80, 0.70], [0.40, 0.85, 0.40], 0.025, palette.cream);
    }
  }

  function campfire(at, level) {
    cylinder(at, 0, 0.24, 0, 0.98, 0.08, "#b39e78");
    for (let i = 0; i < 6; i++) {
      const a = i / 6 * tau;
      box(at, Math.sin(a) * 0.28, 0.38, Math.cos(a) * 0.28, 0.16, 0.15, 0.75, "#8e5e3d", { ry: a });
    }
    for (let i = 0; i < 8; i++) {
      const a = i / 8 * tau;
      sphere(at, Math.sin(a) * 0.66, 0.32, Math.cos(a) * 0.66, 0.16, "#918a78");
    }
    cone(at, 0, 0.68, 0, 0.28, 0, 0.62, "#ff7921");
    for (let i = -1; i <= 1; i++) cone(at, i * 0.17, 0.85, 0, 0.11, 0, 0.47, "#ffbf38", { rz: i * 0.14 });
    for (const x of [-0.86, 0.86]) materialBox(at, x, 0.50, 0.10, 0.24, 0.19, 1.25, 1);
    if (level >= 3) {
      for (const x of [-0.70, 0.70]) cylinder(at, x, 1.05, 0, 0.05, 1.6, palette.wood);
      box(at, 0, 1.80, 0, 1.50, 0.08, 0.13, palette.wood);
    }
  }

  function well(at, level) {
    cylinder(at, 0, 0.24, 0, 0.98, 0.08, "#b39e78");
    cylinder(at, 0, 0.58, 0, 0.62, 0.65, "#a6aba3");
    cylinder(at, 0, 0.93, 0, 0.43, 0.04, "#2673a6");
    for (const x of [-0.55, 0.55]) cylinder(at, x, 1.0, 0, 0.055, 1.15, palette.wood);
    cone(at, 0, 1.65, 0, 0.82, 0, 0.43, palette.roof);
    cylinder(at, 0, 1.42, 0, 0.06, 1, palette.timber, { rz: Math.PI / 2 });
    cylinder(at, -0.72, 1.42, 0, 0.17, 0.11, palette.brass, { rz: Math.PI / 2 });
    cylinder(at, 0, 1.03, 0, 0.025, 0.55, "#baa672", { rz: 0.06 });
    cylinder(at, 0, 0.68, 0, 0.23, 0.37, palette.timber);
    for (let row = 0; row < 3; row++) for (let i = 0; i < 12; i++) {
      const a = i * Math.PI / 6 + row % 2 * 0.26;
      box(at, Math.sin(a) * 0.58, 0.41 + row * 0.20, Math.cos(a) * 0.58, 0.24, 0.17, 0.13,
        ["#aaa892", "#b5ad9d", "#c0b39c"][i % 3], { ry: a });
    }
    if (level >= 3) cylinder(at, 0, 2.05, 0, 0.32, 0.50, "#4aa1c4");
  }

  function dwelling(at, kind, level) {
    const height = 1.03 + (level - 1) * 0.14;
    box(at, 0, 0.35 + height / 2, 0, 1.4, height, 1.18, palette.cream);
    for (let i = 0; i < 7; i++) box(at, 0, 0.43 + i * 0.14, 0, 1.42, 0.012, 1.2, "#bdae87");
    materialBox(at, 0, 0.70, 0.61, 0.33, 0.71, 0.055, 1);
    sphere(at, 0.11, 0.71, 0.66, 0.026, palette.brass);
    for (const x of [-0.48, 0.48]) {
      box(at, x, 0.92, 0.62, 0.30, 0.41, 0.045, palette.wood);
      box(at, x, 0.92, 0.65, 0.24, 0.33, 0.055, palette.amber);
      box(at, x, 0.92, 0.69, 0.02, 0.34, 0.02, palette.cream);
      box(at, x, 0.92, 0.69, 0.25, 0.025, 0.02, palette.cream);
    }
    roof(at, 1.72, 1.52, height + 0.42, palette.roof);
    materialBox(at, 0, 0.33, 0.90, 1.35, 0.09, 0.40, 1);
    if (kind === "clinic") {
      box(at, 0, 1.18, 0.66, 0.13, 0.46, 0.05, "#ba4a40");
      box(at, 0, 1.18, 0.67, 0.44, 0.12, 0.05, "#ba4a40");
    }
  }

  function training(at) {
    for (const x of [-0.66, 0.66]) cylinder(at, x, 1.08, -0.50, 0.065, 1.55, palette.wood);
    distanceBeam(at, [-0.66, 1.84, -0.50], [0.66, 1.84, -0.50], 0.05, palette.wood);
    for (const x of [-0.26, 0.26]) {
      distanceBeam(at, [x, 1.80, -0.50], [x, 1.25, -0.50], 0.015, palette.cream);
      const hoop = at.group({ x, y: 1.14, z: -0.50, rx: Math.PI / 2 });
      ring(hoop, 0, 0, 0, 0.11, 0.025, palette.wood);
    }
    for (const z of [-0.35, 0.28]) materialBox(at, 0, 0.57, z, 0.95, 0.12, 0.20, 1);
    for (const x of [-0.62, 0.62]) cylinder(at, x, 0.52, 0.62, 0.12, 0.06, palette.roof, { rz: Math.PI / 2 });
  }

  function facilityUpgrades(at, level, extended = false) {
    if (level >= 2) {
      if (extended) {
        for (const z of [-0.86, 0.86]) box(at, 0, 0.41, z, 1.80, 0.035, 0.035, palette.brass);
      } else {
        for (const x of [-0.80, 0.80]) {
          cylinder(at, x, 0.46, 0.72, 0.14, 0.22, palette.wood);
          sphere(at, x, 0.65, 0.72, 0.19, "#478247");
        }
      }
    }
    if (level >= 3) {
      if (extended) {
        for (const x of [-0.80, 0.80]) {
          cylinder(at, x, 0.48, 0.71, 0.11, 0.16, palette.wood);
          foliage(at, 5, x, 0.55, 0.71, 0.35);
        }
      } else {
        materialBox(at, 0.45, 1.63, -0.35, 0.23, 0.75, 0.24, 2);
      }
    }
    if (level >= 4) {
      for (const x of [-0.79, 0.79]) {
        cylinder(at, x, extended ? 0.85 : 1.12, -0.79, 0.035, extended ? 0.93 : 1.70, palette.brass);
        sphere(at, x, extended ? 1.35 : 1.99, -0.79, 0.08, palette.cream);
      }
    }
  }

  function rainCollector(at) {
    const tank = at.group({ x: 0.30, z: 0.14 });
    cylinder(tank, 0, 0.88, 0, 0.46, 0.95, palette.sage);
    for (const y of [0.47, 0.70, 1.06, 1.33]) ring(tank, 0, y, 0, 0.466, 0.02, palette.brass);
    cylinder(tank, 0, 1.37, 0, 0.43, 0.025, palette.water);
    for (const x of [-0.76, 0.76]) cylinder(at, x, 1.16, -0.48, 0.04, 1.55, palette.wood);
    box(at, 0, 1.83, -0.25, 1.72, 0.055, 0.92, palette.sage, { rx: 0.22 });
    cylinder(at, 0, 1.73, 0.22, 0.05, 1.70, palette.brass, { rz: Math.PI / 2 });
    distanceBeam(at, [0.70, 1.72, 0.22], [0.70, 1.18, 0.22], 0.038, palette.brass);
    distanceBeam(at, [0.30, 0.57, 0.55], [0.30, 0.57, 0.82], 0.045, palette.brass);
    cylinder(at, 0.30, 0.43, 0.77, 0.13, 0.16, palette.cream);
    for (let i = 0; i < 8; i++) box(at, -0.13, 0.62 + i * 0.075, 0.40, 0.025, 0.045, 0.025, palette.cream);
  }

  function orchard(at) {
    for (const [x, z, fruit] of [[-0.48, -0.30, "#cf401f"], [0.45, 0.35, "#eda72e"]]) {
      cylinder(at, x, 0.90, z, 0.075, 0.97, palette.wood);
      foliage(at, 1, x, 0.63, z, 1.48);
      for (let k = 0; k < 5; k++) {
        const angle = k / 5 * tau;
        distanceBeam(at, [x, 1.03, z], [x + Math.sin(angle) * 0.30, 1.5, z + Math.cos(angle) * 0.28], 0.035, palette.wood);
        sphere(at, x + Math.sin(angle) * 0.42, 1.42, z + Math.cos(angle) * 0.38, 0.065, fruit);
      }
    }
    for (const z of [-0.81, 0.81]) {
      for (let i = 0; i < 7; i++) materialBox(at, (i - 3) * 0.26, 0.60, z, 0.06, 0.36, 0.05, 1);
      box(at, 0, 0.67, z, 1.70, 0.05, 0.05, palette.wood);
    }
    materialBox(at, 0.48, 0.51, -0.61, 0.40, 0.22, 0.35, 1);
    for (let i = 0; i < 6; i++) {
      sphere(at, 0.36 + i % 3 * 0.11, 0.65, -0.68 + Math.floor(i / 3) * 0.12, 0.065, "#e3661f");
    }
  }

  function workshop(at) {
    materialBox(at, 0, 0.87, -0.67, 1.58, 0.84, 0.13, 1);
    for (const x of [-0.72, 0.72]) materialBox(at, x, 1.09, -0.60, 0.09, 1.45, 0.09, 1);
    roof(at, 1.85, 1.35, 1.77, palette.sage);
    materialBox(at, 0, 0.92, 0.17, 1.37, 0.11, 0.59, 1);
    for (const x of [-0.58, 0.58]) for (const z of [-0.05, 0.40]) materialBox(at, x, 0.65, z, 0.07, 0.50, 0.07, 1);
    cylinder(at, 0.25, 1.02, 0.13, 0.23, 0.024, palette.cream, { rx: Math.PI / 2 });
    for (let i = 0; i < 5; i++) {
      const x = (i - 2) * 0.23;
      box(at, x, 1.23, -0.56, 0.035, 0.28, 0.035, palette.wood);
      box(at, x, 1.39, -0.56, 0.14, 0.07, 0.06, palette.brass);
    }
    for (let i = 0; i < 4; i++) cylinder(at, 0, 0.47 + i * 0.11, 0.62, 0.055, 1.25, palette.wood, { rz: Math.PI / 2 });
  }

  function windmill(at) {
    cone(at, 0, 1.18, 0, 0.58, 0.34, 1.65, palette.cream);
    for (let i = 0; i < 7; i++) ring(at, 0, 0.46 + i * 0.21, 0, 0.55 - i * 0.029, 0.014, [0.47, 0.31, 0.19, 0.45]);
    cone(at, 0, 2.29, 0, 0.60, 0, 0.60, palette.sage);
    materialBox(at, 0, 0.70, 0.52, 0.28, 0.54, 0.05, 1);
    const rotor = at.group({ y: 1.83, z: 0.52, animate: (node, seconds) => { node.rz = -(seconds % 12) / 12 * tau; } });
    for (let i = 0; i < 4; i++) {
      const sail = rotor.group({ rz: i * Math.PI / 2 });
      materialBox(sail, 0, 0.49, 0, 0.055, 1.08, 0.055, 1);
      box(sail, 0.12, 0.58, 0, 0.23, 0.72, 0.028, palette.cream);
      for (let j = 0; j < 5; j++) box(sail, 0.12, 0.26 + j * 0.15, 0.025, 0.27, 0.02, 0.038, palette.wood);
    }
    sphere(rotor, 0, 0, 0.05, 0.10, palette.brass);
  }

  function kitchen(at) {
    sphere(at, -0.22, 0.78, -0.15, 0.64, "#b06e45", { sy: 0.9, sz: 0.85 });
    materialBox(at, -0.22, 0.51, -0.15, 1.25, 0.36, 1.12, 2);
    box(at, -0.22, 0.71, 0.40, 0.50, 0.40, 0.04, "#251e17");
    box(at, -0.22, 0.55, 0.43, 0.31, 0.08, 0.045, "#f46e1e");
    materialBox(at, -0.40, 1.62, -0.33, 0.24, 0.78, 0.25, 2);
    materialBox(at, 0.65, 0.91, 0, 0.50, 0.09, 1.30, 1);
    for (const z of [-0.50, 0.50]) materialBox(at, 0.65, 0.63, z, 0.10, 0.50, 0.10, 1);
    for (const z of [-0.38, 0.12]) {
      cylinder(at, 0.65, 0.98, z, 0.12, 0.025, palette.cream);
      sphere(at, 0.65, 1.025, z, 0.09, "#d1a145", { sy: 0.5, sz: 0.8 });
    }
    distanceBeam(at, [-0.78, 0.41, 0.67], [-0.78, 1.28, 0.62], 0.026, palette.wood);
  }

  function teaHouse(at) {
    for (const x of [-0.70, 0.70]) for (const z of [-0.65, 0.65]) cylinder(at, x, 1.05, z, 0.055, 1.36, palette.wood);
    roof(at, 1.95, 1.88, 1.90, palette.sage);
    cylinder(at, 0, 0.88, 0, 0.40, 0.065, palette.wood);
    cylinder(at, 0, 0.64, 0, 0.075, 0.45, palette.wood);
    for (const x of [-0.60, 0.60]) {
      materialBox(at, x, 0.64, 0, 0.22, 0.09, 1.05, 1);
      for (const z of [-0.4, 0.4]) materialBox(at, x, 0.49, z, 0.08, 0.24, 0.09, 1);
    }
    sphere(at, 0, 1.01, 0, 0.11, palette.cream, { sy: 0.8 });
    distanceBeam(at, [0.06, 1.01, 0], [0.19, 1.07, 0], 0.028, palette.cream);
    for (const x of [-0.21, 0.21]) cylinder(at, x, 0.96, 0.15, 0.052, 0.07, palette.sage);
    for (const x of [-0.70, 0.70]) sphere(at, x, 1.49, 0.65, 0.075, palette.amber);
  }

  const extendedModels = { rainCollector, orchard, workshop, windmill, kitchen, teaHouse };

  function buildIsland(world, items) {
    const stage = items.find((item) => item.kind === "__world")?.level || 0;
    terrain(world.root, stage);
    for (const item of items) {
      if (item.kind === "__world") continue;
      const { id, level, x, z, movable, title } = item;
      const at = world.group({ id, x, z, movable });
      const extended = extendedModels[id];
      if (extended) {
        materialBox(at, 0, 0.32, 0, 1.85, 0.14, 1.80, 2);
        extended(at);
        facilityUpgrades(at, level, true);
      } else {
        materialBox(at, 0, 0.29, 0, 1.90, 0.13, 1.80, 2);
        if (id === "campfire") campfire(at, level);
        else if (id === "well") well(at, level);
        else if (["garden", "farm", "herbGarden"].includes(id)) cropBeds(at, id, level);
        else {
          if (id === "training") training(at);
          else dwelling(at, id, level);
          facilityUpgrades(at, level);
        }
      }
      if (title) world.label?.(at, { text: `${title} · ${level}`, y: 2.55, color: "#163439", onlySelected: true, w: 2 });
    }
  }

  const gao = () => window.Gao;
  const t = (cn, en) => gao().t(cn, en);
  const e = (value) => gao().esc(value);
  const icon = (name) => gao().icon(name);
  const api = "/api/health/";
  let mounted = [];
  const view = { selected: "", layout: false, draft: {}, zoom: initialZoom, notice: "", saving: false };

  function control(label, action, { id = "", glyph = "", disabled = false, primary = false, iconOnly = false, title = label } = {}) {
    return `<button type="button" data-island-action="${e(action)}" data-island-id="${e(id)}"
      ${title ? `title="${e(title)}" aria-label="${e(title)}"` : ""}${disabled ? " disabled" : ""}
      ${primary ? 'class="primary"' : ""}>${glyph ? icon(glyph) : ""}${iconOnly ? "" : `<span>${e(label)}</span>`}</button>`;
  }

  function render(preview = false) {
    const label = preview ? "" : `role="region" aria-label="${e(t("活力之岛", "The living island"))}"`;
    return `<div class="health-island-world ${preview ? "island-overview" : "island-interactive"}" data-island-world="${preview ? "preview" : "full"}" ${label}>
      <img class="island-world-fallback" src="${art.island}" alt="${preview ? "" : e(t("荒岛场景", "Island view"))}">
      <div class="island-world-surface"${preview ? ' aria-hidden="true"' :
        ` tabindex="0" aria-label="${e(t("岛屿三维场景。布局时用方向键移动所选建筑。", "Island scene. In Layout, use the arrow keys to move the selected building."))}"`}></div>
      ${preview ? "" : `<div class="island-scene-heading"><div><p>${e(t("活力之岛", "THE LIVING ISLAND"))}</p>
        <h2>${e(t("在岛上亲手建一座家", "Build a home on the island"))}</h2>
        <p data-island-hint></p></div><div class="island-camera-buttons"></div></div>
        <div class="island-scene-footer"><div data-island-panel></div><div class="island-scene-bar"></div></div>
        <p class="island-world-status" role="status" aria-live="polite"></p>`}</div>`;
  }

  function problemText(value) {
    if (!value) return "";
    return value.split(" · ").map((part) => {
      const expansion = /^需先扩建海岸至 (\d+) 级$/.exec(part);
      return t(part, expansion ? `Requires shore expansion level ${expansion[1]}` : problemNames[part]);
    }).join(" · ");
  }

  function titleOf(catalog, id) {
    const recipe = catalog.islandRecipes.find((item) => item.id === id);
    return recipe ? t(recipe.name, recipe.englishName || buildings[id]?.[0]) : id;
  }

  function itemsFor(scene, catalog, preview) {
    return [{ id: "__world", kind: "__world", level: scene.expansionLevel }, ...scene.buildings.map((id) => {
      const position = (!preview && view.layout ? view.draft[id] : null) || scene.placements[id] || { x: 0, z: 0 };
      return { id, kind: id, title: titleOf(catalog, id), level: scene.buildingLevels[id] || 1,
        x: Number(position.x), z: Number(position.z), movable: !preview && view.layout };
    })];
  }

  function setNotice(mount, text) {
    view.notice = text;
    const status = mount.host.querySelector(".island-world-status");
    if (status) status.textContent = text;
  }

  function moveBuilding(mount, id, x, z) {
    if (!view.layout || view.saving || !Object.hasOwn(view.draft, id)) return false;
    const point = { x: Math.round(x * 1000) / 1000, z: Math.round(z * 1000) / 1000 };
    const radius = Math.sqrt(31) + mount.scene.expansionLevel * 0.7;
    if (!Number.isFinite(point.x) || !Number.isFinite(point.z) || Math.hypot(point.x, point.z) >= radius) {
      setNotice(mount, t("建筑不能超出海岸。", "Keep the building inside the shore."));
      return false;
    }
    if (Object.entries(view.draft).some(([key, value]) => key !== id && Math.hypot(value.x - point.x, value.z - point.z) <= 1.5)) {
      setNotice(mount, t("建筑之间需要留出空间。", "Leave space between buildings."));
      return false;
    }
    view.draft[id] = point;
    select(mount, id);
    setNotice(mount, "");
    return true;
  }

  function applyCoordinateFields(mount) {
    const x = mount.host.querySelector('[name="island-x"]');
    const z = mount.host.querySelector('[name="island-z"]');
    if (!x?.reportValidity() || !z?.reportValidity()) return;
    if (moveBuilding(mount, view.selected, x.valueAsNumber, z.valueAsNumber)) draw(mount, { restore: true });
  }

  function select(mount, id) {
    view.selected = mount.scene.buildings.includes(id) ? id : "";
    mount.engine?.setSelected(view.selected || null);
    paintPanel(mount);
  }

  function draw(mount, { restore = false } = {}) {
    const { scene, catalog, preview, host } = mount;
    if (restore && mount.engine) view.zoom = mount.engine.getCamera().zoom;
    mount.engine?.destroy();
    mount.engine = window.GaoWorld?.mount(host.querySelector(".island-world-surface"), {
      mode: "island",
      items: itemsFor(scene, catalog, preview),
      zoom: preview ? initialZoom + scene.expansionLevel * 1.6 : view.zoom,
      yaw,
      rotate: false,
      camera: { target: [0, 0, 0], minimumZoom: zoomLimits[0], maximumZoom: zoomLimits[1], pitch: Math.atan2(13, 17) },
      background: "#7ac4d9",
      label: t("岛屿三维场景", "Island scene"),
      build: buildIsland,
      onSelect: preview ? undefined : (id) => select(mount, id),
      onMove: preview ? undefined : (id, x, z) => moveBuilding(mount, id, x, z),
      onFallback: () => {
        mount.engine = null;
        host.dataset.islandRenderer = "art";
        if (!preview) paintTools(mount);
      },
    }) || null;
    host.dataset.islandRenderer = mount.engine ? "webgl" : "art";
    if (preview && mount.engine) mount.engine.canvas.tabIndex = -1;
    if (mount.engine && !preview && view.selected) mount.engine.setSelected(view.selected);
    if (!preview) {
      paintTools(mount);
      paintPanel(mount);
    }
  }

  function paintTools(mount) {
    const { scene, catalog, host, engine } = mount;
    const hint = host.querySelector("[data-island-hint]");
    if (view.layout) {
      hint.textContent = engine ?
        t("拖动布置建筑 · 完成后保存或取消", "Drag buildings · save or cancel when finished") :
        t("输入建筑坐标 · 完成后保存或取消", "Enter building coordinates · save or cancel when finished");
    } else {
      hint.textContent = engine ?
        t("点击建筑查看和升级 · 移动建筑请进入布局模式", "Click a building to inspect · enter Layout to move") :
        t("从清单查看建筑 · 移动建筑请进入布局模式", "Choose a building to inspect · enter Layout to move");
    }
    host.dataset.islandLayout = String(view.layout);
    const controls = view.layout ?
      control(t("取消", "Cancel"), "cancel", { disabled: view.saving }) +
      control(t("保存布局", "Save layout"), "save", { primary: true, disabled: view.saving }) :
      control(t("布局模式", "Layout"), "layout", { glyph: "edit" });
    host.querySelector(".island-camera-buttons").innerHTML = controls + (!engine ? "" :
      control(t("放大", "Zoom in"), "zoom-in", { glyph: "plus", iconOnly: true }) +
      control("−", "zoom-out", { title: t("缩小", "Zoom out") }));
    const unbuilt = catalog.islandRecipes.filter((item) => !item.tool && !scene.buildings.includes(item.id));
    const build = unbuilt.length ? `<details class="island-world-menu"><summary>${icon("home")}${e(t("建造", "Build"))}</summary>
      <div>${unbuilt.map((recipe) => {
        const problem = problemText(scene.buildProblems[recipe.id]);
        return control([titleOf(catalog, recipe.id), problem].filter(Boolean).join(" · "), "build", { id: recipe.id, disabled: Boolean(problem) });
      }).join("")}</div></details>` : control(t("建造", "Build"), "build", { glyph: "home", disabled: true });
    const gather = `<details class="island-world-menu"><summary>${icon("leaf")}${e(t("采集", "Gather"))}</summary>
      <div>${catalog.islandActions.map((action) => {
        const problem = problemText(scene.actionProblems[action.id]);
        return control([t(action.name, action.englishName || actionNames[action.id]), problem].filter(Boolean).join(" · "), "gather",
          { id: action.id, disabled: Boolean(problem) });
      }).join("")}</div></details>`;
    host.querySelector(".island-scene-bar").innerHTML = (view.layout ? "" : build + gather +
      control(t("扩地", "Expand"), "expand", { glyph: "water", disabled: Boolean(scene.expansionProblem),
        title: problemText(scene.expansionProblem) || t("扩地", "Expand") })) +
      `<span class="island-level">${icon("leaf")} Lv.${scene.level} · ${scene.prosperity}</span>`;
  }

  function paintPanel(mount) {
    const { host, scene, catalog } = mount;
    const panel = host.querySelector("[data-island-panel]");
    if (!panel) return;
    const current = view.selected;
    const detail = current ? buildings[current] : null;
    const chooser = scene.buildings.length ?
      `<label class="island-item-chooser"><span>${e(t("建筑", "Building"))}</span>
      <select name="island-building"><option value="">${e(t("选择建筑", "Choose a building"))}</option>
      ${scene.buildings.map((id) => `<option value="${e(id)}"${current === id ? " selected" : ""}>${e(titleOf(catalog, id))}</option>`).join("")}</select></label>` : "";
    const choose = () => {
      panel.querySelector('[name="island-building"]')?.addEventListener("change", (event) => {
        select(mount, event.currentTarget.value);
        host.querySelector('[name="island-building"]')?.focus({ preventScroll: true });
      });
    };
    if (view.layout) {
      const point = view.draft[current];
      panel.innerHTML = !scene.buildings.length ? `<p class="island-selection">${e(t("建好第一座建筑后即可调整布局。", "Build your first structure to arrange the island."))}</p>` :
        `<div class="island-selection">${chooser}${point ? `<label>X<input type="number" name="island-x" step="any" required value="${e(point.x)}"></label>
        <label>Z<input type="number" name="island-z" step="any" required value="${e(point.z)}"></label>
        ${control(t("移动", "Move"), "coordinates", { disabled: view.saving })}` : ""}</div>`;
      choose();
      return;
    }
    if (!current || !detail) {
      panel.innerHTML = chooser;
      choose();
      return;
    }
    const level = scene.buildingLevels[current] || 1;
    const upgradeProblem = problemText(scene.upgradeProblems[current]);
    const preferences = gao().state.health.preferences;
    const ledger = gao().state.health.dailyLedger;
    const teaProblem = scene.paused || !preferences.gameEnabled ? t("茶亭尚未开放", "Tea pavilion unavailable") :
      (ledger.teaUses || 0) >= 2 ? t("今日已泡茶 2 次", "Daily limit reached") :
      ((scene.inventory.herb || 0) < 2 || scene.energy >= 100 ? t("需要 2 药材，且活力未满", "Needs 2 herbs and room for energy") : "");
    panel.innerHTML = `<div class="island-selection">${icon(detail[3])}<div><strong>${e(titleOf(catalog, current))} · Lv.${level}</strong>
      <small>${e(t(detail[1], detail[2]))}</small></div>${current === "teaHouse" ?
        control(t("泡茶 · 2 药材", "Brew · 2 herbs"), "tea", { title: teaProblem || t("泡茶 · 2 药材", "Brew · 2 herbs"), disabled: Boolean(teaProblem) }) : ""}
      ${control(level >= 4 ? t("已满级", "Max level") : t("升级外观与能力", "Upgrade"), "upgrade", {
        id: current, disabled: Boolean(upgradeProblem), title: upgradeProblem || t("升级外观与能力", "Upgrade") })}
      ${control("×", "clear", { title: t("关闭建筑详情", "Close building details") })}</div>`;
  }

  async function onControl(mount, target) {
    const action = target.dataset.islandAction;
    const id = target.dataset.islandId;
    switch (action) {
      case "layout":
        view.draft = Object.fromEntries(mount.scene.buildings.map((key) => [key, { ...mount.scene.placements[key] }]));
        view.layout = true;
        setNotice(mount, "");
        draw(mount, { restore: true });
        mount.host.querySelector('[data-island-action="cancel"]')?.focus({ preventScroll: true });
        return;
      case "cancel":
        view.layout = false;
        view.draft = {};
        setNotice(mount, "");
        draw(mount, { restore: true });
        mount.host.querySelector('[data-island-action="layout"]')?.focus({ preventScroll: true });
        return;
      case "save": {
        view.saving = true;
        paintTools(mount);
        try {
          await gao().act(api + "layout", { placements: view.draft }, { render: false, throw: true });
          view.layout = false;
          view.draft = {};
          view.notice = "";
          gao().render();
          document.querySelector('.island-interactive [data-island-action="layout"]')?.focus({ preventScroll: true });
        } catch (error) {
          setNotice(mount, error.message);
        } finally {
          view.saving = false;
          if (mount.host.isConnected) paintTools(mount);
        }
        return;
      }
      case "zoom-in":
      case "zoom-out":
        mount.engine?.setZoom(mount.engine.getCamera().zoom + (action === "zoom-in" ? -1.5 : 1.5));
        return;
      case "clear": select(mount, ""); return;
      case "coordinates": applyCoordinateFields(mount); return;
      case "build": {
        const result = await gao().act(api + "build", { id }, { render: false });
        if (result) { view.selected = id; gao().render(); }
        return;
      }
      case "gather": await gao().act(api + "act", { id }); return;
      case "upgrade": await gao().act(api + "upgrade", { id }); return;
      case "expand": await gao().act(api + "expand"); return;
      case "tea": await gao().act(api + "tea"); return;
    }
  }

  function readKey(event, mount) {
    if (!view.layout || !view.selected || !event.target.closest(".island-world-surface")) return;
    const delta = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
    if (!delta) return;
    event.preventDefault();
    event.stopPropagation();
    const [dx, dz] = delta;
    const { x, z } = view.draft[view.selected];
    const step = event.shiftKey ? 0.45 : 0.15;
    if (moveBuilding(mount, view.selected, x + dx * step, z + dz * step)) {
      draw(mount, { restore: true });
      mount.host.querySelector(".island-world-surface").focus({ preventScroll: true });
    }
  }

  function clear({ preserve = true } = {}) {
    for (const mount of mounted) {
      if (preserve && !mount.preview && mount.engine) view.zoom = mount.engine.getCamera().zoom;
      mount.engine?.destroy();
    }
    mounted = [];
  }

  function bind(scene, catalog) {
    clear();
    if (!scene) return;
    if (!scene.buildings.includes(view.selected)) view.selected = "";
    for (const host of document.querySelectorAll("[data-island-world]")) {
      const preview = host.dataset.islandWorld === "preview";
      const mount = { host, preview, scene, catalog, engine: null };
      if (!preview) {
        host.addEventListener("keydown", (event) => readKey(event, mount), { capture: true });
        host.addEventListener("click", (event) => {
          const button = event.target.closest("[data-island-action]");
          if (button && !button.disabled) onControl(mount, button).catch((error) => setNotice(mount, error.message));
        });
      }
      mounted.push(mount);
      draw(mount);
      if (view.notice && !preview) setNotice(mount, view.notice);
    }
  }

  function leave() {
    clear({ preserve: false });
    Object.assign(view, { selected: "", layout: false, draft: {}, zoom: initialZoom, notice: "", saving: false });
  }

  window.IslandWorld = { render, bind, leave };
})();
