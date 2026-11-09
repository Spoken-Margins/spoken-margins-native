"""What hosted integration has proved about the trunk's tip right now (#3602).

hosted-integration.yml runs one at a time, and a tip that merges while a run is pending replaces the pending run
(its run shows "cancelled" and never started; the next run tests the newer tip, which includes the older one).
So most of the recent runs on `main` read "cancelled" while the check works as designed, and "the last
completed run passed" can stay true of a tip many merges back. This prints the facts a start-of-run check needs:

- the last run that finished with a verdict (success or failure), which tip it tested and how long ago it ended;
- how many merged PRs `main` has gained since that tip;
- the run in progress and the pending one, and which tip each covers;
- one verdict line: OK, RED, STALE or NONE.

    python3 scripts/hosted_integration_status.py [--max-merges N] [--branch NAME]

Exit status: 0 OK, 1 RED, 2 STALE or NONE, 3 could not read GitHub or bad arguments. Reads the Actions API with `gh`; changes nothing.
Stdlib only.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from trunk import trunk_branch  # noqa: E402

REPO = os.environ.get('SM_INTEGRATION_REPO', 'Spoken-Margins/spoken-margins-native')
WORKFLOW = 'hosted-integration.yml'
MAX_MERGES = 10        # a green result this many merged PRs behind the tip is still "OK"; beyond it, STALE
# 'cancelled' and 'skipped' tested nothing. A startup_failure is a workflow file that would not start: red, not silence.
DONE_WITH_VERDICT = ('success', 'failure', 'timed_out', 'startup_failure')
PAGE = 100
MAX_PAGES = 5          # a verdict older than 500 runs back is read as NONE
WAITING = ('queued', 'pending', 'waiting', 'requested')


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def _short(sha: str) -> str:
    return sha[:7]


def _age(delta_seconds: float) -> str:
    minutes = max(0, int(delta_seconds // 60))
    return f'{minutes // 60}h{minutes % 60:02d}m'


def classify(runs: list) -> dict:
    """Pick the newest finished-with-a-verdict run, the run in progress and the newest pending run.

    `runs` is the Actions API's `workflow_runs` list for one branch, newest first (any order works)."""
    ordered = sorted(runs, key=lambda r: r['created_at'], reverse=True)
    last = next((r for r in ordered if r.get('status') == 'completed' and r.get('conclusion') in DONE_WITH_VERDICT), None)
    running = next((r for r in ordered if r.get('status') == 'in_progress'), None)
    pending = next((r for r in ordered if r.get('status') in WAITING), None)
    return {'last': last, 'running': running, 'pending': pending}


def verdict(picked: dict, tip: str, merges_behind: Optional[int], max_merges: int = MAX_MERGES) -> str:
    """OK: the last verdict is green and `main` is at most `max_merges` merges past its tip.
    RED: the last verdict is a failure of any kind (read the run: a test failure and a missing tool differ). STALE: green but further behind, or the distance is unknown.
    NONE: no run with a verdict in the window."""
    last = picked['last']
    if last is None:
        return 'NONE'
    if last['conclusion'] != 'success':
        return 'RED'
    if last['head_sha'] == tip:
        return 'OK'
    if merges_behind is not None and merges_behind <= max_merges:
        return 'OK'
    return 'STALE'


def render(picked: dict, tip: str, merges_behind: Optional[int], now: datetime, max_merges: int = MAX_MERGES) -> str:
    last, running, pending = picked['last'], picked['running'], picked['pending']
    lines = [f'Hosted integration on the trunk (tip {_short(tip)})']
    if last is None:
        lines.append('last finished: none in the runs read (a workflow that is skipped, or whose runs were all cancelled, tested nothing)')
    else:
        ended = _ts(last['updated_at'])
        started = _ts(last.get('run_started_at') or last['created_at'])
        word = 'PASS' if last['conclusion'] == 'success' else f"FAIL ({last['conclusion']})"
        if last['head_sha'] == tip:
            distance = 'it tested the current tip'
        elif merges_behind is None:
            distance = 'distance to the tip unknown'
        else:
            distance = f'the trunk is {merges_behind} merged PR{"" if merges_behind == 1 else "s"} ahead of it'
        lines.append(f"last finished: {word} on {_short(last['head_sha'])}, ran {_age((ended - started).total_seconds())}, "
                     f"ended {_age((now - ended).total_seconds())} ago; {distance}")
    for label, run in (('in progress', running), ('pending', pending)):
        if run is None:
            continue
        since = _ts(run.get('run_started_at') or run['created_at'])
        covers = 'the current tip' if run['head_sha'] == tip else f"{_short(run['head_sha'])}, not the current tip"
        lines.append(f"{label}: {covers}, {_age((now - since).total_seconds())} so far")
    if running is None and pending is None:
        lines.append('no run in progress or pending')
    result = verdict(picked, tip, merges_behind, max_merges)
    meaning = {
        'OK': 'the last result is green and the trunk is within reach of it',
        'RED': 'the last result is a failure; read the run and its report on #184 to see whether it is a test failure',
        'STALE': f'green, but more than {max_merges} merges behind (or the distance is unknown); '
                 'say so on the tracking issue and name the run that will cover the tip',
        'NONE': 'no hosted result in the runs read; check that LANE_HOSTED_APP is on',
    }[result]
    lines.append(f'verdict: {result}: {meaning}')
    return '\n'.join(lines)


def _gh(path: str) -> dict:
    out = subprocess.run(['gh', 'api', path], capture_output=True, text=True, check=True, timeout=60).stdout
    return json.loads(out)


def merges_between(compare: dict) -> int:
    """Merged PRs in a compare result: the commits whose message starts "Merge pull request". A PR branch's own
    "Merge ... main into ws/..." commits are not counted (on 2026-11-07, 10 PR merges came with 17 merge commits and
    37 commits). The API lists at most 250 commits; past that the commit count stands in, which is only ever too high."""
    commits = compare.get('commits') or []
    if compare['ahead_by'] > len(commits):
        return compare['ahead_by']
    return sum(1 for c in commits if ((c.get('commit') or {}).get('message') or '').startswith('Merge pull request'))


def read(branch: str, api: Callable[[str], dict] = _gh) -> tuple:
    """(runs, tip sha, PR merges the trunk gained since the last finished run's tip, or None when no run finished).

    Pages through the runs until one has a verdict, so a day of queued or cancelled runs doesn't hide a red."""
    runs: list = []
    for page in range(1, MAX_PAGES + 1):
        got = api(f'repos/{REPO}/actions/workflows/{WORKFLOW}/runs?branch={branch}&per_page={PAGE}&page={page}')['workflow_runs']
        runs.extend(got)
        if len(got) < PAGE or classify(runs)['last'] is not None:
            break
    tip = api(f'repos/{REPO}/commits/{branch}')['sha']
    last = classify(runs)['last']
    behind = None
    if last is not None and last['conclusion'] == 'success':   # a red needs no distance, and its sha may be gone
        behind = 0 if last['head_sha'] == tip else merges_between(api(f'repos/{REPO}/compare/{last["head_sha"]}...{tip}'))
    return runs, tip, behind


def main(argv=None, api: Callable[[str], dict] = _gh, now: Optional[datetime] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        max_merges, branch = MAX_MERGES, trunk_branch()
        while argv:
            flag = argv.pop(0)
            if flag == '--max-merges':
                max_merges = int(argv.pop(0))
            elif flag == '--branch':
                branch = argv.pop(0)
            else:
                raise ValueError(flag)
    except (ValueError, IndexError):
        print('usage: hosted_integration_status.py [--max-merges N] [--branch NAME]', file=sys.stderr)
        return 3
    try:
        runs, tip, behind = read(branch, api)
        picked = classify(runs)
        text = render(picked, tip, behind, now or datetime.now(timezone.utc), max_merges)
        code = {'OK': 0, 'RED': 1, 'STALE': 2, 'NONE': 2}[verdict(picked, tip, behind, max_merges)]
    except Exception as error:   # any unreadable answer is exit 3, never a traceback that reads as RED (exit 1)
        print(f'could not read GitHub: {type(error).__name__}', file=sys.stderr)
        return 3
    print(text)
    return code


if __name__ == '__main__':
    sys.exit(main())
