#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text()


def main():
    content = read("Sources/WorkspaceContentView.swift")
    today = read("Sources/DashboardViews.swift")
    farm = read("Sources/GameEstateViews.swift")
    health = read("Integrated/Health/Sources/App.swift")
    footprints = read("Integrated/Footprints/Sources/App.swift")
    footprints_map = read("Integrated/Footprints/Sources/MapView.swift")
    map_shell = footprints_map.split("struct MapPage: View {", 1)[1].split("var visibleCities", 1)[0]

    assert "VStack(alignment:.leading,spacing:17) {" in map_shell, "地图页需收紧纵向间距，避免最小高度把共享工作台上顶"
    assert "VStack(alignment:.leading,spacing:18) {" not in map_shell, "18 点间距仍会让共享工作台上移约 3 像素"
    assert "ZStack(alignment: .top)" in footprints, "足迹正文必须从顶部排布，避免空间紧张时向上跳动"
    assert "ZStack(alignment: .bottom)" not in footprints, "底部对齐会在内容最小高度超出可用空间时挤出顶部"
    assert ".toolbar" not in health, "健康不应再向系统标题栏注入独立按钮"
    assert ".toolbar" not in footprints, "足迹不应再向系统标题栏注入独立按钮"
    assert "HealthModuleActionsView()" in content
    assert "FootprintsModuleActionsView()" in content
    assert "PlaygroundBackBar" not in content, "乐园应共用晨光次级导航，而非另一条横条"

    assert "showingSleepEditor" in today, "今天需要直接打开睡眠记录编辑器"
    assert "ManualSleepEditor" in today
    assert "Button(RhythmLocalization.text(\"记录睡眠\"))" in today

    assert "CropCollectionView" in farm, "农场需要自己的作物图鉴"
    assert "AnimalCollectionView" in farm, "牧场需要自己的牲畜图鉴"
    assert "FishCollectionView" in farm, "渔场需要自己的鱼类图鉴"
    assert "title: \"庄园图鉴\"" not in farm, "游戏内不再使用统一的庄园图鉴入口"
    print("PASS: shared workspace chrome, direct sleep entry, and local species collections")


if __name__ == "__main__":
    main()
