#!/usr/bin/env python3
"""Keep a worktree's build folders where the disk-relief job can clear them.

The disk-relief job (ops/disk/sm_disk_relief.py) runs from launchd without Full Disk Access, by the
owner's call (2026-10-14), so macOS refuses it everything in ~/Documents. Every worktree lives there,
and so did their build folders: on 2026-10-19 about 20 GiB of `.build` and `Packages/SessionKit/.build`
sat in .claude/worktrees while every run reported "cleared 0 MiB".

So a worktree under ~/Documents gets its two build folders as links into this Mac's cache folder:

    <worktree>/.build                    -> ~/Library/Caches/SpokenMarginsBuilds/<slot>/root
    <worktree>/Packages/SessionKit/.build -> ~/Library/Caches/SpokenMarginsBuilds/<slot>/sessionkit

One slot per worktree path (its folder name plus a hash of the path), so each worktree keeps its own
DerivedData (AGENTS.md: a shared one gives false "does not conform" errors). `<slot>/owner.txt` names
the worktree, which is how disk relief tells a slot whose worktree is gone. Every tool keeps using the
same paths (`.build/dd`, `.build/verification/...`, `Packages/SessionKit/.build/debug/...`).

Left alone: a worktree outside ~/Documents (the lane's runner workspaces, which link `.build` to the
lane's own warm cache, and Codex worktrees in ~/.codex, which the job can read), an existing link, and
an existing real folder that a build may be using. An idle real folder is moved into the slot: a rename
on the same disk, so nothing is copied.

Settings: SM_BUILD_CACHE=off turns linking off; SM_BUILD_CACHE_ROOT moves the cache folder;
SM_BUILD_CACHE_UNDER changes which worktrees are linked (default ~/Documents). Tests use all three.

CLI:  scripts/sm_build_cache.py link [worktree]   (setup-worktree.sh calls it)
      scripts/sm_build_cache.py slot [worktree]   (prints the slot folder)
"""
from __future__ import annotations

import fcntl
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import List, Optional, Tuple

FOLDERS = (('.build', 'root'), ('Packages/SessionKit/.build', 'sessionkit'))
OWNER_FILE = 'owner.txt'
# A real folder changed this recently may belong to a build in progress: it isn't moved.
MOVE_IDLE_SECONDS = 10 * 60


def cache_root() -> Path:
    value = os.environ.get('SM_BUILD_CACHE_ROOT')
    return Path(os.path.expanduser(value)) if value else Path.home() / 'Library/Caches/SpokenMarginsBuilds'


def linked_area() -> Path:
    value = os.environ.get('SM_BUILD_CACHE_UNDER')
    return Path(os.path.expanduser(value)) if value else Path.home() / 'Documents'


def _real(path: Path) -> Path:
    return Path(os.path.realpath(str(path)))


def slot_name(worktree: Path) -> str:
    """`<folder name>-<12 hex of the real path's SHA-256>`; Codex-style `<id>/spoken-margins-native` keeps the id."""
    path = _real(worktree)
    name = path.name if path.name != 'spoken-margins-native' else f'{path.parent.name}-{path.name}'
    name = re.sub(r'[^A-Za-z0-9._-]+', '-', name)[:60] or 'worktree'
    return f'{name}-{hashlib.sha256(str(path).encode()).hexdigest()[:12]}'


def slot_for(worktree: Path) -> Path:
    return cache_root() / slot_name(worktree)


def applies_to(worktree: Path) -> bool:
    if os.environ.get('SM_BUILD_CACHE', '').strip().lower() in ('off', '0', 'no') or os.environ.get('GITHUB_ACTIONS'):
        return False
    area = str(_real(linked_area())).rstrip('/') + '/'
    return str(_real(worktree)).startswith(area)


def _newest_mtime(path: Path, newer_than: float) -> float:
    """The newest mtime under path, stopping early once one is newer than newer_than."""
    newest = 0.0
    stack = [str(path)]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            try:
                st = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            newest = max(newest, st.st_mtime)
            if newest > newer_than:
                return newest
            if entry.is_dir(follow_symlinks=False):
                stack.append(entry.path)
    return newest


def _verification_lock_free(build: Path) -> bool:
    """False while verify-tests holds `.build/verification.lock` in this worktree."""
    lock = build / 'verification.lock'
    if not lock.exists():
        return True
    try:
        with lock.open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
        return True
    except OSError:
        return False


def _move_in(folder: Path, target: Path) -> Optional[str]:
    """Move an idle real build folder into its empty slot folder; returns why not, or None when moved."""
    if any(target.iterdir()):
        return f'{target} already holds a build'
    if not _verification_lock_free(folder):
        return 'verify-tests is running in this worktree'
    if _newest_mtime(folder, time.time() - MOVE_IDLE_SECONDS) > time.time() - MOVE_IDLE_SECONDS:
        return 'it changed in the last 10 minutes'
    try:
        target.rmdir()
        os.rename(folder, target)
    except OSError as error:
        target.mkdir(parents=True, exist_ok=True)
        return f'could not move it ({error.strerror})'
    return None


def ensure_links(worktree: Path, log=None) -> List[Tuple[Path, str]]:
    """Link the worktree's two build folders into its slot. Returns (link, what happened) for each folder."""
    worktree = Path(worktree)
    if not applies_to(worktree):
        return []
    slot = slot_for(worktree)
    done = []
    try:
        slot.mkdir(parents=True, exist_ok=True)
        owner = slot / OWNER_FILE
        if not owner.exists() or owner.read_text().strip() != str(_real(worktree)):
            owner.write_text(str(_real(worktree)) + '\n')
    except OSError as error:
        return [(worktree, f'no cache folder ({error.strerror}); building in the worktree')]
    for relative, name in FOLDERS:
        link, target = worktree / relative, slot / name
        target.mkdir(exist_ok=True)
        if link.is_symlink():
            if _real(link) == _real(target):
                continue  # linked already; a cleared slot was recreated above
            done.append((link, 'linked elsewhere (the lane); left alone'))
            continue
        if not link.parent.is_dir():
            continue  # an old checkout without SessionKit
        if link.exists():
            why = _move_in(link, target) if link.is_dir() else 'not a folder'
            if why:
                done.append((link, f'kept in the worktree: {why}'))
                continue
        link.symlink_to(target, target_is_directory=True)
        done.append((link, f'linked to {target}'))
    if log:
        for link, what in done:
            log(f'[build-cache] {link}: {what}')
    return done


def worktree_root(start: Optional[Path] = None) -> Optional[Path]:
    try:
        out = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True, cwd=start,
                                      stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return Path(out) if out else None


def main(argv: List[str]) -> int:
    if not argv or argv[0] not in ('link', 'slot'):
        print(__doc__.strip().splitlines()[0])
        print('usage: sm_build_cache.py link|slot [worktree]', file=sys.stderr)
        return 2
    tree = Path(argv[1]) if len(argv) > 1 else worktree_root()
    if tree is None:
        print('not inside a git checkout', file=sys.stderr)
        return 1
    if argv[0] == 'slot':
        print(slot_for(tree))
        return 0
    if not applies_to(tree):
        print(f'build folders stay in the worktree ({tree} is outside {linked_area()}, or linking is off)')
        return 0
    results = ensure_links(tree)
    for link, what in results:
        print(f'{link.relative_to(tree)}: {what}')
    if not results:
        print(f'build folders: already linked to {slot_for(tree)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
