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

## Follow-Up Beads Filed

- **zuban-0nm**: Rename: keyword argument call sites not updated
- **zuban-vc9**: Rename: cross-file edits not returned for definition file
- **zuban-b0w**: Rename: module/file rename not implemented
- **zuban-z07**: Rename: string annotations not updated (forward references)
- **zuban-ljo**: Rename: var-not-found, keyword-param2, nonlocal-rename return null unexpectedly

---

## Jedi Refactoring Integration Analysis

### Background

Investigation into whether jedi's Python refactoring operations (extract_variable,
extract_function, inline, introduce_parameter, introduce_field) could be integrated
into zuban, and what form that integration would take.

### CST Comparison: parsa_python vs parso

Both are full-fidelity lossless CSTs that can round-trip source code exactly.

| Dimension | zuban (parsa_python) | jedi (parso) |
|---|---|---|
| Storage | Flat `Vec<InternalNode>`, 16 bytes/node | Linked pointer tree (Python objects) |
| Position | Byte offset (u32) | (line, col) tuples, 1-indexed |
| Whitespace/comments | Retrieved via `prefix_to_previous_leaf()` | Pre-attached as `Leaf.prefix` string |
| Node types | Enum (`Terminal(TerminalType::Name)`, etc.) | Class hierarchy (~20 specialised leaf types) |
| Parent navigation | O(n) backward scan through Vec | O(1) via stored pointer |
| Sibling/child iteration | `iter_children()`, offset arithmetic | `node.children` list, direct indexing |

The flat Vec layout is cache-friendly for tree walks. The main ergonomic difference
is that parso pre-attaches whitespace/comments to the following leaf as `.prefix`,
while parsa_python requires an explicit call to retrieve trivia. Jedi's refactoring
code uses `.prefix` heavily; porting would need a thin wrapper.

The key incompatibility for porting is **position representation**: jedi uses
(line, col) tuples throughout its refactoring code; zuban uses byte offsets.
Conversion is lossless but requires scanning for newlines — a cached line-start
table (which zuban likely already builds for LSP diagnostics) would handle this.

### Semantic Requirements vs Zuban's Existing Capabilities

Zuban is a full language server. Most of what jedi's refactoring needs from its
inference engine is already present in zuban:

| Operation | Cross-file refs | Data flow | Pure CST | Zuban readiness |
|---|---|---|---|---|
| Rename | yes | no | no | ~95% — `references_for_rename()` exists and is LSP-wired |
| Inline | yes (refs + def) | no | heavy | ~80% — `references()` + `goto()` exist |
| Extract Variable | no | no | 100% | 100% — no inference needed |
| Extract Function | yes (free vars) | yes | partial | ~70% — one gap (below) |
| Introduce Parameter | no | no | 100% | 100% — no inference needed |

**The one semantic gap** is in extract_function: classifying each free variable in
the extracted range as an *input* (defined outside → becomes a parameter) or
*output* (defined inside → becomes a return value). Jedi does this by calling
`context.goto(name)` and checking whether the definition falls within the extracted
range. Zuban has `goto()` already; what's missing is a thin wrapper:

```rust
fn is_name_defined_in_range(doc, name, range_start, range_end) -> bool
```

### Integration Options

**Subprocess/JSON-RPC wrapper** — lightest path for prototyping. A thin Python shim
takes a JSON request and returns a JSON diff. Zuban spawns a persistent subprocess
with stdin/stdout. No new Rust dependencies; jedi stays pure Python. Downside:
subprocess startup latency (mitigated by keeping the process alive), and a Python
runtime dependency that conflicts with zuban's standalone value proposition.

**Native Rust implementation** — right long-term answer. Zuban already has the CST
and the inference infrastructure. The work is CST manipulation (expression boundary
detection, precedence analysis, scope insertion point selection) plus one new
semantic helper for extract_function. No new inference capabilities are needed.
Mechanical porting effort estimated at ~200–300 lines of adapter/wrapper code plus
systematic translation of the refactoring logic itself.

**PyO3 (embedded Python)** — single-process, direct API access, no serialisation
overhead. Significant architectural cost: adds a Python runtime dependency to what
is currently a standalone Rust binary.

### Conclusion

A native Rust implementation is the right path. The semantic infrastructure is
~90% already present in zuban. The remaining work is CST manipulation logic plus
one new `is_name_defined_in_range` helper — building on solid foundations rather
than starting from scratch.
