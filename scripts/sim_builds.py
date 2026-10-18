#!/usr/bin/env python3
"""Ready-made simulator builds of the base branch's tip, kept so desks install instead of building.

Stdlib only, Python 3.9+. The integration run (ops/testdesk/sm_integration_run.py) calls store() after a
good simulator build of a tip. Only SpokenMarginsApp.app is copied, never DerivedData. The newest two
builds are kept, each in `<root>/<sha7>/` with a `build.json`, and `<root>/latest` points at the newest.
scripts/sim-build-latest reads them.

Root: SM_SIM_BUILDS, else <ops home>/sim-builds (~/SpokenMarginsOps/sim-builds).
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from typing import Optional

import sm_paths

APP_NAME = 'SpokenMarginsApp.app'
KEEP = 2
MIN_FREE_BYTES = 10 * 1024 ** 3      # ops/disk: no copy below 10 GB free
LATEST = 'latest'
SHA_RE = re.compile(r'[0-9a-f]{40}')


def root() -> Path:
    setting = os.environ.get('SM_SIM_BUILDS', '').strip()
    return Path(os.path.expanduser(setting)) if setting else sm_paths.ops_home() / 'sim-builds'


def tree_bytes(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob('*') if f.is_file() and not f.is_symlink())


def builds(folder: Path) -> list[dict]:
    """Kept builds, newest first: {'sha', 'branch', 'built_at', 'size_bytes', 'app', 'dir'}."""
    found = []
    if not folder.is_dir():
        return found
    for entry in folder.iterdir():
        if entry.is_symlink() or not entry.is_dir() or entry.name.endswith('.partial'):
            continue
        try:
            record = json.loads((entry / 'build.json').read_text())
        except (OSError, ValueError):
            continue
        app = entry / APP_NAME
        if SHA_RE.fullmatch(record.get('sha', '')) and app.is_dir():
            found.append(dict(record, app=str(app), dir=str(entry)))
    return sorted(found, key=lambda b: b.get('built_at', 0), reverse=True)


def latest(folder: Path) -> Optional[dict]:
    kept = builds(folder)
    return kept[0] if kept else None


def find(folder: Path, sha: str) -> Optional[dict]:
    """The kept build of exactly this commit (a full SHA, or a prefix of at least 7)."""
    sha = sha.strip().lower()
    if not re.fullmatch(r'[0-9a-f]{7,40}', sha):
        return None
    return next((b for b in builds(folder) if b['sha'].startswith(sha)), None)


def store(app: Path, sha: str, branch: str, folder: Path, *, free_bytes: int,
          keep: int = KEEP, now: Optional[float] = None) -> dict:
    """Copy one built .app in as `sha`'s build, point `latest` at it and drop all but the newest `keep`.

    Returns {'stored': bool, 'why' or the build record}. Never deletes the build it just stored."""
    if not SHA_RE.fullmatch(sha):
        return {'stored': False, 'why': f'not a full SHA: {sha!r}'}
    if not (app / 'Info.plist').is_file():
        return {'stored': False, 'why': f'no built app at {app}'}
    if free_bytes < MIN_FREE_BYTES:
        return {'stored': False, 'why': f'{free_bytes / 1024 ** 3:.1f} GB free, under the 10 GB floor'}
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / sha[:7]
    partial = folder / f'{sha[:7]}.partial'
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir()
    # ditto keeps the bundle's symlinks, modes and extended attributes, so the signed app installs as built.
    subprocess.run(['ditto', str(app), str(partial / APP_NAME)], check=True, timeout=600,
                   stdin=subprocess.DEVNULL, capture_output=True)
    record = {'sha': sha, 'branch': branch, 'built_at': now if now is not None else time.time(),
              'size_bytes': tree_bytes(partial / APP_NAME)}
    (partial / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    shutil.rmtree(target, ignore_errors=True)
    partial.rename(target)
    link = folder / f'{LATEST}.tmp'
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target.name)
    link.replace(folder / LATEST)
    removed = []
    for old in builds(folder)[keep:]:
        if Path(old['dir']) != target:
            shutil.rmtree(old['dir'], ignore_errors=True)
            removed.append(old['sha'][:7])
    for stale in folder.glob('*.partial'):  # a copy cut off by a restart
        if stale != partial:
            shutil.rmtree(stale, ignore_errors=True)
    return dict(record, stored=True, app=str(target / APP_NAME), removed=removed)
