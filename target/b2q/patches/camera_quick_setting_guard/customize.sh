#!/usr/bin/env bash
# Adaptive three-stage Samsung Camera guard for Galaxy Z Flip3 (b2q).
#
# Stage 1 omits the unsupported top-level BACK_CAMERA_PICTURE_SIZE_TOGGLE_MENU
# command while retaining the separate submenu mapping.
# Stage 2 skips commands missing from mQuickSettingViewItemMap in
# getMainItemList().
# Stage 3 performs the same defensive check in getIndicatorItemList() before
# the donor code resolves command metadata through Q2/p.a().
#
# All missing stages are analysed and built in memory before any smali file is
# replaced. In "auto" mode an unknown donor APK is left untouched. "strict"
# aborts the build on an unknown layout; "off" disables this module.

CAMERA_APK="system/priv-app/SamsungCamera/SamsungCamera.apk"
TOGGLE_FIELD='Lcom/sec/android/app/camera/interfaces/CommandId;->BACK_CAMERA_PICTURE_SIZE_TOGGLE_MENU:Lcom/sec/android/app/camera/interfaces/CommandId;'
QUICK_MENU_FIELD='Lcom/sec/android/app/camera/interfaces/CommandId;->QUICK_SETTING_MENU:Lcom/sec/android/app/camera/interfaces/CommandId;'
MULTI_FEATURE='SUPPORT_BACK_MULTI_HIGH_RESOLUTION'
PICTURE_MENU_FIELD='BACK_CAMERA_PICTURE_SIZE_MENU'
VIEW_MAP_FIELD='mQuickSettingViewItemMap:Ljava/util/EnumMap;'
ENUM_MAP_GET='Ljava/util/EnumMap;->get(Ljava/lang/Object;)Ljava/lang/Object;'
VIEW_ITEM_TYPE='LC2/o;'
COMMAND_CONFIG_METHOD='LQ2/p;->a(Lcom/sec/android/app/camera/interfaces/CommandId;)LQ2/n;'

LIST_PATCH_MARKER='UN1CA b2q: omit unsupported back picture-size quick setting'
MAIN_PATCH_MARKER='UN1CA b2q: skip quick-setting item missing from view-item map'
MAIN_PATCH_LABEL=':un1ca_b2q_skip_missing_quick_item'
MAIN_METHOD='getMainItemList(Ljava/util/List;)Ljava/util/List;'
INDICATOR_PATCH_MARKER='UN1CA b2q: skip indicator item missing from view-item map'
INDICATOR_PATCH_LABEL=':un1ca_b2q_skip_missing_indicator_item'
INDICATOR_METHOD='getIndicatorItemList(Ljava/util/List;)Ljava/util/List;'

CAMERA_GUARD_MODE="${B2Q_CAMERA_GUARD_MODE:-strict}"
case "$CAMERA_GUARD_MODE" in
    auto|strict|off) ;;
    *) ABORT "Invalid B2Q_CAMERA_GUARD_MODE='$CAMERA_GUARD_MODE' (expected auto, strict or off)" ;;
esac

if [[ "$CAMERA_GUARD_MODE" == off ]]; then
    LOG "- CAMERA-GUARD: SKIPPED — disabled by B2Q_CAMERA_GUARD_MODE=off"
    return 0
fi

if ! DECODE_APK "system" "$CAMERA_APK"; then
    if [[ "$CAMERA_GUARD_MODE" == strict ]]; then
        ABORT "Could not decode SamsungCamera.apk for the required b2q camera guard"
    fi
    LOG "- CAMERA-GUARD: SKIPPED — SamsungCamera.apk could not be decoded for this donor"
    return 0
fi

CAMERA_DECODED="$APKTOOL_DIR/system/${CAMERA_APK#system/}"

if CAMERA_RESULT="$(python3 - \
    "$CAMERA_DECODED" \
    "$TOGGLE_FIELD" \
    "$QUICK_MENU_FIELD" \
    "$MULTI_FEATURE" \
    "$PICTURE_MENU_FIELD" \
    "$VIEW_MAP_FIELD" \
    "$ENUM_MAP_GET" \
    "$VIEW_ITEM_TYPE" \
    "$COMMAND_CONFIG_METHOD" \
    "$LIST_PATCH_MARKER" \
    "$MAIN_PATCH_MARKER" \
    "$MAIN_PATCH_LABEL" \
    "$MAIN_METHOD" \
    "$INDICATOR_PATCH_MARKER" \
    "$INDICATOR_PATCH_LABEL" \
    "$INDICATOR_METHOD" 2>&1 <<'PY_CAMERA_GUARD'
from __future__ import annotations

from pathlib import Path
import os
import re
import sys

(
    root_arg,
    toggle,
    quick_menu,
    multi_feature,
    picture_menu,
    view_map_field,
    enum_map_get,
    view_item_type,
    command_config_method,
    list_marker,
    main_marker,
    main_label,
    main_method,
    indicator_marker,
    indicator_label,
    indicator_method,
) = sys.argv[1:]
root = Path(root_arg)


def method_ranges(lines: list[str]):
    start = None
    signature = None
    for index, line in enumerate(lines):
        stripped = line.rstrip("\r\n")
        if line.startswith(".method"):
            start = index
            signature = stripped
        elif start is not None and line.startswith(".end method"):
            yield start, index, signature or ""
            start = None
            signature = None


def meaningful_next(lines: list[str], start: int, end: int) -> int | None:
    index = start
    while index < end:
        stripped = lines[index].strip()
        if stripped and not lines[index].lstrip().startswith("#"):
            return index
        index += 1
    return None


def sget_ref(line: str, field: str) -> tuple[str, str] | None:
    if field not in line:
        return None
    match = re.match(r"^(\s*)sget-object\s+([vp]\d+),\s+.*$", line.rstrip("\r\n"))
    if not match:
        return None
    return match.group(1), match.group(2)


def marker_files(files: list[Path], marker: str) -> list[Path]:
    return [
        path
        for path in files
        if marker in path.read_text(encoding="utf-8", errors="surrogateescape")
    ]


def verify_existing(files: list[Path], marker: str, label: str | None = None) -> Path | None:
    found = marker_files(files, marker)
    if not found:
        return None
    if len(found) != 1:
        raise RuntimeError(f"marker '{marker}' occurs in {len(found)} files")
    text = found[0].read_text(encoding="utf-8", errors="surrogateescape")
    if text.count(marker) != 1:
        raise RuntimeError(f"marker '{marker}' occurs {text.count(marker)} times")
    if label is not None and text.count(label) != 2:
        raise RuntimeError(
            f"label '{label}' occurs {text.count(label)} times; expected branch and target"
        )
    return found[0]


def find_list_candidate(files: list[Path]) -> Path | None:
    candidates: list[Path] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        if toggle not in text or quick_menu not in text:
            continue
        lines = text.splitlines(keepends=True)
        ranges = [item for item in method_ranges(lines) if "<clinit>()V" in item[2]]
        if len(ranges) != 1:
            continue
        start, end, _ = ranges[0]
        toggle_refs = [i for i in range(start + 1, end) if sget_ref(lines[i], toggle)]
        quick_refs = [i for i in range(start + 1, end) if sget_ref(lines[i], quick_menu)]
        if len(toggle_refs) != 2 or not quick_refs:
            continue
        first, second = toggle_refs
        if not (first < quick_refs[0] < second):
            continue
        context = "".join(lines[max(start, first - 24):first + 1])
        if multi_feature not in context or picture_menu not in context:
            continue
        candidates.append(path)
    return candidates[0] if len(candidates) == 1 else None


def patch_list(text: str) -> str:
    lines = text.splitlines(keepends=True)
    ranges = [item for item in method_ranges(lines) if "<clinit>()V" in item[2]]
    if len(ranges) != 1:
        raise RuntimeError("expected exactly one <clinit>()V")
    start, end, _ = ranges[0]
    refs = [i for i in range(start + 1, end) if sget_ref(lines[i], toggle)]
    quick_refs = [i for i in range(start + 1, end) if sget_ref(lines[i], quick_menu)]
    if len(refs) != 2 or not quick_refs:
        raise RuntimeError("unexpected command-map reference count")
    first, second = refs
    if not (first < quick_refs[0] < second):
        raise RuntimeError("unexpected command-map ordering")
    context = "".join(lines[max(start, first - 24):first + 1])
    if multi_feature not in context or picture_menu not in context:
        raise RuntimeError("top-level toggle lacks verified high-resolution context")
    parsed = sget_ref(lines[first], toggle)
    if parsed is None:
        raise RuntimeError("top-level toggle is not an sget-object")
    indent, register = parsed
    newline = "\r\n" if lines[first].endswith("\r\n") else "\n"
    lines[first] = (
        f"{indent}# {list_marker}{newline}"
        f"{indent}const/4 {register}, 0x0{newline}"
    )
    patched = "".join(lines)
    method_text = "".join(lines[start:end + 1])
    if patched.count(list_marker) != 1 or method_text.count(toggle) != 1:
        raise RuntimeError("top-level list guard verification failed")
    return patched


def analyse_method_candidate(
    path: Path,
    method_sig: str,
    require_command_config: bool,
) -> bool:
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    required = (method_sig, view_map_field, enum_map_get, view_item_type)
    if any(item not in text for item in required):
        return False
    if require_command_config and command_config_method not in text:
        return False
    try:
        locate_method_lookup(text, method_sig, require_command_config)
    except RuntimeError:
        return False
    return True


def locate_method_lookup(
    text: str,
    method_sig: str,
    require_command_config: bool,
) -> tuple[list[str], int, int, int, str, int]:
    lines = text.splitlines(keepends=True)
    ranges = [item for item in method_ranges(lines) if method_sig in item[2]]
    if len(ranges) != 1:
        raise RuntimeError(f"expected one {method_sig}, found {len(ranges)}")
    start, end, _ = ranges[0]
    lookups: list[tuple[int, str]] = []
    for i in range(start + 1, end):
        if view_map_field not in lines[i]:
            continue
        for j in range(i + 1, min(i + 12, end)):
            if enum_map_get not in lines[j]:
                continue
            move_line = meaningful_next(lines, j + 1, end)
            if move_line is None:
                continue
            move = re.match(
                r"^\s*move-result-object\s+([vp]\d+)\s*$",
                lines[move_line].rstrip("\r\n"),
            )
            if not move:
                continue
            register = move.group(1)
            cast_line = meaningful_next(lines, move_line + 1, end)
            if cast_line is None:
                continue
            cast_re = rf"^\s*check-cast\s+{re.escape(register)},\s+{re.escape(view_item_type)}\s*$"
            if not re.match(cast_re, lines[cast_line].rstrip("\r\n")):
                continue
            if require_command_config:
                found_config = False
                scan = cast_line + 1
                for _ in range(12):
                    scan = meaningful_next(lines, scan, end)
                    if scan is None:
                        break
                    if command_config_method in lines[scan] and "invoke-static" in lines[scan]:
                        found_config = True
                        break
                    scan += 1
                if not found_config:
                    continue
            lookups.append((cast_line, register))
    if len(lookups) != 1:
        raise RuntimeError(
            f"expected one verified view-map lookup in {method_sig}, found {len(lookups)}"
        )
    cast_line, item_register = lookups[0]
    increments = [
        i
        for i in range(cast_line + 1, end)
        if re.match(
            r"^\s*add-int/lit8\s+([vp]\d+),\s*\1,\s*(?:0x1|1)\s*$",
            lines[i].rstrip("\r\n"),
        )
    ]
    if len(increments) != 1:
        raise RuntimeError(
            f"expected one loop increment in {method_sig}, found {len(increments)}"
        )
    return lines, start, end, cast_line, item_register, increments[0]


def patch_method_guard(
    text: str,
    method_sig: str,
    marker: str,
    label: str,
    require_command_config: bool,
) -> str:
    lines, start, end, cast_line, item_register, increment_line = locate_method_lookup(
        text, method_sig, require_command_config
    )
    if label in text:
        raise RuntimeError(f"label collision for {label}")
    newline = "\r\n" if lines[cast_line].endswith("\r\n") else "\n"
    indent_match = re.match(r"^(\s*)", lines[cast_line])
    indent = indent_match.group(1) if indent_match else "    "
    lines.insert(
        cast_line + 1,
        f"{indent}# {marker}{newline}{indent}if-eqz {item_register}, {label}{newline}",
    )
    increment_line += 1
    lines.insert(increment_line, f"{label}{newline}")
    patched = "".join(lines)
    new_method_text = "".join(lines[start:end + 3])
    if new_method_text.count(marker) != 1 or new_method_text.count(label) != 2:
        raise RuntimeError(f"post-patch verification failed for {method_sig}")
    if not re.search(
        rf"if-eqz\s+{re.escape(item_register)},\s*{re.escape(label)}",
        new_method_text,
    ):
        raise RuntimeError(f"branch verification failed for {method_sig}")
    return patched


files = sorted(root.rglob("*.smali"))
if not files:
    print("decoded SamsungCamera tree contains no smali files", file=sys.stderr)
    raise SystemExit(10)

try:
    existing_list = verify_existing(files, list_marker)
    existing_main = verify_existing(files, main_marker, main_label)
    existing_indicator = verify_existing(files, indicator_marker, indicator_label)
except RuntimeError as exc:
    print(f"inconsistent existing camera guard: {exc}", file=sys.stderr)
    raise SystemExit(20)

if existing_list and existing_main and existing_indicator:
    print(
        "CAMERA-GUARD: ALREADY_APPLIED "
        f"{existing_list} | {existing_main} | {existing_indicator}"
    )
    raise SystemExit(0)

list_path = existing_list or find_list_candidate(files)
main_candidates = [
    path for path in files if analyse_method_candidate(path, main_method, False)
]
indicator_candidates = [
    path for path in files if analyse_method_candidate(path, indicator_method, True)
]
main_path = existing_main or (main_candidates[0] if len(main_candidates) == 1 else None)
indicator_path = existing_indicator or (
    indicator_candidates[0] if len(indicator_candidates) == 1 else None
)

missing = []
if list_path is None:
    missing.append("command-map")
if main_path is None:
    missing.append(f"{main_method} ({len(main_candidates)} candidates)")
if indicator_path is None:
    missing.append(f"{indicator_method} ({len(indicator_candidates)} candidates)")
if missing:
    print(
        "no exact compatible three-stage Samsung Camera layout was found: "
        + ", ".join(missing),
        file=sys.stderr,
    )
    raise SystemExit(10)

# Build all changed contents in memory. Paths may overlap (both presenter
# methods normally live in the same smali file), so changes are applied to the
# in-memory version in a deterministic order.
updates: dict[Path, str] = {}

def current_text(path: Path) -> str:
    return updates.get(path) or path.read_text(
        encoding="utf-8", errors="surrogateescape"
    )

try:
    if existing_list is None:
        updates[list_path] = patch_list(current_text(list_path))
    if existing_main is None:
        updates[main_path] = patch_method_guard(
            current_text(main_path), main_method, main_marker, main_label, False
        )
    if existing_indicator is None:
        updates[indicator_path] = patch_method_guard(
            current_text(indicator_path),
            indicator_method,
            indicator_marker,
            indicator_label,
            True,
        )
except RuntimeError as exc:
    print(f"camera guard analysis failed safely: {exc}", file=sys.stderr)
    raise SystemExit(21)

staged: list[tuple[Path, Path]] = []
try:
    for path, content in updates.items():
        temp = path.with_name(path.name + ".un1ca-camera-new")
        temp.write_text(content, encoding="utf-8", errors="surrogateescape")
        staged.append((path, temp))
    for path, temp in staged:
        os.replace(temp, path)
except Exception:
    for _, temp in staged:
        try:
            temp.unlink(missing_ok=True)
        except Exception:
            pass
    raise

print(
    "CAMERA-GUARD: APPLIED "
    f"{list_path} | {main_path} | {indicator_path}"
)
PY_CAMERA_GUARD
)"; then
    LOG "- $CAMERA_RESULT"
else
    CAMERA_STATUS=$?
    case "$CAMERA_STATUS" in
        10|11)
            if [[ "$CAMERA_GUARD_MODE" == strict ]]; then
                ABORT "Samsung Camera donor layout did not match the required three-stage b2q guard: $CAMERA_RESULT"
            fi
            LOG "- CAMERA-GUARD: SKIPPED — donor layout differs; APK was left unchanged"
            LOG "- CAMERA-GUARD detail: ${CAMERA_RESULT//$'\n'/ | }"
            return 0
            ;;
        *)
            ABORT "Samsung Camera adaptive three-stage guard failed safely (status $CAMERA_STATUS): $CAMERA_RESULT"
            ;;
    esac
fi

if [[ "$CAMERA_RESULT" == *"APPLIED"* || "$CAMERA_RESULT" == *"ALREADY_APPLIED"* ]]; then
    mapfile -t LIST_MARKER_FILES < <(grep -rlF --include='*.smali' "$LIST_PATCH_MARKER" "$CAMERA_DECODED" 2>/dev/null | LC_ALL=C sort)
    mapfile -t MAIN_MARKER_FILES < <(grep -rlF --include='*.smali' "$MAIN_PATCH_MARKER" "$CAMERA_DECODED" 2>/dev/null | LC_ALL=C sort)
    mapfile -t INDICATOR_MARKER_FILES < <(grep -rlF --include='*.smali' "$INDICATOR_PATCH_MARKER" "$CAMERA_DECODED" 2>/dev/null | LC_ALL=C sort)
    if [[ "${#LIST_MARKER_FILES[@]}" -ne 1 || "${#MAIN_MARKER_FILES[@]}" -ne 1 || "${#INDICATOR_MARKER_FILES[@]}" -ne 1 ]]; then
        ABORT "Samsung Camera adaptive guard verification failed: expected one marker for each of three stages"
    fi
    if [[ "$(grep -Fc "$MAIN_PATCH_LABEL" "${MAIN_MARKER_FILES[0]}")" -ne 2 ]]; then
        ABORT "Samsung Camera adaptive guard verification failed: main-list branch/label mismatch"
    fi
    if [[ "$(grep -Fc "$INDICATOR_PATCH_LABEL" "${INDICATOR_MARKER_FILES[0]}")" -ne 2 ]]; then
        ABORT "Samsung Camera adaptive guard verification failed: indicator branch/label mismatch"
    fi
fi
