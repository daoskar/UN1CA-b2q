#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW_DIR="${1:-}"

if [[ -z "$FW_DIR" || ! -d "$FW_DIR" ]]; then
    echo "Usage: scripts/prepare_b2q_vintf.sh <extracted-target-firmware-directory>" >&2
    exit 2
fi

DEST="$ROOT/target/b2q/vintf"
OUT="$DEST/compatibility_matrix.device.xml"
MARKER="$DEST/.source-compatibility-matrix"
mkdir -p "$DEST"

# Android installs the device-specific framework compatibility matrix under
# system/etc/vintf. UN1CA's common VINTF module expects the same matrix in the
# target tree, so derive it from the extracted SM-F711B firmware instead of
# copying one from another device or manufacturing a permissive matrix.
candidates=(
    "$FW_DIR/system/system/etc/vintf/compatibility_matrix.device.xml"
    "$FW_DIR/system/etc/vintf/compatibility_matrix.device.xml"
)

while IFS= read -r candidate; do
    candidates+=("$candidate")
done < <(find "$FW_DIR" -type f -name 'compatibility_matrix.device.xml' -print 2>/dev/null | sort)

validate_matrix() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
if not path.is_file() or path.stat().st_size < 64:
    raise SystemExit(1)
try:
    root = ET.parse(path).getroot()
except (ET.ParseError, OSError):
    raise SystemExit(1)
name = root.tag.rsplit('}', 1)[-1]
if name != 'compatibility-matrix':
    raise SystemExit(1)
# compatibility_matrix.device.xml is a framework compatibility matrix. Some
# Samsung releases omit the type attribute, so accept an absent value but
# reject an explicitly incompatible type.
type_value = root.attrib.get('type')
if type_value not in (None, '', 'framework'):
    raise SystemExit(1)
# Reject an effectively empty placeholder. A real device matrix carries at
# least one requirement such as HAL, kernel, vendor-ndk or sepolicy.
children = [child.tag.rsplit('}', 1)[-1] for child in root]
if not any(name in {'hal', 'kernel', 'vendor-ndk', 'sepolicy', 'avb', 'xmlfile'} for name in children):
    raise SystemExit(1)
PY
}

SOURCE=""
declare -A SEEN=()
for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    canonical="$(readlink -f "$candidate")"
    [[ -z "${SEEN[$canonical]+x}" ]] || continue
    SEEN[$canonical]=1
    if validate_matrix "$canonical"; then
        SOURCE="$canonical"
        break
    fi
done

if [[ -z "$SOURCE" ]]; then
    echo "Could not find a valid compatibility_matrix.device.xml in extracted SM-F711B firmware: $FW_DIR" >&2
    echo "Available VINTF files:" >&2
    find "$FW_DIR" -type f -path '*/etc/vintf/*' -printf '  %p\n' 2>/dev/null | sort | head -n 120 >&2 || true
    exit 1
fi

SOURCE_SHA="$(sha256sum "$SOURCE" | awk '{print $1}')"
if [[ -f "$OUT" && -f "$MARKER" ]] \
    && grep -qxF "sha256=$SOURCE_SHA" "$MARKER" \
    && validate_matrix "$OUT"; then
    echo "- b2q VINTF matrix is already prepared from ${SOURCE#"$FW_DIR/"}"
    exit 0
fi

TMP="$(mktemp "$DEST/.compatibility_matrix.device.xml.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cp -- "$SOURCE" "$TMP"
chmod 0644 "$TMP"
validate_matrix "$TMP"
mv -f -- "$TMP" "$OUT"
trap - EXIT

{
    printf 'source=%s\n' "${SOURCE#"$FW_DIR/"}"
    printf 'sha256=%s\n' "$SOURCE_SHA"
} > "$MARKER"
chmod 0644 "$MARKER"

echo "- Prepared target/b2q/vintf/compatibility_matrix.device.xml from stock SM-F711B firmware"
echo "  source: ${SOURCE#"$FW_DIR/"}"
echo "  SHA-256: $SOURCE_SHA"
