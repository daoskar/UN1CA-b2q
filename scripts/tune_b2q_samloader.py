#!/usr/bin/env python3
"""Raise samloader's version.xml timeout without replacing UN1CA's download flow."""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import NoReturn


def die(message: str) -> NoReturn:
    print(f"tune_b2q_samloader: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 4:
    die("usage: tune_b2q_samloader.py <venv-dir> <connect-timeout> <read-timeout>")

venv = Path(sys.argv[1]).expanduser().resolve()
try:
    connect_timeout = int(sys.argv[2])
    read_timeout = int(sys.argv[3])
except ValueError:
    die("timeouts must be integers")

if not (1 <= connect_timeout <= 600 and 1 <= read_timeout <= 600):
    die("timeouts must be in range 1..600 seconds")

candidates = sorted(venv.glob("lib/python*/site-packages/samloader/versionfetch.py"))
if not candidates:
    die(f"samloader/versionfetch.py not found under {venv}")

pattern = re.compile(
    r"timeout\s*=\s*(?:\d+(?:\.\d+)?|\(\s*\d+(?:\.\d+)?\s*,\s*\d+(?:\.\d+)?\s*\))"
)
replacement = f"timeout=({connect_timeout}, {read_timeout})"
matched = 0

for path in candidates:
    original = path.read_text(encoding="utf-8", errors="surrogateescape")
    if "fota-cloud-dn.ospserver.net" not in original:
        print(f"tune_b2q_samloader: skipped unexpected file {path}", file=sys.stderr)
        continue
    updated, count = pattern.subn(replacement, original, count=1)
    if count == 0:
        print(f"tune_b2q_samloader: no timeout literal found in {path}", file=sys.stderr)
        continue
    matched += 1
    if updated != original:
        path.write_text(updated, encoding="utf-8", errors="surrogateescape")
    print(f"tune_b2q_samloader: {path} -> {replacement}")

if matched == 0:
    die("could not activate the requested timeout")
