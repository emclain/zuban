# Zuban vs Jedi Rename Comparison Report

## What Was Implemented

### zuban-elm: LSP Rename Adapter (`test/lsp_compat.py`)
A thin pytest adapter in the jedi repo that:
- Parses jedi fixture files using `_collect_file_tests` from `test/refactor.py`
- Connects to a stdio LSP server and sends `textDocument/rename` requests
- Uses a minimal asyncio stdio LSP client (no external LSP library)
- Handles `documentChanges` and `changes` response formats
- Applies WorkspaceEdit edits end-to-start, produces unified diff with `difflib`
- Error cases pass if server returns LSP error or null result
- Writes source to real temp files (zuban requires on-disk files)
- Auto-restarts server on crash

### zuban-mu1: Test Harness (`test/test_lsp_rename.py`)
A pytest test module that:
- Accepts `--lsp-cmd` option (e.g. `--lsp-cmd='zuban server'`)
- Accepts `--zuban-bin` option to skip cargo build
- Session-scoped `LspSessionManager` that handles server lifecycle and crash recovery
- Parametrizes rename cases from `test/refactor/rename.py`

## Build

Cargo build succeeded without issues. `ZUBAN_TYPESHED` must be set to `third_party/typeshed` for the server to start (it panics without it).

## Jedi Baseline

**67 passed / 0 failed** (all rename fixture tests pass against jedi)

## Zuban Results

**47 passed / 15 failed** (62 single-file rename cases tested)

Note: 5 multi-file-only cases from jedi's 67 were excluded by the adapter (import, module, relative-import cases that only touch other files). The adapter only checks edits for the primary file.

## Cases That Differ

| Case | Jedi | Zuban | Category |
|------|------|-------|----------|
| var-not-found | pass (renames undefined var) | null/error | Undefined name handling |
| keyword-param1 | renames keyword args at call sites | misses keyword arg renames | Keyword parameter rename |
| keyword-param2 | renames keyword args at call sites | null/error | Keyword parameter rename |
| import | renames across files | only renames in current file | Multi-file (expected) |
| module | renames across files | only renames in current file | Multi-file (expected) |
| in-package-with-stub | renames across files + stubs | only renames in current file | Multi-file (expected) |
| package-with-stub | renames across files | null/error | Multi-file (expected) |
| weird-package-mix | renames across files | only renames in current file | Multi-file (expected) |
| import-as-alias | renames across files | only renames in current file | Multi-file (expected) |
| nonlocal-rename | renames nonlocal + outer binding | null/error | Nonlocal handling |
| relative-import-from-dot | renames across files | only renames in current file | Multi-file (expected) |
| relative-import-from-parent-pkg | renames across files | only renames in current file | Multi-file (expected) |
| string-annotation-return | renames inside `'pre'` annotation | does not rename string annotations | String annotations |
| string-annotation-param | renames inside `'pre'` annotation | does not rename string annotations | String annotations |
| string-annotation-variable | renames inside `'pre'` annotation | does not rename string annotations | String annotations |

## Notable Behavioral Gaps

### String Annotations
Zuban does not rename references inside string annotations (e.g. `-> 'pre'`, `x: 'pre'`). Jedi treats these as live references and renames them. This affects 3 test cases.

### Keyword Parameter Renaming
Zuban does not rename keyword argument names at call sites when renaming a function parameter. For example, renaming `param1` in `def f(param1)` should also rename `f(param1=3)` to `f(lala=3)`. This affects 2 test cases.

### Nonlocal Variables
Zuban returns null when asked to rename a variable declared with `nonlocal` from within a nested function scope. Jedi correctly propagates the rename to the outer scope binding.

### Undefined Names
Zuban returns null/error when asked to rename an undefined variable, while jedi still performs a textual rename of the reference.

### Multi-File Renames
As expected for single-file testing, zuban only returns edits for the current file. Import renames, module renames, and cross-file references are not tested here since the adapter only sends one file to the server. This accounts for 8 of the 15 failures and is not necessarily a zuban deficiency.

## Suggested Follow-Up Beads

1. **zuban-kw-rename**: Implement keyword argument renaming at call sites when renaming function parameters
2. **zuban-string-ann**: Support renaming references inside string annotations (`'TypeName'` in annotations)
3. **zuban-nonlocal**: Fix nonlocal variable rename to propagate to outer scope bindings
4. **zuban-multi-file-test**: Extend the LSP adapter to support multi-file rename testing (open multiple documents, check edits across files)
