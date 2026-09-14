#!/usr/bin/env bash
# Restore stock SM-F711B fold/device-state/display configuration and add the
# stock Flex mode panel when the Android 16 donor does not already provide it.
# All inputs are staged from the user's extracted SM-F711B firmware by
# scripts/prepare_b2q_fold_cover.sh.

SOURCE_ROOT="$SRC_DIR/target/b2q/fold-cover/root"
MANIFEST="$SRC_DIR/target/b2q/fold-cover/manifest.tsv"

if [[ ! -d "$SOURCE_ROOT" || ! -f "$MANIFEST" ]]; then
    LOG "- B2Q-FOLD-COVER: no stock staging directory; leaving workdir unchanged"
    return 0 2>/dev/null || exit 0
fi

resolve_destination() {
    local rel="$1" top
    top="${rel%%/*}"
    case "$top" in
        system|vendor|product|system_ext|odm)
            if [[ -d "$WORK_DIR/$top" ]]; then
                printf '%s\n' "$WORK_DIR/$rel"
                return 0
            fi
            ;;
    esac
    return 1
}

is_control_panel_path() {
    local rel="${1,,}"
    [[ "$rel" == *"/controlpanel/"* || "$rel" == *"/controlpanel.apk" || "$rel" == *"flexmodepanel"* || "$rel" == *"flex_mode_panel"* ]]
}

installed=0
skipped=0
while IFS=$'\t' read -r rel expected_sha reason; do
    [[ -n "$rel" ]] || continue
    src="$SOURCE_ROOT/$rel"
    if [[ ! -f "$src" ]]; then
        ABORT "B2Q fold/cover staged file is missing: $rel"
    fi

    actual_sha="$(sha256sum "$src" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        ABORT "B2Q fold/cover staged file checksum mismatch: $rel"
    fi

    if ! dst="$(resolve_destination "$rel")"; then
        LOG "- B2Q-FOLD-COVER: skip $rel (partition root is not present in active workdir)"
        skipped=$((skipped + 1))
        continue
    fi

    # Prefer an Android 16 donor copy of the Flex panel if UN1CA ever starts
    # shipping one. The stock Android 15 app is only used to fill a missing
    # foldable-only package on the slab-phone donor.
    if is_control_panel_path "$rel" && [[ -f "$dst" ]]; then
        LOG "- B2Q-FLEX: donor already contains $(basename "$dst"); keeping donor version"
        skipped=$((skipped + 1))
        continue
    fi

    mkdir -p "$(dirname "$dst")"
    install -m 0644 "$src" "$dst"
    installed=$((installed + 1))

    if is_control_panel_path "$rel"; then
        LOG "- B2Q-FLEX: installed stock SM-F711B Flex mode panel: $rel"
    else
        LOG "- B2Q-FOLD-COVER: restored $rel ($reason)"
    fi
done < "$MANIFEST"

LOG "- B2Q-FOLD-COVER: installed $installed stock target file(s), skipped $skipped"
