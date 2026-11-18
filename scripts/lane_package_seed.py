#!/usr/bin/env python3
"""Seed a fresh build folder's Swift packages from a local copy whose pins match, instead of GitHub.

A new worktree's `.build/dd` has no `SourcePackages`, so its first xcodebuild fetches every package:
onnxruntime, mlx-swift with its large submodules, kokoro-coreml, MisakiSwift and the rest. On
2026-11-18 a Test Desk build of PR 4604 spent 34 minutes there, stalled in `git submodule update`
for mlx-swift's `Source/Cmlx/mlx` at about 50 KB/s. Cloning another checkout's `SourcePackages`
whose pins matched and building with `-skipPackageUpdates` took a few minutes.

So scripts/xcodebuild-lane calls `seed()` before a build:

- The pins wanted are the workspace's Package.resolved (`identity -> revision`).
- A donor is a `SourcePackages` folder whose `workspace-state.json` records exactly those
  revisions, with every checkout present, and whose state file has not changed for a while (one
  still being resolved is skipped). Candidates, in order: the shared copies in
  `<cache>/source-packages/<pins hash>/SourcePackages`, then each build slot's
  `<cache>/<slot>/root/dd/SourcePackages`, newest first.
- The donor is APFS-cloned (`cp -c -R`, no extra disk) into a temporary folder next to the
  target and renamed into place, so a half-made copy is never used and the donor is never written.
  Absolute paths to the donor in the copy's `workspace-state.json` are rewritten to the target.
- No donor, or the clone fails: nothing changes and xcodebuild resolves from GitHub as before.

After a successful build `keep_shared()` clones the build's `SourcePackages` into the shared copy
for its pins, once per pins hash, so the next fresh worktree has a donor even after disk relief
empties the slots. Disk relief may clear the shared copies too (they have no owner.txt); they are
a cache, and the next build refills them.

Settings: SM_LANE_PACKAGE_SEED=off (or SM_BUILD_CACHE=off, or GitHub Actions) turns both off.
SM_BUILD_CACHE_ROOT (sm_build_cache) moves the cache.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from typing import Callable, Dict, Iterable, List, Optional

RESOLVED = Path('SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
SHARED = 'source-packages'
STATE = 'workspace-state.json'
# A donor whose state file changed this recently may be mid-resolution: skipped.
SETTLE_SECONDS = 120


def enabled() -> bool:
    """Off with SM_LANE_PACKAGE_SEED=off, with the build cache off (SM_BUILD_CACHE=off), and on GitHub Actions."""
    off = ('off', '0', 'no')
    return not (os.environ.get('SM_LANE_PACKAGE_SEED', '').strip().lower() in off
                or os.environ.get('SM_BUILD_CACHE', '').strip().lower() in off
                or os.environ.get('GITHUB_ACTIONS'))


def resolved_pins(path: Path) -> Dict[str, str]:
    """`identity -> revision` from a Package.resolved (format 2 or 3); {} if unreadable."""
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    pins = data.get('pins') or data.get('object', {}).get('pins') or []
    out = {}
    for pin in pins:
        identity = (pin.get('identity') or pin.get('package') or '').lower()
        revision = (pin.get('state') or {}).get('revision')
        if identity and revision:
            out[identity] = revision
    return out


def state_pins(source_packages: Path) -> Optional[Dict[str, str]]:
    """`identity -> revision` checked out in a SourcePackages folder, or None if it is incomplete or unreadable."""
    try:
        data = json.loads((Path(source_packages) / STATE).read_text())
    except (OSError, ValueError):
        return None
    out = {}
    for dep in (data.get('object') or {}).get('dependencies') or []:
        state = dep.get('state') or {}
        if state.get('name') != 'sourceControlCheckout':
            return None  # an edited or local dependency: not a plain copy of the pins
        identity = ((dep.get('packageRef') or {}).get('identity') or '').lower()
        revision = (state.get('checkoutState') or {}).get('revision')
        subpath = dep.get('subpath')
        if not (identity and revision and subpath):
            return None
        if not (Path(source_packages) / 'checkouts' / subpath).is_dir():
            return None
        out[identity] = revision
    return out


def pins_hash(pins: Dict[str, str]) -> str:
    text = '\n'.join(f'{k} {v}' for k, v in sorted(pins.items()))
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def candidates(cache: Path, exclude: Iterable[Path] = ()) -> List[Path]:
    """Shared copies first, then build slots, each newest state file first."""
    cache = Path(cache)
    skip = {os.path.realpath(str(p)) for p in exclude}

    def newest_first(paths):
        found = []
        for path in paths:
            if os.path.realpath(str(path)) in skip:
                continue
            try:
                found.append((os.stat(path / STATE).st_mtime, path))
            except OSError:
                continue
        return [p for _, p in sorted(found, key=lambda item: -item[0])]

    shared = newest_first(cache.glob(f'{SHARED}/*/SourcePackages'))
    slots = newest_first(cache.glob('*/root/dd/SourcePackages'))
    return shared + slots


def choose_donor(pins: Dict[str, str], options: Iterable[Path], now: Optional[float] = None,
                 settle: float = SETTLE_SECONDS) -> Optional[Path]:
    """The first option whose checked-out revisions equal `pins` and whose state file has settled."""
    if not pins:
        return None
    now = time.time() if now is None else now
    for option in options:
        try:
            if now - os.stat(Path(option) / STATE).st_mtime < settle:
                continue
        except OSError:
            continue
        if state_pins(option) == pins:
            return Path(option)
    return None


_PREFIX = re.compile(r'^(/.*?/SourcePackages)(?=/|$)')


def rewrite_paths(source_packages: Path, new_prefix: str) -> int:
    """Point absolute `.../SourcePackages` paths in the state file at `new_prefix`; how many strings changed."""
    state = Path(source_packages) / STATE
    data = json.loads(state.read_text())
    changed = 0

    def walk(value):
        nonlocal changed
        if isinstance(value, dict):
            return {k: walk(v) for k, v in value.items()}
        if isinstance(value, list):
            return [walk(v) for v in value]
        if isinstance(value, str):
            match = _PREFIX.match(value)
            if match and match.group(1) != new_prefix:
                changed += 1
                return new_prefix + value[match.end(1):]
        return value

    data = walk(data)
    if changed:
        state.write_text(json.dumps(data, indent=2, sort_keys=True))
    return changed


def clone(donor: Path, target: Path, path_in_build: Optional[str] = None) -> bool:
    """APFS-clone donor to target through a temporary sibling; False (and nothing left behind) on failure."""
    target = Path(target)
    temp = target.parent / f'.{target.name}.seeding-{os.getpid()}'
    shutil.rmtree(temp, ignore_errors=True)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['cp', '-c', '-R', str(donor), str(temp)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        rewrite_paths(temp, path_in_build or str(target))
        os.rename(temp, target)
    except (OSError, ValueError, subprocess.CalledProcessError):
        shutil.rmtree(temp, ignore_errors=True)
        return False
    return True


def seed(root: Path, derived: Path, cache: Path, log: Callable[[str], None] = lambda _: None) -> Optional[Path]:
    """Clone a matching donor into `<derived>/SourcePackages` if it has none; the donor, or None."""
    target = Path(derived) / 'SourcePackages'
    if not enabled() or target.exists() or target.is_symlink():
        return None
    pins = resolved_pins(Path(root) / RESOLVED)
    if not pins:
        return None
    donor = choose_donor(pins, candidates(cache, exclude=[target]))
    if donor is None:
        log(f'[lane] SourcePackages: no local copy pins {pins_hash(pins)}; resolving from GitHub')
        return None
    started = time.time()
    if not clone(donor, target):
        log(f'[lane] SourcePackages: cloning {donor} failed; resolving from GitHub')
        return None
    log(f'[lane] SourcePackages: cloned from {donor} (pins {pins_hash(pins)} match, '
        f'{time.time() - started:.0f}s); building with -skipPackageUpdates. A stale package? '
        f'Delete {target} and build again to resolve from GitHub.')
    return donor


def keep_shared(root: Path, derived: Path, cache: Path, log: Callable[[str], None] = lambda _: None) -> Optional[Path]:
    """After a good build, clone its SourcePackages into the shared copy for its pins if there is none."""
    source = Path(derived) / 'SourcePackages'
    if not enabled() or not source.is_dir():
        return None
    pins = resolved_pins(Path(root) / RESOLVED)
    if not pins or state_pins(source) != pins:
        return None
    target = Path(cache) / SHARED / pins_hash(pins) / 'SourcePackages'
    if target.exists():
        return None
    if clone(source, target):
        log(f'[lane] SourcePackages: kept a shared copy at {target} for the next fresh worktree')
        return target
    return None
