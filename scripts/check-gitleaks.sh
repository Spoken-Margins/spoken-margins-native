#!/usr/bin/env bash
# Scans the repository for committed secrets with gitleaks and the checked-in .gitleaks.toml (#1839).
#
# By default it scans the files git would publish: tracked files plus untracked ones that .gitignore
# doesn't exclude, linked into a temporary folder so local output (artifacts/, .build, .venv) stays out
# of the scan, as it is out of a fresh clone. With --all-refs it scans every commit on every ref instead.
# Exits 0 on a clean scan, 1 on any hit and 2 if it couldn't set up the scan. When gitleaks isn't
# installed it says so and exits 0, so it can be called from places that may lack the tool; hosted CI
# installs it.
#
# On demand only: nothing schedules it, and it isn't in the fast plan. The tree scan takes from half a
# minute to a few minutes on the Mac, depending on load.
#
# Usage: scripts/check-gitleaks.sh [--all-refs]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/.gitleaks.toml"
ALL_REFS=0
if [[ "${1:-}" == "--all-refs" ]]; then ALL_REFS=1; shift; fi
if [[ $# -gt 0 ]]; then
  echo "usage: scripts/check-gitleaks.sh [--all-refs]" >&2
  exit 2
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks not installed, skipped (brew install gitleaks)"
  exit 0
fi

if [[ $ALL_REFS -eq 1 ]]; then
  exec gitleaks git --config "$CONFIG" --redact --no-banner --verbose --log-opts="--all" "$ROOT"
fi

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-tree.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
# cpio won't write through a symlink, and TMPDIR sits under one (/var -> /private/var).
TEMP="$(cd "$TEMP" && pwd -P)"
LIST="$TEMP/files"
WORK="$TEMP/tree"
mkdir "$WORK"
cd "$ROOT"
# Tracked files deleted in the working tree are still listed; skip them.
git ls-files -z --deduplicate --cached --others --exclude-standard \
  | while IFS= read -r -d '' path; do
      if [[ -e "$path" || -L "$path" ]]; then printf '%s\0' "$path"; fi
    done > "$LIST"
# Hard links, not copies: the tree is about 240 MB and disk is often tight. cpio can skip a file and
# still exit 0, so count what arrived; an incomplete tree would scan clean and hide a hit.
cpio -p -d -l -0 --quiet "$WORK" < "$LIST" \
  || { echo "check-gitleaks: linking the tree failed" >&2; exit 2; }
expected="$(tr -cd '\0' < "$LIST" | wc -c | tr -d ' ')"
arrived="$(find "$WORK" \( -type f -o -type l \) | wc -l | tr -d ' ')"
if [[ "$expected" != "$arrived" ]]; then
  echo "check-gitleaks: linked $arrived of $expected files; is TMPDIR on another volume?" >&2
  exit 2
fi
cd "$WORK"
gitleaks dir --config "$CONFIG" --redact --no-banner --verbose .
