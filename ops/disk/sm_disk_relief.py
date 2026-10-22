#!/usr/bin/env python3
"""Disk relief: free space on the Mac's data volume before it limits the work.

Owner, 2026-10-01: "I really hope we are not limiting ourselves because of disk space."

When free space on /System/Volumes/Data drops below 50 GiB, this frees space in order, stopping
as soon as free space reaches 70 GiB. Steps 1 to 5 only delete things that rebuild or are finished,
so they run whether or not the external drive is plugged in; only step 6 needs the drives.

1. Finished worktrees: inside a checkout's `.claude/worktrees/` or in ~/.codex/worktrees, clean, HEAD already in
   origin/main, idle, untouched for 24 hours, no live Claude Code session working there, and
   holding no ignored files except regenerable ones (`.build/`, `.venv`, `node_modules`, ...).
   Removed with `git worktree remove`, which refuses dirty or locked worktrees.
2. Regenerable build caches in idle worktrees of this repo, Codex's included: `.build/dd`, `.build/verification`
   (and anything else in `.build/` except lock files) and `Packages/SessionKit/.build`. A worktree under
   ~/Documents keeps those as links into ~/Library/Caches/SpokenMarginsBuilds/<slot>/ (scripts/sm_build_cache.py),
   because this job can't read ~/Documents; they're cleared there, and a slot whose worktree is gone goes whole.
   Idle means no process has its working directory inside the worktree, no xcodebuild,
   swift-build or verify-tests command names it, no live agent holds its worktree lock, and
   nothing under the cache changed in the last 30 minutes.
3. Scratch folders of Claude Code sessions that ended: /private/tmp/claude-<uid>/<project>/<session id>/.
   Ended means the session isn't in Claude Code's live session list (~/.claude/sessions/<pid>.json
   with a live pid), no process names the session id or has a file or working directory inside the
   folder, nothing in it changed in the last 12 hours, and it isn't this process's own session.
4. Ad-hoc test folders in /private/tmp (`spoken-margins-*`) that no process uses and that
   haven't changed in 12 hours.
5. iOS DeviceSupport folders except the newest one.
6. Moves to /Volumes/SlawBulk/Codex-Offload/<date>-disk-relief/<path relative to home>, plus a
   second copy on the separate mirror disk (/Volumes/SlawArchiveMirror/Current/SlawBulk/...) when
   it happens to be mounted,
   each copied under a `.partial` name and checked by size and file count before the source is
   deleted: `artifacts/` folders in the main checkout untouched for 2 days, older phone builds in
   ~/SpokenMargins-phone (never `latest`, the installed one, or the newest two), and Claude and
   Codex session logs untouched for 3 days. Without SlawBulk, moves are skipped.

On every run, whatever the free space (#1775), it also keeps the lane's own folder, ~/Library/Caches/
SpokenMarginsLane, under a size cap and ages out lane evidence; ops/disk/sm_lane_prune.py has the rules.

Once a night (02:00 to 05:00), when no backup is running, it also deletes Time Machine local
snapshots, which otherwise hold on to everything it deletes. Backups on the Time Machine drive stay.

It never touches the self-hosted runner folders, CoreSimulator, or app data. Codex worktrees follow the same
rules as Claude's (owner, 2026-10-19). Stale worktrees it may not remove (elsewhere, or holding `artifacts/`) are
listed for the owner instead. One run at a time (a lock file); every action goes to
~/SpokenMarginsOps/disk-relief/log.txt; a notification appears only when it acted.

Stdlib only, Python 3.9+. `--dry-run` lists what it would do, with sizes, and changes nothing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import sm_lane_prune as lane_prune  # noqa: E402
import sm_paths  # noqa: E402
from trunk import trunk_ref  # noqa: E402  (#1492)

GiB = 1024 ** 3
HOME = Path.home()
# The owner's development checkout, which is not this script's own (SM_REPO replaces it, #1844).
DEV_CHECKOUT = sm_paths.repo(__file__, default=HOME / 'Documents/GitHub/spoken-margins-native')

CACHE_IDLE_SECONDS = 30 * 60
ARTIFACT_AGE_SECONDS = 2 * 86400
SESSION_LOG_AGE_SECONDS = 3 * 86400
PHONE_KEEP_NEWEST = 2
SESSION_SCRATCH_IDLE_SECONDS = 12 * 3600
TMP_IDLE_SECONDS = 12 * 3600
STALE_WORKTREE_IDLE_SECONDS = 24 * 3600
# Ignored paths `git worktree remove` may delete with a finished worktree: build output and the
# links scripts/setup-worktree.sh makes. Anything else ignored (artifacts/ above all) keeps it.
REGENERABLE_IGNORED = {'.venv', '.venv/', 'node_modules', 'node_modules/', '.claude/settings.local.json'}
REGENERABLE_IGNORED_NAMES = {'.build', '.swiftpm', '__pycache__', '.DS_Store'}  # at any depth
SNAPSHOT_DATE = re.compile(r'^\d{4}-\d{2}-\d{2}-\d{6}$')
SESSION_ID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
BUSY_COMMAND_WORDS = ('xcodebuild', 'swift-build', 'verify-tests')
PHONE_BUILD_NAME = re.compile(r'^\d{8}-\d{6}-[0-9a-f]{7}$')


# ---------- configuration ----------

@dataclass
class Config:
    home: Path = HOME
    repo: Path = DEV_CHECKOUT
    checkout_glob: str = str(DEV_CHECKOUT) + '*'
    data_volume: Path = Path('/System/Volumes/Data')
    drive: Path = Path('/Volumes/SlawBulk')
    offload_dir: str = 'Codex-Offload'
    # The second copy, on a separate physical disk (need-space README): SlawBulk shares its disk
    # with Time Machine. slaw-sync mirrors SlawBulk into Current/SlawBulk there.
    mirror: Path = Path('/Volumes/SlawArchiveMirror')
    mirror_subdir: str = 'Current/SlawBulk'
    # Owner, 2026-10-09: the mirror holds redundant copies of highly sensitive data and is stored
    # away from the desk. Lane evidence, phone builds and session logs don't need it.
    require_mirror: bool = False
    # Owner, 2026-10-09: "We can delete snapshots overnight." Local hours [start, end).
    snapshot_volume: Path = Path('/')
    night_start_hour: int = 2
    night_end_hour: int = 5
    ops_dir: Path = sm_paths.state_dir('disk-relief', home=HOME)
    phone_dir: Path = HOME / 'SpokenMargins-phone'
    device_support: Path = HOME / 'Library/Developer/Xcode/iOS DeviceSupport'
    launch_agents: Path = HOME / 'Library/LaunchAgents'
    claude_projects: Path = HOME / '.claude/projects'
    codex_sessions: Path = HOME / '.codex/sessions'
    # Codex app worktrees, `<id>/<checkout name>`; owner, 2026-10-19: same cleanup rules as Claude's.
    codex_worktrees: Path = HOME / '.codex/worktrees'
    # Build folders of worktrees under ~/Documents, which this job can't read (scripts/sm_build_cache.py).
    build_cache_dir: Path = HOME / 'Library/Caches/SpokenMarginsBuilds'
    # Claude Code's per-session scratch (scratchpad/, tasks/ …) and its list of running sessions.
    claude_tmp: Path = Path(f'/private/tmp/claude-{os.getuid()}')
    claude_sessions: Path = HOME / '.claude/sessions'
    # Ad-hoc test copies agents leave in /private/tmp (a Test Desk copy held 4.2 GiB, 2026-10-09).
    tmp_root: Path = Path('/private/tmp')
    tmp_globs: Tuple[str, ...] = ('spoken-margins-*',)
    own_session: Optional[str] = field(default_factory=lambda: os.environ.get('CLAUDE_CODE_SESSION_ID'))
    # The lane's own folder (warm builds, compilation cache, evidence, state) and where its evidence lands
    # when a runner's .env points SM_LANE_EVIDENCE_DIR at the main checkout (#1775).
    lane_dir: Path = HOME / 'Library/Caches/SpokenMarginsLane'
    lane_cap_bytes: int = lane_prune.LANE_CAP_BYTES
    repo_slug: str = lane_prune.DEFAULT_REPO
    # One app build into a worktree's .build/dd takes 8 to 9 GiB (log, 2026-10-09): start early.
    trigger_bytes: int = 50 * GiB
    target_bytes: int = 70 * GiB
    extra_protected: List[Path] = field(default_factory=list)

    @property
    def log_file(self) -> Path:
        return self.ops_dir / 'log.txt'

    @property
    def lock_file(self) -> Path:
        return self.ops_dir / '.lock'

    @property
    def lane_evidence_dirs(self) -> List[Path]:
        return [self.lane_dir / 'evidence', self.repo / 'artifacts/lane']

    @property
    def snapshot_stamp(self) -> Path:
        """The date of the night local snapshots were last cleared."""
        return self.ops_dir / 'snapshots-cleared.txt'

    def protected(self) -> List[Path]:
        """Paths no action may touch, or contain."""
        paths = [
            self.home / 'Library/Developer/CoreSimulator',
            self.home / 'Library/Containers',
            self.home / 'Library/Group Containers',
            self.home / 'Library/Application Support',
            self.home / 'Library/Mobile Documents',
            self.drive,
            self.mirror,
        ]
        paths += runner_dirs(self.launch_agents)
        paths += self.extra_protected
        return [real(p) for p in paths]


def real(path) -> Path:
    return Path(os.path.realpath(str(path)))


def inside(path: Path, root: Path) -> bool:
    """True when path is root or below it (both already real paths)."""
    return path == root or str(path).startswith(str(root).rstrip('/') + '/')


def runner_dirs(launch_agents: Path) -> List[Path]:
    """The self-hosted runners' folders, from their LaunchAgent plists."""
    found = []
    for plist in sorted(launch_agents.glob('actions.runner.*.plist')):
        try:
            data = plistlib.loads(plist.read_bytes())
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        if data.get('WorkingDirectory'):
            found.append(Path(data['WorkingDirectory']))
        for arg in data.get('ProgramArguments', [])[:1]:
            found.append(Path(arg).parent)
    return found


def is_protected(path: Path, protected: Iterable[Path]) -> bool:
    """A path is off limits if it is inside a protected path or contains one."""
    path = real(path)
    return any(inside(path, p) or inside(p, path) for p in protected)


# ---------- measuring ----------

@dataclass
class TreeStats:
    disk_bytes: int = 0       # blocks on disk: what deleting it frees
    apparent_bytes: int = 0   # file sizes: what a copy must match
    files: int = 0            # regular files and symlinks
    newest_mtime: float = 0.0


def tree_stats(path: Path, stop_if_newer_than: Optional[float] = None) -> TreeStats:
    """Walk without following symlinks. With stop_if_newer_than, return early once a newer
    mtime is seen (the caller only wants to know the tree is busy)."""
    stats = TreeStats()

    def add(st, is_file):
        stats.disk_bytes += getattr(st, 'st_blocks', 0) * 512
        if is_file:
            stats.apparent_bytes += st.st_size
            stats.files += 1
        stats.newest_mtime = max(stats.newest_mtime, st.st_mtime)

    try:
        top = os.lstat(path)
    except OSError:
        return stats
    if not os.path.isdir(path) or os.path.islink(path):
        add(top, True)
        return stats
    add(top, False)
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
            is_dir = entry.is_dir(follow_symlinks=False)
            add(st, not is_dir)
            if stop_if_newer_than is not None and st.st_mtime > stop_if_newer_than:
                return stats
            if is_dir:
                stack.append(entry.path)
    return stats


def gib(n: float) -> str:
    return f'{n / GiB:.1f} GiB'


def size_text(n: int) -> str:
    if n >= GiB:
        return gib(n)
    return f'{n / 1024 ** 2:.0f} MiB'


# ---------- the machine (the boundary tests replace) ----------

@dataclass
class Proc:
    pid: int
    cwd: Optional[str]
    command: str


class Machine:
    def now(self) -> float:
        return time.time()

    def free_bytes(self, path: Path) -> int:
        st = os.statvfs(str(path))
        return st.f_bavail * st.f_frsize

    def is_mounted(self, path: Path) -> bool:
        return os.path.ismount(str(path))

    def processes(self) -> List[Proc]:
        procs = {}
        ps = run_quiet(['ps', '-axww', '-o', 'pid=,command='])
        for line in ps.splitlines():
            parts = line.strip().split(None, 1)
            if parts and parts[0].isdigit():
                procs[int(parts[0])] = Proc(int(parts[0]), None, parts[1] if len(parts) > 1 else '')
        pid = None
        for line in run_quiet(['lsof', '-nP', '-a', '-d', 'cwd', '-Fpn'], timeout=120).splitlines():
            if line.startswith('p') and line[1:].isdigit():
                pid = int(line[1:])
            elif line.startswith('n') and pid is not None:
                procs.setdefault(pid, Proc(pid, None, '')).cwd = line[1:]
        return list(procs.values())

    def open_files(self) -> Optional[List[Tuple[int, str]]]:
        """(pid, path) for every file, folder and working directory this user's processes hold
        open. None when lsof fails: then nothing may count as unused."""
        try:
            done = subprocess.run(['lsof', '-nP', '-u', str(os.getuid()), '-Fpn'], capture_output=True,
                                  text=True, errors='replace', timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            return None
        found, pid = [], None
        for line in done.stdout.splitlines():
            if line.startswith('p') and line[1:].isdigit():
                pid = int(line[1:])
            elif line.startswith('n/') and pid is not None:
                found.append((pid, line[1:]))
        return found or None

    def pid_alive(self, pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def git(self, cwd: Path, *args) -> Tuple[int, str]:
        try:
            done = subprocess.run(['git', '-C', str(cwd), *args], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return 1, ''
        return done.returncode, done.stdout

    def copy(self, src: Path, dst: Path) -> bool:
        """rsync -a, a folder's contents into dst/ or a file to dst."""
        dst.parent.mkdir(parents=True, exist_ok=True)
        source = str(src) + ('/' if src.is_dir() and not src.is_symlink() else '')
        target = str(dst) + ('/' if src.is_dir() and not src.is_symlink() else '')
        try:
            done = subprocess.run(['/usr/bin/rsync', '-a', source, target], capture_output=True, text=True,
                                  timeout=6 * 3600)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return done.returncode == 0

    def remove(self, path: Path) -> None:
        if path.is_dir() and not path.is_symlink():
            def retry_writable(func, p, _exc):
                try:
                    os.chmod(p, 0o700)
                    func(p)
                except OSError:
                    pass
            shutil.rmtree(path, onerror=retry_writable)
        else:
            path.unlink()

    def snapshot_dates(self, volume: Path) -> Optional[List[str]]:
        """Dates (YYYY-MM-DD-HHMMSS) of the volume's Time Machine local snapshots; None on failure."""
        try:
            done = subprocess.run(['tmutil', 'listlocalsnapshotdates', str(volume)], capture_output=True,
                                  text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if done.returncode != 0:
            return None
        return [line.strip() for line in done.stdout.splitlines() if SNAPSHOT_DATE.match(line.strip())]

    def backup_running(self) -> Optional[bool]:
        """Whether a Time Machine backup is running; None when tmutil status can't be read."""
        match = re.search(r'\bRunning = (\d+);', run_quiet(['tmutil', 'status']))
        return None if match is None else match.group(1) != '0'

    def delete_snapshot(self, date: str) -> bool:
        try:
            done = subprocess.run(['tmutil', 'deletelocalsnapshots', date], capture_output=True, text=True,
                                  timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return done.returncode == 0

    def open_pull_requests(self, repo: str) -> Optional[set]:
        """Numbers of the open PRs; None when GitHub can't be asked."""
        return lane_prune.open_pull_requests(repo)

    def notify(self, title: str, message: str) -> None:
        command = os.environ.get('SM_DISK_NOTIFY', 'osascript')
        if command == 'off':
            return
        script = ['-e', 'on run argv', '-e',
                  'display notification (item 1 of argv) with title (item 2 of argv)', '-e', 'end run']
        try:
            subprocess.run([*command.split(), *script, message, title], capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            pass


def run_quiet(command: List[str], timeout: int = 60) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ''


# ---------- worktrees and busy paths ----------

@dataclass
class Worktree:
    path: Path
    locked: Optional[str] = None


def parse_worktrees(porcelain: str) -> List[Worktree]:
    trees: List[Worktree] = []
    for line in porcelain.splitlines():
        if line.startswith('worktree '):
            trees.append(Worktree(Path(line[len('worktree '):])))
        elif trees and line.startswith('locked'):
            trees[-1].locked = line[len('locked'):].strip() or 'locked'
    return trees


def list_worktrees(cfg: Config, machine: Machine) -> List[Worktree]:
    """Every worktree of the main checkout, plus any spoken-margins-native* checkouts and theirs."""
    roots = [cfg.repo] + [Path(p) for p in sorted(glob.glob(cfg.checkout_glob))]
    seen = {}
    for root in roots:
        if not (root / '.git').exists():
            continue
        code, out = machine.git(root, 'worktree', 'list', '--porcelain')
        found = parse_worktrees(out) if code == 0 else []
        if not found:
            found = [Worktree(root)]
        for tree in found:
            key = real(tree.path)
            if key not in seen and tree.path.exists():
                seen[key] = Worktree(key, tree.locked)
    # Without Full Disk Access `git worktree list` can't run in ~/Documents; Codex's worktrees are found
    # by their `.git` file instead, which points into one of the checkouts above.
    for tree in codex_worktrees(cfg, roots):
        seen.setdefault(real(tree), Worktree(real(tree)))
    return list(seen.values())


def codex_worktrees(cfg: Config, roots: List[Path]) -> List[Path]:
    """`~/.codex/worktrees/<id>/<name>` (or `<name>`) folders that are worktrees of one of these checkouts."""
    git_dirs = [str(root / '.git') + '/' for root in roots] + [str(real(root / '.git')) + '/' for root in roots]
    found = []
    for gitfile in sorted([*cfg.codex_worktrees.glob('*/.git'), *cfg.codex_worktrees.glob('*/*/.git')]):
        try:
            text = gitfile.read_text(errors='replace').strip()
        except OSError:
            continue
        if text.startswith('gitdir: ') and any(text[len('gitdir: '):].startswith(g) for g in git_dirs):
            found.append(gitfile.parent)
    return found


def in_codex_worktrees(cfg: Config, path: Path) -> bool:
    """A Codex worktree itself: `<codex worktrees>/<id>/<name>`, or `<codex worktrees>/<name>` (older runs)."""
    root = real(cfg.codex_worktrees)
    return inside(path, root) and len(path.relative_to(root).parts) in (1, 2)


def owner_of(path: str, roots: List[Path]) -> Optional[Path]:
    """The deepest worktree root holding this path (a nested worktree owns its own files)."""
    p = real(path)
    best = None
    for root in roots:
        if inside(p, root) and (best is None or len(str(root)) > len(str(best))):
            best = root
    return best


def path_words(command: str) -> List[str]:
    words = []
    for word in command.split():
        word = word.strip('\'"')
        if '=' in word:
            word = word.split('=', 1)[1]
        if word.startswith('/'):
            words.append(word)
    return words


def lock_pid_alive(locked: Optional[str], machine: Machine) -> bool:
    """`git worktree lock` reasons written by Claude agents name a pid; a live one means in use."""
    if not locked:
        return False
    match = re.search(r'\bpid (\d+)', locked)
    return bool(match) and machine.pid_alive(int(match.group(1)))


def busy_worktrees(trees: List[Worktree], procs: List[Proc], machine: Machine) -> dict:
    """Map each busy worktree root to the reason it is busy."""
    roots = [t.path for t in trees]
    busy = {}
    for proc in procs:
        if proc.cwd:
            owner = owner_of(proc.cwd, roots)
            if owner is not None:
                busy.setdefault(owner, f'process {proc.pid} works there')
        if any(word in proc.command for word in BUSY_COMMAND_WORDS):
            for word in path_words(proc.command):
                owner = owner_of(word, roots)
                if owner is not None:
                    busy.setdefault(owner, f'process {proc.pid} builds or tests there')
    for tree in trees:
        if lock_pid_alive(tree.locked, machine):
            busy.setdefault(tree.path, 'a live agent holds its lock')
    return busy


def busy_paths(paths: List[Path], procs: List[Proc]) -> set:
    """Which of these (non-worktree) paths a process works in or a build command names."""
    roots = [real(p) for p in paths]
    hit = set()
    for proc in procs:
        words = ([proc.cwd] if proc.cwd else []) + path_words(proc.command)
        for word in words:
            owner = owner_of(word, roots)
            if owner is not None:
                hit.add(owner)
    return hit


# ---------- planning ----------

NO_ACCESS = 'macOS will not let this job read it (no Full Disk Access, by design); skipped'

@dataclass
class Candidate:
    step: str            # 'worktree', 'cache', 'session-scratch', 'tmp', 'device-support' or 'move'
    path: Path
    size: int            # bytes on disk it frees
    why: str
    # Asked again just before acting; a reason means keep it after all.
    recheck: Optional[Callable[[], Optional[str]]] = None
    # Put back empty after deleting: a worktree's `.build` link points at it (sm_build_cache.py).
    recreate: bool = False


@dataclass
class Plan:
    candidates: List[Candidate] = field(default_factory=list)
    skipped: List[str] = field(default_factory=list)
    # Stale worktrees kept for the owner to remove, with why they were kept.
    stale_worktrees: List[Tuple[Path, str]] = field(default_factory=list)


def cache_dirs(worktree: Path) -> List[Path]:
    found = []
    build = worktree / '.build'
    if build.is_dir() and not build.is_symlink():  # a link's folder is planned where it lives
        for child in sorted(build.iterdir()):
            if child.name.endswith('.lock') or child.is_symlink():
                continue
            if child.is_dir():
                found.append(child)
    swiftpm = worktree / 'Packages/SessionKit/.build'
    if swiftpm.is_dir() and not swiftpm.is_symlink():
        found.append(swiftpm)
    return found


def plan_caches(cfg: Config, machine: Machine, trees: List[Worktree], busy: dict,
                protected: List[Path], plan: Plan, removing: set = frozenset()) -> None:
    idle_since = machine.now() - CACHE_IDLE_SECONDS
    found = []
    for tree in trees:
        if tree.path in removing or is_protected(tree.path, protected):
            continue
        try:
            dirs = cache_dirs(tree.path)
        except PermissionError:
            plan.skipped.append(f'caches in {tree.path}: {NO_ACCESS}')
            continue
        if not dirs:
            continue
        if tree.path in busy:
            plan.skipped.append(f'caches in {tree.path}: {busy[tree.path]}')
            continue
        for d in dirs:
            if is_protected(d, protected):
                continue
            recent = tree_stats(d, stop_if_newer_than=idle_since)
            if recent.newest_mtime > idle_since:
                plan.skipped.append(f'{d}: changed in the last 30 minutes')
                continue
            stats = tree_stats(d)
            if stats.disk_bytes:
                found.append(Candidate('cache', d, stats.disk_bytes, 'build cache in an idle worktree'))
    plan.candidates += sorted(found, key=lambda c: -c.size)


SLOT_OWNER = 'owner.txt'  # sm_build_cache.OWNER_FILE


def worktree_gone(owner: Optional[str]) -> bool:
    """True only when the slot's worktree surely no longer exists. A folder macOS won't let this job
    look into counts as still there."""
    if not owner:
        return True
    try:
        os.lstat(owner)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return False


def verification_running(folder: Path) -> bool:
    """Whether verify-tests holds the slot's `verification.lock` (it locks `.build/verification.lock`)."""
    lock = folder / 'verification.lock'
    if not lock.exists():
        return False
    try:
        with lock.open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
    except OSError:
        return True
    return False


def plan_build_slots(cfg: Config, machine: Machine, procs: List[Proc], protected: List[Path], plan: Plan,
                     busy: Optional[dict] = None) -> None:
    """Build folders that worktrees under ~/Documents keep in ~/Library/Caches/SpokenMarginsBuilds/<slot>/
    (`root/` is the worktree's `.build`, `sessionkit/` its SessionKit `.build`). Same idle rule as step 2,
    including a live agent's worktree lock (`busy`, from busy_worktrees); the folders are emptied, not
    removed, so the worktree's links keep working. A slot whose worktree is gone goes whole."""
    busy = busy or {}
    root = cfg.build_cache_dir
    if not root.is_dir() or is_protected(root, protected):
        return
    idle_since = machine.now() - CACHE_IDLE_SECONDS
    found = []
    for slot in sorted(root.iterdir()):
        if slot.is_symlink() or not slot.is_dir():
            continue
        try:
            # First line: the worktree's path. Second: its identity, which only sm_build_cache reads.
            owner = ((slot / SLOT_OWNER).read_text(errors='replace').strip().splitlines() or [''])[0] or None
        except OSError:
            owner = None
        if owner and real(owner) in busy:
            plan.skipped.append(f'{slot}: {busy[real(owner)]}')
            continue
        watched = [slot] + ([Path(owner)] if owner else [])
        if busy_paths(watched, procs):
            plan.skipped.append(f'{slot}: a process works in or builds {owner or slot}')
            continue
        if verification_running(slot / 'root'):
            plan.skipped.append(f'{slot}: verify-tests is running there')
            continue

        def recheck(slot=slot):
            if verification_running(slot / 'root'):
                return 'verify-tests is running there'
            return None

        if worktree_gone(owner):
            if tree_stats(slot, stop_if_newer_than=idle_since).newest_mtime > idle_since:
                plan.skipped.append(f'{slot}: changed in the last 30 minutes')
                continue
            size = tree_stats(slot).disk_bytes
            if size:
                found.append(Candidate('cache', slot, size, 'build cache of a worktree that no longer exists',
                                       recheck))
            continue
        dirs = []
        if (slot / 'root').is_dir():
            dirs += [c for c in sorted((slot / 'root').iterdir())
                     if c.is_dir() and not c.is_symlink() and not c.name.endswith('.lock')]
        if (slot / 'sessionkit').is_dir() and any((slot / 'sessionkit').iterdir()):
            dirs.append(slot / 'sessionkit')
        for d in dirs:
            if tree_stats(d, stop_if_newer_than=idle_since).newest_mtime > idle_since:
                plan.skipped.append(f'{d}: changed in the last 30 minutes')
                continue
            size = tree_stats(d).disk_bytes
            if size:
                found.append(Candidate('cache', d, size, f'build cache of an idle worktree ({owner})', recheck,
                                       recreate=d.name == 'sessionkit'))
    plan.candidates += sorted(found, key=lambda c: -c.size)


@dataclass
class SessionSignals:
    live: set                      # session ids of running Claude Code sessions
    open_paths: List[Tuple[int, str]]  # (pid, path) under the scratch root: open files and cwds
    procs: List[Proc]


def live_sessions(cfg: Config, machine: Machine) -> List[Tuple[str, Optional[str]]]:
    """(session id, cwd) from ~/.claude/sessions/<pid>.json whose pid is alive (read only)."""
    live = []
    for entry in sorted(cfg.claude_sessions.glob('*.json')) if cfg.claude_sessions.is_dir() else []:
        try:
            data = json.loads(entry.read_text())
            pid, session = int(data['pid']), str(data['sessionId'])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if machine.pid_alive(pid):
            cwd = data.get('cwd')
            live.append((session, cwd if isinstance(cwd, str) else None))
    return live


def live_session_ids(cfg: Config, machine: Machine) -> set:
    return {session for session, _ in live_sessions(cfg, machine)}


def session_signals(cfg: Config, machine: Machine, procs: List[Proc]) -> Optional[SessionSignals]:
    open_files = machine.open_files()
    if open_files is None:
        return None
    roots = [cfg.claude_tmp, real(cfg.claude_tmp)]
    held = [(pid, path) for pid, path in open_files + [(p.pid, p.cwd) for p in procs if p.cwd]
            if any(inside(Path(path), r) for r in roots)]
    return SessionSignals(live_session_ids(cfg, machine), held, procs)


def session_scratch_in_use(cfg: Config, folder: Path, signals: SessionSignals, idle_since: float) -> Optional[str]:
    """Why this session's scratch folder may still be in use, or None when its session ended."""
    session = folder.name
    if session == cfg.own_session:
        return "this process's own session"
    if session in signals.live:
        return 'its Claude Code session is running'
    for proc in signals.procs:
        if session in proc.command:
            return f'process {proc.pid} names the session'
    roots = [folder, real(folder)]
    for pid, path in signals.open_paths:
        if any(inside(Path(path), r) for r in roots):
            return f'process {pid} has {path} open'
    if tree_stats(folder, stop_if_newer_than=idle_since).newest_mtime > idle_since:
        return 'changed in the last 12 hours'
    return None


def session_scratch_folders(cfg: Config) -> List[Path]:
    """<claude_tmp>/<project slug>/<session id>/ folders. Project slugs are cwd paths with '/'
    turned into '-', so they start with '-'; nothing else there is touched."""
    found = []
    root = cfg.claude_tmp
    if not root.is_dir():
        return found
    for project in sorted(root.iterdir()):
        if not project.name.startswith('-') or project.is_symlink() or not project.is_dir():
            continue
        for folder in sorted(project.iterdir()):
            if SESSION_ID.match(folder.name) and folder.is_dir() and not folder.is_symlink() \
                    and inside(real(folder), real(root)):
                found.append(folder)
    return found


def plan_session_scratch(cfg: Config, machine: Machine, procs: List[Proc], protected: List[Path],
                         plan: Plan) -> None:
    folders = session_scratch_folders(cfg)
    if not folders:
        return
    signals = session_signals(cfg, machine, procs)
    if signals is None:
        plan.skipped.append(f'session scratch in {cfg.claude_tmp}: could not list open files')
        return
    idle_since = machine.now() - SESSION_SCRATCH_IDLE_SECONDS
    found, recent = [], 0
    for folder in folders:
        if is_protected(folder, protected):
            continue
        reason = session_scratch_in_use(cfg, folder, signals, idle_since)
        if reason == 'changed in the last 12 hours':
            recent += 1
        elif reason:
            plan.skipped.append(f'{folder}: {reason}')
        else:
            def recheck(folder=folder):
                fresh = session_signals(cfg, machine, procs)
                if fresh is None:
                    return 'could not list open files'
                return session_scratch_in_use(cfg, folder, fresh, machine.now() - SESSION_SCRATCH_IDLE_SECONDS)
            found.append(Candidate('session-scratch', folder, tree_stats(folder).disk_bytes,
                                   'scratch of an ended Claude Code session', recheck))
    if recent:
        plan.skipped.append(f'{recent} session scratch folder(s) in {cfg.claude_tmp}: changed in the last 12 hours')
    plan.candidates += sorted(found, key=lambda c: -c.size)


def tmp_folders(cfg: Config) -> List[Path]:
    """This user's own folders in /private/tmp matching tmp_globs (not symlinks)."""
    found = []
    for pattern in cfg.tmp_globs:
        for name in sorted(glob.glob(str(cfg.tmp_root / pattern))):
            path = Path(name)
            try:
                st = path.lstat()
            except OSError:
                continue
            if path.is_dir() and not path.is_symlink() and st.st_uid == os.getuid():
                found.append(path)
    return found


def tmp_in_use(path: Path, procs: List[Proc], open_paths: List[Tuple[int, str]], idle_since: float) -> Optional[str]:
    if real(path) in busy_paths([path], procs):
        return 'a process works there'
    roots = [path, real(path)]
    for pid, held in open_paths:
        if any(inside(Path(held), r) for r in roots):
            return f'process {pid} has {held} open'
    if tree_stats(path, stop_if_newer_than=idle_since).newest_mtime > idle_since:
        return 'changed in the last 12 hours'
    return None


def plan_tmp(cfg: Config, machine: Machine, procs: List[Proc], protected: List[Path], plan: Plan) -> None:
    folders = [f for f in tmp_folders(cfg) if not is_protected(f, protected)]
    if not folders:
        return
    open_paths = machine.open_files()
    if open_paths is None:
        plan.skipped.append(f'test folders in {cfg.tmp_root}: could not list open files')
        return
    idle_since = machine.now() - TMP_IDLE_SECONDS
    found = []
    for folder in folders:
        reason = tmp_in_use(folder, procs, open_paths, idle_since)
        if reason:
            plan.skipped.append(f'{folder}: {reason}')
            continue

        def recheck(folder=folder):
            fresh = machine.open_files()
            if fresh is None:
                return 'could not list open files'
            return tmp_in_use(folder, procs, fresh, machine.now() - TMP_IDLE_SECONDS)
        found.append(Candidate('tmp', folder, tree_stats(folder).disk_bytes,
                               'test folder in /private/tmp untouched for 12 hours', recheck))
    plan.candidates += sorted(found, key=lambda c: -c.size)


def plan_device_support(cfg: Config, procs: List[Proc], protected: List[Path], plan: Plan) -> None:
    if not cfg.device_support.is_dir():
        return
    folders = [p for p in cfg.device_support.iterdir() if p.is_dir() and not p.is_symlink()]
    if len(folders) < 2:
        return
    # Keep the newest by date and the highest iOS version: the phone runs the newest iOS, and
    # the need-space README says keep the version the phone runs now.
    keep = {max(folders, key=lambda p: p.stat().st_mtime), max(folders, key=ios_version)}
    busy = busy_paths(folders, procs)
    found = []
    for folder in folders:
        if folder in keep or is_protected(folder, protected):
            continue
        if real(folder) in busy:
            plan.skipped.append(f'{folder}: in use')
            continue
        found.append(Candidate('device-support', folder, tree_stats(folder).disk_bytes,
                               'older than ' + ' and '.join(sorted(k.name for k in keep))))
    plan.candidates += sorted(found, key=lambda c: -c.size)


def ios_version(folder: Path) -> Tuple[int, ...]:
    """'iPhone18,1 27.0.1 (24A437)' -> (27, 0, 1); folders without one sort first."""
    match = re.search(r'(?:^|\s)(\d+(?:\.\d+)+)(?:\s|$)', folder.name)
    return tuple(int(n) for n in match.group(1).split('.')) if match else ()


def artifact_folders(artifacts: Path, older_than: float) -> List[Path]:
    """Folders in artifacts/ untouched since older_than. A folder that changed recently but holds
    old run folders (artifacts/lane) is looked into one level down."""
    picked = []
    if not artifacts.is_dir():
        return picked
    for child in sorted(artifacts.iterdir()):
        if not child.is_dir() or child.is_symlink():
            continue
        if tree_stats(child, stop_if_newer_than=older_than).newest_mtime <= older_than:
            picked.append(child)
            continue
        for grandchild in sorted(child.iterdir()):
            if grandchild.is_dir() and not grandchild.is_symlink() and \
                    tree_stats(grandchild, stop_if_newer_than=older_than).newest_mtime <= older_than:
                picked.append(grandchild)
    return picked


def installed_sha(phone_dir: Path) -> Optional[str]:
    try:
        words = (phone_dir / 'installed.txt').read_text().split()
    except OSError:
        return None
    return words[0] if words and re.fullmatch(r'[0-9a-f]{7,40}', words[0]) else None


def phone_builds_to_move(phone_dir: Path) -> List[Path]:
    """Every stamped build except latest's target, the installed one and the newest two."""
    if not phone_dir.is_dir():
        return []
    builds = sorted(p for p in phone_dir.iterdir()
                    if p.is_dir() and not p.is_symlink() and PHONE_BUILD_NAME.match(p.name))
    keep = {p.name for p in builds[-PHONE_KEEP_NEWEST:]}
    link = phone_dir / 'latest'
    if link.is_symlink() or link.exists():
        keep.add(real(link).name)
    sha = installed_sha(phone_dir)
    if sha:
        keep.update(p.name for p in builds if p.name[-7:] == sha[:7])
    return [p for p in builds if p.name not in keep]


def session_logs(cfg: Config, older_than: float) -> List[Path]:
    files = []
    if cfg.claude_projects.is_dir():
        files += [Path(p) for p in glob.glob(str(cfg.claude_projects / '*' / '*.jsonl'))]
    if cfg.codex_sessions.is_dir():
        for dirpath, _dirs, names in os.walk(cfg.codex_sessions):
            files += [Path(dirpath) / n for n in names]
    picked = []
    for f in sorted(files):
        try:
            st = f.lstat()
        except OSError:
            continue
        if f.is_file() and not f.is_symlink() and st.st_mtime <= older_than:
            picked.append(f)
    return picked


def plan_moves(cfg: Config, machine: Machine, procs: List[Proc], protected: List[Path], plan: Plan) -> None:
    now = machine.now()
    groups = [
        ('artifacts folder untouched for 2 days', artifact_folders(cfg.repo / 'artifacts', now - ARTIFACT_AGE_SECONDS)),
        ('older phone build', phone_builds_to_move(cfg.phone_dir)),
        ('session log untouched for 3 days', session_logs(cfg, now - SESSION_LOG_AGE_SECONDS)),
    ]
    for why, paths in groups:
        busy = busy_paths(paths, procs) if paths and paths[0].is_dir() else set()
        found = []
        for p in paths:
            if is_protected(p, protected):
                continue
            if real(p) in busy:
                plan.skipped.append(f'{p}: in use')
                continue
            found.append(Candidate('move', p, tree_stats(p).disk_bytes, why))
        plan.candidates += sorted(found, key=lambda c: -c.size) if why != 'session log untouched for 3 days' else found


def is_stale(machine: Machine, tree: Path) -> bool:
    """Clean (no changes, no untracked files) and HEAD already in the trunk (origin/main)."""
    code, status = machine.git(tree, 'status', '--porcelain')
    if code != 0 or status.strip():
        return False
    code, _ = machine.git(tree, 'merge-base', '--is-ancestor', 'HEAD', trunk_ref())
    return code == 0


def worktree_keep_reason(cfg: Config, machine: Machine, tree: Worktree, live_cwds: List[str]) -> Optional[str]:
    """Why a stale worktree must stay, or None when `git worktree remove` may take it."""
    standing = {real(cfg.repo)} | {real(p) for p in glob.glob(cfg.checkout_glob)}
    if not any(inside(tree.path, root / '.claude/worktrees') and tree.path != root / '.claude/worktrees'
               for root in standing) and not in_codex_worktrees(cfg, tree.path):
        return "not in a checkout's .claude/worktrees or in Codex's worktrees"
    if tree.locked:
        return 'locked'
    for cwd in live_cwds:
        if inside(real(cwd), tree.path):
            return 'a live Claude Code session works there'
    # matching: each ignored path as its pattern matched it, not collapsed into a parent folder.
    code, ignored = machine.git(tree.path, 'status', '--porcelain', '--ignored=matching')
    if code != 0:
        return 'git status failed'
    kept = sorted({path for path in (line[3:] for line in ignored.splitlines() if line.startswith('!! '))
                   if path not in REGENERABLE_IGNORED
                   and path.rstrip('/').rsplit('/', 1)[-1] not in REGENERABLE_IGNORED_NAMES})
    if kept:
        return 'holds ignored files that do not rebuild: ' + ', '.join(kept[:3])
    idle_since = machine.now() - STALE_WORKTREE_IDLE_SECONDS
    if tree_stats(tree.path, stop_if_newer_than=idle_since).newest_mtime > idle_since:
        return 'changed in the last 24 hours'
    return None


def remove_worktree(machine: Machine, tree: Path) -> Tuple[bool, str]:
    """`git worktree remove` without --force: git itself refuses a dirty or locked worktree."""
    code, common = machine.git(tree, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if code != 0 or not common.strip():
        return False, 'could not find its repository'
    code, _ = machine.git(Path(common.strip()), 'worktree', 'remove', str(tree))
    if code != 0 or tree.exists():
        return False, 'git worktree remove refused'
    if tree.parent.parent.name == 'worktrees' and tree.parent.parent.parent.name == '.codex':
        try:  # Codex's `<id>/` folder, now empty
            tree.parent.rmdir()
        except OSError:
            pass
    return True, 'removed (git worktree remove)'


def plan_worktrees(cfg: Config, machine: Machine, trees: List[Worktree], protected: List[Path],
                   busy: dict, plan: Plan) -> set:
    """Finished worktrees go first, whole. Not the standing checkouts (the main one, -test-desk,
    -finisher), not one in use; ones it may not remove are listed for the owner. Returns the
    worktrees planned for removal, so their caches aren't planned twice."""
    standing = {real(cfg.repo)} | {real(p) for p in glob.glob(cfg.checkout_glob)}
    live_cwds = [cwd for _, cwd in live_sessions(cfg, machine) if cwd]
    found = []
    for tree in trees:
        if tree.path in standing or tree.path in busy or is_protected(tree.path, protected):
            continue
        if not is_stale(machine, tree.path):
            continue
        reason = worktree_keep_reason(cfg, machine, tree, live_cwds)
        if reason:
            plan.stale_worktrees.append((tree.path, reason))
            continue

        def recheck(tree=tree):
            if not is_stale(machine, tree.path):
                return f'no longer clean and in {trunk_ref()}'
            return worktree_keep_reason(cfg, machine, tree,
                                        [cwd for _, cwd in live_sessions(cfg, machine) if cwd])
        found.append(Candidate('worktree', tree.path, tree_stats(tree.path).disk_bytes,
                               f'finished worktree: clean, in {trunk_ref()}, idle 24 hours', recheck))
    plan.candidates += sorted(found, key=lambda c: -c.size)
    return {c.path for c in found}


# ---------- the lane folder (#1775) ----------

def lane_live_trees(cfg: Config) -> List[Path]:
    """The checkouts the lane builds in: this repo's checkouts and their worktrees, and the runners' workspaces.
    Each one's warm-build folder is named by a hash of its path (lane-runner.py checkout_folder)."""
    trees = [cfg.repo]
    for match in sorted(glob.glob(cfg.checkout_glob)):
        trees.append(Path(match))
        trees += sorted(Path(match).glob('.claude/worktrees/*'))
    for runner in runner_dirs(cfg.launch_agents):
        trees.append(runner / '_work/spoken-margins-native/spoken-margins-native')
    return trees


def plan_lane(cfg: Config, machine: Machine) -> lane_prune.Plan:
    return lane_prune.plan_prune(cfg.lane_dir, cfg.lane_evidence_dirs, lane_live_trees(cfg),
                                 machine.open_pull_requests(cfg.repo_slug), machine.now(), cap=cfg.lane_cap_bytes)


def prune_lane(cfg: Config, machine: Machine, log: Log) -> int:
    """Cap the lane folder and age out its evidence. Runs every time, not only below the free-space trigger: on
    2026-10-16 the folder grew from 10 to 23 GB in a day while nothing here was due to act. A failure here
    never stops the rest of the run."""
    try:
        plan = plan_lane(cfg, machine)
        return lane_prune.prune(plan, machine.now(), log)
    except Exception as error:  # noqa: BLE001 - one step's fault must not stop the others
        log(f'lane folder step failed: {error!r}')
        return 0


def make_plan(cfg: Config, machine: Machine) -> Plan:
    plan = Plan()
    protected = cfg.protected()
    procs = machine.processes()
    try:
        trees = list_worktrees(cfg, machine)
    except PermissionError as error:
        plan.skipped.append(f'worktrees: {error.filename or "a folder"}: {NO_ACCESS}')
        trees = []
    busy = busy_worktrees(trees, procs, machine)

    # A folder macOS won't let this job read skips that step, not the whole run: the job
    # runs without Full Disk Access by the owner's choice (see README), and one blocked
    # folder used to crash every run before anything was freed (2026-10-11 to 10-14).
    def step(name, plan_step, *args):
        try:
            return plan_step(*args)
        except PermissionError as error:
            plan.skipped.append(f'{name}: {error.filename or "a folder"}: {NO_ACCESS}')
            return None

    removing = step('worktrees', plan_worktrees, cfg, machine, trees, protected, busy, plan) or set()
    step('caches', plan_caches, cfg, machine, trees, busy, protected, plan, removing)
    step('build cache folder', plan_build_slots, cfg, machine, procs, protected, plan, busy)
    step('session scratch', plan_session_scratch, cfg, machine, procs, protected, plan)
    step('tmp', plan_tmp, cfg, machine, procs, protected, plan)
    step('device support', plan_device_support, cfg, procs, protected, plan)
    step('moves', plan_moves, cfg, machine, procs, protected, plan)
    return plan


# ---------- acting ----------

def should_run(free: int, cfg: Config) -> bool:
    return free < cfg.trigger_bytes


def volume_ready(machine: Machine, volume: Path, folder: Path, write_probe: bool) -> Optional[str]:
    """None when the volume is mounted and folder on it is writable, else the reason."""
    if not machine.is_mounted(volume):
        return f'{volume} is not mounted'
    if not write_probe:
        return None if os.access(str(folder if folder.exists() else volume), os.W_OK) else f'{volume} is not writable'
    try:
        folder.mkdir(parents=True, exist_ok=True)
        probe = folder / f'.disk-relief-probe-{os.getpid()}'
        probe.write_text('ok')
        probe.unlink()
    except OSError as error:
        return f'{volume} is not writable ({error})'
    return None


def drive_ready(cfg: Config, machine: Machine, write_probe: bool) -> Optional[str]:
    return volume_ready(machine, cfg.drive, cfg.drive / cfg.offload_dir, write_probe)


def mirror_ready(cfg: Config, machine: Machine, write_probe: bool) -> Optional[str]:
    return volume_ready(machine, cfg.mirror, cfg.mirror / cfg.mirror_subdir / cfg.offload_dir, write_probe)


def relative_to_home(cfg: Config, src: Path) -> Path:
    source = real(src)
    try:
        return source.relative_to(real(cfg.home))
    except ValueError:
        return Path(str(source).lstrip('/'))


def run_folder(cfg: Config, day: str) -> Path:
    """<date>-disk-relief, relative to SlawBulk (and to Current/SlawBulk on the mirror)."""
    return Path(cfg.offload_dir) / f'{day}-disk-relief'


def free_name(roots: List[Path], rel: Path) -> Path:
    """rel, or rel~2, rel~3 … so nothing already on either drive is overwritten."""
    candidate, n = rel, 2
    while any((r / candidate).exists() or (r / candidate).is_symlink() or
              (r / (str(candidate) + '.partial')).exists() for r in roots):
        candidate = rel.parent / f'{rel.name}~{n}'
        n += 1
    return candidate


def copy_checked(machine: Machine, src: Path, dst: Path, want: TreeStats) -> Optional[str]:
    """Copy to dst.partial (an unfinished copy is obvious), check size and file count, then
    rename to dst. None on success, else what went wrong."""
    partial = Path(str(dst) + '.partial')
    if not machine.copy(src, partial):
        return f'copy to {partial} failed'
    got = tree_stats(partial)
    if (got.apparent_bytes, got.files) != (want.apparent_bytes, want.files):
        return (f'copy at {partial} does not match ({got.files} files, {got.apparent_bytes} bytes; '
                f'source {want.files} files, {want.apparent_bytes} bytes)')
    os.replace(partial, dst)
    return None


def move_verified(cfg: Config, machine: Machine, src: Path, day: str, mirror: bool) -> Tuple[bool, str]:
    """Copy to SlawBulk (and the mirror disk when asked), check each copy's size and file count,
    check the source didn't change meanwhile, and only then delete the source."""
    before = tree_stats(src)
    folder = run_folder(cfg, day)
    roots = [cfg.drive / folder] + ([cfg.mirror / cfg.mirror_subdir / folder] if mirror else [])
    rel = free_name(roots, relative_to_home(cfg, src))
    copies = []
    for root in roots:
        dst = root / rel
        problem = copy_checked(machine, src, dst, before)
        if problem:
            return False, f'{problem}; kept the source'
        copies.append(dst)
    after = tree_stats(src)
    if (after.apparent_bytes, after.files, after.newest_mtime) != (before.apparent_bytes, before.files, before.newest_mtime):
        return False, f'{src} changed during the copy; kept the source (copies left at {", ".join(map(str, copies))})'
    machine.remove(src)
    note = f'{day} {src} -> {" and ".join(map(str, copies))}\n'
    for root in roots:
        append(root / 'MANIFEST.txt', note)
    if not inside(real(src.parent), real(cfg.claude_projects)) and not inside(real(src.parent), real(cfg.codex_sessions)):
        # A pointer where the owner would look for it (need-space README). Not in the Claude
        # and Codex session folders, which those tools own.
        append(src.parent / 'MOVED-TO-SLAWBULK.txt', note)
    return True, 'moved to ' + ' and '.join(map(str, copies))


def append(path: Path, text: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a') as f:
            f.write(text)
    except OSError:
        pass


class Log:
    def __init__(self, path: Optional[Path], echo: bool = True):
        self.path = path
        self.echo = echo
        self.lines: List[str] = []

    def __call__(self, message: str) -> None:
        self.lines.append(message)
        if self.echo:
            print(message, flush=True)
        if self.path:
            append(self.path, f'{dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")} {message}\n')


@dataclass
class Result:
    acted: bool = False
    freed: int = 0
    actions: List[str] = field(default_factory=list)
    failures: List[str] = field(default_factory=list)
    reason: str = ''


class PhoneBuildLock:
    """Hold scripts/phone-build's lock while moving phone builds, so it can't prune or point
    `latest` at the same time. If a build is running, phone moves are skipped this run."""

    def __init__(self, phone_dir: Path):
        self.path = phone_dir / '.phone-build.lock'
        self.handle = None

    def acquire(self) -> bool:
        if self.handle is not None:
            return True
        if not self.path.parent.is_dir():
            return False
        try:
            self.handle = open(self.path, 'a+')
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if self.handle:
                self.handle.close()
            self.handle = None
            return False

    def release(self) -> None:
        if self.handle:
            fcntl.flock(self.handle, fcntl.LOCK_UN)
            self.handle.close()
            self.handle = None


def reached_target(cfg: Config, start: int, measured: int, freed: int) -> bool:
    """Stop at the target by what the volume reports or by what this run deleted, whichever is
    higher: a Time Machine local snapshot can hold deleted files, and then the measured number
    doesn't move and the run would otherwise clear everything (need-space README, 2026-09-28)."""
    return measured >= cfg.target_bytes or start + freed >= cfg.target_bytes


def execute(cfg: Config, machine: Machine, plan: Plan, log: Log, start: int) -> Result:
    result = Result()
    day = dt.datetime.fromtimestamp(machine.now()).strftime('%Y-%m-%d')
    protected = cfg.protected()
    phone_lock = PhoneBuildLock(cfg.phone_dir)
    phone_root = real(cfg.phone_dir)
    has_moves = any(c.step == 'move' for c in plan.candidates)
    drive_problem = drive_ready(cfg, machine, write_probe=True) if has_moves else None
    mirror_problem = mirror_ready(cfg, machine, write_probe=True) if has_moves else None
    use_mirror = mirror_problem is None
    move_problem = drive_problem or (mirror_problem if cfg.require_mirror else None)
    if drive_problem:
        log(f'moves skipped this run: {drive_problem}')
    elif mirror_problem and cfg.require_mirror:
        log(f'moves skipped this run: {mirror_problem}; moved files need a second copy on another disk')
    try:
        for c in plan.candidates:
            free = machine.free_bytes(cfg.data_volume)
            if reached_target(cfg, start, free, result.freed):
                log(f'stop: {gib(free)} free measured, {size_text(result.freed)} cleared this run; target {gib(cfg.target_bytes)}')
                break
            if is_protected(c.path, protected):
                log(f'refused (protected): {c.path}')
                continue
            if not (c.path.exists() or c.path.is_symlink()):
                continue
            busy_now = c.recheck() if c.recheck else None
            if busy_now:
                log(f'skip {c.path}: {busy_now}')
                continue
            if c.step == 'move':
                if move_problem:
                    continue
                if inside(real(c.path), phone_root) and not phone_lock.acquire():
                    log(f'skip {c.path}: a phone build is running')
                    continue
                short = [(v, machine.free_bytes(v)) for v in [cfg.drive] + ([cfg.mirror] if use_mirror else [])]
                short = [(v, f) for v, f in short if f <= 2 * c.size]
                if short:
                    v, f = short[0]
                    log(f'skip {c.path}: {v} has {size_text(f)} free, needs more than twice {size_text(c.size)}')
                    continue
                ok, message = move_verified(cfg, machine, c.path, day, mirror=use_mirror)
            elif c.step == 'worktree':
                ok, message = remove_worktree(machine, c.path)
            else:
                try:
                    machine.remove(c.path)
                    if c.recreate:
                        c.path.mkdir(exist_ok=True)
                    ok, message = True, 'deleted (regenerable)' if c.step in ('cache', 'device-support') else 'deleted'
                except OSError as error:
                    ok, message = False, f'delete failed: {error}'
            if ok:
                after = machine.free_bytes(cfg.data_volume)
                result.acted = True
                result.freed += c.size
                result.actions.append(f'{c.step} {c.path} ({size_text(c.size)})')
                log(f'{c.step}: {c.path} {size_text(c.size)} {message}; free now {gib(after)}')
            else:
                result.failures.append(f'{c.path}: {message}')
                log(f'FAILED {c.step}: {c.path}: {message}')
    finally:
        phone_lock.release()
    return result


def clear_snapshots_overnight(cfg: Config, machine: Machine, log: Log) -> None:
    """Once a night, delete Time Machine local snapshots: they hold on to everything this job
    deletes (2026-10-04: 17 GiB cleared, free space unchanged). Not while a backup runs, which may
    be reading one; then a later run in the window tries again. Backups on the drive stay."""
    now = dt.datetime.fromtimestamp(machine.now())
    if not cfg.night_start_hour <= now.hour < cfg.night_end_hour:
        return
    night = now.strftime('%Y-%m-%d')
    try:
        if cfg.snapshot_stamp.read_text().strip() == night:
            return
    except OSError:
        pass
    running = machine.backup_running()
    if running:
        return
    if running is None:
        log('local snapshots kept: could not read tmutil status')
        return
    dates = machine.snapshot_dates(cfg.snapshot_volume)
    if dates is None:
        log(f'local snapshots kept: could not list them on {cfg.snapshot_volume}')
        return
    before = machine.free_bytes(cfg.data_volume)
    failed = []
    for date in dates:
        if machine.delete_snapshot(date):
            log(f'snapshot: deleted local Time Machine snapshot {date}')
        else:
            failed.append(date)
            log(f'FAILED snapshot: could not delete local Time Machine snapshot {date}')
    if dates:
        log(f'snapshots: {len(dates) - len(failed)} of {len(dates)} deleted; free {gib(before)} -> '
            f'{gib(machine.free_bytes(cfg.data_volume))}')
    if not failed:
        cfg.snapshot_stamp.parent.mkdir(parents=True, exist_ok=True)
        cfg.snapshot_stamp.write_text(night + '\n')


def run(cfg: Config, machine: Machine, log: Log) -> Result:
    """One scheduled run. Assumes the caller holds the run lock."""
    clear_snapshots_overnight(cfg, machine, log)
    prune_lane(cfg, machine, log)
    free = machine.free_bytes(cfg.data_volume)
    if not should_run(free, cfg):
        return Result(reason=f'{gib(free)} free; acts below {gib(cfg.trigger_bytes)}')
    # No drive check here: only moves need the drives, and execute() skips them without one.
    log(f'start: {gib(free)} free, below {gib(cfg.trigger_bytes)}; freeing to {gib(cfg.target_bytes)}')
    plan = make_plan(cfg, machine)
    for line in plan.skipped:
        log(f'skip {line}')
    result = execute(cfg, machine, plan, log, free)
    end = machine.free_bytes(cfg.data_volume)
    log(f'done: cleared {size_text(result.freed)} in {len(result.actions)} actions, '
        f'{len(result.failures)} failures; {gib(end)} free')
    held = result.freed > 0 and end - free < result.freed // 2
    if held:
        log('free space rose by less than half of what was cleared: a Time Machine local snapshot may hold it '
            f'(tmutil listlocalsnapshots /); they are deleted overnight from {cfg.night_start_hour:02d}:00.')
    for tree, why in plan.stale_worktrees:
        log(f'stale worktree kept ({why}; yours to remove): {tree}')
    if result.acted or result.failures:
        message = f'Cleared {size_text(result.freed)}; {gib(end)} free now.'
        if held:
            message += ' Free space lags: a local snapshot may hold it.'
        if result.failures:
            message += f' {len(result.failures)} item(s) kept after a failed check.'
        if plan.stale_worktrees:
            message += f' {len(plan.stale_worktrees)} stale worktree(s) listed in the log.'
        machine.notify('Disk relief', message)
    return result


def dry_run(cfg: Config, machine: Machine, pretend_free: Optional[int]) -> List[str]:
    out = []
    free = pretend_free if pretend_free is not None else machine.free_bytes(cfg.data_volume)
    triggered = should_run(free, cfg)
    out.append(f'Free on {cfg.data_volume}: {gib(free)}' + (' (pretend)' if pretend_free is not None else '')
               + f'. Acts below {gib(cfg.trigger_bytes)}, stops at {gib(cfg.target_bytes)}.')
    reason = drive_ready(cfg, machine, write_probe=False)
    out.append(f'Drive: {reason}; moves would be skipped' if reason else
               f'Drive: {cfg.drive} mounted, {gib(machine.free_bytes(cfg.drive))} free')
    mirror_problem = mirror_ready(cfg, machine, write_probe=False)
    if mirror_problem:
        out.append(f'Mirror: {mirror_problem}; ' + ('moves would be skipped' if cfg.require_mirror else
                                                   'moves would make one copy, on the drive'))
    else:
        out.append(f'Mirror: {cfg.mirror} mounted, {gib(machine.free_bytes(cfg.mirror))} free')
    out.append('Lane folder (checked on every run, whatever the free space):')
    out += ['  ' + line for line in lane_prune.describe(plan_lane(cfg, machine))]
    plan = make_plan(cfg, machine)
    start = free if triggered else cfg.trigger_bytes
    out.append('Would act now.' if triggered else
               f'Would not act now. Below, the order it would take starting from {gib(start)} free:')
    running = 0
    stopped = False
    for i, c in enumerate(plan.candidates, 1):
        if not stopped and start + running >= cfg.target_bytes:
            out.append(f'  --- stops here: {gib(start + running)} free reaches the target ---')
            stopped = True
        running += c.size
        out.append(f'  {i:3}. {c.step:14} {size_text(c.size):>9}  total {size_text(running):>9}  {c.path}  ({c.why})')
    by_step = {}
    for c in plan.candidates:
        by_step[c.step] = by_step.get(c.step, 0) + c.size
    out.append('Totals: ' + ', '.join(f'{k} {size_text(v)}' for k, v in by_step.items()) +
               f'; all {size_text(running)} ({len(plan.candidates)} items).')
    for line in plan.skipped:
        out.append(f'Skipped: {line}')
    for tree, why in plan.stale_worktrees:
        out.append(f'Stale worktree kept ({why}): {tree}')
    return out


def locked_run(cfg: Config, machine: Machine, log: Log) -> Result:
    """run() under the lock file, so two runs never overlap; a second one exits at once."""
    cfg.ops_dir.mkdir(parents=True, exist_ok=True)
    with open(cfg.lock_file, 'a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return Result(reason='another disk relief run holds the lock')
        try:
            return run(cfg, machine, log)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--dry-run', action='store_true', help='list what it would do, with sizes; change nothing')
    parser.add_argument('--free-gib', type=float, help='with --dry-run: pretend this much is free')
    args = parser.parse_args(argv)
    cfg = Config()
    machine = Machine()
    if args.dry_run:
        pretend = int(args.free_gib * GiB) if args.free_gib is not None else None
        for line in dry_run(cfg, machine, pretend):
            print(line)
        return 0
    if args.free_gib is not None:
        parser.error('--free-gib only works with --dry-run')
    # Quiet when there's nothing to do: launchd runs this every 15 minutes.
    locked_run(cfg, machine, Log(cfg.log_file))
    return 0


if __name__ == '__main__':
    sys.exit(main())
