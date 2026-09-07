#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/bootstrap-python-tools.sh"
PYTHON="$ROOT/.venv/bin/python"
DEVICE_ARGS=()
if [[ -n "${PHONE_UDID:-${DEVICE_UDID:-}}" ]]; then
  DEVICE_ARGS=(--device "${PHONE_UDID:-$DEVICE_UDID}")
fi
# XCUITest proves the Library is reachable/hittable and attaches its screenshot.
# The runner builds into an exact path and reuses compatible test products.
"$PYTHON" "$ROOT/scripts/verify-tests.py" --plan smoke "${DEVICE_ARGS[@]}"
