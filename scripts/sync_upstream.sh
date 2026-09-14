#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE=upstream
URL=https://github.com/salvogiangri/UN1CA.git
BRANCH=sixteen
MODE=merge
DRY_RUN=false

usage() {
    cat <<'USAGE'
Usage: scripts/sync_upstream.sh [options]
  --url URL          Upstream repository URL
  --remote NAME      Git remote name (default: upstream)
  --branch NAME      Upstream branch (default: sixteen)
  --rebase           Rebase your current branch instead of merging
  --dry-run          Fetch and show incoming commits without modifying HEAD

The script intentionally keeps b2q in isolated target/platform directories so
normal upstream merges usually require no manual conflict resolution.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url) URL="$2"; shift ;;
        --remote) REMOTE="$2"; shift ;;
        --branch) BRANCH="$2"; shift ;;
        --rebase) MODE=rebase ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a Git repository: $ROOT" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean. Commit or stash changes first." >&2; exit 2; }

if git remote get-url "$REMOTE" >/dev/null 2>&1; then
    git remote set-url "$REMOTE" "$URL"
else
    git remote add "$REMOTE" "$URL"
fi

git fetch --prune --tags "$REMOTE" "$BRANCH"
UPSTREAM_REF="$REMOTE/$BRANCH"

echo "Incoming commits:"
git log --oneline --decorate HEAD.."$UPSTREAM_REF" || true

$DRY_RUN && exit 0

BACKUP_TAG="b2q-pre-sync-$(date -u +%Y%m%d-%H%M%S)"
git tag "$BACKUP_TAG"
echo "Created local backup tag: $BACKUP_TAG"
git config rerere.enabled true

if [[ "$MODE" == rebase ]]; then
    git rebase "$UPSTREAM_REF"
else
    git merge --no-edit "$UPSTREAM_REF"
fi

"$ROOT/scripts/validate_b2q.sh"
echo "Upstream sync completed and b2q validation passed."
