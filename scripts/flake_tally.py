"""The retry-pass tally on #2176, in one place (owner call 2026-10-24; #2176, #2596).

A test that failed and then passed on its rerun counts as a pass, and each such retry-pass is tallied as a comment
on #2176 whose first line is `flake-tally: <test> <sha7> <run id> <UTC time>`. A test with 3 or more retry-passes
in 7 days gets its own `ready` Showcase issue, whose body carries `<!-- flake-test: <test> -->` so a second issue is
never opened for it. The hosted integration run (`ops/testdesk/sm_integration_run.py`), the lane runner
(`scripts/lane-runner.py`) and `scripts/flake_tally_report.py` all format, parse and judge them here, so the
comment format older comments use stays one thing.
"""
from __future__ import annotations

import datetime as dt
import re
from typing import Callable

import comment_trust

TALLY_ISSUE = 2176
TALLY_PREFIX = 'flake-tally:'
TALLY_WINDOW = dt.timedelta(days=7)
TALLY_THRESHOLD = 3
TIME_FORMAT = '%Y-%m-%dT%H:%M:%SZ'
FLAKE_MARKER = re.compile(r'<!-- flake-test: (.+?) -->')
FLAKE_TITLE_MAX = 120


def tally_line(test: str, sha: str, run_id: str, when: dt.datetime) -> str:
    """The machine-readable first line of a tally comment: one test that failed, then passed on retry."""
    return f'{TALLY_PREFIX} {test} {sha[:7]} {run_id} {when.astimezone(dt.timezone.utc).strftime(TIME_FORMAT)}'


def parse_line(body: str | None) -> tuple[str, str, dt.datetime] | None:
    """(test, run id, time) from a comment's first line, or None when it is not a tally line. The test is everything
    between the prefix and the last three fields, so a name with spaces still counts."""
    first = (body or '').splitlines()[:1]
    parts = first[0].split() if first else []
    if len(parts) < 5 or parts[0] != TALLY_PREFIX:
        return None
    try:
        when = dt.datetime.strptime(parts[-1], TIME_FORMAT).replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None
    return ' '.join(parts[1:-3]), parts[-2], when


def bot_only(comment: dict) -> bool:
    """The hosted integration run's stricter rule: only the workflow's own bot counts."""
    return comment_trust.author_login(comment) in comment_trust.TRUSTED_BOTS


def tally_counts(comments: list[dict], now: dt.datetime,
                 trust: Callable[[dict], bool] = comment_trust.trusted) -> dict[str, list[str]]:
    """Retry-passes per test in the last 7 days -> their run ids. Only comments `trust` accepts count (#1822), by
    default the owner, collaborators and the workflow's bot, so a stranger's look-alike line can't open an issue.
    The same run counts once per test."""
    seen: dict[str, dict[str, None]] = {}
    for comment in comments:
        if not trust(comment):
            continue
        parsed = parse_line(comment.get('body'))
        if parsed and now - TALLY_WINDOW <= parsed[2] <= now:
            seen.setdefault(parsed[0], {})[parsed[1]] = None
    return {test: list(runs) for test, runs in seen.items()}


def flake_marker(test: str) -> str:
    """The line in a flake issue's body that says which test it is for: the full test id, matched exactly."""
    return f'<!-- flake-test: {test.replace("-->", "")} -->'


def flake_markers(issues: list[dict]) -> set[str]:
    """Test ids named by a marker in the body of a trusted open issue (#1822: a stranger's marker can't hide a flake)."""
    return {match.group(1) for issue in comment_trust.trusted_only(issues)
            for match in FLAKE_MARKER.finditer(issue.get('body') or '')}


def tests_due_an_issue(counts: dict[str, list[str]], open_markers: set[str]) -> list[str]:
    """Tests with 3 or more retry-passes in the window and no open issue carrying their exact marker. The title
    can't decide this: it is cut to fit, and a short name is a prefix of a longer one."""
    return sorted(test for test, runs in counts.items() if len(runs) >= TALLY_THRESHOLD
                  and test.replace('-->', '') not in open_markers)


def flake_issue_text(test: str, runs: list[str], repo: str, where: str = 'runs') -> tuple[str, str]:
    """(title, body) of the `Flaky:` issue. `where` says what the runs were, e.g. 'hosted integration runs'."""
    name = test.rsplit('/', 1)[-1].removesuffix('()')
    links = '\n'.join(f'- https://github.com/{repo}/actions/runs/{r}' for r in runs)
    prefix = 'Flaky: '
    room = FLAKE_TITLE_MAX - len(prefix)
    return (prefix + (name if len(name) <= room else name[:room - 1] + '…'),
            f'{flake_marker(test)}\n\n`{test}` failed on its first run and passed on a re-run in {len(runs)} {where} '
            f'in the last 7 days (tally on #{TALLY_ISSUE}). The run still counted as a pass '
            f'(owner, 2026-10-24), so fix the test or the code under it rather than leave it to retry.\n\n'
            f'Runs:\n{links}\n')
