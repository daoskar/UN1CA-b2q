# Disable only Samsung's cosmetic AOD clock-transition capability in the
# active donor work tree. The current UN1CA RRO guard evaluates the work-tree
# floating_feature.xml, not the extracted target firmware input, so this must
# run as a target patch after create_work_dir and before the common RRO patch.
FLOATING_FEATURE="$WORK_DIR/system/system/etc/floating_feature.xml"
if [[ ! -f "$FLOATING_FEATURE" ]]; then
    ABORT "File not found: ${FLOATING_FEATURE#"$WORK_DIR"}"
fi

python3 - "$FLOATING_FEATURE" <<'PY_B2Q_AOD_WORK'
from __future__ import annotations
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
tag = "SEC_FLOATING_FEATURE_FRAMEWORK_CONFIG_AOD_ITEM"
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    rf"(<{re.escape(tag)}(?:\s[^>]*)?>)(.*?)(</{re.escape(tag)}>)",
    re.IGNORECASE | re.DOTALL,
)
match = pattern.search(text)
if match is None:
    print("    - AOD item tag is absent; no clock-transition token to remove")
    raise SystemExit(0)

old = match.group(2)


def strip_clock_transition(value: str) -> tuple[str, bool]:
    original = value
    parts = re.split(r"([,;|])", value)
    out: list[str] = []
    for part in parts:
        if part in {",", ";", "|"}:
            out.append(part)
            continue
        normalized = re.sub(r"[^a-z0-9]", "", part.casefold())
        if "clock" in normalized and "transition" in normalized:
            out.append("")
        else:
            out.append(part)
    value = "".join(out)
    value = re.sub(
        r"(?i)(?<![A-Za-z0-9])[^,;|\s]*clock[^,;|\s]*transition[^,;|\s]*(?![A-Za-z0-9])",
        "",
        value,
    )
    value = re.sub(r"\s*([,;|])\s*", r"\1", value)
    value = re.sub(r"([,;|]){2,}", lambda m: m.group(0)[0], value)
    value = re.sub(r"^[,;|]+|[,;|]+$", "", value)
    value = re.sub(r"[ \t]{2,}", " ", value).strip()
    return value, value != original

new, changed = strip_clock_transition(old)
old_normalized = re.sub(r"[^a-z0-9]", "", old.casefold())
new_normalized = re.sub(r"[^a-z0-9]", "", new.casefold())
old_has_marker = "clock" in old_normalized and "transition" in old_normalized
new_has_marker = "clock" in new_normalized and "transition" in new_normalized

if old_has_marker and (not changed or new_has_marker):
    raise SystemExit("Could not safely remove AOD clock-transition capability")
if not old_has_marker:
    print("    - AOD clock-transition capability is already disabled")
    raise SystemExit(0)

updated = text[: match.start(2)] + new + text[match.end(2) :]
tmp = path.with_name(path.name + ".b2q-aod-new")
tmp.write_text(updated, encoding="utf-8")
# Verify the exact active-work-tree value before replacing the source file.
verify = pattern.search(updated)
if verify is not None:
    verify_normalized = re.sub(r"[^a-z0-9]", "", verify.group(2).casefold())
    if "clock" in verify_normalized and "transition" in verify_normalized:
        tmp.unlink(missing_ok=True)
        raise SystemExit("AOD clock-transition marker remained after patch")
tmp.replace(path)
print("    - Disabled AOD clock transition in active workdir floating_feature.xml")
print("    - Always On Display remains enabled")
PY_B2Q_AOD_WORK
