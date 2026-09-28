#!/bin/bash
# Make a new worktree ready for host checks (verify-tests.py --plan fast): link the main checkout's
# git-ignored tool folders (.venv, node_modules) into it. Links, not copies: no disk, nothing to sync.
set -euo pipefail
here=$(git rev-parse --show-toplevel)
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if [ "$here" = "$main" ]; then
  echo "This is the main checkout; nothing to link."
  exit 0
fi
for dir in .venv node_modules; do
  if [ -e "$here/$dir" ]; then
    echo "$dir: already present"
  elif [ -d "$main/$dir" ]; then
    ln -s "$main/$dir" "$here/$dir"
    echo "$dir: linked to $main/$dir"
  else
    echo "$dir: missing in the main checkout too. Run scripts/bootstrap-python-tools.sh or npm ci in $main first." >&2
    exit 1
  fi
done
