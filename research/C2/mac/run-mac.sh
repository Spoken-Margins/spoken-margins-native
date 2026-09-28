#!/bin/sh
# (Mac) Full M2 Mac pass: set up, fetch models, benchmark every candidate,
# render Samantha, rebuild the listening page with the Samantha clip.
# Takes about 20 minutes on an Apple-silicon Mac. Plug in power; close heavy apps.
set -e
cd "$(dirname "$0")/.."
[ -x .venv/bin/python ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
.venv/bin/pip install -q https://huggingface.co/spacy/en_core_web_sm/resolve/main/en_core_web_sm-any-py3-none-any.whl
./fetch_models.sh
./run_all.sh
./mac/samantha.sh
.venv/bin/python intelligibility.py
.venv/bin/python build_page.py
.venv/bin/python summarize.py darwin > results/darwin/summary.md
echo "Done. Commit results/ and listening/, then republish listening/index.html to the same artifact URL (see README)."
