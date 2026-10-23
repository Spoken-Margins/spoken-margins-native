#!/usr/bin/env python3
"""Keep the lane's tools copy on `main` (#2536).

The lane runners get their `.venv` and `node_modules` from a copy of the repository outside ~/Documents
(`SM_LANE_TOOLS`, default ~/Library/Caches/SpokenMarginsLane/tools), because macOS denies the runners' node access to
Documents (#2493). Nothing updated that copy, so a new Python requirement or a changed `package-lock.json` would never
reach the runners. This job, run hourly by launchd from the copy itself:

1. fetches `main` (depth 1) and moves the copy to it;
2. runs `scripts/bootstrap-python-tools.sh` when `requirements-dev.txt` no longer matches what the `.venv` holds, and
   `npm ci` when `package-lock.json` changed since the last install (a stamp inside `node_modules` records which);
3. checks nothing in the copy points into ~/Documents;
4. says so on #337 (once a day per problem) when it could not do one of these, or when a needed install waited more
   than 6 hours for a lane job to finish.

Installs wait while a `lane-runner.py` process is running, so the `.venv` is never changed under a test. Stdlib
only, Python 3.9+. It only ever writes inside the tools copy and its own state file.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, List, Optional

REPO_SLUG = 'Spoken-Margins/spoken-margins-native'
REMOTE_BRANCH = 'main'
REPORT_ISSUE = 337
DAY = 24 * 3600
DEFER_LIMIT = 6 * 3600
LOCK_STAMP = '.sm-package-lock.sha256'


def default_tools() -> Path:
    return Path(os.environ.get('SM_LANE_TOOLS') or Path.home() / 'Library/Caches/SpokenMarginsLane/tools')


def default_state() -> Path:
    return Path.home() / 'SpokenMarginsOps/lane-tools-refresh/state.json'


def sh(args: List[str], cwd: Path, env: Optional[dict] = None, timeout: int = 1800) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, **(env or {})})


def lane_job_running() -> bool:
    out = subprocess.run(['pgrep', '-f', 'lane-runner.py'], capture_output=True, text=True)
    return out.returncode == 0 and bool(out.stdout.strip())


def digest(path: Path) -> Optional[str]:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def documents_references(tools: Path) -> List[str]:
    """Places in the copy that point into ~/Documents, which the runners cannot read."""
    found = []
    cfg = tools / '.venv/pyvenv.cfg'
    try:
        if '/Documents/' in cfg.read_text():
            found.append(str(cfg))
    except OSError:
        pass
    for folder in (tools / '.venv', tools / 'node_modules'):
        try:
            if folder.is_symlink() and '/Documents/' in os.path.realpath(folder):
                found.append(f'{folder} -> {os.path.realpath(folder)}')
        except OSError:
            pass
    return found


class Refresh:
    def __init__(self, tools: Path, state_path: Path, now: float, run: Callable = sh,
                 busy: Callable[[], bool] = lane_job_running, post: Optional[Callable[[str], None]] = None,
                 log: Callable[[str], None] = print):
        self.tools, self.state_path, self.now = tools, state_path, now
        self.run, self.busy, self.post, self.log = run, busy, post, log
        self.problems: List[str] = []
        try:
            self.state = json.loads(state_path.read_text())
        except (OSError, ValueError):
            self.state = {}

    def problem(self, key: str, text: str) -> None:
        self.problems.append(text)
        self.log(f'PROBLEM: {text}')
        if self.state.get('said', {}).get(key, 0) > self.now - DAY or self.post is None:
            return
        try:
            self.post(f'**Lane tools copy** (`{self.tools}`): {text}')
        except Exception as error:  # a failed comment must not stop the refresh
            self.log(f'could not post to #{REPORT_ISSUE}: {error}')
            return
        self.state.setdefault('said', {})[key] = self.now

    def save(self) -> None:
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            self.state_path.write_text(json.dumps(self.state, indent=1))
        except OSError as error:
            self.log(f'could not write {self.state_path}: {error}')

    def git(self, *args: str) -> subprocess.CompletedProcess:
        return self.run(['git', *args], self.tools)

    def update_checkout(self) -> Optional[str]:
        """Moves the copy to origin's main; returns the commit it had before, or None when nothing moved."""
        before = self.git('rev-parse', 'HEAD').stdout.strip()
        fetched = self.git('fetch', '--quiet', '--depth', '1', 'origin', REMOTE_BRANCH)
        if fetched.returncode != 0:
            self.problem('fetch', f'could not fetch {REMOTE_BRANCH}: {fetched.stderr.strip()[:200]}')
            return None
        after = self.git('rev-parse', 'FETCH_HEAD').stdout.strip()
        if not before or not after or before == after:
            return None
        # The copy is a throwaway clone that nobody edits, so a hard reset is how it follows main.
        moved = self.git('reset', '--quiet', '--hard', after)
        if moved.returncode != 0:
            self.problem('reset', f'could not move to {after[:7]}: {moved.stderr.strip()[:200]}')
            return None
        self.log(f'moved {before[:7]} -> {after[:7]}')
        return before

    def python_stale(self) -> bool:
        wanted = digest(self.tools / 'requirements-dev.txt')
        return wanted is not None and wanted != digest(self.tools / '.venv/.requirements-dev.txt')

    def node_stale(self, before: Optional[str]) -> bool:
        lock = digest(self.tools / 'package-lock.json')
        if lock is None or not (self.tools / 'node_modules').is_dir():
            return False
        stamp_file = self.tools / 'node_modules' / LOCK_STAMP
        try:
            return stamp_file.read_text().strip() != lock
        except OSError:
            pass
        # No stamp yet: trust the install matched the lock the copy had before this move.
        if before:
            old = self.git('show', f'{before}:package-lock.json')
            if old.returncode == 0:
                return hashlib.sha256(old.stdout.encode()).hexdigest() != lock
        return False

    def install(self, before: Optional[str]) -> None:
        python_stale, node_stale = self.python_stale(), self.node_stale(before)
        if not (python_stale or node_stale):
            self.state.pop('waiting_since', None)
            lock = digest(self.tools / 'package-lock.json')
            if lock and (self.tools / 'node_modules').is_dir():
                try:
                    (self.tools / 'node_modules' / LOCK_STAMP).write_text(lock)
                except OSError:
                    pass
            return
        if self.busy():
            since = self.state.setdefault('waiting_since', self.now)
            self.log('tools need an install; a lane job is running, so it waits')
            if self.now - since > DEFER_LIMIT:
                self.problem('deferred', 'new Python or Node requirements have waited more than 6 hours for a quiet '
                                         'moment between lane jobs; the runners are testing with the old install')
            return
        self.state.pop('waiting_since', None)
        if python_stale:
            done = self.run(['bash', 'scripts/bootstrap-python-tools.sh'], self.tools)
            if done.returncode != 0:
                self.problem('python', f'bootstrap-python-tools.sh failed: {(done.stderr or done.stdout).strip()[-300:]}')
            else:
                self.log('refreshed .venv')
        if node_stale:
            done = self.run(['npm', 'ci', '--no-audit', '--no-fund'], self.tools)
            if done.returncode != 0:
                self.problem('node', f'npm ci failed: {(done.stderr or done.stdout).strip()[-300:]}')
            else:
                lock = digest(self.tools / 'package-lock.json') or ''
                (self.tools / 'node_modules' / LOCK_STAMP).write_text(lock)
                self.log('refreshed node_modules')

    def go(self) -> int:
        if not (self.tools / '.git').exists():
            self.problem('missing', 'is not a git checkout, so it cannot follow main')
            self.save()
            return 1
        before = self.update_checkout()
        self.install(before)
        for ref in documents_references(self.tools):
            self.problem('documents', f'points into ~/Documents, which macOS denies the runners: {ref}')
        if not self.problems:
            self.log('tools copy is current')
        self.save()
        return 1 if self.problems else 0


def post_comment(text: str) -> None:
    done = subprocess.run(['gh', 'issue', 'comment', str(REPORT_ISSUE), '--repo', REPO_SLUG, '--body', text],
                          capture_output=True, text=True, timeout=120)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip()[:200])


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--tools', type=Path, default=default_tools())
    parser.add_argument('--state', type=Path, default=default_state())
    parser.add_argument('--no-post', action='store_true', help='print problems instead of commenting on #337')
    args = parser.parse_args(argv)
    return Refresh(args.tools, args.state, time.time(),
                   post=None if args.no_post else post_comment).go()


if __name__ == '__main__':
    sys.exit(main())
