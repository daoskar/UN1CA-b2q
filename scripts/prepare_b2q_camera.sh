#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW_DIR="${1:-}"
DEST="$ROOT/target/b2q/camera/camera-feature.xml"

usage() {
    echo "Usage: scripts/prepare_b2q_camera.sh <extracted-target-firmware-directory>" >&2
}

[[ -n "$FW_DIR" ]] || { usage; exit 2; }
FW_DIR="$(cd "$FW_DIR" 2>/dev/null && pwd)" || {
    echo "Extracted target firmware directory not found: $1" >&2
    exit 2
}

# UN1CA's common camera patch expects a target-specific camera-feature.xml when
# the target firmware cannot be consumed directly. Do not invent feature flags:
# derive the file from the already extracted stock SM-F711B firmware.
candidates=(
    "$FW_DIR/system/system/cameradata/camera-feature.xml"
    "$FW_DIR/system/cameradata/camera-feature.xml"
    "$FW_DIR/product/etc/camera/camera-feature.xml"
    "$FW_DIR/vendor/etc/camera/camera-feature.xml"
    "$FW_DIR/system/system/cameradata/camera_features.xml"
    "$FW_DIR/system/cameradata/camera_features.xml"
)

SOURCE=""
for candidate in "${candidates[@]}"; do
    if [[ -s "$candidate" ]]; then
        SOURCE="$candidate"
        break
    fi
done

# Firmware layouts can move files between releases. Fall back to a constrained
# search while still requiring a cameradata/camera path and the expected name.
if [[ -z "$SOURCE" ]]; then
    while IFS= read -r candidate; do
        case "$candidate" in
            */cameradata/camera-feature.xml|*/camera/camera-feature.xml|*/cameradata/camera_features.xml)
                SOURCE="$candidate"
                break
                ;;
        esac
    done < <(find "$FW_DIR" -type f \
        \( -iname 'camera-feature.xml' -o -iname 'camera_features.xml' \) \
        -size +128c -print 2>/dev/null | LC_ALL=C sort)
fi

if [[ -z "$SOURCE" ]]; then
    echo "Stock SM-F711B camera-feature.xml was not found under: $FW_DIR" >&2
    echo "Available camera data files:" >&2
    find "$FW_DIR" -type f \
        \( -path '*/cameradata/*' -o -path '*/camera/*' \) \
        -printf '  %P\n' 2>/dev/null | LC_ALL=C sort | head -n 80 >&2 || true
    exit 1
fi

# Basic sanity check only. The upstream camera patch is responsible for editing
# the Samsung XML; this helper must preserve the stock feature set byte-for-byte.
python3 - "$SOURCE" <<'PYCHECK'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_bytes()
if len(data) < 128 or b"<" not in data or b">" not in data:
    raise SystemExit(f"Invalid or unexpectedly small camera feature file: {p}")
PYCHECK

mkdir -p "$(dirname "$DEST")"
TMP="$DEST.tmp.$$"
cp -f "$SOURCE" "$TMP"
chmod 0644 "$TMP"
mv -f "$TMP" "$DEST"

SOURCE_REL="${SOURCE#"$ROOT/"}"
DEST_REL="${DEST#"$ROOT/"}"
SHA256="$(sha256sum "$DEST" | awk '{print $1}')"
echo "- Prepared $DEST_REL from $SOURCE_REL"
echo "- camera-feature.xml SHA-256: $SHA256"
