#!/usr/bin/env bash
# agent-start.sh — Bootstrap a multi-agent session and claim one issue.
#
# Usage (from the primary checkout):
#   bash scripts/agent-start.sh
#
# The primary checkout is a coordination hub that no agent edits. This script
# fast-forwards it to origin/jedi-compare, makes sure the shared beads Dolt
# server is running, claims one issue, and creates an isolated worktree for it.
#
# On success, prints the worktree path and the claimed issue id.
# On "no work available", exits 0 with a message.
# On any hard error, exits non-zero.
#
# See MULTI_AGENT.md for the full procedure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

GIT_DIR_ABS="$(git rev-parse --path-format=absolute --git-dir)"
GIT_COMMON_ABS="$(git rev-parse --path-format=absolute --git-common-dir)"
if [ "$GIT_DIR_ABS" != "$GIT_COMMON_ABS" ]; then
  echo "ERROR: run agent-start.sh from the primary checkout, not a worktree." >&2
  echo "  cd $(dirname "$GIT_COMMON_ABS") && bash scripts/agent-start.sh" >&2
  exit 1
fi

# ── 1. Ensure required tools are on PATH ─────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
if ! command -v cargo &>/dev/null; then
  source "$HOME/.cargo/env" 2>/dev/null || true
fi
# dolt is needed alongside bd: bd runs the shared `dolt sql-server` from it.
for tool in bd dolt jq cargo; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool not found on PATH. See 'Beads Setup' and 'Setup' in AGENTS.md." >&2
    exit 1
  fi
done

# ── 2. Ensure zuban debug binary is built ────────────────────────────────────
if [ ! -f "$REPO_ROOT/target/debug/zuban" ]; then
  echo "Building zuban (first run, may take a few minutes)..."
  cargo build
fi

# ── 3. Ensure jedi repo is checked out alongside ─────────────────────────────
JEDI_DIR="$(cd "$REPO_ROOT/.." && pwd)/jedi"
if [ ! -d "$JEDI_DIR" ]; then
  echo "Cloning jedi alongside zuban..."
  git clone https://github.com/emclain/jedi "$JEDI_DIR" --branch refactoring-test-coverage
fi
bash "$REPO_ROOT/scripts/setup-jedi-venv.sh" "$JEDI_DIR"

# ── 4. Fast-forward the primary checkout ─────────────────────────────────────
# Worktrees branch from origin/jedi-compare directly; this only keeps the hub's
# scripts and .beads config current. It refuses rather than touch local work.
echo "Fast-forwarding primary checkout to origin/jedi-compare..."
git fetch origin jedi-compare
if [ "$(git branch --show-current)" != "jedi-compare" ]; then
  echo "ERROR: the primary checkout must stay on jedi-compare (it is on '$(git branch --show-current)')." >&2
  exit 1
fi
if ! git diff --quiet --ignore-submodules || ! git diff --cached --quiet --ignore-submodules; then
  echo "ERROR: the primary checkout has uncommitted changes. No agent should work in it;" >&2
  echo "move that work to a worktree, then re-run." >&2
  git status --short --untracked-files=no >&2
  exit 1
fi
if ! git merge --ff-only origin/jedi-compare; then
  echo "ERROR: the primary checkout could not fast-forward to origin/jedi-compare." >&2
  echo "If another agent was starting at the same moment, re-run. Otherwise it has local" >&2
  echo "commits or untracked files in the way; resolve that by hand." >&2
  exit 1
fi

# ── 5. Ensure the shared beads database is up ────────────────────────────────
# Parallel agents need beads' server mode: embedded mode is documented as
# single-writer. Every worktree resolves to this checkout's .beads/ through
# git's common dir, so they all talk to the one server this checkout runs.
if [ "$(jq -r .dolt_mode .beads/metadata.json)" != "server" ]; then
  echo "ERROR: .beads/metadata.json is not in server mode; parallel agents need the shared Dolt server." >&2
  echo "See 'Beads Database' in MULTI_AGENT.md." >&2
  exit 1
fi
fresh_db=0
[ -d .beads/dolt ] || fresh_db=1
bd dolt start
if [ "$fresh_db" -eq 1 ]; then
  # Fresh checkout: clone the database from the Dolt remote. Needs the server
  # up first, and unlike `bd init --force` it never deletes existing data.
  echo "No beads database yet — bootstrapping..."
  bd bootstrap --yes
fi

# ── 6. Claim one issue ───────────────────────────────────────────────────────
# `bd update --claim` is idempotent for the same actor, and bd's default actor
# is git user.name — shared by every agent in this environment. Without a
# unique actor, every agent would "win" the same issue.
export BEADS_ACTOR="agent-$(hostname)-$$"
ready_json="$(bd ready --json --limit 10)"
claimed=""
for id in $(jq -r '.[].id' <<<"$ready_json"); do
  if claim_err="$(bd update "$id" --claim 2>&1 >/dev/null)"; then
    claimed="$id"
    break
  fi
  # Losing a claim race is expected; any other failure is not.
  if [ "$(bd show "$id" --json | jq -r '.[0].status')" = "in_progress" ]; then
    continue
  fi
  echo "ERROR: claiming $id failed: $claim_err" >&2
  exit 1
done

if [ -z "$claimed" ]; then
  echo "No available work — all issues are claimed or done."
  exit 0
fi

echo "Claimed issue: $claimed"

# ── 7. Create isolated worktree ──────────────────────────────────────────────
worktree="../zuban-${claimed}"
worktree_abs="$(cd .. && pwd)/zuban-${claimed}"

# Clean up stale worktree from a prior crashed run
if [ -d "$worktree" ]; then
  echo "Stale worktree found at $worktree — removing..."
  git worktree remove --force "$worktree" 2>/dev/null || true
  git branch -D "work/$claimed" 2>/dev/null || true
fi

git worktree add "$worktree" -b "work/$claimed" origin/jedi-compare

# Git worktrees do NOT inherit submodule contents — initialize them now.
echo "Initializing submodules in worktree..."
git -C "$worktree" submodule update --init

echo "Worktree created at: $worktree_abs"

# ── 8. Write .agent-env ──────────────────────────────────────────────────────
cat > "$worktree/.agent-env" <<EOF
export CLAIMED_ID=$claimed
export BEADS_ACTOR="$BEADS_ACTOR"
export ZUBAN_TYPESHED=$worktree_abs/third_party/typeshed
export JEDI_DIR=$JEDI_DIR
export CARGO_TARGET_DIR=$worktree_abs/target
EOF

echo ""
echo "Ready. Run the following to start work:"
echo "  cd $worktree_abs"
echo "  source .agent-env"
echo "  bd show $claimed"
echo ""
echo "When done (work committed), land with:"
echo "  bash scripts/agent-land.sh"
echo ""
echo "To run rename tests:"
echo "  bash scripts/run_jedi_rename_tests.sh"
