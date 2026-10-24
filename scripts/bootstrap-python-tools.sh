#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
PYTHON="${PYTHON:-python3}"
REQUIREMENTS="$ROOT/requirements-dev.txt"
INSTALLED_REQUIREMENTS="$VENV/.requirements-dev.txt"

if [[ ! -x "$VENV/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV"
fi

if [[ ! -f "$INSTALLED_REQUIREMENTS" ]] \
  || ! cmp -s "$REQUIREMENTS" "$INSTALLED_REQUIREMENTS" \
  || ! "$VENV/bin/python" -c 'import jsonschema, rfc3339_validator, rfc3986_validator, yaml'; then
  "$VENV/bin/python" -m pip install \
    --disable-pip-version-check \
    --requirement "$REQUIREMENTS"
  cp "$REQUIREMENTS" "$INSTALLED_REQUIREMENTS"
fi

echo "Python development tools are available in $VENV."
