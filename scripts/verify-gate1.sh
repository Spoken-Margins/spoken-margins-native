#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/bootstrap-python-tools.sh"
PYTHON="$ROOT/.venv/bin/python"
DEVICE_ARGS=()
if [[ -n "${PHONE_UDID:-${DEVICE_UDID:-}}" ]]; then
  DEVICE_ARGS=(--device "${PHONE_UDID:-$DEVICE_UDID}")
fi
# Closeout requires both form factors; never silently omit the tablet.
if [[ -z "${IPAD_UDID:-}" ]]; then
  echo "Set IPAD_UDID for the required tablet UI gate. See docs/testing.md." >&2
  exit 1
fi
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan release "${DEVICE_ARGS[@]}"
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan ui --device "$IPAD_UDID"
