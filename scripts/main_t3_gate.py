#!/usr/bin/env python3
"""The release gate on main's scheduled app tests (#4575, plan on #2048): no phone build or App Store Connect upload of
a commit without a green `main-t3` status on that exact SHA.

Owner decision 2026-11-18: no per-PR simulator runs; main is tested on a schedule (scripts/main_t3.py,
.github/workflows/main-t3.yml), and a release takes only a commit that run passed. main_t3.py writes the contract this
reads: a commit status with context `main-t3` whose state is `success` only when every app test passed.

Who reads it:
- scripts/phone-build. A build of the trunk takes the newest commit in the tip's history that main-t3 passed, not the
  tip itself, and says so when they differ; with none in reach it builds nothing. A build of a named commit (--commit)
  or a hosted build of a commit without a green main-t3 is refused with a line naming the SHA, and phone-build starts
  a main-t3 run on that commit itself (`request`) when it is on main and has no result or a runner fault, so a build
  can follow once it passes.
- The upload steps (AGENTS.md "Releasing a build"): `scripts/main_t3_gate.py check --sha <archived commit>` before an
  upload, which exits 1 and names the SHA when the commit has no green run. `--request` also starts one.

Usage:
  scripts/main_t3_gate.py check --sha SHA [--request]
  scripts/main_t3_gate.py request --sha SHA

`check` exits 0 when main-t3 passed on SHA, 1 when it did not (the line says what it found: no run, in progress,
failed, a runner fault), 2 when GitHub could not be read. `--request` starts a run only for no result or a runner
fault, not for a real failure. `request` dispatches main-t3.yml for SHA with `force` (a run starts even if the commit
has a status already) and exits 0 when GitHub took it; main-t3 tests only a commit on main. SHA is the full 40
characters.
Environment: GH_REPO (default Spoken-Margins/spoken-margins-native), SM_GATE_GH (the gh command, for tests).
Stdlib only, Python 3.9-compatible: launchd runs phone-build under /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Callable, Optional

CONTEXT = 'main-t3'
WORKFLOW = 'main-t3.yml'
DEFAULT_REPO = 'Spoken-Margins/spoken-margins-native'
# How far back in the tip's history a trunk build looks for a commit main-t3 passed. main-t3 runs every 3 hours and on
# a push (with a 3-hour floor), so a green commit is normally a few merges back; 100 covers a busy day.
HISTORY_DEPTH = 100

Gh = Callable[..., Optional[str]]

HISTORY_QUERY = '''query($owner: String!, $name: String!, $expr: String!) {
  repository(owner: $owner, name: $name) { object(expression: $expr) { ... on Commit {
    history(first: %d) { nodes { oid status { context(name: "%s") { state } } } } } } } }''' % (HISTORY_DEPTH, CONTEXT)

FULL_SHA = re.compile(r'[0-9a-f]{40}')
# A run is worth starting only when the commit has no result or a runner fault: a `failure` is a real test failure
# that main_t3.py already retried, so another ~80-minute run would fail the same way (start one by hand with `request`).
WORTH_A_RUN = (None, 'error')

WORDS = {
    None: 'no main-t3 run on it yet',
    'pending': 'its main-t3 run is still going',
    'failure': 'main-t3 failed on it',
    'error': 'its main-t3 run hit a runner fault, which proves nothing',
}


def newest_state(statuses) -> tuple[Optional[str], Optional[str]]:
    """(state, target_url) of the newest main-t3 status in a commit's statuses list; (None, None) with none."""
    ours = sorted((s for s in statuses or [] if isinstance(s, dict) and s.get('context') == CONTEXT),
                  key=lambda s: s.get('created_at') or '', reverse=True)
    if not ours:
        return None, None
    return (ours[0].get('state') or None), (ours[0].get('target_url') or None)


def newest_green(nodes) -> Optional[str]:
    """The oid of the first commit in a history (the commit itself first) that main-t3 passed, or None."""
    for node in nodes or []:
        state = (((node or {}).get('status') or {}).get('context') or {}).get('state') or ''
        if state.lower() == 'success' and node.get('oid'):
            return node['oid']
    return None


def state_of(gh: Gh, repo: str, sha: str) -> tuple[Optional[str], Optional[str], bool]:
    """(state, target_url, read): `read` is False when GitHub could not be read, so nothing is known."""
    raw = gh('api', f'repos/{repo}/commits/{sha}/statuses?per_page=100')
    if raw is None:
        return None, None, False
    try:
        statuses = json.loads(raw)
    except ValueError:
        return None, None, False
    if not isinstance(statuses, list):
        return None, None, False
    state, url = newest_state(statuses)
    return state, url, True


def green_in_history(gh: Gh, repo: str, sha: str) -> tuple[Optional[str], bool]:
    """(the newest commit main-t3 passed in `sha`'s history, read). `read` is False when GitHub could not be read."""
    owner, name = repo.split('/', 1)
    raw = gh('api', 'graphql', '-f', f'query={HISTORY_QUERY}', '-f', f'owner={owner}', '-f', f'name={name}',
             '-f', f'expr={sha}')
    if raw is None:
        return None, False
    try:
        nodes = json.loads(raw)['data']['repository']['object']['history']['nodes']
    except (ValueError, KeyError, TypeError):
        return None, False
    return newest_green(nodes), True


def refusal(sha: str, state: Optional[str], read: bool = True) -> str:
    """The plain line for a commit the gate refuses."""
    if not read:
        return f'refused {sha}: GitHub could not be read, so whether main-t3 passed on it is unknown'
    return f'refused {sha}: {WORDS.get(state, f"its main-t3 status is {state}")}, and a release needs a green one (#4575)'


def request(gh: Gh, repo: str, sha: str) -> bool:
    """Starts main-t3 on `sha` (workflow_dispatch with `force`). True when GitHub took it.

    The workflow tests only a full SHA on main and ends at once otherwise, so callers pass a full SHA they know is on
    main; a short one is refused here rather than "started"."""
    if not FULL_SHA.fullmatch(sha):
        return False
    return gh('workflow', 'run', WORKFLOW, '--repo', repo, '-f', f'sha={sha}', '-f', 'force=true') is not None


def full_sha(value: str) -> str:
    """argparse type: the full 40-character SHA main-t3's status and dispatch are keyed by."""
    value = value.strip().lower()
    if not FULL_SHA.fullmatch(value):
        raise argparse.ArgumentTypeError(f'{value!r} is not a full 40-character commit SHA')
    return value


def default_gh(*args) -> Optional[str]:
    command = os.environ.get('SM_GATE_GH', 'gh').split()
    try:
        done = subprocess.run([*command, *args], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def main(argv=None, gh: Gh = default_gh) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('command', choices=['check', 'request'])
    parser.add_argument('--sha', required=True, type=full_sha, help='the full commit SHA (on main)')
    parser.add_argument('--request', action='store_true',
                        help='check: also start a main-t3 run when the commit has none or a runner fault')
    args = parser.parse_args(argv)
    repo = os.environ.get('GH_REPO') or DEFAULT_REPO
    if args.command == 'request':
        if request(gh, repo, args.sha):
            print(f'started a main-t3 run on {args.sha}')
            return 0
        print(f'could not start a main-t3 run on {args.sha}', file=sys.stderr)
        return 2
    state, url, read = state_of(gh, repo, args.sha)
    if state == 'success':
        print(f'allowed {args.sha}: main-t3 passed on it' + (f' ({url})' if url else ''))
        return 0
    print(refusal(args.sha, state, read), file=sys.stderr)
    if not read:
        return 2
    if args.request and state in WORTH_A_RUN:
        print(('started' if request(gh, repo, args.sha) else 'could not start') + f' a main-t3 run on {args.sha}',
              file=sys.stderr)
    elif args.request and state == 'failure':
        print(f'started no run: main-t3 failed on {args.sha} and would fail again; '
              f'`{sys.argv[0]} request --sha {args.sha}` forces one', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
