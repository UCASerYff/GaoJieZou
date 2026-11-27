"""Build a per-user x64 Windows Installer package from the frozen programs."""

from __future__ import annotations

import argparse
import pathlib
import sys
import uuid
from tempfile import TemporaryDirectory

import msilib
from msilib import schema, sequence

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "src"))
from gaojiezou.version import MARKETING_VERSION, WINDOWS_BUILD


UPGRADE_NAMESPACE = uuid.UUID("801bf94e-e785-4aca-aaca-211cb7c1bc44")
VERSION = f"{MARKETING_VERSION}.{WINDOWS_BUILD}"
FILE_VERSION = f"{MARKETING_VERSION}.0.{WINDOWS_BUILD}"


def guid(name):
    return "{" + str(uuid.uuid5(UPGRADE_NAMESPACE, name)).upper() + "}"


def make_installer(output: pathlib.Path, payload: pathlib.Path, icon: pathlib.Path) -> None:
    if not msilib.AMD64:
        raise RuntimeError("The package requires x64 Python 3.12.")
    db = msilib.init_database(str(output), schema, "GaoJieZou (Rhythm)", guid("x64-" + VERSION), VERSION, "GaoSeries")
    summary = db.GetSummaryInformation(5)
    summary.SetProperty(msilib.PID_WORDCOUNT, 10)  # Compressed, no elevation required.
    summary.SetProperty(msilib.PID_PAGECOUNT, 500)
    summary.SetProperty(msilib.PID_APPNAME, "GaoSeries Windows Installer")
    summary.Persist()

    msilib.add_data(db, "Property", [
        ("UpgradeCode", guid("upgrade")),
        ("ARPPRODUCTICON", "Rhythm.ico"),
        ("SecureCustomProperties", "OLDER_RHYTHM;NEWER_RHYTHM;WIN_MAJOR"),
    ])
    msilib.add_data(db, "Icon", [("Rhythm.ico", msilib.Binary(str(icon)))])
    msilib.add_data(db, "Upgrade", [
        (guid("upgrade"), None, VERSION, None, 0, None, "OLDER_RHYTHM"),
        (guid("upgrade"), VERSION, None, None, 2, None, "NEWER_RHYTHM"),
    ])
    msilib.add_data(db, "LaunchCondition", [
        ('Installed OR (VersionNT64 AND WIN_MAJOR AND WIN_MAJOR >= "#10")', "Rhythm requires Windows 10 or Windows 11 x64."),
        ("NOT NEWER_RHYTHM OR Installed", "A newer version of Rhythm is already installed."),
    ])
    # MSI caps VersionNT and WindowsBuild at Windows 8.1 for compatibility.
    msilib.add_data(db, "AppSearch", [("WIN_MAJOR", "WindowsMajorVersion")])
    msilib.add_data(db, "RegLocator", [("WindowsMajorVersion", 2, r"Software\Microsoft\Windows NT\CurrentVersion",
                                        "CurrentMajorVersionNumber", 18)])
    msilib.add_data(db, "Directory", [
        ("TARGETDIR", None, "SourceDir"),
        ("LocalAppDataFolder", "TARGETDIR", "."),
        ("LocalPrograms", "LocalAppDataFolder", "Programs"),
        ("INSTALLDIR", "LocalPrograms", "GAOJIE~1|GaoJieZou"),
        ("ProgramMenuFolder", "TARGETDIR", "."),
        ("RhythmMenu", "ProgramMenuFolder", "GAOJIE~1|GaoJieZou"),
    ])
    msilib.Feature(db, "Application", "Rhythm", "Rhythm desktop application and command line", 1,
                   directory="INSTALLDIR", attributes=16)
    msilib.Feature(db, "ShellIntegration", "Start menu", "Desktop widget launcher and Rhythm links", 3)
    msilib.add_data(db, "Component", [
        ("Gui", guid("gui"), "INSTALLDIR", 256, None, "GuiFile"),
        ("Cli", guid("cli"), "INSTALLDIR", 256, None, "CliFile"),
        ("RhythmShell", guid("shell"), "RhythmMenu", 260, None, "RhythmShellMarker"),
    ])
    msilib.add_data(db, "FeatureComponents", [
        ("Application", "Gui"), ("Application", "Cli"), ("ShellIntegration", "RhythmShell"),
    ])

    files = []
    cab_inputs = []
    for count, (key, component, name, short) in enumerate([
        ("GuiFile", "Gui", "GaoJieZou.exe", "GAOJIE~1.EXE"),
        ("CliFile", "Cli", "GaoJieZou-cli.exe", "GAOJIE~2.EXE"),
    ], start=1):
        source = payload / name
        files.append((key, component, short + "|" + name, source.stat().st_size, FILE_VERSION, "0", 512, count))
        cab_inputs.append((str(source), key))
    msilib.add_data(db, "File", files)
    with TemporaryDirectory(prefix="gao-rhythm-msi-") as temp:
        cab = str(pathlib.Path(temp) / "Payload.cab")
        msilib.FCICreate(cab, cab_inputs)
        msilib.add_stream(db, "Payload.cab", cab)
    msilib.add_data(db, "Media", [(1, len(files), None, "#Payload.cab", None, None)])

    msilib.add_data(db, "Registry", [
        ("RhythmShellMarker", 1, r"Software\GaoSeries\Rhythm\WindowsInstaller", "Shell", "#1", "RhythmShell"),
        ("ProtocolName", 1, r"Software\Classes\gaojiezou", None, "URL:GaoJieZou Rhythm", "RhythmShell"),
        ("ProtocolFlag", 1, r"Software\Classes\gaojiezou", "URL Protocol", "", "RhythmShell"),
        ("ProtocolIcon", 1, r"Software\Classes\gaojiezou\DefaultIcon", None, '"[#GuiFile]",0', "RhythmShell"),
        ("ProtocolOpen", 1, r"Software\Classes\gaojiezou\shell\open\command", None, '"[#GuiFile]" "%1"', "RhythmShell"),
    ])
    msilib.add_data(db, "Shortcut", [
        ("OpenRhythm", "RhythmMenu", "RHYTHM~1|GaoJieZou", "RhythmShell", "[#GuiFile]", None,
         "Open Rhythm", None, None, None, None, "INSTALLDIR"),
        ("OpenWidgets", "RhythmMenu", "RHYTHM~2|Rhythm Desktop Widgets", "RhythmShell", "[#GuiFile]", "--widgets",
         "Open Rhythm, Health and Footprints desktop widgets", None, None, None, None, "INSTALLDIR"),
    ])
    msilib.add_data(db, "RemoveFile", [("RemoveRhythmMenu", "RhythmShell", None, "RhythmMenu", 2)])

    execute = []
    for action, condition, order in sequence.InstallExecuteSequence:
        if action == "LaunchConditions":
            order = 490
        if action == "RemoveExistingProducts":
            order = 1510  # Roll back the upgrade as one transaction if installing fails.
        execute.append((action, condition, order))
    msilib.add_data(db, "InstallExecuteSequence", execute)
    add_ui(db)
    db.Commit()


def add_ui(db) -> None:
    msilib.add_data(db, "Property", [("DefaultUIFont", "InstallerFont")])
    msilib.add_data(db, "TextStyle", [("InstallerFont", "Segoe UI", 9, None, 0)])
    start = msilib.Dialog(db, "WelcomeDialog", 50, 50, 310, 105, 3, "[ProductName] setup", "Install", "Install", "Cancel")
    start.text("Description", 12, 12, 283, 47, 3,
               "Install [ProductName] [ProductVersion] for this Windows user. Rhythm keeps its records in your existing data folder.")
    start.pushbutton("Install", 179, 77, 58, 16, 3, "Install", "Cancel").event("EndDialog", "Return")
    start.pushbutton("Cancel", 241, 77, 58, 16, 3, "Cancel", "Install").event("EndDialog", "Exit")

    progress = msilib.Dialog(db, "ProgressDialog", 50, 50, 310, 90, 1, "[ProductName] setup", "Description", None, None)
    progress.text("Description", 12, 12, 283, 18, 3, "Windows Installer is working on [ProductName].")
    progress.control("Progress", "ProgressBar", 12, 40, 283, 12, 3, None, None, None, None).mapping("SetProgress", "Progress")

    for name, text in [("ExitDialog", "Windows Installer completed the operation."),
                       ("FatalError", "Windows Installer could not complete the operation."),
                       ("UserExit", "Windows Installer was cancelled.")]:
        dialog = msilib.Dialog(db, name, 50, 50, 310, 90, 3, "[ProductName] setup", "Okay", "Okay", "Okay")
        dialog.text("Description", 12, 12, 283, 38, 3, text)
        dialog.pushbutton("Okay", 241, 61, 58, 16, 3, "Close", "Okay").event("EndDialog", "Return")

    ui = [(action, condition, 490 if action == "LaunchConditions" else order)
          for action, condition, order in sequence.InstallUISequence]
    ui += [("WelcomeDialog", "NOT Installed", 1230), ("ProgressDialog", None, 1280)]
    msilib.add_data(db, "InstallUISequence", ui)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--payload", type=pathlib.Path, required=True)
    parser.add_argument("--icon", type=pathlib.Path, required=True)
    args = parser.parse_args()
    make_installer(args.output.resolve(), args.payload.resolve(), args.icon.resolve())


if __name__ == "__main__":
    main()
