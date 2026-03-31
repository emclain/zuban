#!/usr/bin/env bash
# agent-start.sh — Bootstrap a multi-agent session and claim one issue.
#
# Usage:
#   cd /workspace/dev/zuban
#   bash scripts/agent-start.sh
#
# On success, prints the worktree path and the claimed issue id.
# On "no work available", exits 0 with a message.
# On any hard error, exits non-zero.
#
# See MULTI_AGENT.md for the full procedure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── 1. Ensure bd is on PATH ───────────────────────────────────────────────────
if ! command -v bd &>/dev/null; then
  echo "bd not found — installing..."
  if curl -sSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash; then
    echo "bd installed via install script."
  else
    echo "Install script failed, trying direct dolt binary download..."
    ARCH=$(uname -m)
    [ "$ARCH" = "aarch64" ] && ARCH="arm64"
    curl -fsSL "https://github.com/dolthub/dolt/releases/latest/download/dolt-linux-${ARCH}.tar.gz" \
      | tar -xz -C /tmp
    mkdir -p "$HOME/.local/bin"
    cp "/tmp/dolt-linux-${ARCH}/bin/dolt" "$HOME/.local/bin/bd"
    chmod +x "$HOME/.local/bin/bd"
    export PATH="$HOME/.local/bin:$PATH"
    echo "bd installed to ~/.local/bin/bd"
  fi
fi

export PATH="$HOME/.local/bin:$PATH"

if ! command -v bd &>/dev/null; then
  echo "ERROR: bd still not found after installation attempt. Add ~/.local/bin to PATH." >&2
  exit 1
fi

# ── 2. Ensure jq is available (needed for --json parsing) ────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed. Install it with: apt-get install -y jq" >&2
  exit 1
fi

# ── 3. Ensure Rust/cargo is available ────────────────────────────────────────
if ! command -v cargo &>/dev/null; then
  source "$HOME/.cargo/env" 2>/dev/null || true
fi
if ! command -v cargo &>/dev/null; then
  echo "ERROR: cargo not found. Install Rust from https://rustup.rs" >&2
  exit 1
fi

# ── 3b. Ensure zuban debug binary is built ───────────────────────────────────
if [ ! -f "$REPO_ROOT/target/debug/zuban" ]; then
  echo "Building zuban (first run, may take a few minutes)..."
  cargo build
fi

# ── 3c. Ensure jedi repo is checked out alongside ────────────────────────────
JEDI_DIR="$(cd "$REPO_ROOT/.." && pwd)/jedi"
if [ ! -d "$JEDI_DIR" ]; then
  echo "Cloning jedi alongside zuban..."
  git clone https://github.com/emclain/jedi "$JEDI_DIR" --branch refactoring-test-coverage
fi
if [ ! -d "$JEDI_DIR/.venv" ]; then
  echo "Setting up jedi Python venv..."
  python3 -m venv "$JEDI_DIR/.venv"
  "$JEDI_DIR/.venv/bin/pip" install -q -e "$JEDI_DIR/[testing]"
fi

# ── 4. Initialize beads if not already done ──────────────────────────────────
if ! bd list &>/dev/null 2>&1; then
  echo "Initializing beads database..."
  bd init --force --prefix zuban
  bd import
fi

# ── 5. Pull latest ────────────────────────────────────────────────────────────
echo "Pulling latest from origin/jedi-compare..."
git pull origin jedi-compare

# ── 6. Claim one issue ───────────────────────────────────────────────────────
claimed=""
for id in $(bd ready --json --limit 10 | jq -r '.[].id'); do
  if bd update "$id" --claim 2>/dev/null; then
    claimed="$id"
    break
  fi
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

# Git worktrees also do NOT inherit .beads/ — copy config so bd in the worktree
# connects to the same Dolt server as this checkout.
echo "Bridging bd into worktree..."
mkdir -p "$worktree/.beads"
cp -f "$REPO_ROOT/.beads/config.yaml" "$worktree/.beads/"
if [ -f "$REPO_ROOT/.beads/dolt-server.port" ]; then
  cp -f "$REPO_ROOT/.beads/dolt-server.port" "$worktree/.beads/"
fi

echo "Worktree created at: $worktree_abs"

# ── 8. Write .agent-env ──────────────────────────────────────────────────────
cat > "$worktree/.agent-env" <<EOF
export CLAIMED_ID=$claimed
export BEADS_ACTOR="agent-$(hostname)-$$"
export ZUBAN_TYPESHED=$REPO_ROOT/third_party/typeshed
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
