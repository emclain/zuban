#!/usr/bin/env bash
# agent-land.sh — Land one completed issue: quality gates, push, beads sync, cleanup.
#
# Usage (from the worktree, after committing your work):
#   bash scripts/agent-land.sh
#
# Reads CLAIMED_ID from the environment (source .agent-env first) or pass as $1.
# Must be run from the worktree (not the main checkout).

set -euo pipefail

# Guard: git ownership check
_add_safe_dirs() {
  local dir
  for dir in "$@"; do
    git config --global --add safe.directory "$dir" 2>/dev/null || true
  done
}
if ! git rev-parse --git-common-dir &>/dev/null; then
  _add_safe_dirs "$(pwd)" "$(realpath "$(pwd)/..")"
  if ! git rev-parse --git-common-dir &>/dev/null; then
    echo "ERROR: git ownership check failed even after adding safe.directory." >&2
    exit 1
  fi
fi

claimed="${1:-${CLAIMED_ID:-}}"
if [ -z "$claimed" ]; then
  echo "ERROR: pass the issue id as \$1 or set CLAIMED_ID (source .agent-env)." >&2
  exit 1
fi

git_common="$(git rev-parse --git-common-dir)"
if [[ "$git_common" = /* ]]; then
  MAIN_CHECKOUT="$(dirname "$git_common")"
else
  MAIN_CHECKOUT="$(git rev-parse --show-toplevel)"
fi
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"

_add_safe_dirs "$MAIN_CHECKOUT" "$WORKTREE_ROOT"

# Helper: run a bd command; refresh server port and retry once on failure.
bd_run() {
  if ! bd "$@" 2>/dev/null; then
    echo "bd $* failed — refreshing server port from main checkout and retrying..."
    if [ -f "$MAIN_CHECKOUT/.beads/dolt-server.port" ]; then
      cp -f "$MAIN_CHECKOUT/.beads/dolt-server.port" "$WORKTREE_ROOT/.beads/dolt-server.port"
    fi
    bd "$@"
  fi
}

# ── 1. Quality gates ─────────────────────────────────────────────────────────
echo "=== Quality gates ==="
# Isolate build artifacts to this worktree to avoid cross-instance file-lock conflicts.
export CARGO_TARGET_DIR="$WORKTREE_ROOT/target"
cargo test

# ── 2. Close the issue ───────────────────────────────────────────────────────
echo "=== Closing $claimed ==="
bd_run close "$claimed"

# ── 3. Push code to remote (retry loop handles concurrent instances) ─────────
echo "=== Pushing code ==="
while true; do
  git fetch origin jedi-compare
  git merge origin/jedi-compare --no-edit
  git push origin "work/$claimed:jedi-compare" && break
  echo "Push rejected — another instance landed first, retrying..."
  sleep 1
done

# ── 4. Persist beads state ───────────────────────────────────────────────────
echo "=== Persisting beads state ==="
bd_run export > "$WORKTREE_ROOT/.beads/issues.jsonl"
git add .beads/issues.jsonl
git commit -m "bd sync: update issues.jsonl after $claimed"

while true; do
  git fetch origin jedi-compare
  git merge origin/jedi-compare --no-edit
  git push origin "work/$claimed:jedi-compare" && break
  echo "Push rejected — retrying..."
  sleep 1
done

# ── 5. Clean up worktree ─────────────────────────────────────────────────────
echo "=== Cleaning up ==="
cd "$MAIN_CHECKOUT"
git worktree remove --force "$WORKTREE_ROOT"
git branch -d "work/$claimed"

echo ""
echo "✓ $claimed landed successfully."
