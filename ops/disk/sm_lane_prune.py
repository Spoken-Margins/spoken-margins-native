#!/usr/bin/env python3
"""Lane folder cap: keep ~/Library/Caches/SpokenMarginsLane under one size, and age out lane evidence (#1775).

On 2026-10-16 the lane folder grew from 10 GB to 23 GB in a working day while the Mac's free disk fell from
73 GB to 31 GB. Lane evidence (6.2 GB) was never pruned, and the warm builds were capped only per checkout
and cleared only at 15 GB free, below the 20 GiB at which the Mac finisher pauses.

What it does, in order (the cap is LANE_CAP_BYTES, documented in docs/workstreams/test-lane.md):

1. Warm-build folders (`warm-build/checkout-*`) for a checkout that no longer exists, once every cache in
   them is idle and untouched for a day. Only when the caller names the checkouts that do exist.
2. Evidence folders (`pr<PR>-r<run>[-a<N>][-auto]`) older than EVIDENCE_MAX_AGE, in the lane folder's
   `evidence/` and in `artifacts/lane/`. Never the latest run's folders for an open PR.
3. Only while the lane folder is over the cap: idle warm-build caches, oldest first, across all checkouts.
   The newest cache of each checkout stays, and a cache a job holds (its `.lock` flock) is never touched.
   Run before a build (the lane runner's call, and any command-line run), it also leaves room under the cap for
   the cache that build may make (BUILD_ROOM_BYTES), so the folder stays under the cap while the build runs.
4. Only if that is not enough: the oldest remaining evidence in the lane folder, still never the latest
   run of an open PR and never anything changed in the last hour.

It never touches the state files in the lane folder (slot locks, step-ledger.json, unsafe-simulators.json,
desk-simulator-pool.json, guard.log, inherited-holds.json, ...), and never `compilation-cache/`, which Xcode
bounds itself and which a running build uses. Anything it cannot read is skipped and listed.

Stdlib only, Python 3.9+. The disk relief job calls it on every run; the lane runner can call it too.
`--dry-run` lists what it would do and changes nothing.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Set, Tuple

GiB = 1024 ** 3
DAY = 86400

# The one number: the lane folder's total size. It holds warm builds, the compilation cache (about 6 GB,
# bounded by Xcode), evidence and state. A warm cache that takes an app build is 3 to 4 GB.
LANE_CAP_BYTES = 16 * GiB
EVIDENCE_MAX_AGE = 7 * DAY
# Room left under the cap before a build: one new app-build warm cache. Pruning only to the cap let each build
# take the folder over it until the next run: up to 19.5 GiB on 2026-10-18 and 10-19, against the 16 GiB cap.
BUILD_ROOM_BYTES = int(3.5 * GiB)
# When GitHub can't be asked which PRs are open, keep the latest run of any PR seen in this long.
UNKNOWN_OPEN_PR_KEEP = 30 * DAY
# A checkout folder nothing in this Mac's checkouts or runners maps to, idle for this long, is dropped.
ORPHAN_IDLE = DAY
# Evidence a job may still be writing.
ACTIVE_WINDOW = 3600

TOMBSTONE = '.deleting-'
REQUEST_ID = re.compile(r'^pr(\d+)-r(\d+)(?:-a\d+)?(?:-auto)?$')
DEFAULT_REPO = 'Spoken-Margins/spoken-margins-native'


def real(path) -> Path:
    return Path(os.path.realpath(str(path)))


def checkout_folder(tree: Path) -> str:
    """Same name scripts/lane-runner.py's checkout_folder gives a checkout's cache folder."""
    return 'checkout-' + hashlib.sha1(str(real(tree)).encode()).hexdigest()[:8]


def cache_busy(cache: Path) -> bool:
    """Same test scripts/lane-runner.py's _cache_busy uses: a job holds the cache's `.lock` flock.
    A cache with no `.lock` was never taken by a job; looking must not create one, which would make the folder
    look just used."""
    if not (cache / '.lock').exists():
        return False
    try:
        with open(cache / '.lock', 'a+') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    except OSError:
        return False


def disk_bytes(path: Path) -> int:
    """Blocks on disk under path, links not followed: what deleting it frees."""
    total = 0
    try:
        total += os.lstat(path).st_blocks * 512
    except OSError:
        return 0
    if os.path.islink(path) or not os.path.isdir(path):
        return total
    stack = [str(path)]
    while stack:
        try:
            entries = list(os.scandir(stack.pop()))
        except OSError:
            continue
        for entry in entries:
            try:
                total += entry.stat(follow_symlinks=False).st_blocks * 512
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
            except OSError:
                continue
    return total


def newest_mtime(path: Path, newer_than: Optional[float] = None) -> float:
    """The newest mtime under path (links not followed). With newer_than, stops at the first newer one."""
    try:
        newest = os.lstat(path).st_mtime
    except OSError:
        return 0.0
    if os.path.islink(path) or not os.path.isdir(path):
        return newest
    stack = [str(path)]
    while stack:
        try:
            entries = list(os.scandir(stack.pop()))
        except OSError:
            continue
        for entry in entries:
            try:
                newest = max(newest, entry.stat(follow_symlinks=False).st_mtime)
                if newer_than is not None and newest > newer_than:
                    return newest
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
            except OSError:
                continue
    return newest


def size_text(n: int) -> str:
    return f'{n / GiB:.1f} GiB' if n >= GiB else f'{n / 1024 ** 2:.0f} MiB'


def open_pull_requests(repo: str = DEFAULT_REPO) -> Optional[Set[int]]:
    """Numbers of the open PRs, from `gh`; None when it can't be asked (then nothing counts as closed)."""
    path = os.pathsep.join([os.environ.get('PATH', ''), '/opt/homebrew/bin', '/usr/local/bin'])
    gh = shutil.which('gh', path=path)
    if not gh:
        return None
    try:
        done = subprocess.run([gh, 'pr', 'list', '--repo', repo, '--state', 'open', '--limit', '1000',
                               '--json', 'number', '--jq', '.[].number'],
                              capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    return {int(line) for line in done.stdout.split() if line.isdigit()}


@dataclass
class Item:
    kind: str            # 'orphan-checkout', 'warm-cache' or 'evidence'
    path: Path
    size: int
    why: str


@dataclass
class Plan:
    items: List[Item] = field(default_factory=list)
    skipped: List[str] = field(default_factory=list)
    total: int = 0       # the lane folder before acting
    after: int = 0       # and what the plan leaves of it
    cap: int = LANE_CAP_BYTES
    room: int = 0        # bytes kept free under the cap for a build about to start
    warm_dir: Optional[Path] = None

    @property
    def over_cap(self) -> bool:
        return self.after > self.cap


def mtime(path: Path) -> float:
    """The folder's own mtime; 0 when it vanished (a runner prunes its caches too)."""
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def checkout_caches(checkout: Path) -> List[Path]:
    """The checkout's warm caches, oldest first."""
    try:
        found = [d for d in checkout.iterdir() if d.is_dir() and not d.is_symlink() and d.name.startswith('sk-')]
    except FileNotFoundError:
        return []
    return sorted(found, key=mtime)


def unreadable(error: OSError, fallback: Path) -> str:
    return f'{error.filename or fallback}: macOS will not let this job read it; skipped'


def evidence_folders(directory: Path, skipped: List[str]) -> List[Path]:
    # Under launchd without Full Disk Access even is_dir() raises on ~/Documents (Python 3.9 re-raises EPERM).
    try:
        if not directory.is_dir():
            return []
        return sorted(d for d in directory.iterdir() if d.is_dir() and not d.is_symlink())
    except PermissionError as error:
        skipped.append(unreadable(error, directory))
        return []


def protected_evidence(folders: Iterable[Path], open_prs: Optional[Set[int]], now: float) -> Set[Path]:
    """The latest run's folders (every attempt and its -auto run) of each PR that may be open."""
    newest = {}  # PR -> (mtime, run id)
    runs = []
    for folder in folders:
        match = REQUEST_ID.match(folder.name)
        if not match:
            continue
        pr, run = int(match.group(1)), match.group(2)
        mtime = newest_mtime(folder)
        runs.append((pr, run, folder))
        if pr not in newest or mtime > newest[pr][0]:
            newest[pr] = (mtime, run)
    keep = set()
    for pr, run, folder in runs:
        latest_mtime, latest_run = newest[pr]
        if run != latest_run:
            continue
        if open_prs is not None:
            if pr in open_prs:
                keep.add(folder)
        elif latest_mtime >= now - UNKNOWN_OPEN_PR_KEEP:
            keep.add(folder)
    return keep


def plan_prune(lane_dir: Path, evidence_dirs: Iterable[Path], live_trees: Optional[Iterable[Path]],
               open_prs: Optional[Set[int]], now: float, cap: int = LANE_CAP_BYTES,
               evidence_age: float = EVIDENCE_MAX_AGE, warm_dir: Optional[Path] = None, room: int = 0) -> Plan:
    """What to delete, in order. live_trees are the checkouts the lane builds in; None skips step 1. room is
    kept free under the cap for a build about to start (steps 3 and 4 bring the folder to cap - room)."""
    warm = warm_dir or lane_dir / 'warm-build'
    plan = Plan(cap=cap, room=room, warm_dir=warm)
    room = max(room, 0)  # a negative room would loosen the cap
    plan.room = room
    target = max(cap - room, 0)

    def why() -> str:
        return 'lane folder over its cap' if plan.total - freed > cap else 'room under the cap for a build'
    plan.total = disk_bytes(lane_dir)
    freed = 0  # bytes the plan frees inside the lane folder: only those count against the cap
    lane_prefix = str(lane_dir).rstrip('/') + '/'

    def in_lane_dir(path: Path) -> bool:
        return str(path).startswith(lane_prefix)

    folders = []
    for directory in evidence_dirs:
        folders += evidence_folders(directory, plan.skipped)
    keep = protected_evidence(folders, open_prs, now)
    in_lane = [f for f in folders if in_lane_dir(f)]

    def idle(folder: Path) -> bool:
        return newest_mtime(folder, newer_than=now - ACTIVE_WINDOW) <= now - ACTIVE_WINDOW

    checkouts = []
    try:
        if warm.is_dir():
            checkouts = sorted(d for d in warm.glob('checkout-*') if d.is_dir() and not d.is_symlink())
    except PermissionError as error:
        plan.skipped.append(unreadable(error, warm))

    # 1. Checkout folders nothing on this Mac maps to.
    orphans = set()
    if live_trees is not None:
        live = {checkout_folder(t) for t in live_trees}
        for checkout in checkouts:
            if checkout.name in live:
                continue
            caches = checkout_caches(checkout)
            if any(cache_busy(c) for c in caches):
                plan.skipped.append(f'{checkout}: a job holds a cache in it')
                continue
            if newest_mtime(checkout, newer_than=now - ORPHAN_IDLE) > now - ORPHAN_IDLE:
                plan.skipped.append(f'{checkout}: used in the last day')
                continue
            size = disk_bytes(checkout)
            plan.items.append(Item('orphan-checkout', checkout, size,
                                   'no checkout or runner on this Mac has this path, idle for a day'))
            orphans.add(checkout)
            freed += size

    # 2. Evidence past its age.
    old = set()
    for folder in folders:
        if folder in keep or not idle(folder):
            continue
        if newest_mtime(folder, newer_than=now - evidence_age) <= now - evidence_age:
            size = disk_bytes(folder)
            plan.items.append(Item('evidence', folder, size,
                                   f'lane evidence older than {int(evidence_age // DAY)} days'))
            old.add(folder)
            if in_lane_dir(folder):
                freed += size

    # 3. Over the cap (less the room for a build): idle warm caches, oldest first, the newest of each checkout stays.
    if plan.total - freed > target:
        spare = []
        for checkout in checkouts:
            if checkout in orphans:
                continue
            caches = checkout_caches(checkout)
            for cache in caches[:-1]:
                if cache_busy(cache):
                    plan.skipped.append(f'{cache}: a job holds it')
                else:
                    spare.append((mtime(cache), cache))
        for _, cache in sorted(spare):
            if plan.total - freed <= target:
                break
            size = disk_bytes(cache)
            plan.items.append(Item('warm-cache', cache, size, 'idle warm build, oldest first, ' + why()))
            freed += size

    # 4. Still over: the oldest evidence in the lane folder.
    if plan.total - freed > target:
        rest = sorted((f for f in in_lane if f not in keep and f not in old and idle(f)), key=newest_mtime)
        for folder in rest:
            if plan.total - freed <= target:
                break
            size = disk_bytes(folder)
            plan.items.append(Item('evidence', folder, size, 'oldest lane evidence, ' + why()))
            freed += size

    plan.after = plan.total - freed
    return plan


def remove_cache(cache: Path) -> Tuple[bool, str]:
    """Delete one warm cache while holding its lock. It is first renamed out of the `sk-*` names (same volume,
    atomic), so a job that starts while the delete runs finds no cache, makes a new one and builds cold, rather
    than locking a half-deleted folder."""
    if not (cache / '.lock').exists():
        try:
            (cache / '.lock').touch()
        except OSError as error:
            return False, f'cannot take its lock: {error}'
    try:
        handle = open(cache / '.lock', 'a+')
    except OSError as error:
        return False, f'cannot take its lock: {error}'
    with handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False, 'a job holds it'
        tomb = cache.parent / f'{TOMBSTONE}{cache.name}'
        try:
            shutil.rmtree(tomb, ignore_errors=True)
            cache.rename(tomb)
        except OSError as error:
            return False, f'could not move it aside: {error}'
        shutil.rmtree(tomb, ignore_errors=True)
    return True, 'deleted'


def sweep_tombstones(warm: Path) -> None:
    """Finish deletes an earlier run was cut off in the middle of."""
    try:
        for tomb in warm.glob(f'checkout-*/{TOMBSTONE}*'):
            shutil.rmtree(tomb, ignore_errors=True)
    except OSError:
        pass


def act(item: Item, now: float, log: Callable[[str], None]) -> bool:
    """Delete one planned item after asking again whether it is still safe."""
    if not item.path.exists():
        return False
    if item.kind == 'evidence':
        if newest_mtime(item.path, newer_than=now - ACTIVE_WINDOW) > now - ACTIVE_WINDOW:
            log(f'skip {item.path}: changed in the last hour')
            return False
        shutil.rmtree(item.path, ignore_errors=True)
        return not item.path.exists()
    if item.kind == 'warm-cache':
        ok, message = remove_cache(item.path)
        if not ok:
            log(f'skip {item.path}: {message}')
        return ok
    if item.kind == 'orphan-checkout':
        for cache in checkout_caches(item.path):
            ok, message = remove_cache(cache)
            if not ok:
                log(f'skip {item.path}: {cache.name}: {message}')
                return False
        shutil.rmtree(item.path, ignore_errors=True)
        return not item.path.exists()
    return False


def prune(plan: Plan, now: float, log: Callable[[str], None]) -> int:
    """Carry out a plan; returns the bytes freed."""
    freed = 0
    if plan.warm_dir:
        sweep_tombstones(plan.warm_dir)
    for item in plan.items:
        if act(item, now, log):
            freed += item.size
            log(f'lane {item.kind}: {item.path} {size_text(item.size)} deleted ({item.why})')
    for line in plan.skipped:
        log(f'skip lane {line}')
    if freed or plan.items:
        room = f', room for a build {size_text(plan.room)}' if plan.room else ''
        log(f'lane folder: {size_text(plan.total)} before, cleared {size_text(freed)}, cap {size_text(plan.cap)}{room}')
    if plan.after > plan.cap:
        log(f'lane folder still over its cap: {size_text(plan.after)} left after the plan, cap {size_text(plan.cap)}; '
            'what remains is the compilation cache, state, evidence of open PRs, busy caches and one cache per checkout')
    return freed


def describe(plan: Plan) -> List[str]:
    room = f' less {size_text(plan.room)} of room for a build' if plan.room else ''
    out = [f'Lane folder: {size_text(plan.total)}, cap {size_text(plan.cap)}{room}; the plan leaves {size_text(plan.after)}.']
    for i, item in enumerate(plan.items, 1):
        out.append(f'  {i:3}. {item.kind:15} {size_text(item.size):>9}  {item.path}  ({item.why})')
    for line in plan.skipped:
        out.append(f'Skipped: {line}')
    if not plan.items:
        out.append('Nothing to delete.')
    return out


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--dry-run', action='store_true', help='list what it would delete; change nothing')
    parser.add_argument('--lane-dir', type=Path, default=Path.home() / 'Library/Caches/SpokenMarginsLane')
    parser.add_argument('--evidence-dir', type=Path, action='append', default=[],
                        help='another folder of lane evidence (the default one is always included); repeatable')
    parser.add_argument('--live-tree', type=Path, action='append', default=None,
                        help='a checkout the lane builds in; with any, other checkouts\' idle caches are dropped')
    parser.add_argument('--cap-gib', type=float, default=LANE_CAP_BYTES / GiB)
    parser.add_argument('--room-gib', type=float, default=BUILD_ROOM_BYTES / GiB,
                        help='room to leave under the cap for a build about to start (the lane runner calls this '
                             'before each build); 0 to prune only to the cap')
    parser.add_argument('--repo', default=DEFAULT_REPO)
    args = parser.parse_args(argv)
    now = time.time()
    evidence = [args.lane_dir / 'evidence', *args.evidence_dir]
    plan = plan_prune(args.lane_dir, evidence, args.live_tree, open_pull_requests(args.repo), now,
                      cap=int(args.cap_gib * GiB), room=int(args.room_gib * GiB))
    if args.dry_run:
        print('\n'.join(describe(plan)))
        return 0
    prune(plan, now, lambda message: print(message, flush=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
