#!/usr/bin/env python3
import contextlib
import io
from pathlib import Path
import shutil
import subprocess
import sys
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/install.sh").read_text()
START = SCRIPT.index("import pathlib,re,subprocess,sys,uuid")
END = SCRIPT.index("\nPYWIDGETREG", START)
EMBEDDED = SCRIPT[START:END]
BID = "com.gaojiezou.rhythm.widgets"
FIXTURE_ROOT = ROOT / ".registration-test.noindex"
EXTENSION = FIXTURE_ROOT / "搞节奏.app/Contents/PlugIns/GaoJieZouWidgets.appex"
CANDIDATE = FIXTURE_ROOT / "候选.app/Contents/PlugIns/GaoJieZouWidgets.appex"


def block(version, path, identifier):
    return f"""+    {BID}({version})
\t            Path = {path}
\t            UUID = {identifier}
\t       Timestamp = 2026-11-10 10:19:06 +0000
"""


def main():
    EXTENSION.mkdir(parents=True)
    CANDIDATE.mkdir(parents=True)
    output = (
        block("4.11", CANDIDATE, "24216E32-886E-4654-9606-8D34F004808E")
        + "\n"
        + block("4.10", EXTENSION, "2BAC53D6-2A5E-4097-A599-7BD9E38787A9")
        + "\n (2 plug-ins)\n"
    )
    completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=output, stderr="")
    arguments = ["embedded", str(EXTENSION), BID, "4.10"]
    stdout = io.StringIO()
    try:
        with mock.patch.object(sys, "argv", arguments), mock.patch("subprocess.run", return_value=completed), contextlib.redirect_stdout(stdout):
            exec(compile(EMBEDDED, "scripts/install.sh::widget-registration", "exec"), {})
    finally:
        shutil.rmtree(FIXTURE_ROOT)
    assert stdout.getvalue().strip() == "present", stdout.getvalue()
    print("PASS: duplicate bundle IDs are resolved by the exact formal extension path")


if __name__ == "__main__":
    main()
