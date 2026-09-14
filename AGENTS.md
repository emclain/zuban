# Goals

Adapt the rename test cases built for jedi to run over zuban, investigating
several approaches to testing rename behavior. The goal is to compare zuban's
rename output against jedi's, find gaps, and expand coverage.

# Work Tracking

As a work tracking system, we use Beads (see instructions below)
https://github.com/steveyegge/beads
instead of unstructured markdown or Claude memory files. Start with a
plan and work your way through breaking it down into smaller pieces,
filing beads as you go.

If you find issues impeding your work, file them as beads rather than
context switching to try to fix them.

Work in small bites, file beads as you go, and push your changes
without my prompting. When you reach the end of your context window,
prefer to use beads as your memory and quit rather than compacting.

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Beads Setup (fresh checkout)

Beads requires the `bd` CLI and the `dolt` binary. This project runs beads in server mode, where
`bd` runs a local `dolt sql-server` for the checkout (see "Beads Database" in MULTI_AGENT.md).
On a new machine or container:

```bash
# 1. Install the bd CLI
curl -sSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# 2. Install dolt, if it is not already on PATH
ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH="amd64"; [ "$ARCH" = "aarch64" ] && ARCH="arm64"
curl -fsSL "https://github.com/dolthub/dolt/releases/latest/download/dolt-linux-$ARCH.tar.gz" | tar -xz -C /tmp
cp /tmp/dolt-linux-$ARCH/bin/dolt ~/.local/bin/

# 3. Start the beads server, then clone the issue database from the Dolt remote
#    (refs/dolt/data on origin). Never use `bd init --force` here: it re-initializes
#    over existing data.
bd dolt start
bd bootstrap --yes

# 4. Verify
bd list
```

> Note: the Dolt database is runtime state (not in git), in `.beads/dolt/`. `scripts/agent-start.sh`
> runs step 3 automatically when it is missing. Export back with `bd export > .beads/issues.jsonl`
> before committing.

## Setup

```bash
# Initialize submodules (required — includes third_party/typeshed which zuban
# needs at runtime; without it the server panics on the first didOpen)
git submodule update --init

# Build the project
cargo build

# Run Rust tests
cargo test

# Run jedi rename fixture tests against zuban
# (sets ZUBAN_TYPESHED automatically; requires ../jedi to be checked out. ../jedi is
# read-only for zuban agents — see "Changes in jedi" in MULTI_AGENT.md)
bash scripts/run_jedi_rename_tests.sh
```

> **Note:** `zuban server` is the correct invocation for stdio LSP mode.
> `zuban --stdio` is not a valid flag and will cause the server to fail to start.

## Multi-Agent Parallelism

When multiple instances are running in one environment, see **[MULTI_AGENT.md](MULTI_AGENT.md)** for the full procedure. In brief: run `bash scripts/agent-start.sh` in the primary checkout to claim one issue and get a worktree, work in that worktree, and land with `bash scripts/agent-land.sh`. Never edit files or commit in the primary checkout — it holds the shared beads server, and `agent-start.sh` only fast-forwards it.

**Each agent works on exactly one issue, then stops.**

## Project-Specific Beads Sync Policy (overrides the managed block below)

> **Why this section exists here:** `bd init`/`bd setup` regenerates everything between the
> `BEGIN BEADS INTEGRATION`/`END BEADS INTEGRATION` markers below verbatim on every run — it
> already happened once in this repo's history (an earlier mandatory-push workflow in that block
> was silently replaced by the generic upstream template). Anything project-specific must live
> outside the markers to survive. The managed block's own text agrees this section wins:
> *"Explicit user or orchestrator instructions override this Beads block."*

- **Both sync paths are required, not either/or.** `bd dolt push` syncs the database via
  `refs/dolt/data` on the `origin` git remote, and fresh checkouts clone it from there
  (`bd bootstrap`, see "Beads Setup" above) — a fresh checkout is only as current as the last push.
  The `.beads/issues.jsonl` export is still required: it's what keeps issue changes visible in
  normal PR diffs, and bootstrap's fallback when there is no Dolt remote. `scripts/agent-land.sh`
  runs both. By hand:
  ```bash
  bd dolt push
  bd export > .beads/issues.jsonl
  git add .beads/issues.jsonl && git commit -m "bd sync: ..." && git push
  ```
- **Sessions must end pushed, not just reported.** This overrides the managed block's
  "Conservative: report status, wait for approval" default — see MULTI_AGENT.md for the full
  claim/push/retry procedure this project uses instead.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
