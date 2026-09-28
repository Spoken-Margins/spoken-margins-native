#!/bin/sh
# (Mac) Runs the app's current PDF extractor over the C1 corpus and scores it.
#
#   research/C1/mac/run.sh            # whole corpus
#   research/C1/mac/run.sh --only pmc-pmc10756530
#
# Needs Xcode's Swift toolchain (macOS 15+) and python3. First run downloads
# the corpus (~300 MB) into research/C1/cache/, which git ignores.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
c1=$(cd "$here/.." && pwd)

if [ ! -x "$c1/.venv/bin/python" ]; then
    python3 -m venv "$c1/.venv"
    "$c1/.venv/bin/pip" install --quiet -r "$c1/requirements.txt"
fi
py="$c1/.venv/bin/python"

"$py" "$c1/tools/fetch.py"
"$here/sync-app-sources.sh"
swift build --package-path "$here" -c release
"$here/.build/release/c1-extract" --root "$c1" "$@"
"$py" "$c1/tools/score.py" --extractor app-baseline "$@"
"$py" "$c1/tools/report.py"
echo "Scores: research/C1/results/app-baseline/scores.json; report: research/C1/results/REPORT.md"
