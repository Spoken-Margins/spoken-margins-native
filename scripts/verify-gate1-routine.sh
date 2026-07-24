#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$ROOT/.venv/bin/python"

"$ROOT/scripts/bootstrap-python-tools.sh"
"$PYTHON" "$ROOT/scripts/validate-contracts.py"
"$PYTHON" "$ROOT/scripts/validate-surface-contracts.py"
"$ROOT/scripts/run-sessionkit-tests.sh"
