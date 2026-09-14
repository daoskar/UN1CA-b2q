#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW_DIR="${1:-}"
SIOP_POLICY="${2:-siop_b2q_sm8350}"
DVFS_POLICY="${3:-dvfs_policy_sm8350_xx}"
CUSTOMIZE="$ROOT/unica/patches/dvfs/customize.sh"
DEST_DIR="$ROOT/target/b2q/dvfs"

usage() {
    echo "Usage: scripts/prepare_b2q_dvfs.sh <extracted-target-firmware-directory> [siop-policy-name] [dvfs-policy-name]" >&2
}

[[ -n "$FW_DIR" ]] || { usage; exit 2; }
FW_DIR="$(cd "$FW_DIR" 2>/dev/null && pwd)" || {
    echo "Extracted target firmware directory not found: $1" >&2
    exit 2
}

mkdir -p "$DEST_DIR"

validate_siop_xml() {
    local file=$1
    python3 - "$file" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

p = Path(sys.argv[1])
data = p.read_bytes()
if len(data) < 128:
    raise SystemExit(f"SIOP XML is unexpectedly small: {p}")
try:
    root = ET.fromstring(data)
except ET.ParseError as exc:
    raise SystemExit(f"Invalid SIOP XML {p}: {exc}")

root_name = root.tag.rsplit('}', 1)[-1].lower()
text = data.lower()
if root_name != "siop_document" and b"modelsettings" not in text:
    raise SystemExit(f"File does not look like a Samsung SIOP model document: {p}")
PY
}

choose_exact_file() {
    local name=$1 candidate
    local preferred=(
        "$FW_DIR/system/system/etc/$name"
        "$FW_DIR/system/etc/$name"
        "$FW_DIR/system/system/etc/dvfs/$name"
        "$FW_DIR/system/etc/dvfs/$name"
        "$FW_DIR/system/system/etc/siop/$name"
        "$FW_DIR/system/etc/siop/$name"
        "$FW_DIR/product/etc/$name"
        "$FW_DIR/product/etc/dvfs/$name"
        "$FW_DIR/vendor/etc/$name"
        "$FW_DIR/vendor/etc/dvfs/$name"
        "$FW_DIR/odm/etc/$name"
        "$FW_DIR/odm/etc/dvfs/$name"
    )

    for candidate in "${preferred[@]}"; do
        [[ -s "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done

    find "$FW_DIR" -type f -name "$name" -size +0c -print 2>/dev/null \
        | LC_ALL=C sort | head -n1
}

find_sdhms_apks() {
    find "$FW_DIR" -type f \
        \( -iname 'SamsungDeviceHealthManagerService.apk' \
        -o -iname '*Samsung*Device*Health*Manager*.apk' \
        -o -iname '*DeviceHealthManager*.apk' \
        -o -iname '*SDHMS*.apk' \) \
        -size +0c -print 2>/dev/null | LC_ALL=C sort
}

extract_plain_xml_from_apk() {
    local apk=$1 out=$2
    python3 - "$apk" "$out" "$SIOP_POLICY" "$DVFS_POLICY" <<'PY'
from pathlib import Path, PurePosixPath
import sys
import zipfile
import xml.etree.ElementTree as ET

apk = Path(sys.argv[1])
out = Path(sys.argv[2])
siop = sys.argv[3].lower() + ".xml"
dvfs = sys.argv[4].lower() + ".xml"

def valid(data: bytes) -> bool:
    if len(data) < 128 or b"<" not in data or b">" not in data:
        return False
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return False
    name = root.tag.rsplit("}", 1)[-1].lower()
    low = data.lower()
    return name == "siop_document" or b"modelsettings" in low

with zipfile.ZipFile(apk) as zf:
    candidates = []
    for name in zf.namelist():
        base = PurePosixPath(name).name.lower()
        if not base.endswith(".xml"):
            continue
        if base == "siop_model.xml":
            tier = 0
        elif base == siop:
            tier = 1
        elif base == dvfs:
            tier = 2
        elif "siop" in base:
            tier = 3
        elif "dvfs" in base:
            tier = 4
        elif "model" in base:
            tier = 5
        else:
            # Some Samsung builds use an obfuscated/generic resource name.
            # Keep it as a low-priority candidate and accept it only when the
            # decoded root is a real siop_document/modelsettings document.
            tier = 6
        candidates.append((tier, len(PurePosixPath(name).parts), name))

    for _, _, name in sorted(candidates):
        try:
            data = zf.read(name)
        except (KeyError, OSError):
            continue
        if valid(data):
            out.write_bytes(data)
            print(name)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

find_decoded_siop_xml() {
    local decoded=$1
    python3 - "$decoded" "$SIOP_POLICY" "$DVFS_POLICY" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
siop = sys.argv[2].lower() + ".xml"
dvfs = sys.argv[3].lower() + ".xml"

def valid(p: Path) -> bool:
    try:
        data = p.read_bytes()
        if len(data) < 128:
            return False
        node = ET.fromstring(data)
    except (OSError, ET.ParseError):
        return False
    name = node.tag.rsplit("}", 1)[-1].lower()
    return name == "siop_document" or b"modelsettings" in data.lower()

def rank(p: Path):
    base = p.name.lower()
    if base == "siop_model.xml": tier = 0
    elif base == siop: tier = 1
    elif base == dvfs: tier = 2
    elif "siop" in base: tier = 3
    elif "dvfs" in base: tier = 4
    elif "model" in base: tier = 5
    else: tier = 9
    s = p.as_posix().lower()
    location = 0 if "/assets/" in s else 1 if "/res/raw" in s else 2
    return (tier, location, len(p.parts), s)

items = [p for p in root.rglob("*.xml") if valid(p)]
if not items:
    raise SystemExit(1)
print(min(items, key=rank))
PY
}

prepare_siop_model() {
    local dest="$DEST_DIR/siop_model.xml"
    local direct apk entry tmp decoded apktool_bin source_desc decoded_candidate

    direct="$(choose_exact_file siop_model.xml || true)"
    if [[ -n "$direct" ]]; then
        validate_siop_xml "$direct"
        cp -f "$direct" "$dest.tmp.$$"
        source_desc="${direct#"$ROOT/"}"
    else
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/b2q-dvfs.XXXXXX")"
        while IFS= read -r apk; do
            [[ -n "$apk" ]] || continue
            entry="$(extract_plain_xml_from_apk "$apk" "$tmp/siop_model.xml" 2>/dev/null || true)"
            if [[ -n "$entry" && -s "$tmp/siop_model.xml" ]]; then
                validate_siop_xml "$tmp/siop_model.xml"
                cp -f "$tmp/siop_model.xml" "$dest.tmp.$$"
                source_desc="${apk#"$ROOT/"}!/$entry"
                break
            fi
        done < <(find_sdhms_apks)

        if [[ ! -s "$dest.tmp.$$" ]]; then
            apktool_bin="$(command -v apktool 2>/dev/null || true)"
            [[ -n "$apktool_bin" ]] || apktool_bin="$ROOT/out/tools/bin/apktool"
            if [[ -x "$apktool_bin" ]]; then
                while IFS= read -r apk; do
                    [[ -n "$apk" ]] || continue
                    rm -rf "$tmp/decoded"
                    if "$apktool_bin" d -f -s -o "$tmp/decoded" "$apk" >/dev/null 2>&1; then
                        decoded_candidate="$(find_decoded_siop_xml "$tmp/decoded" 2>/dev/null || true)"
                        if [[ -n "$decoded_candidate" ]]; then
                            validate_siop_xml "$decoded_candidate"
                            cp -f "$decoded_candidate" "$dest.tmp.$$"
                            source_desc="${apk#"$ROOT/"}!/${decoded_candidate#"$tmp/decoded/"} (apktool)"
                            break
                        fi
                    fi
                done < <(find_sdhms_apks)
            fi
        fi

        if [[ ! -s "$dest.tmp.$$" ]]; then
            echo "Could not extract the SM-F711B SIOP model from SamsungDeviceHealthManagerService.apk." >&2
            echo "Searched target firmware: ${FW_DIR#"$ROOT/"}" >&2
            echo "Detected SDHMS APK candidates:" >&2
            find_sdhms_apks | sed "s#^$ROOT/#  #" >&2 || true
            echo "Archive entries mentioning SIOP/DVFS/model:" >&2
            while IFS= read -r apk; do
                [[ -n "$apk" ]] || continue
                echo "  ${apk#"$ROOT/"}:" >&2
                unzip -Z1 "$apk" 2>/dev/null \
                    | grep -Ei '(^|/)[^/]*(siop|dvfs|model)[^/]*\.xml$' \
                    | head -n 80 | sed 's/^/    /' >&2 || true
            done < <(find_sdhms_apks)
            rm -rf "$tmp"
            return 1
        fi

        rm -rf "$tmp"
    fi

    chmod 0644 "$dest.tmp.$$"
    mv -f "$dest.tmp.$$" "$dest"
    local sha256
    sha256="$(sha256sum "$dest" | awk '{print $1}')"
    echo "- Prepared target/b2q/dvfs/siop_model.xml from $source_desc"
    echo "- siop_model.xml SHA-256: $sha256"
}

# The current upstream DVFS module aborts when this generic target-side model
# file is absent. It then installs/renames the document according to the target
# SIOP policy configured in target/b2q/config.sh. The stock file is embedded in
# SamsungDeviceHealthManagerService.apk, not normally exposed as system/etc XML.
prepare_siop_model
