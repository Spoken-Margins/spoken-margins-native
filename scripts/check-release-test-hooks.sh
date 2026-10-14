#!/usr/bin/env bash
# Fails if a built app still carries the UI-test launch hooks (#517).
#
#   scripts/check-release-test-hooks.sh path/to/SpokenMarginsApp.app
#
# Run it on a Release build or an archive's app (`.xcarchive/Products/Applications/*.app`). A Debug
# build carries the hooks on purpose, so it is expected to fail. It scans every file in the bundle,
# frameworks included, for the launch argument and the environment-value prefix.
set -euo pipefail

APP="${1:?usage: check-release-test-hooks.sh path/to/App.app}"
[ -d "$APP" ] || { echo "not an app bundle: $APP" >&2; exit 2; }

hits="$(grep -rlaE -e '--ui-testing' -e 'SPOKEN_MARGINS_UI_TEST' "$APP" || true)"
if [ -n "$hits" ]; then
    echo "UI-test hooks found in:" >&2
    echo "$hits" >&2
    exit 1
fi
echo "No UI-test hook literals in $APP"
