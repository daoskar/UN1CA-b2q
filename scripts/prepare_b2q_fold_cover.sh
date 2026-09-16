#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stage fold/cover specific files from the extracted stock SM-F711B firmware.
# Nothing is taken from another donor device. The staged files are installed
# later into UN1CA's active work tree by target/b2q/patches/fold_cover_stock.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_FW_DIR="${1:-}"
DEST="$ROOT/target/b2q/fold-cover"

if [[ -z "$TARGET_FW_DIR" || ! -d "$TARGET_FW_DIR" ]]; then
    echo "Usage: scripts/prepare_b2q_fold_cover.sh <extracted-target-firmware-directory>" >&2
    exit 2
fi

rm -rf "$DEST"
mkdir -p "$DEST/root"

python3 - "$TARGET_FW_DIR" "$DEST" <<'PY_B2Q_FOLD_COVER'
from __future__ import annotations

from hashlib import sha256
from pathlib import Path
import re
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET

fw = Path(sys.argv[1]).resolve()
dest = Path(sys.argv[2]).resolve()
stage = dest / "root"
manifest = dest / "manifest.tsv"
report = dest / "report.txt"


def relpath(path: Path) -> Path:
    return path.resolve().relative_to(fw)


def text_contains(path: Path, pattern: re.Pattern[str]) -> bool:
    try:
        return pattern.search(path.read_text(encoding="utf-8", errors="ignore")) is not None
    except OSError:
        return False


def add(path: Path, reason: str, collected: dict[Path, str]) -> None:
    try:
        rel = relpath(path)
    except ValueError:
        return
    if not path.is_file():
        return
    collected.setdefault(rel, reason)


# Keep an immutable stock reference for the final workdir audit. Upstream
# __floating_feature already merges target features; do not invent config vars.
ff_candidates = [fw / item for item in (
    "system/system/etc/floating_feature.xml", "system/etc/floating_feature.xml")]
ff = next((item for item in ff_candidates if item.is_file()), None)
if ff is None:
    raise SystemExit("Stock floating_feature.xml missing; incomplete F711B extraction")
ET.parse(ff)
shutil.copy2(ff, dest / "stock-floating-feature.xml")
(dest / "stock-floating-feature.sha256").write_text(sha256(ff.read_bytes()).hexdigest() + "\n")

collected: dict[Path, str] = {}

# AOSP/Samsung fold-state and multi-display policy. Copy the complete stock
# XML directories because the files frequently cross-reference physical
# display ids and state identifiers.
for path in fw.rglob("*.xml"):
    posix = "/" + path.as_posix().lower().lstrip("/")
    name = path.name.lower()

    if "/etc/devicestate/" in posix:
        add(path, "stock device-state configuration", collected)
        continue
    if "/etc/displayconfig/" in posix:
        add(path, "stock display configuration", collected)
        continue
    if name == "input-port-associations.xml" and "/etc/" in posix:
        add(path, "stock input/display port association", collected)
        continue

    if "/etc/permissions/" in posix:
        if "hinge" in name or text_contains(path, re.compile(r"android\.hardware\.sensor\.hinge_angle", re.I)):
            add(path, "stock hinge-angle feature declaration", collected)
            continue
        if text_contains(path, re.compile(r"com\.samsung\.controlpanel", re.I)):
            add(path, "stock Flex mode panel permission declaration", collected)
            continue

    if "/etc/sysconfig/" in posix and text_contains(
        path,
        re.compile(r"com\.samsung\.controlpanel|flex.?mode|half.?fold|sub.?display|cover.?screen", re.I),
    ):
        add(path, "stock fold/Flex sysconfig", collected)

# The Flex mode panel is a Samsung system application (package
# com.samsung.controlpanel). On slab-phone donors such as the Galaxy S22 it can
# be absent even when the framework has the Flip floating-feature flags.
# Prefer the canonical ControlPanel.apk path and fall back to filenames that
# clearly identify the component. We intentionally do NOT transplant AOD,
# SystemUI or Settings APKs from Android 15 into the Android 16 donor.
apk_candidates: list[tuple[int, Path]] = []
package_ascii = b"com.samsung.controlpanel"
package_utf16 = "com.samsung.controlpanel".encode("utf-16le")
for path in fw.rglob("*.apk"):
    low_name = path.name.lower()
    low_parent = path.parent.name.lower()
    rank: int | None = None
    if low_name == "controlpanel.apk" or low_parent == "controlpanel":
        rank = 0
    elif "flexmodepanel" in low_name or "flex_mode_panel" in low_name:
        rank = 1
    else:
        # Binary AndroidManifest.xml string pools retain the package string in
        # either UTF-8 or UTF-16LE form. This lets us find the package even if
        # Samsung changes the APK filename, without needing aapt/apktool here.
        try:
            with zipfile.ZipFile(path) as archive:
                raw_manifest = archive.read("AndroidManifest.xml")
            if package_ascii in raw_manifest or package_utf16 in raw_manifest:
                rank = 2
        except (OSError, KeyError, zipfile.BadZipFile):
            pass
    if rank is not None:
        apk_candidates.append((rank, path))

apk_candidates.sort(key=lambda item: (
    item[0],
    0 if "/priv-app/" in item[1].as_posix().lower() else 1,
    len(item[1].as_posix()),
    item[1].as_posix(),
))
control_panel: Path | None = apk_candidates[0][1] if apk_candidates else None
if control_panel is not None:
    add(control_panel, "stock Samsung Flex mode panel application", collected)

if not collected:
    raise SystemExit("No fold/cover files found in stock; refusing a successful no-op patch")

# Copy staged files with their exact partition-relative path.
manifest_rows: list[tuple[str, str, str]] = []
for rel in sorted(collected, key=lambda p: p.as_posix()):
    src = fw / rel
    dst = stage / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    digest = sha256(dst.read_bytes()).hexdigest()
    manifest_rows.append((rel.as_posix(), digest, collected[rel]))

manifest.write_text(
    "".join(f"{rel}\t{digest}\t{reason}\n" for rel, digest, reason in manifest_rows),
    encoding="utf-8",
)

# Produce a human-readable report that lands in build logs via the wrapper.
device_state_files = [r for r, _, _ in manifest_rows if "/devicestate/" in ("/" + r.lower())]
display_files = [r for r, _, _ in manifest_rows if "/displayconfig/" in ("/" + r.lower())]
hinge_files = [r for r, _, reason in manifest_rows if "hinge-angle" in reason]
control_rel = relpath(control_panel).as_posix() if control_panel is not None else "missing"

state_tokens: set[str] = set()
for rel in device_state_files:
    try:
        text = (fw / rel).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    for token in ("CLOSED", "HALF_FOLDED", "HALF-FOLDED", "OPEN", "hinge_angle", "hinge angle"):
        if token.lower() in text.lower():
            state_tokens.add(token)

lines = [
    "B2Q stock fold/cover preparation report",
    f"firmware={fw}",
    f"staged_files={len(manifest_rows)}",
    f"device_state_files={len(device_state_files)}",
    f"display_config_files={len(display_files)}",
    f"hinge_feature_files={len(hinge_files)}",
    f"control_panel={control_rel}",
    f"device_state_tokens={','.join(sorted(state_tokens)) if state_tokens else 'none-detected'}",
    "",
]
if device_state_files:
    lines.append("Device-state files:")
    lines.extend(f"  {item}" for item in device_state_files)
else:
    lines.append("WARNING: no stock */etc/devicestate/*.xml files were found")

lines.append("")
if display_files:
    lines.append("Display-config files:")
    lines.extend(f"  {item}" for item in display_files)
else:
    lines.append("WARNING: no stock */etc/displayconfig/*.xml files were found")

lines.append("")
if control_panel is not None:
    lines.append(f"Flex mode panel APK: {control_rel}")
else:
    lines.append("WARNING: stock ControlPanel/FlexModePanel APK was not found")

report.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"- B2Q-FOLD-COVER: staged {len(manifest_rows)} stock SM-F711B file(s)")
print(f"- B2Q-FOLD-COVER: device-state XML(s): {len(device_state_files)}")
print(f"- B2Q-FOLD-COVER: display-config XML(s): {len(display_files)}")
if control_panel is not None:
    print(f"- B2Q-FLEX: stock Flex mode panel candidate: {control_rel}")
else:
    print("- B2Q-FLEX: WARNING: stock Flex mode panel APK not found; panel injection will be skipped", file=sys.stderr)
if state_tokens:
    print(f"- B2Q-FOLD-COVER: stock state tokens: {', '.join(sorted(state_tokens))}")
else:
    print("- B2Q-FOLD-COVER: stock device-state tokens were not identified; exact stock files are still staged", file=sys.stderr)
print(f"- B2Q-FOLD-COVER: report: {report.relative_to(Path(ROOT)) if 'ROOT' in globals() else report}")
PY_B2Q_FOLD_COVER

chmod 0644 "$DEST/manifest.tsv" "$DEST/report.txt"
find "$DEST/root" -type f -exec chmod 0644 {} +

echo "- B2Q-FOLD-COVER: preparation summary"
sed 's/^/  /' "$DEST/report.txt"
