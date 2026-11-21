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
- Absolute paths to the donor are rewritten to the target: in the copy's `workspace-state.json`, and
  in each checkout's git storage link (`.git/objects/info/alternates`) and `origin` url
  (`.git/config`), submodules included. SwiftPM makes each checkout with `git clone --shared` from
  `SourcePackages/repositories/<pkg>`, so without this the copy reads its history from the donor
  and breaks once the donor is deleted (phone-build deletes `dd-sim`, disk relief empties slots).
- Before the rename the copy is checked: its state file still records the pins, and each checkout's
  HEAD is the recorded revision, readable through the rewritten links, with every submodule at its
  recorded commit. A donor whose checkout SwiftPM was updating in place (it saves the state file
  only at the end) fails this and is not used.
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
import stat
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


# An absolute `.../SourcePackages` path at the start of a line (alternates) or after `=` (git config).
_GIT_PATH = re.compile(r'(^|=[ \t]*)(/[^\n]*?/SourcePackages)(?=/|$)', re.M)
# Inside a git folder these hold objects, refs and logs, never a config or alternates file to rewrite.
_GIT_SKIP = {'objects', 'refs', 'logs', 'hooks', 'info', 'lfs'}


def _git_link_files(git_dir: Path) -> Iterable[Path]:
    """`config` and `objects/info/alternates` of a checkout's git folder and of its submodules' (`modules/...`)."""
    for dirpath, dirnames, filenames in os.walk(git_dir):
        if 'config' in filenames:
            yield Path(dirpath) / 'config'
        alternates = Path(dirpath) / 'objects' / 'info' / 'alternates'
        if alternates.is_file():
            yield alternates
        dirnames[:] = [d for d in dirnames if d not in _GIT_SKIP]


def rewrite_git_paths(source_packages: Path, new_prefix: str) -> int:
    """Point every checkout's alternates and git config paths under `.../SourcePackages` at `new_prefix`.

    The files are read-only in a SwiftPM checkout, so each is replaced (same mode), not written in
    place; with an APFS clone the donor's file is untouched either way. Returns how many paths changed."""
    changed = 0
    checkouts = Path(source_packages) / 'checkouts'
    for checkout in sorted(checkouts.iterdir()) if checkouts.is_dir() else []:
        git_dir = checkout / '.git'
        if not git_dir.is_dir():
            continue
        for path in _git_link_files(git_dir):
            text = path.read_text(errors='surrogateescape')
            count = 0

            def swap(match):
                nonlocal count
                if match.group(2) == new_prefix:
                    return match.group(0)
                count += 1
                return match.group(1) + new_prefix

            new = _GIT_PATH.sub(swap, text)
            if not count:
                continue
            temp = path.with_name(path.name + '.seeding')
            temp.write_text(new, errors='surrogateescape')
            os.chmod(temp, stat.S_IMODE(path.stat().st_mode))
            os.replace(temp, path)
            changed += count
    return changed


def _git(checkout: Path, *args: str) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE',
                                                            'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES')}
    return subprocess.run(['git', '-C', str(checkout), *args], env=env, capture_output=True, text=True)


def has_git_lock(git_dir: Path) -> bool:
    """A `*.lock` file anywhere in a checkout's git folder or its submodules' (`modules/...`) except `objects`.

    Git holds `index.lock` for the whole time `git checkout` writes the working files, and HEAD and the saved index
    change only at the end, so a copy taken then has the old HEAD over a mix of old and new files."""
    for dirpath, dirnames, filenames in os.walk(git_dir):
        if any(name.endswith('.lock') for name in filenames):
            return True
        dirnames[:] = [d for d in dirnames if d != 'objects']
    return False


def verify(source_packages: Path, pins: Dict[str, str]) -> bool:
    """The copy records `pins`, and each checkout's HEAD is its recorded revision with readable history
    and every submodule at its recorded commit, no checkout holds a git lock, and every checkout's working files
    (and its submodules') match its index with nothing extra. Catches a donor checkout caught mid-update, however
    its folders were ordered in the copy."""
    if state_pins(source_packages) != pins:
        return False
    data = json.loads((Path(source_packages) / STATE).read_text())
    for dep in data['object']['dependencies']:
        checkout = Path(source_packages) / 'checkouts' / dep['subpath']
        revision = dep['state']['checkoutState']['revision']
        if not (checkout / '.git').is_dir() or has_git_lock(checkout / '.git'):
            return False
        head = _git(checkout, 'rev-parse', '--verify', '-q', 'HEAD^{commit}')
        if head.returncode != 0 or head.stdout.strip() != revision:
            return False
        # The files themselves against the copied index, submodules included. HEAD, the index and the lock files
        # all describe git's side only: a copy whose .git was taken before an update began, and whose sources were
        # taken while it ran, has none of the signs above and still mixes old and new files. A clean, complete
        # status means the working files are exactly what the copied index says, whenever cp reached each folder.
        clean = _git(checkout, 'status', '--porcelain', '--ignore-submodules=none')
        if clean.returncode != 0 or clean.stdout.strip():
            return False
        if (checkout / '.gitmodules').is_file():
            status = _git(checkout, 'submodule', 'status', '--recursive')
            # ' ' = at the recorded commit; '-' not checked out, '+' another commit, 'U' conflicted.
            if status.returncode != 0 or any(line and line[0] != ' ' for line in status.stdout.splitlines()):
                return False
    return True


def clone(donor: Path, target: Path, pins: Dict[str, str]) -> bool:
    """APFS-clone donor to target through a temporary sibling, relink it to itself and check it
    against `pins`; False (and nothing left behind) on failure."""
    target = Path(os.path.abspath(target))
    # Also named SourcePackages, so its paths take the same prefix rewrite as the final folder.
    holder = target.parent / f'.seeding-{target.name}-{os.getpid()}'
    temp = holder / 'SourcePackages'
    shutil.rmtree(holder, ignore_errors=True)
    try:
        holder.mkdir(parents=True)
        subprocess.run(['cp', '-c', '-R', str(donor), str(temp)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # Link the copy to itself and check it there, then point it at its final path and move it.
        for prefix in (str(temp), str(target)):
            rewrite_paths(temp, prefix)
            rewrite_git_paths(temp, prefix)
            if prefix == str(temp) and not verify(temp, pins):
                raise ValueError(f'{donor}: copy does not match its pins')
        os.rename(temp, target)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        return False
    finally:
        shutil.rmtree(holder, ignore_errors=True)
    return True


def seed(root: Path, derived: Path, cache: Path, log: Callable[[str], None] = lambda _: None) -> Optional[Path]:
    """Clone a matching donor into `<derived>/SourcePackages` if it has none; the donor, or None."""
    # Absolute: these paths are written into the copy, where SwiftPM expects absolute ones.
    target = Path(os.path.abspath(derived)) / 'SourcePackages'
    cache = Path(os.path.abspath(cache))
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
    if not clone(donor, target, pins):
        log(f'[lane] SourcePackages: cloning {donor} failed; resolving from GitHub')
        return None
    log(f'[lane] SourcePackages: cloned from {donor} (pins {pins_hash(pins)} match, '
        f'{time.time() - started:.0f}s); building with -skipPackageUpdates. A stale package? '
        f'Delete {target} and build again to resolve from GitHub.')
    return donor


def keep_shared(root: Path, derived: Path, cache: Path, log: Callable[[str], None] = lambda _: None) -> Optional[Path]:
    """After a good build, clone its SourcePackages into the shared copy for its pins if there is none."""
    source = Path(os.path.abspath(derived)) / 'SourcePackages'
    cache = Path(os.path.abspath(cache))
    if not enabled() or not source.is_dir():
        return None
    pins = resolved_pins(Path(root) / RESOLVED)
    if not pins or state_pins(source) != pins:
        return None
    target = Path(cache) / SHARED / pins_hash(pins) / 'SourcePackages'
    if target.exists():
        return None
    if clone(source, target, pins):
        log(f'[lane] SourcePackages: kept a shared copy at {target} for the next fresh worktree')
        return target
    return None
