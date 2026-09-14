#!/usr/bin/env bash
# agent-land.sh — Land one completed issue: quality gates, push, beads sync, cleanup.
#
# Usage (from the worktree, after committing your work):
#   bash scripts/agent-land.sh
#
# Reads CLAIMED_ID from the environment (source .agent-env first) or pass as $1.
# A worktree from `agent-start.sh --no-claim` sets WORK_NAME instead, and lands
# the same way except that there is no issue to close.
# Must be run from the worktree (not the primary checkout).

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
work_name="${claimed:-${WORK_NAME:-}}"
if [ -z "$work_name" ]; then
  echo "ERROR: pass the issue id as \$1 or set CLAIMED_ID (source .agent-env)." >&2
  exit 1
fi
branch="work/$work_name"

git_common="$(git rev-parse --path-format=absolute --git-common-dir)"
if [ "$(git rev-parse --path-format=absolute --git-dir)" = "$git_common" ]; then
  echo "ERROR: run agent-land.sh from the issue's worktree, not the primary checkout." >&2
  exit 1
fi
MAIN_CHECKOUT="$(dirname "$git_common")"
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
cd "$WORKTREE_ROOT"
# The cleanup below removes this worktree, so it must be the one being landed.
if [ "$(git branch --show-current)" != "$branch" ]; then
  echo "ERROR: this worktree is on '$(git branch --show-current)', not $branch." >&2
  exit 1
fi

if ! git -C "$MAIN_CHECKOUT" rev-parse --git-dir &>/dev/null; then
  _add_safe_dirs "$MAIN_CHECKOUT"
fi

# Merge origin/jedi-compare into this branch. .beads/issues.jsonl is only an
# export of the shared beads database, so a conflict there is resolved by
# exporting again. A conflict in any other file stops the landing.
merge_origin() {
  git fetch origin jedi-compare
  if git merge origin/jedi-compare --no-edit; then
    return 0
  fi
  local conflicted
  conflicted="$(git diff --name-only --diff-filter=U)"
  if [ "$conflicted" = ".beads/issues.jsonl" ]; then
    echo "issues.jsonl conflict — re-exporting from the beads database..."
    bd export > .beads/issues.jsonl
    git add .beads/issues.jsonl
    git commit --no-edit
    return 0
  fi
  git merge --abort 2>/dev/null || true
  echo "ERROR: merging origin/jedi-compare failed. Conflicted files:" >&2
  echo "${conflicted:-(none — see git output above)}" >&2
  echo "Resolve it here (git merge origin/jedi-compare), commit, and re-run agent-land.sh." >&2
  exit 1
}

# Commit a fresh export of the shared database, if it differs from HEAD.
commit_export() {
  bd export > .beads/issues.jsonl
  git add .beads/issues.jsonl
  if ! git diff --cached --quiet -- .beads/issues.jsonl; then
    git commit -m "bd sync: update issues.jsonl after $work_name"
  fi
}

# ── 1. Quality gates ─────────────────────────────────────────────────────────
echo "=== Quality gates ==="
# Isolate build artifacts to this worktree to avoid cross-instance file-lock conflicts.
export CARGO_TARGET_DIR="$WORKTREE_ROOT/target"
# Disable incremental compilation: rustc's incremental session management hard-links
# .o files between session directories (nlink can reach 3 per file). On overlayfs
# (Docker), unlinking a file with nlink>1 returns EPERM. CARGO_INCREMENTAL=0
# eliminates the hard-links at their source. See rust-lang/rust#76727.
export CARGO_INCREMENTAL=0
cargo test

# ── 2. Push code to remote (retry loop handles concurrent instances) ─────────
# The issue stays in_progress until the code is on origin, so a landing that
# stops on a conflict never leaves a closed issue behind.
echo "=== Pushing code ==="
merge_origin
until git push origin "$branch:jedi-compare"; do
  echo "Push rejected — another instance landed first, retrying..."
  sleep 1
  merge_origin
done

# ── 3. Close the issue ───────────────────────────────────────────────────────
if [ -n "$claimed" ]; then
  echo "=== Closing $claimed ==="
  bd close "$claimed"
fi

# ── 4. Persist beads state ───────────────────────────────────────────────────
# Both are required (see "Beads Database" in MULTI_AGENT.md): the jsonl export
# for git, and bd dolt push for the Dolt history that `bd bootstrap` restores.
echo "=== Persisting beads state ==="
commit_export
until git push origin "$branch:jedi-compare"; do
  echo "Push rejected — retrying..."
  sleep 1
  merge_origin
  commit_export
done

dolt_pushed=0
for attempt in 1 2 3; do
  if bd dolt push; then
    dolt_pushed=1
    break
  fi
  echo "bd dolt push failed (attempt $attempt/3)."
  sleep 2
done

# ── 5. Clean up worktree ─────────────────────────────────────────────────────
echo "=== Cleaning up ==="
cd "$MAIN_CHECKOUT"
git worktree remove --force "$WORKTREE_ROOT"
git branch -d "$branch"

if [ "$dolt_pushed" -ne 1 ]; then
  echo "" >&2
  echo "ERROR: $work_name landed in git, but bd dolt push failed. Run it from $MAIN_CHECKOUT:" >&2
  echo "  bd dolt push" >&2
  exit 1
fi

echo ""
echo "✓ $work_name landed successfully."
