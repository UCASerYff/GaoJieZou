#!/usr/bin/env python3
"""Enforce the active workspace integration build schedule; never acquire a lease."""
import json
import os
from pathlib import Path

master = Path(__file__).resolve().parents[2] / '合并迁移-2026-11-02'
if master.is_dir():
    receipt = master / 'build.lock/owner.json'
    token = os.environ.get('GAO_BUILD_LEASE_TOKEN', '')
    owner = os.environ.get('GAO_BUILD_LEASE_OWNER', '')
    if not receipt.is_file() or receipt.is_symlink():
        raise SystemExit('Integration build requires Root GO and the current owned build lease; none acquired here')
    data = json.loads(receipt.read_text())
    if not owner or data.get('owner') != owner or not token or data.get('token') != token:
        raise SystemExit('Exact Rhythm integration owner/token required; refusing heavy build')
