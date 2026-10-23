#!/usr/bin/env python3
"""A size ratchet on the two hot files (the ready-queue plan, mechanism 4).

Gate1AppModel.swift and Gate1RootView.swift are edited by most streams, and every commit that grew
the model file added 1 to 13 lines, so a fixed allowance wouldn't hold. Each file's ceiling is the
smallest size it has had on next since the ratchet started. A change may not grow a hot file above
its ceiling: move the same number of lines out, or ask the desk for the `hot-file-ok` label. A file
already above its ceiling (after a hot-file-ok) may not grow further.
Kill rule (the desk's): if most PRs that touch these files get hot-file-ok, the ratchet is wrong
and gets dropped.

  scripts/hot_file_ratchet.py               this branch's committed files against the trunk (origin/main)
  scripts/hot_file_ratchet.py --base REF    against another ref

The lane runner runs next's copy of this check in automerge runs, before any build.
Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HOT_FILES = ('App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift',
             'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift')
RATCHET_START = '2a4ee13ec923406dde8321ac4890020bd70942f7'  # next when the ratchet started, 2026-09-29
OVERRIDE = 'hot-file-ok'


def _git(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True)


def lines_at(root: Path, ref: str, path: str) -> int | None:
    shown = _git(root, 'show', f'{ref}:{path}')
    return shown.stdout.count('\n') if shown.returncode == 0 else None


def ceiling(root: Path, base: str, path: str, start: str = RATCHET_START) -> int | None:
    """The smallest size the file has had on <base>'s first-parent history since <start>.

    If <start> isn't in <base>'s history (a shallow or unrelated clone), the size on <base> is the ceiling.
    """
    if _git(root, 'merge-base', '--is-ancestor', start, base).returncode != 0:
        return lines_at(root, base, path)
    changed = _git(root, 'log', '--first-parent', '--format=%H', f'{start}..{base}', '--', path).stdout.split()
    sizes = [size for size in (lines_at(root, commit, path) for commit in [start, *changed]) if size is not None]
    return min(sizes) if sizes else None


def size_after_merge(root: Path, base: str, head: str, path: str) -> int | None:
    """The file's size once <head> merges into <base>: <base>'s size plus <head>'s own net change.

    Exact for a clean merge, and exactly <head>'s size when <head> already contains <base> (the runner's
    merged tree). A branch that is behind next isn't blamed for next's newer changes.
    """
    merge_base = _git(root, 'merge-base', base, head).stdout.strip()
    sizes = [lines_at(root, ref, path) for ref in (base, head, merge_base)]
    if None in sizes:
        return sizes[1]
    on_base, on_head, at_fork = sizes
    return on_base + on_head - at_fork


def violations(root: Path, base: str, head: str = 'HEAD', labels=(), start: str = RATCHET_START) -> list[str]:
    """What's wrong with <head>'s hot files, one line each; empty when it passes."""
    if OVERRIDE in labels:
        return []
    found = []
    for path in HOT_FILES:
        limit, on_base = ceiling(root, base, path, start), lines_at(root, base, path)
        now = size_after_merge(root, base, head, path)
        if None in (limit, on_base, now):
            continue
        allowed = max(limit, on_base)
        if now > allowed:
            found.append(f'{Path(path).name} would be {now} lines, above its ceiling of {limit} (its smallest on '
                         f'next since the ratchet started; next has {on_base}). Move {now - allowed} lines out of '
                         f'it, or ask the desk for the {OVERRIDE} label.')
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--base', help='the base ref (default: origin/<trunk>)')
    args = parser.parse_args(argv)
    if args.base is None:  # #1492: the trunk (scripts/trunk.py)
        from trunk import trunk_ref
        args.base = trunk_ref()
    found = violations(ROOT, args.base)
    for path in HOT_FILES:
        print(f'{Path(path).name}: {size_after_merge(ROOT, args.base, "HEAD", path)} lines after merging, ceiling '
              f'{ceiling(ROOT, args.base, path)}, {lines_at(ROOT, args.base, path)} on {args.base}')
    for line in found:
        print(f'FAIL {line}')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
