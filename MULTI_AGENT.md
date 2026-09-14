# Multi-Agent Workflow

Multiple Claude instances can work in parallel in one environment by combining beads' atomic `--claim`, a shared beads Dolt server, and one git worktree per issue.

## How It Works

- **Claim** serializes issue assignment — `bd update --claim` fails atomically if another instance beat you to it. Each instance claims under its own `BEADS_ACTOR`; a claim is idempotent for the same actor, so a shared actor would let every instance "win" the same issue.
- **The beads server** is the one database every instance writes to. Beads' embedded mode is single-writer, so parallel agents require server mode (see [Beads Database](#beads-database)).
- **Worktrees** give each instance its own working tree, index and build directory, so file edits never interfere.
- **The remote** is the only coordination point for git — instances never share a local branch.

## The Primary Checkout

The primary checkout (the directory holding `.git/`, e.g. `dev/zuban`) is a coordination hub. **No agent edits files in it or commits from it** (running `bd` there is fine; it only touches the database). It holds shared state that every instance uses:

- **The beads database and server.** Every worktree resolves `.beads/` to the primary's through git's common directory, so all `bd` commands reach the server running from the primary's `.beads/dolt/` (PID, port and log files sit beside it; all gitignored).
- **Its own `jedi-compare` branch and working tree.** `agent-start.sh` fast-forwards them to `origin/jedi-compare`, which is how script and `.beads` config changes pushed by other agents reach the hub. It refuses to run if the primary has uncommitted changes or local commits.
- **Worktree bookkeeping.** Creating and removing worktrees and `work/<id>` branches changes `.git/`; the worktrees themselves live beside it as `../zuban-<id>`.
- **A one-time build.** `agent-start.sh` builds `target/debug/zuban` in the primary if it is missing.

**`../jedi` is read-only for zuban agents.** It is jedi's own primary checkout (jedi runs this same workflow; see its MULTI_AGENT.md). `agent-start.sh` clones it and creates its `.venv` if missing, and `scripts/run_jedi_rename_tests.sh` runs the rename tests there — but no zuban agent edits or commits in it. Changes zuban needs in jedi go through jedi's tracker; see [Changes in jedi](#changes-in-jedi). jedi's own agents fast-forward that checkout, so a rename test run can see its files change mid-run.

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

To claim a specific issue rather than the top ready one, pass its id: `bash scripts/agent-start.sh <id>`. For work that is not a tracked issue, such as a change a user asks for directly, `bash scripts/agent-start.sh --no-claim [<name>]` does everything except the claim, in `../zuban-<name>` on `work/<name>`; `agent-land.sh` lands that worktree the same way, minus closing an issue.

What it does: checks for `bd`, `dolt`, `jq` and `cargo`; fast-forwards the primary checkout; starts the beads server (`bd dolt start`, bootstrapping the database on a fresh checkout); claims the highest-priority ready issue under a unique `BEADS_ACTOR`; creates `../zuban-<id>` on branch `work/<id>` from `origin/jedi-compare` with submodules initialized; and writes `.agent-env` into it.

```bash
cd ../zuban-<id>
source .agent-env   # sets CLAIMED_ID (WORK_NAME with --no-claim), BEADS_ACTOR, ZUBAN_TYPESHED, JEDI_DIR, CARGO_TARGET_DIR
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

#### Changes in jedi

The rename test driver (`test/test_lsp_rename.py`), the adapter (`test/lsp_compat.py`) and the rename fixtures live in jedi, not here. If your issue needs a change in jedi, do not edit `../jedi`. File the change in jedi's tracker, mark this issue blocked, and stop:

```bash
bd -C ../jedi create --title="..." --description="Needed by $CLAIMED_ID: ..." --type=task --priority=<n>
bd note $CLAIMED_ID "Blocked on <jedi-id>: <what jedi needs to change>"
bd update $CLAIMED_ID --status blocked
bd -C ../jedi dolt push
bd dolt push
```

Those writes reach every local agent immediately through the beads servers, but reach origin only through `bd dolt push` — and a blocked issue has no landing to run it, so run both pushes yourself (re-run one that fails). The git-tracked `.beads/issues.jsonl` in each repo catches up at that repo's next landing, whose export includes everything in its database.

Do not run `agent-land.sh` for a blocked issue. If the worktree holds nothing worth keeping, remove it from the primary checkout (`git worktree remove --force ../zuban-<id>` and `git branch -D work/<id>`); otherwise say what it holds in the note. Once the jedi bead has landed, set this issue back to `open`; `agent-start.sh` deletes any leftover worktree for it when it is next claimed.

### 3. Landing the Plane (in the worktree)

File beads for anything you noticed but didn't work on — related issues, edge cases, tangents. Do not pursue them.

```bash
bd create --title="..." --type=task --priority=<n>
```

If the new bead requires changes to the **core zuban codebase** (server-side rename logic, new LSP capabilities, etc.) rather than the test harness or adapter, mark it deferred immediately:

```bash
bd update <id> --status deferred
```

Core zuban work is out of scope for this project until prioritized separately. Only test harness, adapter (`lsp_compat.py`), and fixture/script work is in scope — and apart from `scripts/run_jedi_rename_tests.sh`, those files live in jedi (see [Changes in jedi](#changes-in-jedi)).

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

Review the session for friction, gaps, or follow-up work. This step is **not optional** — do not skip it. `agent-land.sh` removes your worktree, so reflect on startup and work *before* running it, and on the landing itself afterwards.

**For every issue you encountered or discovered (permission errors, missing steps, unclear instructions, new edge cases):**

Fix in-place (only when the fix is clear and unambiguous):
- **If `scripts/agent-start.sh` or `agent-land.sh` failed or was incomplete:** improve the script.
- **If setup instructions in AGENTS.md were wrong or missing a step:** update them.
- **If a new category of obstacle appeared:** add it to the script's guard logic.
- **If any step is currently prose instructions:** convert it to scripted commands.

Commit these fixes in your worktree before running `agent-land.sh`, so they land with your change; the next `agent-start.sh` fast-forwards them into the primary checkout. Anything found during landing has no worktree to fix it in — file a bead for it.

File a bead for anything requiring deeper investigation or design:
1. **File a bead** — `bd create --title="..." --description="..." --type=task --priority=<n>`
2. **Push any new beads** — beads filed before `agent-land.sh` are exported and pushed by it. After landing, run `bd dolt push` in the primary checkout (it pushes only the database; `.beads/issues.jsonl` catches up at the next landing).

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
