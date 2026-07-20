#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$ROOT/scripts/validate-contracts.py"
python3 "$ROOT/scripts/validate-surface-contracts.py"
"$ROOT/scripts/run-sessionkit-tests.sh"
