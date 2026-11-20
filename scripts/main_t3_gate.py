#!/usr/bin/env python3
"""Refuse to build a commit for the owner's phone or App Store Connect unless main's T3 passed on it (#4575).

Owner's call, 2026-11-18 (#2048): no per-PR simulator run; main is tested on a schedule; and no TestFlight or
App Store Connect build, and no rolling phone build, is made from a commit whose app-hosted T3 on main did not
pass. The scheduled main T3 (#4573) records its result as a GitHub commit status on the tested commit:
context `main-t3`, state `success`, `failure` or `error`, target_url the run. This module reads it back.

The rule: the commit's newest `main-t3` status must be `success`. Missing, `pending`, `failure`, `error`, or
GitHub unreachable, refuses, and the message names the commit, the state found, the run link, and how to get
a green one. The owner alone may build anyway with `--allow-without-main-t3 "<reason>"`; the reason is printed
and appended as one JSON line to the override log (SM_MAIN_T3_OVERRIDE_LOG, default
~/Library/Logs/SpokenMargins/main-t3-overrides.jsonl), so routine overrides show up.

Callers: scripts/phone-build (the rolling phone build, both sources) and scripts/xcodebuild-lane (an
`archive`, the first step of an upload). Run it by hand on any commit:

  scripts/main_t3_gate.py [<commit>]            exit 0 allowed, 1 refused, 2 bad arguments
  scripts/main_t3_gate.py <commit> --allow-without-main-t3 "<reason>"

Stdlib only, Python 3.9-compatible: scripts/phone-build imports it under launchd's /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import datetime
import getpass
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Optional, Tuple

REPO = 'Spoken-Margins/spoken-margins-native'
CONTEXT = 'main-t3'
WORKFLOW = 'main-t3.yml'  # the scheduled main T3 (#4573); a run can be dispatched on one commit
OVERRIDE_FLAG = '--allow-without-main-t3'
GREEN = 'success'
SEARCH_DEPTH = 100  # newest_green looks this far back in main's history
FULL_SHA = re.compile(r'[0-9a-f]{40}')

# A gh runner: (args) -> (stdout or None when it failed, why it failed).
GhRunner = Callable[..., Tuple[Optional[str], str]]


class Verdict:
    """Whether a commit may be built, and the words that say why."""

    def __init__(self, sha: str, allowed: bool, state: str, url: str = '', reason: str = '', detail: str = ''):
        self.sha, self.allowed, self.state, self.url = sha, allowed, state, url
        self.reason = reason  # the override's reason, when the owner built without a green run
        self.detail = detail  # why GitHub couldn't be read, when it couldn't
        self.logged_to: Optional[Path] = None  # where an override was recorded

    @property
    def overridden(self) -> bool:
        return bool(self.reason)

    def lines(self) -> list:
        found = f'{CONTEXT}: {self.state}' + (f' ({self.detail})' if self.detail else '')
        run = [f'  - run: {self.url}'] if self.url else []
        if self.allowed and not self.overridden:
            return [f'main T3 gate: allowed. main\'s T3 passed on {self.sha}.'] + run
        if self.overridden:
            return [f'main T3 gate: OVERRIDDEN. {self.sha} has no green main T3 ({found}); building anyway.',
                    f'  - reason: {self.reason}'] + run
        return [f'main T3 gate: REFUSED. main\'s T3 has not passed on {self.sha} ({found}).'] + run + [
            '  - To get one: dispatch the main-t3 workflow on this commit '
            f'(gh workflow run {WORKFLOW} --ref main -f sha={self.sha}), or run the Test Desk\'s local T3 on it '
            f'and post its result as a `{CONTEXT}` commit status (docs/releasing.md).',
            f'  - Owner only: {OVERRIDE_FLAG} "<reason>" builds anyway and records the reason.']


def latest_status(statuses: Iterable[dict], context: str = CONTEXT) -> Optional[dict]:
    """The newest status for `context`. GitHub lists newest first, but sort anyway: by created_at, then id."""
    mine = [s for s in statuses if isinstance(s, dict) and s.get('context') == context]
    if not mine:
        return None
    return max(mine, key=lambda s: (str(s.get('created_at') or s.get('updated_at') or ''), s.get('id') or 0))


def check_reason(reason: Optional[str]) -> Optional[str]:
    """The override's reason, stripped; None when there is no override. An empty reason is refused."""
    if reason is None:
        return None
    if not reason.strip():
        raise ValueError(f'{OVERRIDE_FLAG} needs a reason: say why this commit ships without a green main T3')
    return ' '.join(reason.split())


def decide(sha: str, statuses: Optional[list], override: Optional[str] = None, detail: str = '') -> Verdict:
    """The verdict for `sha` from its commit statuses (None: GitHub couldn't be read, `detail` says why)."""
    reason = check_reason(override)
    if statuses is None:
        state, url = 'unknown, GitHub could not be read', ''
    else:
        newest = latest_status(statuses)
        state = str(newest.get('state') or 'unknown') if newest else 'missing'
        url = str(newest.get('target_url') or '') if newest else ''
    if state == GREEN:
        return Verdict(sha, True, state, url)
    return Verdict(sha, reason is not None, state, url, reason or '', detail)


def _gh(*args) -> Tuple[Optional[str], str]:
    try:
        done = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as failure:
        return None, f'gh could not run ({failure})'
    if done.returncode == 0:
        return done.stdout, ''
    lines = [line.strip() for line in (done.stderr or done.stdout or '').splitlines() if line.strip()]
    return None, f'gh exited {done.returncode}' + (f': {lines[-1][:200]}' if lines else '')


def fetch_statuses(sha: str, gh: Optional[GhRunner] = None, repo: str = REPO) -> Tuple[Optional[list], str]:
    """(the commit's statuses, or None and why GitHub couldn't be read). One paginated `gh api` call."""
    out, why = (gh or _gh)('api', '--paginate', f'repos/{repo}/commits/{sha}/statuses', '--jq', '.[] | @json')
    if out is None:
        return None, why
    statuses = []
    for line in out.split('\n'):
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict):
            statuses.append(item)
    return statuses, ''


NEWEST_GREEN_QUERY = '''query($owner: String!, $name: String!, $ref: String!, $depth: Int!) {
  repository(owner: $owner, name: $name) { ref(qualifiedName: $ref) { target { ... on Commit {
    history(first: $depth) { nodes { oid status { context(name: "%s") { state targetUrl } } } }
  } } } }
}''' % CONTEXT


def newest_green(branch: str = 'main', gh: Optional[GhRunner] = None, repo: str = REPO,
                 depth: int = SEARCH_DEPTH) -> Tuple[Optional[str], str]:
    """(the newest commit on `branch` whose newest main-t3 status is success, or None and why). One GraphQL call.

    GitHub's `context(name:)` is the newest status of that context, the same rule `decide` applies."""
    owner, name = repo.split('/', 1)
    out, why = (gh or _gh)('api', 'graphql', '-f', f'query={NEWEST_GREEN_QUERY}', '-f', f'owner={owner}', '-f',
                           f'name={name}', '-f', f'ref=refs/heads/{branch}', '-F', f'depth={depth}')
    if out is None:
        return None, f'GitHub could not be read ({why})'
    try:
        nodes = json.loads(out)['data']['repository']['ref']['target']['history']['nodes']
    except (ValueError, KeyError, TypeError):
        return None, 'GitHub\'s answer had no commit history'
    for node in nodes or []:
        context = ((node or {}).get('status') or {}).get('context') or {}
        if str(context.get('state', '')).lower() == GREEN and FULL_SHA.fullmatch(str(node.get('oid', ''))):
            return node['oid'], ''
    return None, f'none of {branch}\'s newest {depth} commits has a green {CONTEXT} status yet'


def override_log() -> Path:
    configured = os.environ.get('SM_MAIN_T3_OVERRIDE_LOG')
    return Path(configured) if configured else Path.home() / 'Library' / 'Logs' / 'SpokenMargins' / 'main-t3-overrides.jsonl'


def record_override(verdict: Verdict, tool: str, path: Optional[Path] = None) -> Optional[Path]:
    """Append an override to the log; the log's path, or None if it couldn't be written (the build still says so)."""
    if not verdict.overridden:
        return None
    path = path or override_log()
    entry = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'), 'tool': tool,
             'sha': verdict.sha, 'found': verdict.state, 'run': verdict.url, 'reason': verdict.reason}
    try:
        user = getpass.getuser()
    except (KeyError, OSError):  # no passwd entry, as in some containers: the line is still worth keeping
        user = ''
    entry['user'] = user
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a', encoding='utf-8') as log:
            log.write(json.dumps(entry, sort_keys=True) + '\n')
    except OSError:
        return None
    return path


def check(sha: str, override: Optional[str], tool: str, gh: Optional[GhRunner] = None, repo: str = REPO) -> Verdict:
    """Fetch, decide and record: the one call a release path makes."""
    if not FULL_SHA.fullmatch(sha):
        raise ValueError(f'the main T3 gate needs a full 40-character commit, not {sha!r}')
    statuses, why = fetch_statuses(sha, gh, repo)
    verdict = decide(sha, statuses, override, why)
    if verdict.overridden:
        verdict.logged_to = record_override(verdict, tool)
    return verdict


def report(verdict: Verdict, say: Callable[[str], None]) -> None:
    for line in verdict.lines():
        say(line)
    if verdict.overridden:
        say(f'  - recorded in {verdict.logged_to}' if verdict.logged_to else '  - the override log could not be written; this output is the record')


def split_override(argv: list) -> Tuple[list, Optional[str]]:
    """(argv without the override flag, its reason or None), for wrappers that pass the rest on (xcodebuild-lane).

    The flag needs a following value; a missing one raises ValueError."""
    rest, reason, i = [], None, 0
    while i < len(argv):
        arg = argv[i]
        if arg == OVERRIDE_FLAG:
            if i + 1 >= len(argv):
                raise ValueError(f'{OVERRIDE_FLAG} needs a reason')
            reason, i = argv[i + 1], i + 2
            continue
        if arg.startswith(OVERRIDE_FLAG + '='):
            reason = arg.split('=', 1)[1]
        else:
            rest.append(arg)
        i += 1
    return rest, reason


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('commit', nargs='?', default='HEAD', help='a commit or ref (default: HEAD)')
    parser.add_argument(OVERRIDE_FLAG, dest='override', metavar='REASON',
                        help='owner only: allow the commit without a green main T3, recording REASON')
    args = parser.parse_args(argv)
    try:
        sha = subprocess.run(['git', 'rev-parse', '--verify', f'{args.commit}^{{commit}}'], capture_output=True,
                             text=True, check=True).stdout.strip()
        verdict = check(sha, args.override, 'main_t3_gate.py')
    except subprocess.CalledProcessError:
        print(f'main T3 gate: {args.commit!r} is not a commit here', file=sys.stderr)
        return 2
    except ValueError as error:
        print(f'main T3 gate: {error}', file=sys.stderr)
        return 2
    stream = sys.stdout if verdict.allowed else sys.stderr
    report(verdict, lambda line: print(line, file=stream))
    return 0 if verdict.allowed else 1


if __name__ == '__main__':
    sys.exit(main())
