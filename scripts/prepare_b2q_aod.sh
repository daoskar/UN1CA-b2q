#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Validate the b2q AOD compatibility policy before make_rom. The actual change
# is applied by target/b2q/patches/aod_clock_transition/customize.sh directly
# to the active work tree, which is the input inspected by UN1CA's RRO guard.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_FW_DIR="${1:-}"
MODE="${2:-apply}"
OVERLAY_DIR="$ROOT/target/b2q/overlay"
MODULE_DIR="$ROOT/target/b2q/patches/aod_clock_transition"
MODULE_SCRIPT="$MODULE_DIR/customize.sh"
MODULE_PROP="$MODULE_DIR/module.prop"

usage() {
    echo "Usage: scripts/prepare_b2q_aod.sh <extracted-target-firmware-directory> [apply|restore|status]" >&2
}

if [[ -z "$TARGET_FW_DIR" || ! -d "$TARGET_FW_DIR" ]]; then
    usage
    exit 2
fi
case "$MODE" in
    apply|restore|status) ;;
    *) usage; exit 2 ;;
esac

if [[ ! -f "$MODULE_SCRIPT" || ! -f "$MODULE_PROP" ]]; then
    echo "Missing b2q active-work-tree AOD patch module: $MODULE_DIR" >&2
    exit 1
fi
bash -n "$MODULE_SCRIPT"
if ! grep -q 'SEC_FLOATING_FEATURE_FRAMEWORK_CONFIG_AOD_ITEM' "$MODULE_SCRIPT"; then
    echo "b2q AOD module does not inspect the Samsung AOD item tag" >&2
    exit 1
fi
if ! grep -Eq 'WORK_DIR/.*/floating_feature\.xml|WORK_DIR.*floating_feature\.xml' "$MODULE_SCRIPT"; then
    echo "b2q AOD module does not patch the active UN1CA work tree" >&2
    exit 1
fi

GEOMETRY_STATUS="missing"
if [[ -f "$OVERLAY_DIR/.power-button-geometry" ]]; then
    GEOMETRY_STATUS="$(tr -d '\r\n' < "$OVERLAY_DIR/.power-button-geometry")"
fi
if [[ "$GEOMETRY_STATUS" != "confirmed" && "$GEOMETRY_STATUS" != "missing" ]]; then
    echo "Invalid b2q power-button geometry status: $GEOMETRY_STATUS" >&2
    exit 1
fi

case "$MODE" in
    apply)
        echo "- Prepared b2q AOD compatibility policy"
        echo "  geometry: $GEOMETRY_STATUS"
        echo "  execution: active workdir target patch before common RRO module"
        echo "  policy: remove only clock-transition capability; preserve AOD"
        ;;
    restore)
        # No stock/extracted input is modified in 1.8.9, so there is nothing to restore.
        ;;
    status)
        printf 'geometry=%s\n' "$GEOMETRY_STATUS"
        printf 'mode=active-workdir-target-module\n'
        printf 'state=ready\n'
        ;;
esac
