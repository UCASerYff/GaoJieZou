#!/usr/bin/env python3
"""Optional synthetic macOS metadata probe. It does not run unless confirmed.

Without ``--confirm-synthetic-macos-probe`` this process prints ``not_run`` and
creates nothing. With that flag, on macOS only, it creates one new directory
whose name ends in ``.noindex``, writes a synthetic quarantine attribute inside
that directory, and runs the synthetic recovery tests with ``TMPDIR`` pointed
there. It does not launch 搞节奏, take build/foreground/writer locks, or read
the real Group, Application Support, Preferences, or /Applications.

The probe directory is left on disk. Removing it requires a separate decision.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import receiver_whitelist_recovery as tool  # noqa: E402

CONFIRM = "--confirm-synthetic-macos-probe"
SYNTHETIC_QUARANTINE = b"0083;00000000;RhythmSyntheticProbe;00000000"


def refuse_destination(path):
    tool.refuse_live(path)
    if not path.name.endswith(".noindex"):
        tool.fail("output_not_noindex")
    for forbidden in ("/Applications",):
        if tool.within(path, Path(forbidden)):
            tool.fail("live_data_root_refused", forbidden)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv != [CONFIRM]:
        if CONFIRM not in argv:
            print(json.dumps({"status": "not_run", "created": None,
                              "reason": "confirmation_required",
                              "realRecoveryCompleted": False}, sort_keys=True))
            return 0
        print(json.dumps({"status": "refused", "code": "probe_arguments_refused",
                          "created": None, "realRecoveryCompleted": False}, sort_keys=True))
        return 2
    if sys.platform != "darwin":
        print(json.dumps({"status": "refused", "code": "macos_probe_requires_darwin",
                          "created": None, "realRecoveryCompleted": False}, sort_keys=True))
        return 2
    parent = Path(tempfile.gettempdir())
    try:
        refuse_destination(parent / "rhythm-macos-probe-check.noindex")
    except tool.RecoveryError as error:
        print(json.dumps({"status": "refused", "code": error.code, "created": None,
                          "realRecoveryCompleted": False}, sort_keys=True))
        return 2
    created = Path(tempfile.mkdtemp(prefix="rhythm-macos-probe-", suffix=".noindex", dir=parent))
    try:
        refuse_destination(created)
    except tool.RecoveryError as error:
        print(json.dumps({"status": "refused", "code": error.code, "created": str(created),
                          "deleted": False, "realRecoveryCompleted": False}, sort_keys=True))
        return 2
    sample = created / "synthetic-quarantine-sample.bin"
    sample.write_bytes(b"synthetic-quarantine-not-user-data")
    os.setxattr(sample, "com.apple.quarantine", SYNTHETIC_QUARANTINE, follow_symlinks=False)
    readback = os.getxattr(sample, "com.apple.quarantine", follow_symlinks=False)
    env = os.environ.copy()
    env["TMPDIR"] = str(created)
    tests = subprocess.run([sys.executable, str(ROOT / "Tests/test_receiver_whitelist_recovery.py"), "-v"],
                           cwd=created, env=env, check=False, capture_output=True, text=True)
    result = {"status": "probe_finished_directory_retained", "created": str(created),
              "quarantineRoundTrip": readback == SYNTHETIC_QUARANTINE,
              "syntheticQuarantineOnly": True, "appLaunched": False, "locksAcquired": [],
              "unitTestExit": tests.returncode, "deleted": False,
              "realRecoveryCompleted": False, "productionPlanByteHashVerified": None,
              "removalRequiresSeparateConfirmation": True}
    (created / "RESULT.json").write_text(json.dumps(result, ensure_ascii=False, sort_keys=True) + "\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if tests.returncode == 0 and readback == SYNTHETIC_QUARANTINE else 1


if __name__ == "__main__":
    sys.exit(main())
