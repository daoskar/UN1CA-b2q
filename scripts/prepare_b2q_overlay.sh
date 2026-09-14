#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generate UN1CA's flat target overlay from the already extracted stock
# SM-F711B product RRO. Current UN1CA expects XML files directly under
# target/<codename>/overlay (for example overlay/dimens.xml), not a decoded
# Android res/values directory tree.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_FW_DIR="${1:-}"
DEST="$ROOT/target/b2q/overlay"
POWER_DIMEN="physical_power_button_center_screen_location_y"

if [[ -z "$TARGET_FW_DIR" || ! -d "$TARGET_FW_DIR" ]]; then
    echo "Usage: scripts/prepare_b2q_overlay.sh <extracted-target-firmware-directory>" >&2
    exit 2
fi

find_apktool() {
    local candidate
    for candidate in \
        "$ROOT/out/tools/bin/apktool" \
        "$ROOT/out/tools/apktool/apktool"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if command -v apktool >/dev/null 2>&1; then
        command -v apktool
        return 0
    fi
    return 1
}

APKTOOL="$(find_apktool || true)"
if [[ -z "$APKTOOL" ]]; then
    echo "apktool not found. Run scripts/build_dependencies.sh first." >&2
    exit 1
fi

PRODUCT_OVERLAY_DIR=""
for candidate in \
    "$TARGET_FW_DIR/product/overlay" \
    "$TARGET_FW_DIR/system/product/overlay" \
    "$TARGET_FW_DIR/system/system/product/overlay"; do
    if [[ -d "$candidate" ]]; then
        PRODUCT_OVERLAY_DIR="$candidate"
        break
    fi
done
if [[ -z "$PRODUCT_OVERLAY_DIR" ]]; then
    PRODUCT_OVERLAY_DIR="$(find "$TARGET_FW_DIR" -type d -path '*/product/overlay' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$PRODUCT_OVERLAY_DIR" ]]; then
    echo "Target product/overlay directory not found under: $TARGET_FW_DIR" >&2
    exit 1
fi

RRO_APK="$(find "$PRODUCT_OVERLAY_DIR" -maxdepth 2 -type f \
    -iname 'framework-res__b2qxxx__auto_generated_rro_product.apk' -print -quit 2>/dev/null || true)"
if [[ -z "$RRO_APK" ]]; then
    RRO_APK="$(find "$PRODUCT_OVERLAY_DIR" -maxdepth 2 -type f \
        -iname 'framework-res__*b2q*__auto_generated_rro_product.apk' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$RRO_APK" ]]; then
    RRO_APK="$(find "$PRODUCT_OVERLAY_DIR" -maxdepth 2 -type f \
        -iname 'framework-res__*__auto_generated_rro_product.apk' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$RRO_APK" || ! -f "$RRO_APK" ]]; then
    echo "Stock framework-res product RRO was not found in: $PRODUCT_OVERLAY_DIR" >&2
    find "$PRODUCT_OVERLAY_DIR" -maxdepth 2 -type f -iname 'framework-res*.apk' -printf '  %p\n' 2>/dev/null | head -n 50 >&2 || true
    exit 1
fi

FRAMEWORK_APK=""
for candidate in \
    "$TARGET_FW_DIR/system/framework/framework-res.apk" \
    "$TARGET_FW_DIR/system/system/framework/framework-res.apk"; do
    if [[ -f "$candidate" ]]; then
        FRAMEWORK_APK="$candidate"
        break
    fi
done
if [[ -z "$FRAMEWORK_APK" ]]; then
    FRAMEWORK_APK="$(find "$TARGET_FW_DIR" -type f -path '*/framework/framework-res.apk' -print -quit 2>/dev/null || true)"
fi

nonzero_power_resource_exists() {
    local tree="$1"
    [[ -f "$tree/dimens.xml" ]] || return 1
    python3 - "$tree/dimens.xml" "$POWER_DIMEN" <<'PY_CHECK'
import re
import sys
import xml.etree.ElementTree as ET

path, name = sys.argv[1], sys.argv[2]
try:
    root = ET.parse(path).getroot()
except (ET.ParseError, OSError):
    raise SystemExit(1)
for node in root:
    if node.tag != "dimen" or node.attrib.get("name") != name:
        continue
    value = "".join(node.itertext()).strip()
    match = re.fullmatch(r"(-?\d+(?:\.\d+)?)(?:px|dp|dip|sp|pt|in|mm)?", value)
    if match and float(match.group(1)) != 0.0:
        raise SystemExit(0)
raise SystemExit(1)
PY_CHECK
}

RRO_SHA="$(sha256sum "$RRO_APK" | awk '{print $1}')"
MARKER="$DEST/.source-rro.sha256"
if [[ -f "$MARKER" ]] \
    && [[ "$(cat "$MARKER" 2>/dev/null || true)" == "$RRO_SHA" ]] \
    && [[ "$(cat "$DEST/.layout-version" 2>/dev/null || true)" == "flat-values-v4-integer-px" ]] \
    && [[ -f "$DEST/.power-button-geometry" ]] \
    && find "$DEST" -maxdepth 1 -type f -name '*.xml' -print -quit | grep -q .; then
    echo "- b2q flat product overlay is already prepared from $(basename "$RRO_APK")"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/un1ca-b2q-overlay.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/framework" "$TMP/decoded"

if [[ -n "$FRAMEWORK_APK" ]]; then
    "$APKTOOL" if -p "$TMP/framework" "$FRAMEWORK_APK" >/dev/null
fi

if ! "$APKTOOL" d -f -s -p "$TMP/framework" -o "$TMP/decoded" "$RRO_APK"; then
    echo "Failed to decode stock target RRO: $RRO_APK" >&2
    exit 1
fi

VALUES_DIR="$TMP/decoded/res/values"
if [[ ! -d "$VALUES_DIR" ]]; then
    echo "Decoded target RRO does not contain an unqualified res/values directory: $RRO_APK" >&2
    exit 1
fi

mapfile -d '' VALUE_XMLS < <(find "$VALUES_DIR" -maxdepth 1 -type f -name '*.xml' -print0 | sort -z)
if ((${#VALUE_XMLS[@]} == 0)); then
    echo "Decoded target RRO contains no XML files in res/values: $RRO_APK" >&2
    exit 1
fi

STAGE="$ROOT/target/b2q/.overlay.new.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
for xml in "${VALUE_XMLS[@]}"; do
    cp -a "$xml" "$STAGE/$(basename "$xml")"
done
printf '%s\n' "$RRO_SHA" > "$STAGE/.source-rro.sha256"
printf '%s\n' "${RRO_APK#"$ROOT/"}" > "$STAGE/.source-rro.path"
printf '%s\n' 'flat-values-v4-integer-px' > "$STAGE/.layout-version"

# Return VALUE<TAB>SOURCE_XML from a decoded resource tree. Prefer the
# unqualified values/dimens.xml, resolving simple @dimen aliases.
read_power_dimen_from_tree() {
    local tree="$1"
    python3 - "$tree" "$POWER_DIMEN" <<'PY'
from __future__ import annotations
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

tree = Path(sys.argv[1])
name = sys.argv[2]
files = sorted(
    tree.glob("res/values*/dimens.xml"),
    key=lambda p: (0 if p.parent.name == "values" else 1, len(str(p)), str(p)),
)
values: dict[str, tuple[str, Path]] = {}
for path in files:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        continue
    for node in root:
        if node.tag == "dimen" and node.attrib.get("name"):
            text = "".join(node.itertext()).strip()
            if text:
                values.setdefault(node.attrib["name"], (text, path))

seen: set[str] = set()
current = name
for _ in range(12):
    if current in seen or current not in values:
        break
    seen.add(current)
    value, source = values[current]
    if value.startswith("@dimen/"):
        current = value.split("/", 1)[1]
        continue
    if value.startswith("@*android:dimen/") or value.startswith("@android:dimen/"):
        break
    match = __import__("re").fullmatch(r"(-?\d+(?:\.\d+)?)(?:px|dp|dip|sp|pt|in|mm)?", value)
    if match and float(match.group(1)) != 0.0:
        print(f"{value}\t{source}")
        raise SystemExit(0)
    break
raise SystemExit(1)
PY
}

apk_declares_resource() {
    local apk="$1"
    (set +o pipefail; unzip -p "$apk" resources.arsc 2>/dev/null | grep -aFq "$POWER_DIMEN")
}

merge_power_dimen() {
    local value="$1" source="$2" dest_file="$STAGE/dimens.xml"
    python3 - "$dest_file" "$POWER_DIMEN" "$value" "$source" <<'PY'
from __future__ import annotations
import html
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
value = sys.argv[3].strip()
source = sys.argv[4]
match = re.fullmatch(r"(-?\d+(?:\.\d+)?)(px|dp|dip|sp|pt|in|mm)?", value)
if not match:
    raise SystemExit(f"Unsupported value for {name}: {value!r}")
number = float(match.group(1))
unit = match.group(2) or ""
# UN1CA's current RRO guard expects the physical-button location in the same
# canonical integer-pixel form used by its maintained targets. Apktool emits
# stock Samsung integer dimensions as e.g. 620.0px, so normalize only exact
# integral px values without changing the measured coordinate.
if unit == "px" and number.is_integer():
    value = f"{int(number)}px"

if path.exists():
    text = path.read_text(encoding="utf-8")
else:
    text = '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n'

pattern = re.compile(
    rf'(<dimen\s+[^>]*name=["\']{re.escape(name)}["\'][^>]*>)(.*?)(</dimen>)',
    re.DOTALL,
)
if pattern.search(text):
    text = pattern.sub(lambda m: m.group(1) + html.escape(value) + m.group(3), text, count=1)
    path.write_text(text, encoding="utf-8")
    ET.parse(path)
    raise SystemExit(0)
entry = (
    f'    <!-- Copied from stock SM-F711B resource: {html.escape(source)} -->\n'
    f'    <dimen name="{name}">{html.escape(value)}</dimen>\n'
)
if "</resources>" not in text:
    raise SystemExit(f"Invalid resources XML without </resources>: {path}")
text = text.replace("</resources>", entry + "</resources>", 1)
path.write_text(text, encoding="utf-8")
ET.parse(path)
PY
    printf 'value=%s\nsource=%s\n' "$value" "$source" > "$STAGE/.source-power-button-dimen"
}

if ! nonzero_power_resource_exists "$STAGE"; then
    echo "- Stock b2q product RRO does not contain $POWER_DIMEN"
    echo "- Searching stock SM-F711B SystemUI/framework resources..."
    FOUND=""

    while IFS= read -r -d '' xml; do
        if grep -qsE "<dimen[[:space:]][^>]*name=[\"']${POWER_DIMEN}[\"']" "$xml"; then
            loose_root="$TMP/loose.$RANDOM"
            mkdir -p "$loose_root/res/values"
            cp "$xml" "$loose_root/res/values/dimens.xml"
            if raw_found="$(read_power_dimen_from_tree "$loose_root" 2>/dev/null)"; then
                IFS=$'\t' read -r found_value _found_xml <<< "$raw_found"
                FOUND="${found_value}"$'\t'"${xml#"$TARGET_FW_DIR/"}"
                break
            fi
        fi
    done < <(find "$TARGET_FW_DIR" -type f -path '*/res/values*/dimens.xml' -print0 2>/dev/null)

    if [[ -z "$FOUND" ]]; then
        mapfile -d '' APK_CANDIDATES < <(
            find "$TARGET_FW_DIR" -type f \( \
                -path '*/overlay/*.apk' -o \
                -name 'SystemUI.apk' -o \
                -name 'framework-res.apk' \
            \) -print0 2>/dev/null
        )
        index=0
        for apk in "${APK_CANDIDATES[@]}"; do
            apk_declares_resource "$apk" || continue
            index=$((index + 1))
            decoded="$TMP/power-dimen-$index"
            echo "  candidate: ${apk#"$TARGET_FW_DIR/"}"
            if ! "$APKTOOL" d -f -s -p "$TMP/framework" -o "$decoded" "$apk" >/dev/null 2>&1; then
                echo "    warning: apktool could not decode this candidate" >&2
                continue
            fi
            if raw_found="$(read_power_dimen_from_tree "$decoded" 2>/dev/null)"; then
                IFS=$'\t' read -r found_value found_xml <<< "$raw_found"
                FOUND="${found_value}"$'\t'"${apk#"$TARGET_FW_DIR/"}!/${found_xml#"$decoded/"}"
                break
            fi
        done
    fi

    if [[ -z "$FOUND" ]]; then
        echo "- No non-zero $POWER_DIMEN exists in stock SM-F711B resources"
        echo "  AOD clock transition will be disabled by the stock-derived b2q AOD policy."
        python3 - "$STAGE/dimens.xml" "$POWER_DIMEN" <<'PY_REMOVE'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
path = Path(sys.argv[1])
name = sys.argv[2]
if not path.exists():
    path.write_text('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n', encoding='utf-8')
root = ET.parse(path).getroot()
for node in list(root):
    if node.tag == 'dimen' and node.attrib.get('name') == name:
        root.remove(node)
ET.indent(root, space='    ')
ET.ElementTree(root).write(path, encoding='utf-8', xml_declaration=True)
PY_REMOVE
        printf '%s\n' 'missing' > "$STAGE/.power-button-geometry"
        printf 'value=unavailable\nsource=stock-sm-f711b-search\n' > "$STAGE/.source-power-button-dimen"
    else
        IFS=$'\t' read -r POWER_VALUE POWER_SOURCE <<< "$FOUND"
        merge_power_dimen "$POWER_VALUE" "$POWER_SOURCE"
        printf '%s\n' 'confirmed' > "$STAGE/.power-button-geometry"
        CANONICAL_POWER_VALUE="$(python3 - "$STAGE/dimens.xml" "$POWER_DIMEN" <<'PY_VALUE'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root:
    if node.tag == "dimen" and node.attrib.get("name") == sys.argv[2]:
        print("".join(node.itertext()).strip())
        break
PY_VALUE
)"
        echo "- Added $POWER_DIMEN=$CANONICAL_POWER_VALUE to flat overlay/dimens.xml"
        echo "  stock value: $POWER_VALUE"
        echo "  source: $POWER_SOURCE"
    fi
else
    printf '%s\n' 'confirmed' > "$STAGE/.power-button-geometry"
fi

# Parse every generated XML now, before UN1CA reaches its RRO module.
python3 - "$STAGE" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root = Path(sys.argv[1])
files = sorted(root.glob("*.xml"))
if not files:
    raise SystemExit("No flat overlay XML files were generated")
for path in files:
    ET.parse(path)
PY

rro_guard_compatible_power_resource_exists() {
    local file="$1/dimens.xml"
    [[ -f "$file" ]] || return 1
    grep -Eq '<dimen[[:space:]]+name="physical_power_button_center_screen_location_y">[1-9][0-9]*px</dimen>' "$file"
}

GEOMETRY_STATUS="$(cat "$STAGE/.power-button-geometry" 2>/dev/null || true)"
if [[ "$GEOMETRY_STATUS" == "confirmed" ]] && ! nonzero_power_resource_exists "$STAGE"; then
    echo "Power-button geometry is marked confirmed but overlay/dimens.xml has no non-zero value" >&2
    rm -rf "$STAGE"
    exit 1
fi
if [[ "$GEOMETRY_STATUS" == "confirmed" ]] && ! rro_guard_compatible_power_resource_exists "$STAGE"; then
    echo "Power-button geometry is not in UN1CA-compatible integer-pixel form" >&2
    sed -n '/physical_power_button_center_screen_location_y/p' "$STAGE/dimens.xml" >&2 || true
    rm -rf "$STAGE"
    exit 1
fi
if [[ "$GEOMETRY_STATUS" != "confirmed" && "$GEOMETRY_STATUS" != "missing" ]]; then
    echo "Invalid generated power-button geometry status: $GEOMETRY_STATUS" >&2
    rm -rf "$STAGE"
    exit 1
fi

# Remove the obsolete 1.8.4/1.8.5 decoded-tree layout. Current UN1CA reads
# target/<codename>/overlay/*.xml directly and checks overlay/dimens.xml.
rm -rf "$DEST"
mv "$STAGE" "$DEST"

if [[ -d "$DEST/res" ]]; then
    echo "Unexpected legacy nested res directory remained in $DEST" >&2
    exit 1
fi
if [[ ! -f "$DEST/dimens.xml" ]]; then
    echo "UN1CA-compatible flat overlay/dimens.xml was not generated" >&2
    exit 1
fi

XML_COUNT="$(find "$DEST" -maxdepth 1 -type f -name '*.xml' | wc -l)"
echo "- Prepared flat target/b2q/overlay for current UN1CA RRO module"
echo "  base source: ${RRO_APK#"$ROOT/"}"
echo "  flat resources: $XML_COUNT XML file(s)"
echo "  required file: target/b2q/overlay/dimens.xml"
echo "  power-button geometry: $GEOMETRY_STATUS"
echo "  sha256: $RRO_SHA"
