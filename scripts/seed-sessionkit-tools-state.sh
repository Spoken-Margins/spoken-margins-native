#!/usr/bin/env bash
# Give Packages/SessionKitTools' scratch folder (SessionKit/.build/tools) the SwiftPM state of SessionKit's own .build,
# so the tools build reuses the onnxruntime binary artifacts the SessionKit build already has (#4664).
#
# Both packages resolve the same binary targets (SessionKitTools depends only on SessionKit). SwiftPM won't fetch an
# artifact its workspace state says it has, at the path the state records (lane-runner.py missing_binary_artifacts, #405),
# and the state records absolute paths, so a copy of SessionKit's state points the tools build at the artifacts that
# are already on disk. Without it `tools` downloads them again from download.onnxruntime.ai, whose certificate was
# invalid on 2026-11-21 and failed the merge queue's Mac job 6 s after `package` had passed.
#
# Only when the tools folder has no state of its own (a warm .build/tools keeps its state) and SessionKit's state lists
# artifacts that exist on disk. Anything else leaves the folder alone, so a cold run behaves as before.
# usage: seed-sessionkit-tools-state.sh <Packages/SessionKit directory>
set -euo pipefail
package=${1:?usage: $0 <Packages/SessionKit directory>}
state="$package/.build/workspace-state.json"
tools="$package/.build/tools"
[[ -f "$state" ]] || { echo "tools state: not seeded (no $state)"; exit 0; }
[[ ! -f "$tools/workspace-state.json" ]] || { echo "tools state: kept (the tools folder has its own)"; exit 0; }
python3 - "$state" <<'PY' || { echo "tools state: not seeded (SessionKit's state lists no artifact on disk)"; exit 0; }
import json, os, sys
artifacts = json.load(open(sys.argv[1])).get('object', {}).get('artifacts', [])
paths = [a.get('path') for a in artifacts if isinstance(a, dict) and a.get('path')]
sys.exit(0 if paths and all(os.path.exists(p) for p in paths) else 1)
PY
mkdir -p "$tools"
cp "$state" "$tools/workspace-state.json"
echo "tools state: seeded from SessionKit's, so its binary artifacts are not fetched again"
