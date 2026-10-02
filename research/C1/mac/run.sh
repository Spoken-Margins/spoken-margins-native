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

# The pinned PyMuPDF and pdfminer need Python 3.10+; Xcode's python3 is 3.9.
if [ ! -x "$c1/.venv/bin/python" ]; then
    base=""
    for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
            base=$candidate
            break
        fi
    done
    if [ -z "$base" ]; then
        echo "Needs Python 3.10 or later (for example: brew install python@3.12)." >&2
        exit 1
    fi
    "$base" -m venv "$c1/.venv"
    "$c1/.venv/bin/pip" install --quiet -r "$c1/requirements.txt"
fi
py="$c1/.venv/bin/python"

# A failed download or a re-rendered arXiv PDF shouldn't stop the run: both
# steps report what went wrong (run-info.json lists it), and scoring goes on
# with whatever was extracted.
fetch_status=0
"$py" "$c1/tools/fetch.py" || fetch_status=$?
"$here/sync-app-sources.sh"
swift build --package-path "$here" -c release
extract_status=0
"$here/.build/release/c1-extract" --root "$c1" "$@" || extract_status=$?
"$py" "$c1/tools/score.py" --extractor app-baseline "$@"
# C1 M3: extraction v2 (I13 roles, spoken per I14), with v1 timed beside it.
"$here/.build/release/c1-extract" --root "$c1" --v2 "$@" || extract_status=$?
"$py" "$c1/tools/score.py" --extractor app-v2 "$@"
# #272: chapters built from title, author or front-matter lines.
"$py" "$c1/tools/chapters.py" app-v2
"$py" "$c1/tools/report.py"
# C1 M2: fit and evaluate the hard-PDF pre-check on the app's own output.
"$py" "$c1/tools/precheck.py"
"$py" "$c1/tools/precheck.py" --target content
echo "Scores: research/C1/results/app-baseline/scores.json, research/C1/results/app-v2/scores.json; report: research/C1/results/REPORT.md; pre-check: research/C1/results/app-baseline/precheck.json"
if [ "$fetch_status" != 0 ] || [ "$extract_status" != 0 ]; then
    echo "Warning: some PDFs failed to fetch or didn't match the manifest's sha256; see the output above and results/app-baseline/run-info.json." >&2
fi
