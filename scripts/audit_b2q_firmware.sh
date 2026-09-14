#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/audit_b2q_firmware.sh <extracted-firmware-directory>

Audits an extracted SM-F711B Android 15 firmware before a first UN1CA build.
It does not modify the firmware. For the strongest check, make lpdump available
in PATH (UN1CA builds it through scripts/build_dependencies.sh).
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
FW="$(cd "$1" 2>/dev/null && pwd)" || { echo "Directory not found: $1" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$ROOT/target/b2q/config.sh"
# shellcheck disable=SC1090
source "$ROOT/platform/sm8350/config.sh"
# shellcheck disable=SC1090
source "$ROOT/target/b2q/config.sh"

ERRORS=0
WARNINGS=0
ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }

find_one() {
    local name="$1"
    find "$FW" -type f \( -name "$name" -o -name "${name}.lz4" \) -print -quit 2>/dev/null
}

check_prop() {
    local regex="$1" label="$2"
    if grep -RIEq --include='*build.prop' --include='default.prop' "$regex" "$FW" 2>/dev/null; then
        ok "$label"
    else
        warn "$label not found in extracted properties"
    fi
}

check_padded_image() {
    local image_name="$1" expected="$2" file size
    file="$(find_one "$image_name")"
    if [[ -z "$file" ]]; then
        warn "$image_name not found"
        return
    fi
    if [[ "$file" == *.lz4 ]]; then
        warn "$image_name is still LZ4-compressed; extract it before comparing partition size"
        return
    fi
    size="$(stat -c '%s' "$file")"
    if [[ "$size" -eq "$expected" ]]; then
        ok "$image_name size=$size"
    elif [[ "$size" -lt "$expected" ]]; then
        warn "$image_name size=$size, configured partition=$expected (image may be unpadded)"
    else
        fail "$image_name size=$size exceeds configured partition=$expected"
    fi
}

check_prop 'ro\.product\.vendor\.device=b2q([[:space:]]|$)' 'vendor codename b2q'
check_prop 'ro\.product\.first_api_level=30([[:space:]]|$)' 'first API level 30'
check_prop 'ro\.build\.version\.sdk=35([[:space:]]|$)' 'Android 15 / SDK 35'
check_prop 'ro\.board\.api_level=30([[:space:]]|$)' 'board API level 30'

check_padded_image boot.img "$TARGET_BOOT_PARTITION_SIZE"
check_padded_image vendor_boot.img "$TARGET_VENDOR_BOOT_PARTITION_SIZE"
check_padded_image dtbo.img "$TARGET_DTBO_PARTITION_SIZE"

SUPER="$(find_one super.img)"
[[ -z "$SUPER" ]] && SUPER="$(find_one super_empty.img)"
if [[ -z "$SUPER" ]]; then
    # extract_fw normally removes/consumes super.img after lpunpack. Treat the
    # already-unpacked logical partition trees as a successful extraction,
    # while keeping lpdump/PIT verification as a separate first-flash gate.
    LOGICAL_FOUND=0
    for part in system vendor product odm; do
        if [[ -d "$FW/$part" ]] \
            || find "$FW" -maxdepth 2 -type d -name "$part" -print -quit 2>/dev/null | grep -q . \
            || find "$FW" -maxdepth 2 -type f -name "${part}.img" -print -quit 2>/dev/null | grep -q .; then
            LOGICAL_FOUND=$((LOGICAL_FOUND + 1))
        fi
    done
    if (( LOGICAL_FOUND == 4 )); then
        ok "super image already unpacked; system/vendor/product/odm found"
    else
        warn "super.img/super_empty.img not found and only $LOGICAL_FOUND/4 logical partitions were detected"
    fi
elif [[ "$SUPER" == *.lz4 ]]; then
    warn "super image is still LZ4-compressed"
elif command -v lpdump >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    RAW="$SUPER"
    if file "$SUPER" | grep -qi 'Android sparse image'; then
        if command -v simg2img >/dev/null 2>&1; then
            RAW="$TMP/super.raw.img"
            simg2img "$SUPER" "$RAW"
        else
            warn "sparse super image found but simg2img is unavailable"
            RAW=""
        fi
    fi
    if [[ -n "$RAW" ]] && lpdump "$RAW" > "$TMP/lpdump.txt" 2>&1; then
        grep -q 'samsung_dynamic_partitions' "$TMP/lpdump.txt" && ok 'lpdump group samsung_dynamic_partitions' || fail 'lpdump group mismatch'
        grep -q '9122611200' "$TMP/lpdump.txt" && ok 'lpdump group size 9122611200' || warn 'configured group size not printed by lpdump; inspect output manually'
        grep -q '9126805504' "$TMP/lpdump.txt" && ok 'lpdump super size 9126805504' || warn 'configured super size not printed by lpdump; inspect block-device/PIT size'
        for part in system vendor product odm; do
            grep -Eq "Name:[[:space:]]*${part}([[:space:]]|$)|Partition name:[[:space:]]*${part}([[:space:]]|$)" "$TMP/lpdump.txt" \
                && ok "lpdump partition $part" || warn "lpdump did not expose partition $part in expected format"
        done
    else
        warn "lpdump could not parse the selected super image"
    fi
else
    warn "lpdump unavailable; dynamic-partition metadata was not audited"
fi

if find "$FW" -type f -name 'fstab*' -print0 2>/dev/null | xargs -0 -r grep -Elq '(^|[[:space:]])(system|vendor|product|odm)([[:space:]]|$)'; then
    ok 'stock fstab files found'
else
    warn 'stock fstab files were not found in extracted firmware'
fi

printf '\nAudit result: %d error(s), %d warning(s).\n' "$ERRORS" "$WARNINGS"
(( ERRORS == 0 ))
