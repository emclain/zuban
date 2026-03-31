#!/usr/bin/env bash
# Run jedi's rename fixture tests against zuban.
#
# Usage:
#   bash scripts/run_jedi_rename_tests.sh [--jedi-dir <path>] [--no-build] [pytest args...]
#
# Options:
#   --jedi-dir <path>   Path to jedi checkout (default: ../jedi)
#   --no-build          Skip cargo build, use existing target/debug/zuban
#
# Any remaining arguments are forwarded to pytest.
#
# Example:
#   bash scripts/run_jedi_rename_tests.sh -v -k simple

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZUBAN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JEDI_DIR=""
NO_BUILD=0
PYTEST_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jedi-dir)
            JEDI_DIR="$2"; shift 2 ;;
        --no-build)
            NO_BUILD=1; shift ;;
        *)
            PYTEST_ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$JEDI_DIR" ]]; then
    JEDI_DIR="$(cd "$ZUBAN_DIR/../jedi" 2>/dev/null && pwd)" || {
        echo "Error: could not find jedi checkout. Use --jedi-dir <path>" >&2
        exit 1
    }
fi

BINARY="$ZUBAN_DIR/target/debug/zuban"

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "Building zuban..."
    cargo build --manifest-path "$ZUBAN_DIR/Cargo.toml"
fi

if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

TYPESHED="$ZUBAN_DIR/third_party/typeshed"
if [[ ! -d "$TYPESHED" ]]; then
    echo "Error: typeshed not found at $TYPESHED" >&2
    exit 1
fi

echo "Running jedi rename tests against $BINARY..."
cd "$JEDI_DIR"
ZUBAN_TYPESHED="$TYPESHED" python3 -m pytest test/test_lsp_rename.py \
    --lsp-cmd="$BINARY server" \
    "${PYTEST_ARGS[@]}"
