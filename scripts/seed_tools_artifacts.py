#!/usr/bin/env python3
"""Let the SessionKitTools build reuse the binary targets SessionKit's own build already downloaded (#4664).

`run-sessionkit-tests.sh --tools` builds Packages/SessionKitTools into `.build/tools`, a scratch folder of its own,
so SwiftPM fetches the onnxruntime binary targets (download.onnxruntime.ai) a second time, after `package` has
already built them. On 2026-11-21 that host served an invalid certificate: `package` passed from the cache and
`tools` failed on the download, so `hosted fast: Mac rest` failed on every merge group, and the cache that would
have fixed it can only be saved by a run that passes.

SwiftPM records each downloaded binary target in `workspace-state.json` (package, target, source URL and checksum,
and the extracted folder's absolute path) and downloads nothing for a target whose entry matches the manifest and
whose folder exists. This copies SessionKit's entries into the tools scratch's state, pointing at the folders where
they already are, for every entry whose folder exists. Nothing is copied and no file but the tools state is written.
An entry the tools state already has is kept as it is. Best effort: any problem prints one line and leaves the
state alone, so the build downloads as it always did. Never touches a real Library or any listener data.

  scripts/seed_tools_artifacts.py <SessionKit workspace-state.json> <tools workspace-state.json>
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def entry_key(entry: dict) -> tuple:
    ref = entry.get('packageRef') or {}
    return ref.get('identity'), entry.get('targetName')


def read_state(path: Path) -> dict | None:
    try:
        state = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or not isinstance(state.get('object'), dict):
        return None
    return state


def seed(source: Path, target: Path) -> str:
    """Adds the source's usable artifact entries to the target's state. Returns a one-line account."""
    held = read_state(source)
    if held is None:
        return f'no usable SessionKit state at {source}; nothing to reuse'
    usable = [entry for entry in held['object'].get('artifacts', [])
              if isinstance(entry, dict) and entry_key(entry)[0] and entry_key(entry)[1]
              and isinstance(entry.get('path'), str) and Path(entry['path']).exists()]
    if not usable:
        return 'SessionKit holds no downloaded binary targets; nothing to reuse'
    state = read_state(target) if target.exists() else None
    if target.exists() and state is None:
        return f'the tools state at {target} is unreadable; left alone'
    if state is None:  # the same keys the source has, none of its dependencies: SwiftPM resolves those itself
        state = {'version': held.get('version', 7), 'object': {key: [] for key in held['object']}}
    artifacts = state['object'].setdefault('artifacts', [])
    present = {entry_key(entry) for entry in artifacts if isinstance(entry, dict)}
    added = [entry for entry in usable if entry_key(entry) not in present]
    if not added:
        return 'the tools state already holds every binary target SessionKit has'
    artifacts.extend(added)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n', encoding='utf-8')
    temporary.replace(target)
    return 'reusing SessionKit\'s binary targets: ' + ', '.join(sorted(f'{a}/{b}' for a, b in map(entry_key, added)))


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        print(f'seed-tools-artifacts: {seed(Path(argv[1]), Path(argv[2]))}', flush=True)
    except Exception as error:  # noqa: BLE001 - best effort: the build then downloads as before
        print(f'seed-tools-artifacts: skipped ({error!r}); the build will download as before', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
