#!/usr/bin/env python3
"""Every open issue carries exactly one area label (owner, 2026-11-07; #3636). Deterministic, no model.

The five areas are in docs/areas.md. They were a field on the GitHub Project board from 2026-10-31 (#2173), but
cloud sessions can't read or write the board (GraphQL is blocked for them, and the user project answers their
token with 403), so most threads worked blind to an issue's area. Labels are readable and writable everywhere.

For each open issue (pull requests are skipped):
  - exactly one area label: fine, and a `needs-area` label from an earlier pass comes off;
  - none, or two or more: the issue gets `needs-area`. No comment: the label is the whole signal, and a first
    pass over the backlog must not post hundreds of comments.

`--from-board` (one-off, run on the Mac, whose `gh` token has the project scope) first copies each issue's board
Area onto a label when the issue has no area label yet. The board is left as it is.

Dry-run is the default; --apply writes. It runs from the Claude Mac worker's hourly pass
(ops/claude/sm_claude_worker.py), in place of the retired scripts/sm_project_sync.py.
Exit 0 whatever it flagged; 2 when a read failed.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_status

AREAS = {   # label -> colour; the order is docs/areas.md's
    'area: get it in': '1d76db',
    'area: hear it well': '0e8a16',
    'area: answer it': 'fbca04',
    'area: pass it on': '5319e7',
    'area: groundwork': 'bfbfbf',
}
NEEDS = 'needs-area'
NEEDS_COLOUR = 'd93f0b'


def board_name_to_label(name: str) -> str | None:
    """The board's Area option ("1. Get it in", "Groundwork", ...) as its label, or None if it is no area."""
    words = re.sub(r'^\s*\d+[.)]?\s*', '', name or '').strip().lower()
    words = re.sub(r'\s+', ' ', words)
    label = f'area: {words}'
    return label if label in AREAS else None


def areas_of(issue: dict) -> list[str]:
    return sorted(label['name'] for label in issue.get('labels') or [] if label.get('name') in AREAS)


def ensure_labels(api, apply: bool, report: dict) -> None:
    have = {label['name'] for label in api.pages('labels')}
    for name, colour in [*AREAS.items(), (NEEDS, NEEDS_COLOUR)]:
        if name not in have:
            report['labels_created'].append(name)
            if apply:
                api.post('labels', {'name': name, 'color': colour})


def board_areas(owner: str, number: int, repo: str) -> dict[int, str]:
    """Issue number -> board Area option name, read with the Mac's project-scoped token."""
    import sm_project_sync
    board = sm_project_sync.project(sm_project_sync.GitHub(repo), owner, number)
    return {n: item['values'].get('Area', '') for n, item in board['items'].items() if item['values'].get('Area')}


def reconcile(api, apply: bool = False, board: dict[int, str] | None = None) -> dict:
    started = time.monotonic()
    report = {'apply': apply, 'labels_created': [], 'copied': [], 'flagged': [], 'cleared': [],
              'unchanged': 0, 'unknown': []}
    ensure_labels(api, apply, report)
    for issue in api.pages('issues?state=open&sort=created&direction=asc', limit=60):
        if 'pull_request' in issue:
            continue
        number = issue['number']
        try:
            areas = areas_of(issue)
            if not areas and board and number in board:
                label = board_name_to_label(board[number])
                if label is None:
                    report['unknown'].append({'issue': number, 'reason': f'board Area {board[number]!r} is no area'})
                else:
                    report['copied'].append({'issue': number, 'label': label})
                    if apply:
                        api.post(f'issues/{number}/labels', {'labels': [label]})
                    areas = [label]
            flagged = any(label.get('name') == NEEDS for label in issue.get('labels') or [])
            ok = len(areas) == 1
            if ok and flagged:
                report['cleared'].append(number)
                if apply:
                    try:
                        api.delete(f'issues/{number}/labels/{NEEDS}')
                    except sm_status.GitHubError as error:
                        if 'HTTP 404' not in str(error):   # 404: someone took it off first
                            raise
            elif not ok and not flagged:
                report['flagged'].append({'issue': number, 'areas': areas})
                if apply:
                    api.post(f'issues/{number}/labels', {'labels': [NEEDS]})
            else:
                report['unchanged'] += 1
        except (sm_status.GitHubError, KeyError, TypeError, ValueError, OSError) as error:
            report['unknown'].append({'issue': number, 'reason': str(error)})
    report.update(api_calls=getattr(api, 'calls', None), seconds=round(time.monotonic() - started, 3))
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--repo', default=sm_status.REPO)
    parser.add_argument('--from-board', action='store_true', help='one-off: copy board Area values onto labels first')
    parser.add_argument('--owner', default='uncomposed')
    parser.add_argument('--project', type=int, default=6)
    parser.add_argument('--ledger-state', type=Path, help='existing step-ledger directory; apply runs only')
    args = parser.parse_args(argv)
    try:
        board = board_areas(args.owner, args.project, args.repo) if args.from_board else None
        report = reconcile(sm_status.GitHub(args.repo), args.apply, board)
    except (sm_status.GitHubError, ImportError, KeyError, TypeError) as error:
        print(json.dumps({'unknown': [{'issue': None, 'reason': str(error)}]}, indent=2))
        return 2
    if args.apply and args.ledger_state:
        import lane_ledger
        report['ledger_alarms'] = lane_ledger.record_runs(args.ledger_state, [{
            'step': 'area-labels', 'result': 'fault' if report['unknown'] else 'pass',
            'seconds': report['seconds']}], pr=0, head='area-labels')
    print(json.dumps(report, indent=2))
    return 2 if report['unknown'] else 0


if __name__ == '__main__':
    sys.exit(main())
