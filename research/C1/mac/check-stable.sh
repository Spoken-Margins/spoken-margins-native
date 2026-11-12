#!/bin/sh
# (Mac) Reads each C1 PDF three times in one process with the app's current
# extractor (v2) and fails if the spoken lines differ between reads (#3970).
#
#   research/C1/mac/check-stable.sh            # whole corpus
#   research/C1/mac/check-stable.sh --only pmc-pmc11639692
#
# Needs the corpus fetched first (research/C1/mac/run.sh, or tools/fetch.py).
# Writes the same cache/candidates/app-v2/ files run.sh does.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
c1=$(cd "$here/.." && pwd)
"$here/sync-app-sources.sh"
swift build --package-path "$here" -c release
"$here/.build/release/c1-extract" --root "$c1" --v2 --repeat 3 "$@"
