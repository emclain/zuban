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

Beads requires the `bd` CLI and a local Dolt database. On a new machine or container:

```bash
# 1. Install the bd CLI
curl -sSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
# If that requires root, download the binary directly instead:
#   ARCH=$(uname -m); [ "$ARCH" = "aarch64" ] && ARCH="arm64"
#   curl -L "https://github.com/dolthub/dolt/releases/latest/download/dolt-linux-$ARCH.tar.gz" | tar -xz -C /tmp
#   cp /tmp/dolt-linux-$ARCH/bin/dolt ~/.local/bin/

# 2. Initialize the local Dolt database from the checked-in issues.jsonl
bd init --force --prefix zuban

# 3. Import existing issues
bd import

# 4. Verify
bd list
```

> Note: the Dolt database is runtime state (not in git). You must run `bd init` + `bd import`
> on every fresh checkout or container. Export back with `bd export > .beads/issues.jsonl`
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
# (sets ZUBAN_TYPESHED automatically; requires ../jedi to be checked out)
bash scripts/run_jedi_rename_tests.sh
```

> **Note:** `zuban server` is the correct invocation for stdio LSP mode.
> `zuban --stdio` is not a valid flag and will cause the server to fail to start.

## Multi-Agent Parallelism

When multiple instances are running from the same checkout, see **[MULTI_AGENT.md](MULTI_AGENT.md)** for the full procedure. In brief: run `bash scripts/agent-start.sh` to bootstrap, claim with `bd update --claim`, isolate with `git worktree`, push via `work/<id>:jedi-compare` with a retry loop — never touch the shared checkout's local `jedi-compare`.

**Each agent works on exactly one issue, then stops.**


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
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

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull origin jedi-compare
   bd export > .beads/issues.jsonl   # persist beads state (bd dolt push is NOT configured)
   git add .beads/issues.jsonl
   git diff --cached --quiet || git commit -m "bd sync: update issues.jsonl"
   git push origin jedi-compare
   git status  # MUST show "up to date with origin"
   ```
   > **Note:** `bd dolt push` always fails in this environment — no dolt remote is configured.
   > Use `bd export > .beads/issues.jsonl` + git commit + push instead. See MULTI_AGENT.md
   > for details.
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
- Always use `git pull --no-rebase` (merge) — never `git pull --rebase`
<!-- END BEADS INTEGRATION -->
