#!/usr/bin/env python3
"""Tally the Linux SessionKitCoreTests retry-passes on #2176 (#3529; owner, 2026-10-24).

`scripts/linux_core_tests.py run` reruns a red Linux run once, and a pass on the rerun counts as a pass. It hands the
tests that passed only on the rerun to the portable job's `retried` output. hosted-portable.yml's linux-retry-tally
job runs this script from the PR's base, never the PR's code, with a token that may write issues and nothing else.
It posts one `flake-tally:` comment per test, in scripts/flake_tally.py's format so the lane's and the hosted
integration run's tallies count it too, and opens a `ready` Showcase `Flaky:` issue for a test with 3 or more in
7 days. Best effort: the portable check already passed, and a GitHub error is a warning, not a red run.

    RETRIED=<names, comma-separated> HEAD_SHA=<sha> RUN_ID=<id> GH_REPO=<owner/repo> python3 scripts/linux_core_tally.py
"""
from __future__ import annotations

import datetime as dt
import os
import re
import subprocess
import sys

import flake_tally
import flake_tally_report

# The names linux_core_tests.py hands over: a test, or the whole run when the first run named none. Anything else
# came from somewhere else and is dropped, so a forged name can't post a look-alike line or a marker.
NAME = re.compile(r'SessionKitCoreTests(/\w+/\w+)?')


def names(raw: str) -> list[str]:
    kept = []
    for name in (part.strip() for part in raw.split(',')):
        if NAME.fullmatch(name):
            kept.append(name)
        elif name:
            print(f'Not a SessionKitCoreTests name, dropped: {name[:80]!r}', flush=True)
    return kept


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    def post(self, body: str) -> None:
        done = subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{self.repo}/issues/{flake_tally.TALLY_ISSUE}/comments',
                               '-f', f'body={body}'], capture_output=True, text=True)
        if done.returncode:
            raise RuntimeError(done.stderr.strip()[:300])

    def comments(self) -> list[dict]:
        return flake_tally_report.fetch_comments(self.repo)

    def open_issues(self) -> list[dict]:
        return flake_tally_report.fetch_open_issues(self.repo)

    def closed_issues(self, since: dt.datetime) -> list[dict]:
        return flake_tally_report.fetch_closed_issues(self.repo, since)

    def open_issue(self, title: str, body: str) -> str:
        return flake_tally_report.open_issue(self.repo, title, body)


def tally(tests: list[str], sha: str, run_id: str, repo: str, ops, now: dt.datetime) -> list[str]:
    """Post each retry-pass, then open an issue for any of these tests now due one. Returns the issues opened."""
    opened: list[str] = []
    try:
        for test in tests:
            ops.post(flake_tally.tally_line(test, sha, run_id, now) +
                     f'\n\n`{test}` passed on retry on Linux in hosted-portable run {run_id}.')
            print(f'Tallied on #{flake_tally.TALLY_ISSUE}: {test}', flush=True)
        counts = flake_tally.tally_counts(ops.comments(), now, closed=flake_tally.closed_flake_markers(
            ops.closed_issues(now - flake_tally.TALLY_WINDOW)))
        for test in flake_tally.tests_due_an_issue(counts, flake_tally.flake_markers(ops.open_issues())):
            if test in tests:
                title, body = flake_tally.flake_issue_text(test, counts[test], repo)
                opened.append(ops.open_issue(title, body))
                print(f'Opened {opened[-1]}', flush=True)
    except Exception as error:  # noqa: BLE001 - the check already passed; the warning names what was lost
        print(f'::warning title=linux-core-tally::Could not tally {", ".join(tests)} on '
              f'#{flake_tally.TALLY_ISSUE}: {str(error)[:300]}', flush=True)
    return opened


def main(argv=None, environ=None, ops=None) -> int:
    environ = os.environ if environ is None else environ
    tests = names(environ.get('RETRIED', ''))
    if not tests:
        print('No Linux retry-pass to tally.', flush=True)
        return 0
    repo = environ.get('GH_REPO') or flake_tally_report.REPO
    tally(tests, environ.get('HEAD_SHA') or 'unknown', environ.get('RUN_ID') or 'unknown', repo,
          ops or GitHub(repo), dt.datetime.now(dt.timezone.utc))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
