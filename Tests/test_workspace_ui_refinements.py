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
