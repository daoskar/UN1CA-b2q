#!/usr/bin/env bash
# Preserve previous inputs, then force make_rom to package the current workdir.
set -euo pipefail
OUT="${1:?Usage: refresh_b2q_target_files.sh OUT_DIR}"
[[ -d "$OUT" ]] || { echo "Missing output directory: $OUT" >&2; exit 1; }
shopt -s nullglob
files=("$OUT"/b2q_*-target_files.zip)
if ((${#files[@]})); then
    backup="$(mktemp -d "$OUT/b2q-previous-target-files.XXXXXXXX")"
    for file in "${files[@]}"; do
        [[ -f "$file" && ! -L "$file" ]] || { echo "Unexpected archive path: $file" >&2; exit 1; }
        mv -- "$file" "$backup/"
    done
    echo "- B2Q-PACKAGING: preserved ${#files[@]} old target-files ZIP(s) in $backup"
fi
