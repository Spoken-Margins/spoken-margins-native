#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/bootstrap-python-tools.sh"
PYTHON="$ROOT/.venv/bin/python"
DEVICE_ARGS=()
if [[ -n "${PHONE_UDID:-${DEVICE_UDID:-}}" ]]; then
  DEVICE_ARGS=(--device "${PHONE_UDID:-$DEVICE_UDID}")
fi
# Preserve the historical entrypoint with current, inventoried selections.
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan fast
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan app "${DEVICE_ARGS[@]}"
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan adapters "${DEVICE_ARGS[@]}"
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan ui "${DEVICE_ARGS[@]}"
