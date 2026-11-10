#!/usr/bin/env python3
"""Static guard: the shipping UI must not create or schedule backup restores."""
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "Host/AppMain.swift",
    "Host/Settings.swift",
    "Module.swift",
    "Integrated/Health/Module.swift",
    "Integrated/Health/Sources/App.swift",
    "Integrated/Health/Sources/SettingsView.swift",
    "Integrated/Health/Sources/Store.swift",
    "Integrated/Health/Shared/Database.swift",
    "Integrated/Health/Widgets/HealthWidgets.swift",
    "Integrated/Health/HostSupport/Settings.swift",
    "Integrated/Footprints/Module.swift",
    "Integrated/Footprints/Sources/Store.swift",
    "Integrated/Footprints/Sources/JournalViews.swift",
    "Integrated/Footprints/Shared/Repository.swift",
    "Integrated/Footprints/HostSupport/Settings.swift",
]
FORBIDDEN = [
    "导出完整资料",
    "从完整资料恢复",
    "导出模块备份",
    "恢复模块备份",
    "完整资料备份与恢复",
    "从备份恢复",
    "AppBackupRestore.applyPending",
    "applyPendingRestoreBeforeOpening",
    "exportModuleBackup",
    "restoreModuleBackup",
    "exportFullBackup",
    "restoreFullBackup",
    "exportBackup",
    "restoreBackup",
    "automaticBackup(",
    "dailySnapshot(",
    "openBackups(",
    "自动备份目录",
    "恢复备份",
    "导出完整备份",
    "恢复完整备份",
    "store.backup()",
    "store.restore()",
    'destination == "export"',
    'destination == "import"',
    'case "export"',
    'case "import"',
    "GaoSeries.rhythm.export",
    "GaoSeries.rhythm.import",
    "GaoSeries.health.export",
    "GaoSeries.health.import",
    "GaoSeries.footprints.export",
    "GaoSeries.footprints.import",
]

violations = []
for relative in FILES:
    text = (ROOT / relative).read_text(encoding="utf-8")
    for token in FORBIDDEN:
        if token in text:
            violations.append(f"{relative}: {token}")

install = (ROOT / "scripts/install.sh").read_text(encoding="utf-8")
for token in ("rollback", "ARCHIVE", "RECEIPT", "VERIFIED", "upgrade_data.py snapshot"):
    if token in install:
        violations.append(f"scripts/install.sh: {token}")

info = plistlib.loads((ROOT / "Info.plist").read_bytes())
if info.get("CFBundleShortVersionString") != "4.12" or info.get("CFBundleVersion") != "13":
    violations.append("Info.plist: expected version 4.12 build 13")
for key in ("CFBundleDocumentTypes", "UTExportedTypeDeclarations"):
    if "backup" in str(info.get(key, [])).lower() or "备份" in str(info.get(key, [])):
        violations.append(f"Info.plist: backup declaration remains in {key}")

if violations:
    print("FAIL: backup, restore, or rollback entry remains")
    print("\n".join(violations))
    raise SystemExit(1)
print("PASS: no backup, restore, or rollback entry; version is 4.12 build 13")
