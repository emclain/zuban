#!/usr/bin/env bash
# Create jedi's Python venv (with pytest and jedi's test deps) if it is missing.
#
# Usage:
#   bash scripts/setup-jedi-venv.sh [jedi-dir]
#
# jedi-dir defaults to ../jedi. agent-start.sh runs this; run it by hand when
# run_jedi_rename_tests.sh reports a missing venv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JEDI_DIR="${1:-$SCRIPT_DIR/../../jedi}"

if [[ ! -d "$JEDI_DIR" ]]; then
    echo "Error: jedi checkout not found at $JEDI_DIR" >&2
    exit 1
fi
JEDI_DIR="$(cd "$JEDI_DIR" && pwd)"

if [[ -x "$JEDI_DIR/.venv/bin/python" ]]; then
    exit 0
fi

echo "Setting up jedi Python venv..."
python3 -m venv "$JEDI_DIR/.venv"
"$JEDI_DIR/.venv/bin/pip" install -q -e "$JEDI_DIR/[testing]"
