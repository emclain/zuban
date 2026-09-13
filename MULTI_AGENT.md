# Multi-Agent Workflow

Multiple Claude instances can work in parallel in one environment by combining beads' atomic `--claim`, a shared beads Dolt server, and one git worktree per issue.

## How It Works

- **Claim** serializes issue assignment — `bd update --claim` fails atomically if another instance beat you to it. Each instance claims under its own `BEADS_ACTOR`; a claim is idempotent for the same actor, so a shared actor would let every instance "win" the same issue.
- **The beads server** is the one database every instance writes to. Beads' embedded mode is single-writer, so parallel agents require server mode (see [Beads Database](#beads-database)).
- **Worktrees** give each instance its own working tree, index and build directory, so file edits never interfere.
- **The remote** is the only coordination point for git — instances never share a local branch.

## The Primary Checkout

The primary checkout (the directory holding `.git/`, e.g. `dev/zuban`) is a coordination hub. **No agent edits files in it or commits from it.** It holds shared state that every instance uses:

- **The beads database and server.** Every worktree resolves `.beads/` to the primary's through git's common directory, so all `bd` commands reach the server running from the primary's `.beads/dolt/` (PID, port and log files sit beside it; all gitignored).
- **Its own `jedi-compare` branch and working tree.** `agent-start.sh` fast-forwards them to `origin/jedi-compare`, which is how script and `.beads` config changes pushed by other agents reach the hub. It refuses to run if the primary has uncommitted changes or local commits.
- **Worktree bookkeeping.** Creating and removing worktrees and `work/<id>` branches changes `.git/`; the worktrees themselves live beside it as `../zuban-<id>`.
- **A one-time build.** `agent-start.sh` builds `target/debug/zuban` in the primary if it is missing.

Shared outside the primary: `../jedi` and its `.venv`, which `agent-start.sh` clones and creates if missing and every instance's rename tests run in. Worktrees do not isolate it — two instances changing jedi files (such as `test/lsp_compat.py`) would edit the same working tree.

## One Issue Per Session

Each agent instance should claim and complete **exactly one issue**, then stop. Do not loop back to claim another.

Work only what the issue describes. If you notice related problems, edge cases, or tempting tangents, file a bead and move on — do not investigate or fix them. Staying narrowly focused keeps sessions short and avoids conflicts with other instances.

## Procedure

The scripts are the procedure; read them rather than a copy here, which would drift.

### 1. Startup (in the primary checkout)

```bash
bash scripts/agent-start.sh
```

If the script prints a worktree path, `cd` there and continue. If it prints "No available work", stop. If it fails because another instance was starting at the same moment (a git lock error), run it again.

What it does: checks for `bd`, `dolt`, `jq` and `cargo`; fast-forwards the primary checkout; starts the beads server (`bd dolt start`, bootstrapping the database on a fresh checkout); claims the highest-priority ready issue under a unique `BEADS_ACTOR`; creates `../zuban-<id>` on branch `work/<id>` from `origin/jedi-compare` with submodules initialized; and writes `.agent-env` into it.

```bash
cd ../zuban-<id>
source .agent-env   # sets CLAIMED_ID, BEADS_ACTOR, ZUBAN_TYPESHED, JEDI_DIR, CARGO_TARGET_DIR
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

File beads for anything you noticed but didn't work on — related issues, edge cases, tangents. Do not pursue them.

```bash
bd create --title="..." --type=task --priority=<n>
```

If the new bead requires changes to the **core zuban codebase** (server-side rename logic, new LSP capabilities, etc.) rather than the test harness or adapter, mark it deferred immediately:

```bash
bd update <id> --status deferred
```

Core zuban work is out of scope for this project until prioritized separately. Only test harness, adapter (`lsp_compat.py`), and fixture/script work is in scope.

Then run the landing script:

```bash
bash scripts/agent-land.sh
```

What it does, in order:

1. Runs `cargo test` with a per-worktree target directory.
2. Merges `origin/jedi-compare` and pushes `work/<id>:jedi-compare`, retrying on rejection. The issue stays `in_progress` until the code is on origin.
3. Closes the issue.
4. Commits a fresh `bd export` to `.beads/issues.jsonl` and pushes it, retrying the same way; then runs `bd dolt push`.
5. Removes the worktree and its branch.

A conflict in `.beads/issues.jsonl` is resolved automatically by exporting again: the file is only a snapshot of the shared database. A conflict in any other file stops the script with the worktree intact — resolve it there, commit, and re-run `agent-land.sh`. If only `bd dolt push` fails, the landing is complete in git; the script says so and exits non-zero, and `bd dolt push` should be re-run from the primary checkout.

### 4. **MANDATORY: Reflect on Workflow**

Before stopping, review the session for friction, gaps, or follow-up work. This step is **not optional** — do not skip it.

**For every issue you encountered or discovered (permission errors, missing steps, unclear instructions, new edge cases):**

Fix in-place (only when the fix is clear and unambiguous):
- **If `scripts/agent-start.sh` or `agent-land.sh` failed or was incomplete:** improve the script.
- **If setup instructions in AGENTS.md were wrong or missing a step:** update them.
- **If a new category of obstacle appeared:** add it to the script's guard logic.
- **If any step is currently prose instructions:** convert it to scripted commands.

Make these fixes in your worktree and land them like any other change; the next `agent-start.sh` fast-forwards them into the primary checkout.

File a bead for anything requiring deeper investigation or design:
1. **File a bead** — `bd create --title="..." --description="..." --type=task --priority=<n>`
2. **Push any new beads** — run `bd export > .beads/issues.jsonl`, commit, and push to `jedi-compare`.

**If workflow was smooth with no issues:** write one sentence saying so — no bead needed.

The goal: the next agent should be able to run `bash scripts/agent-start.sh`, do their work, and run `bash scripts/agent-land.sh` with no manual intervention.

**Stop after one issue.** Do not loop back to claim another.

## Beads Database

This project runs beads in **server mode** (`"dolt_mode": "server"` in `.beads/metadata.json`). Beads documents its default embedded mode as single-writer — one process at a time — and server mode as the mode for multiple agents writing simultaneously. `agent-start.sh` refuses to run in any other mode.

- **Server lifecycle.** `bd` starts the `dolt sql-server` on demand from the primary checkout's `.beads/`, and it keeps running after agents exit. Stop it with `bd dolt stop` in the primary checkout when no agents are active.
- **Fresh checkout.** Start the server, then `bd bootstrap --yes`, which clones the database from the Dolt remote (`agent-start.sh` does this when `.beads/dolt/` is missing). Never use `bd init --force`: it re-initializes over existing data, and it refuses anyway once origin holds Dolt data.

Two sync paths, and landing runs both:

```bash
bd dolt push                      # full Dolt DB (history, audit trail) via refs/dolt/data on origin
bd export > .beads/issues.jsonl   # git-tracked snapshot
git add .beads/issues.jsonl
git commit -m "bd sync: ..."
git push origin <branch>:jedi-compare
```

`bd dolt push` is what `bd bootstrap` restores from, so a fresh checkout is only as current as the last push. The jsonl export keeps issue changes visible in git history and PR diffs, and `bd bootstrap` falls back to it when there is no Dolt remote.

## Why This Is Safe

- **No agent works in the primary checkout.** `agent-start.sh` only fast-forwards it and refuses when it has local changes or commits; instances push `work/<id>:jedi-compare` directly to the remote.
- **Push rejection is the coordination signal.** The loser fetches, merges, and retries in isolation.
- **`--claim` is atomic** and each instance claims under a unique actor, so exactly one instance wins per issue.
- **One server serves every writer**, which is the concurrency model beads documents for multiple agents.
- **`issues.jsonl` never needs a hand merge.** It is regenerated from the database whenever git reports a conflict in it.
