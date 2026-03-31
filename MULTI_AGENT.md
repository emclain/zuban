# Multi-Agent Workflow

Multiple Claude instances can work in parallel from the same checkout without conflicts by combining beads' atomic `--claim` with git worktrees.

## How It Works

- **Claim** serializes issue assignment — `bd update --claim` fails atomically if another instance beat you to it
- **Worktrees** give each instance its own working tree and index so file edits never interfere
- **The remote** is the only coordination point for git — instances never share a local branch

## One Issue Per Session

Each agent instance should claim and complete **exactly one issue**, then stop. Do not loop back to claim another. This keeps each agent's scope small and avoids long-running sessions that accumulate stale state or conflict with other instances.

## Procedure

### 1. Startup (in the shared checkout)

```bash
cd /workspace/dev/zuban
bash scripts/agent-start.sh
```

If the script prints a worktree path, `cd` there and continue. If it prints "No available work", stop.

Manual equivalent (for reference or debugging):

```bash
cd /workspace/dev/zuban

# Ensure bd is initialized
if ! bd list &>/dev/null; then
  bd init --force --prefix zuban
  bd import
fi

# Pull latest
git pull origin jedi-compare

# Find and claim the highest-priority available issue
claimed=""
for id in $(bd ready --json --limit 10 | jq -r '.[].id'); do
  if bd update "$id" --claim 2>/dev/null; then
    claimed="$id"
    break
  fi
done

[ -z "$claimed" ] && echo "No available work." && exit 0

# Create an isolated worktree + branch for this issue
if [ -d "../zuban-$claimed" ]; then
  git worktree remove --force "../zuban-$claimed" 2>/dev/null || true
  git branch -D "work/$claimed" 2>/dev/null || true
fi
git worktree add ../zuban-$claimed -b work/$claimed origin/jedi-compare

# Worktrees do NOT inherit submodule contents — initialize them now
git -C ../zuban-$claimed submodule update --init

# Worktrees also do NOT inherit .beads/ — copy config and port file so bd
# in the worktree connects to the same already-running server
mkdir -p ../zuban-$claimed/.beads
cp -f .beads/config.yaml ../zuban-$claimed/.beads/
[ -f .beads/dolt-server.port ] && cp -f .beads/dolt-server.port ../zuban-$claimed/.beads/

# Write .agent-env
cat > ../zuban-$claimed/.agent-env <<EOF
export CLAIMED_ID=$claimed
export BEADS_ACTOR="agent-$(hostname)-$$"
EOF

cd ../zuban-$claimed
```

Set a unique actor name so audit trails are distinguishable — `agent-start.sh` writes
`.agent-env` into the worktree for this:

```bash
source .agent-env   # sets CLAIMED_ID and BEADS_ACTOR
```

### 2. Work (in the worktree)

```bash
# Review the issue
bd show $CLAIMED_ID

# Do the work, then run quality gates
cargo test

# Commit
git add <files>
git commit -m "<message>"
```

### 3. Landing the Plane (in the worktree)

First, file any follow-up issues for work you discovered but didn't complete:

```bash
bd create --title="..." --type=task --priority=<n>
```

Then run the landing script:

```bash
bash scripts/agent-land.sh
```

<details>
<summary>Manual equivalent (for reference or debugging)</summary>

```bash
cargo test

bd close $CLAIMED_ID

while true; do
  git fetch origin jedi-compare
  git merge origin/jedi-compare --no-edit
  git push origin "work/$CLAIMED_ID:jedi-compare" && break
  echo "Push rejected — another instance landed first, retrying..."
  sleep 1
done

bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git commit -m "bd sync: update issues.jsonl after $CLAIMED_ID"

while true; do
  git fetch origin jedi-compare
  git merge origin/jedi-compare --no-edit
  git push origin "work/$CLAIMED_ID:jedi-compare" && break
  echo "Push rejected — retrying..."
  sleep 1
done

cd /workspace/dev/zuban
git worktree remove --force "../zuban-$CLAIMED_ID"
git branch -d "work/$CLAIMED_ID"
```
</details>

### 4. **MANDATORY: Reflect on Workflow**

Before stopping, review the session for friction, gaps, or follow-up work. This step is **not optional** — do not skip it.

Fix in-place (don't just file a bead, also fix it):
- **If `scripts/agent-start.sh` or `agent-land.sh` failed or was incomplete:** improve the script.
- **If setup instructions in AGENTS.md were wrong or missing a step:** update them.
- **If a new category of obstacle appeared:** add it to the script's guard logic.

**For every issue you encountered or discovered (permission errors, missing steps, unclear instructions, new edge cases):**

1. **File a bead** — `bd create --title="..." --description="..." --type=task --priority=<n>`
2. **Push it** — beads are only persisted when `bd export > .beads/issues.jsonl` is committed and pushed. If `agent-land.sh` already did this, verify your new issue id appears in the pushed `.beads/issues.jsonl`. If not, run the export/commit/push sequence again.

**If workflow was smooth with no issues:** write one sentence saying so — no bead needed.

**Stop after one issue.** Do not loop back to claim another.

## Beads State Persistence

`bd dolt push` is **not configured** in this environment. Beads state is persisted through the git-tracked `.beads/issues.jsonl` file.

```bash
bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git commit -m "bd sync: ..."
git push origin <branch>:jedi-compare
```

## Why This Is Safe

- **No local `jedi-compare` branch is ever modified.** Instances push `work/$claimed:jedi-compare` directly to the remote.
- **Push rejection is the coordination signal.** The loser fetches, merges, and retries in isolation.
- **`--claim` is atomic.** Exactly one instance wins the race per issue.
