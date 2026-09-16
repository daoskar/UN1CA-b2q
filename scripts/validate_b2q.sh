#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/target/b2q/config.sh"
PLATFORM="$ROOT/platform/sm8350/config.sh"
FSTAB="$ROOT/platform/sm8350/installer/recovery.fstab"
ASSERTIONS="$ROOT/target/b2q/installer/assertions.edify"
CAMERA_PREP="$ROOT/scripts/prepare_b2q_camera.sh"
DVFS_PREP="$ROOT/scripts/prepare_b2q_dvfs.sh"
OVERLAY_PREP="$ROOT/scripts/prepare_b2q_overlay.sh"
VINTF_PREP="$ROOT/scripts/prepare_b2q_vintf.sh"
FOLD_COVER_PREP="$ROOT/scripts/prepare_b2q_fold_cover.sh"
AOD_PREP="$ROOT/scripts/prepare_b2q_aod.sh"
AOD_MODULE="$ROOT/target/b2q/patches/aod_clock_transition/customize.sh"
AOD_MODULE_PROP="$ROOT/target/b2q/patches/aod_clock_transition/module.prop"
CAMERA_GUARD="$ROOT/target/b2q/patches/camera_quick_setting_guard/customize.sh"
CAMERA_GUARD_PROP="$ROOT/target/b2q/patches/camera_quick_setting_guard/module.prop"
FOLD_COVER_MODULE="$ROOT/target/b2q/patches/fold_cover_stock/customize.sh"
FOLD_COVER_MODULE_PROP="$ROOT/target/b2q/patches/fold_cover_stock/module.prop"
BUILD_WRAPPER="$ROOT/scripts/build_b2q.sh"
ERRORS=0
WARNINGS=0

ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }

require_file() {
    local file="$1" rel
    rel="${file#"$ROOT"/}"
    if [[ -f "$file" ]]; then
        ok "present: $rel"
    else
        fail "missing: $rel"
    fi
}
require_eq() {
    local name="$1" expected="$2" actual="${!1-}"
    if [[ "$actual" == "$expected" ]]; then
        ok "$name=$actual"
    else
        fail "$name='$actual' (expected '$expected')"
    fi
}
require_bool() {
    local name="$1" actual="${!1-}"
    if [[ "$actual" == true || "$actual" == false ]]; then
        ok "$name=$actual"
    else
        fail "$name must be true or false (got '$actual')"
    fi
}
require_positive_int() {
    local name="$1" actual="${!1-}"
    if [[ "$actual" =~ ^[0-9]+$ && "$actual" -gt 0 ]]; then
        ok "$name=$actual"
    else
        fail "$name must be a positive integer (got '$actual')"
    fi
}
require_grep() {
    local pattern="$1" file="$2" label="$3"
    if grep -Eq "$pattern" "$file"; then
        ok "$label"
    else
        fail "$label"
    fi
}
check_bash_syntax() {
    local file="$1" label="$2"
    if bash -n "$file"; then
        ok "$label"
    else
        fail "$label"
    fi
}

for file in "$TARGET" "$PLATFORM" "$FSTAB" "$ASSERTIONS" "$CAMERA_PREP" "$DVFS_PREP" "$OVERLAY_PREP" "$VINTF_PREP" "$FOLD_COVER_PREP" "$AOD_PREP" "$AOD_MODULE" "$AOD_MODULE_PROP" "$CAMERA_GUARD" "$CAMERA_GUARD_PROP" "$FOLD_COVER_MODULE" "$FOLD_COVER_MODULE_PROP" "$BUILD_WRAPPER"; do require_file "$file"; done
for file in "$ROOT/scripts/b2q_fold_cover_audit.py" "$ROOT/scripts/refresh_b2q_target_files.sh" "$ROOT/scripts/collect_b2q_fold_logs.py" "$ROOT/scripts/test_b2q_fold_cover.py"; do
    require_file "$file"
done
check_bash_syntax "$ROOT/scripts/refresh_b2q_target_files.sh" "fresh target-files packaging syntax"
if (( ERRORS != 0 )); then
    exit 1
fi

check_bash_syntax "$TARGET" "target config syntax"
check_bash_syntax "$PLATFORM" "platform config syntax"
check_bash_syntax "$CAMERA_PREP" "camera preparation syntax"
check_bash_syntax "$DVFS_PREP" "DVFS preparation syntax"
check_bash_syntax "$OVERLAY_PREP" "RRO preparation syntax"
check_bash_syntax "$VINTF_PREP" "VINTF preparation syntax"
check_bash_syntax "$FOLD_COVER_PREP" "fold/cover stock preparation syntax"
check_bash_syntax "$AOD_PREP" "AOD preparation syntax"
check_bash_syntax "$AOD_MODULE" "AOD workdir module syntax"
check_bash_syntax "$CAMERA_GUARD" "Samsung Camera guard module syntax"
check_bash_syntax "$FOLD_COVER_MODULE" "fold/cover stock module syntax"
check_bash_syntax "$BUILD_WRAPPER" "build wrapper syntax"

# Match UN1CA's load order: target -> platform -> target.
# shellcheck disable=SC1090
source "$TARGET"
# shellcheck disable=SC1090
source "$PLATFORM"
# shellcheck disable=SC1090
source "$TARGET"

require_eq TARGET_NAME "Galaxy Z Flip3 5G"
require_eq TARGET_CODENAME "b2q"
require_eq TARGET_PLATFORM "sm8350"
require_eq TARGET_PLATFORM_SDK_VERSION "35"
require_eq TARGET_PRODUCT_SHIPPING_API_LEVEL "30"
require_eq TARGET_BOARD_API_LEVEL "30"
require_eq TARGET_OS_SINGLE_SYSTEM_IMAGE "qssi"
require_eq TARGET_SUPER_GROUP_NAME "samsung_dynamic_partitions"
require_eq TARGET_SUPER_PARTITION_SIZE "9126805504"
require_eq TARGET_SAMSUNG_DYNAMIC_PARTITIONS_SIZE "9122611200"
require_eq TARGET_BOOT_PARTITION_SIZE "100663296"
require_eq TARGET_DTBO_PARTITION_SIZE "25165824"
require_eq TARGET_VENDOR_BOOT_PARTITION_SIZE "100663296"
require_eq TARGET_FINGERPRINT_CONFIG_SENSOR "google_touch_side,settings=3,navi=1"

for v in \
    TARGET_USE_DYNAMIC_PARTITIONS TARGET_OS_BUILD_SYSTEM_EXT_PARTITION \
    TARGET_AUDIO_SUPPORT_ACH_RINGTONE TARGET_AUDIO_SUPPORT_DUAL_SPEAKER \
    TARGET_AUDIO_SUPPORT_VIRTUAL_VIBRATION_SOUND TARGET_CAMERA_SUPPORT_CAMERAX_EXTENSION \
    TARGET_COMMON_SUPPORT_EMBEDDED_SIM TARGET_LCD_SUPPORT_MDNIE_HW \
    TARGET_WLAN_SUPPORT_80211AX TARGET_WLAN_SUPPORT_80211AX_6GHZ; do
    require_bool "$v"
done

for v in TARGET_SUPER_PARTITION_SIZE TARGET_SAMSUNG_DYNAMIC_PARTITIONS_SIZE \
         TARGET_BOOT_PARTITION_SIZE TARGET_DTBO_PARTITION_SIZE \
         TARGET_VENDOR_BOOT_PARTITION_SIZE TARGET_CACHE_PARTITION_SIZE; do
    require_positive_int "$v"
    value="${!v}"
    if (( value % 4096 == 0 )); then
        ok "$v is 4 KiB aligned"
    else
        fail "$v is not 4 KiB aligned"
    fi
done

if (( TARGET_SUPER_PARTITION_SIZE > TARGET_SAMSUNG_DYNAMIC_PARTITIONS_SIZE )); then
    ok "super partition is larger than its group"
else
    fail "super partition must be larger than its group"
fi

GAP=$((TARGET_SUPER_PARTITION_SIZE - TARGET_SAMSUNG_DYNAMIC_PARTITIONS_SIZE))
if [[ "$GAP" -eq 4194304 ]]; then
    ok "dynamic metadata reserve is 4 MiB"
else
    warn "unexpected super/group gap: $GAP bytes"
fi

if [[ " ${TARGET_ASSERT_MODEL[*]} " == *" SM-F711B "* ]]; then
    ok "SM-F711B model assertion"
else
    fail "SM-F711B missing from TARGET_ASSERT_MODEL"
fi
if [[ "$TARGET_FIRMWARE" =~ ^SM-F711B/[A-Z0-9]{3,4}/([0-9]{15}|[A-Za-z0-9]{8,32})$ ]]; then
    ok "TARGET_FIRMWARE format"
else
    fail "invalid TARGET_FIRMWARE format"
fi
if [[ "$TARGET_FIRMWARE" == "SM-F711B/EUX/352493641234563" ]]; then
    warn "using placeholder FUS identity; set B2Q_TARGET_FIRMWARE to your own full IMEI/serial if download fails"
fi

for part in system vendor product odm; do
    require_grep "^${part}[[:space:]]+/${part}[[:space:]]+" "$FSTAB" "fstab logical partition: $part"
done
for part in boot recovery metadata userdata cache sec_efs carrier apnhlos modem dsp misc keydata keyrefuge dtbo prism optics vbmeta_system vendor_boot vbmeta_samsung imagefv; do
    require_grep "by-name/${part}([[:space:]]|$)|/by-name/${part}([[:space:]]|$)" "$FSTAB" "fstab physical partition: $part"
done
require_grep 'F711BXX' "$ASSERTIONS" "installer checks F711B bootloader"
require_grep 'F711BXXUCJYD9' "$ASSERTIONS" "installer enforces Android 15 baseline"
require_grep 'target/b2q/camera/camera-feature\.xml' "$CAMERA_PREP" "camera feature is generated from extracted F711B firmware"
require_grep 'target/b2q/dvfs' "$DVFS_PREP" "DVFS files are generated from extracted F711B firmware"
require_grep 'siop_model\.xml' "$DVFS_PREP" "DVFS helper includes siop_model.xml"
require_grep 'SamsungDeviceHealthManagerService\.apk' "$DVFS_PREP" "DVFS helper extracts the stock SDHMS APK model"
require_grep 'target/b2q/overlay' "$OVERLAY_PREP" "RRO resources are generated in the target overlay directory"
require_grep "DEST/dimens\\.xml|\\\$STAGE/dimens\\.xml" "$OVERLAY_PREP" "RRO helper writes UN1CA-compatible flat overlay/dimens.xml"
require_grep 'flat-values-v4-integer-px' "$OVERLAY_PREP" "RRO helper uses the integer-pixel flat overlay contract"
require_grep 'auto_generated_rro_product\.apk' "$OVERLAY_PREP" "RRO helper derives resources from stock target firmware"
require_grep 'physical_power_button_center_screen_location_y' "$OVERLAY_PREP" "RRO helper checks stock power-button geometry"
require_grep 'float\(match\.group\(1\)\) != 0\.0' "$OVERLAY_PREP" "RRO helper rejects zero/default power-button geometry"
require_grep '\.power-button-geometry' "$OVERLAY_PREP" "RRO helper records confirmed or missing geometry"
require_grep 'SystemUI\.apk' "$OVERLAY_PREP" "RRO helper can inspect stock SystemUI resources"
require_grep 'source-power-button-dimen' "$OVERLAY_PREP" "RRO helper records power-button dimension provenance"
require_grep 'number\.is_integer\(\)' "$OVERLAY_PREP" "RRO helper normalizes integral stock px values"
require_grep 'rro_guard_compatible_power_resource_exists' "$OVERLAY_PREP" "RRO helper validates upstream-compatible power-button syntax"
require_grep 'compatibility_matrix\.device\.xml' "$VINTF_PREP" "VINTF helper prepares the device framework matrix"
require_grep 'system/system/etc/vintf|system/etc/vintf' "$VINTF_PREP" "VINTF helper prioritizes the stock system matrix"
require_grep 'compatibility-matrix' "$VINTF_PREP" "VINTF helper validates the XML root"
require_grep 'TARGET_FIRMWARE_DIR.*prepare_b2q_vintf|prepare_b2q_vintf.*TARGET_FIRMWARE_DIR' "$BUILD_WRAPPER" "build wrapper prepares VINTF before make_rom"
require_grep 'etc/devicestate' "$FOLD_COVER_PREP" "fold/cover helper stages stock device-state XML"
require_grep 'etc/displayconfig' "$FOLD_COVER_PREP" "fold/cover helper stages stock display config"
require_grep 'hinge_angle' "$FOLD_COVER_PREP" "fold/cover helper preserves hinge-angle feature declaration"
require_grep 'ControlPanel\.apk|controlpanel' "$FOLD_COVER_PREP" "fold/cover helper looks for the stock Samsung Flex mode panel"
require_grep 'does NOT transplant AOD|do NOT transplant AOD|NOT transplant AOD' "$FOLD_COVER_PREP" "fold/cover helper avoids downgrading donor AOD/SystemUI/Settings"
require_grep 'SOURCE_ROOT=.*fold-cover/root' "$FOLD_COVER_MODULE" "fold/cover module reads stock staging root"
require_grep 'sha256sum' "$FOLD_COVER_MODULE" "fold/cover module verifies staged checksums"
require_grep 'donor already contains' "$FOLD_COVER_MODULE" "fold/cover module preserves a donor Flex panel when present"
require_grep '^id=b2q_fold_cover_stock$' "$FOLD_COVER_MODULE_PROP" "fold/cover module identity"
require_grep 'prepare_b2q_fold_cover\.sh.*TARGET_FIRMWARE_DIR' "$BUILD_WRAPPER" "build wrapper prepares stock fold/cover support before make_rom"
require_grep 'active work tree|active-work-tree|active workdir' "$AOD_PREP" "AOD helper uses the active-work-tree policy"
require_grep 'SEC_FLOATING_FEATURE_FRAMEWORK_CONFIG_AOD_ITEM' "$AOD_MODULE" "AOD module edits the Samsung AOD item in the work tree"
require_grep 'WORK_DIR.*floating_feature\.xml' "$AOD_MODULE" "AOD module patches active UN1CA floating_feature.xml"
require_grep 'clock.*transition' "$AOD_MODULE" "AOD module removes only clock-transition capability"
require_grep 'Always On Display remains enabled' "$AOD_MODULE" "AOD workaround preserves Always On Display"
require_grep 'prepare_b2q_aod\.sh.*apply' "$BUILD_WRAPPER" "build wrapper validates AOD policy before make_rom"
require_grep 'B2Q_CAMERA_GUARD_MODE' "$CAMERA_GUARD" "camera guard supports auto/strict/off modes"
require_grep 'QUICK_SETTING_MENU' "$CAMERA_GUARD" "camera guard targets the top-level quick-setting list"
require_grep 'SUPPORT_BACK_MULTI_HIGH_RESOLUTION' "$CAMERA_GUARD" "camera guard verifies the known high-resolution selector"
require_grep 'three-stage Samsung Camera layout' "$CAMERA_GUARD" "camera guard safely handles unknown donor layouts"
require_grep 'const/4.*0x0' "$CAMERA_GUARD" "camera guard omits only the verified top-level item"
require_grep 'getMainItemList\(Ljava/util/List;\)Ljava/util/List;' "$CAMERA_GUARD" "camera guard targets the main quick-setting list"
require_grep 'getIndicatorItemList\(Ljava/util/List;\)Ljava/util/List;' "$CAMERA_GUARD" "camera guard targets the indicator list"
require_grep 'mQuickSettingViewItemMap:Ljava/util/EnumMap;' "$CAMERA_GUARD" "camera guard verifies the view-item map lookup"
require_grep 'LQ2/p;->a\(Lcom/sec/android/app/camera/interfaces/CommandId;\)LQ2/n;' "$CAMERA_GUARD" "indicator guard is placed before command metadata resolution"
require_grep 'skip quick-setting item missing from view-item map' "$CAMERA_GUARD" "camera guard marks the main-list null check"
require_grep 'skip indicator item missing from view-item map' "$CAMERA_GUARD" "camera guard marks the indicator-list null check"
require_grep "MAIN_PATCH_LABEL=':un1ca_b2q_skip_missing_quick_item'" "$CAMERA_GUARD" "camera guard defines the main-list branch target"
require_grep "INDICATOR_PATCH_LABEL=':un1ca_b2q_skip_missing_indicator_item'" "$CAMERA_GUARD" "camera guard defines the indicator-list branch target"
require_grep 'All missing stages are analysed and built in memory' "$CAMERA_GUARD" "camera guard prepares all modifications before replacing files"
require_grep '^id=b2q_camera_quick_setting_guard$' "$CAMERA_GUARD_PROP" "camera guard module identity"
if [[ -e "$ROOT/target/b2q/patches/camera_picture_size_guard" ]]; then
    fail "withdrawn camera_picture_size_guard module is still present"
else
    ok "withdrawn camera_picture_size_guard module is absent"
fi
if grep -Fq 'Required One UI 8 camera feature not found' "$CAMERA_PREP"; then
    fail "withdrawn camera XML merge is still present"
else
    ok "withdrawn camera XML merge is absent"
fi

if [[ -f "$ROOT/buildenv.sh" ]]; then
    require_grep 'find .*target' "$ROOT/buildenv.sh" "buildenv dynamically enumerates target directories"
else
    warn "buildenv.sh not present; validator is running in the standalone bundle"
fi

printf '\nResult: %d error(s), %d warning(s).\n' "$ERRORS" "$WARNINGS"
(( ERRORS == 0 ))
