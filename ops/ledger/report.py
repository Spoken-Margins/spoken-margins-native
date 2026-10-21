#!/usr/bin/env python3
"""Print a local weekly usage summary; never post it. Python 3.9+, stdlib only."""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import sys
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import claude_sessions
import comment_trust  # #1822: only trusted authors' comments count as a confirmed fix
import usage

REPO = 'Spoken-Margins/spoken-margins-native'


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))


def load_rows(path: Path) -> list:
    rows = []
    if not path.exists():
        return rows
    with path.open() as source:
        for number, line in enumerate(source, 1):
            try:
                rows.append(json.loads(line))
            except ValueError:
                raise ValueError(f'{path}:{number}: malformed ledger row; report aborted')
    return rows


def totals(rows: list) -> dict:
    result = {field: sum(row.get(field) or 0 for row in rows) for field in usage.TOKEN_FIELDS}
    result['tokens'] = result['input_tokens'] + result['output_tokens']
    result['runs'] = len(rows)
    result['incomplete_runs'] = sum(not row.get('usage_complete') for row in rows)
    result['missing_fields'] = sum(any(row.get(field) is None for field in usage.TOKEN_FIELDS) for row in rows)
    return result


def target_key(row: dict, target: dict):
    return (row['job'], target.get('pr') or tuple(target.get('issues') or []))


def repeated_runs(all_rows: list) -> set:
    previous, repeated = {}, set()
    for row in sorted(all_rows, key=lambda row: row['time']):
        comparisons = []
        for target in row.get('targets') or []:
            outcome = target.get('outcome') or row.get('outcome') or {}
            value = outcome.get('signature')
            key = target_key(row, target)
            comparisons.append(bool(value and previous.get(key) == value))
            if value:
                previous[key] = value
        # A batch that finds something new on one PR isn't wholly repeated work.
        if comparisons and all(comparisons):
            repeated.add(row['run_id'])
    return repeated


def normalized_title(value: str) -> str:
    return re.sub(r'[^\w]+', ' ', re.sub(r'\[P[0-3]\]', '', value).casefold()).strip()


def confirmed_fixes(row: dict, target: dict, comments: list, compare) -> set:
    """Count exact title + explicit fixed-in SHA + a later commit touching the file.

    This is evidence of a claimed fix, not proof of behavior. Unmatched prose,
    accepted findings and commits merely touching the file are never counted.
    """
    confirmed = set()
    outcome = target.get('outcome') or row.get('outcome') or {}
    audit_url = target.get('comment_url')
    for finding in outcome.get('findings') or []:
        if not finding.get('file'):
            continue
        title = normalized_title(finding['title'])
        for comment in comments:
            body = comment.get('body') or ''
            if not comment.get('created_at') or parse_time(comment['created_at']) <= parse_time(row['time']):
                continue
            head = target.get('head_sha')
            if not (audit_url and audit_url in body or head and head[:7] in body):
                continue
            fixed_titles = re.findall(r'\*\*([^*\n]+?):\s*fixed\.?\*\*', body, re.I)
            if title not in [normalized_title(t) for t in fixed_titles]:
                continue
            for sha in re.findall(r'\bfixed in\s+`([a-f0-9]{7,40})`', body, re.I):
                diff = compare(target['head_sha'], sha)
                if (diff.get('status') == 'ahead' and any(
                        f['filename'] == finding['file'] for f in diff.get('files') or [])):
                    confirmed.add((target['pr'], title, finding['file']))
    return confirmed


class GitHub:
    def __init__(self, repo: str):
        self.repo, self.cache = repo, {}

    def get(self, path: str, paginate=False):
        if path not in self.cache:
            cmd = ['gh', 'api', f'repos/{self.repo}/{path}']
            if paginate:
                cmd += ['--paginate', '--slurp']
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
            value = json.loads(res.stdout)
            self.cache[path] = [item for page in value for item in page] if paginate else value
        return self.cache[path]

    def pull(self, number):
        return self.get(f'pulls/{number}')

    def comments(self, number):
        return comment_trust.trusted_only(self.get(f'issues/{number}/comments?per_page=100', paginate=True))  # #1822

    def compare(self, head, sha):
        return self.get(f'compare/{head}...{sha}')

    def bug(self, number):
        return self.get(f'issues/{number}')


def ratio(rows: list, count: int):
    value = totals(rows)
    return round(value['tokens'] / count, 2) if count and not value['incomplete_runs'] else None


CLAUDE_NOT_MEASURED = [
    'Project threads that run in the cloud leave no transcript on this Mac.',
    'Calls Claude Code makes outside the transcript (titles, side queries, compaction) are missing; '
    'coverage.transcript_share is the measured part of Claude Code\'s own total.',
    'Headless runs with --no-session-persistence (the audit job) are counted from usage.jsonl, not here.',
    'Sessions on other machines and claude.ai chats are not measured.']


def claude_summary(claude_rows, start: dt.datetime, end: dt.datetime):
    """Measured Claude desktop turns on this Mac (ops/ledger/claude_sessions.py), kept apart from the
    wrapper rows above so nothing is added twice. None when the collector has never run."""
    if claude_rows is None:
        return None
    week = [row for row in claude_rows if row.get('time') and start <= parse_time(row['time']) < end]
    turns = [row for row in week if row.get('kind') == 'turn']
    by_job = {}
    for job in sorted({row['job'] for row in turns}):
        group = [row for row in turns if row['job'] == job]
        by_job[job] = dict(totals(group), sessions=len({row['session_id'] for row in group}),
                           outcome_links=len({link for row in group for link in row.get('outcome_links') or []}))
    return {'by_job': by_job, 'total': totals(turns),
            'outcome_links': sorted({link for row in turns for link in row.get('outcome_links') or []}),
            'coverage': claude_sessions.coverage(week), 'not_measured': CLAUDE_NOT_MEASURED}


def summarize(all_rows: list, start: dt.datetime, github, claude_rows=None) -> dict:
    end = start + dt.timedelta(days=7)
    rows = [row for row in all_rows if start <= parse_time(row['time']) < end]
    jobs = {job: totals([r for r in rows if r['job'] == job]) for job in sorted({r['job'] for r in rows})}
    merged, fixes, bugs = set(), set(), set()
    for row in rows:
        for target in row.get('targets') or []:
            number = target.get('pr')
            if number:
                pull = github.pull(number)
                if pull.get('merged_at') and start <= parse_time(pull['merged_at']) < end:
                    merged.add(number)
                if row['job'] == 'audit':
                    fixes.update(confirmed_fixes(row, target, github.comments(number), github.compare))
        for posted in row.get('posted') or []:
            if posted.get('created') and posted.get('issue'):
                issue = github.bug(posted['issue'])
                if 'bug' in [label['name'] for label in issue.get('labels') or []]:
                    bugs.add(posted['issue'])
    repeated = repeated_runs(all_rows)
    repeat_rows = [r for r in rows if r['run_id'] in repeated]
    measured = totals(rows)
    coverage = (max(parse_time(r['time']) for r in all_rows) -
                min(parse_time(r['time']) for r in all_rows)).total_seconds() if all_rows else 0
    return {'week_start': start.isoformat(), 'week_end_exclusive': end.isoformat(), 'by_job': jobs,
            'total': measured, 'merged_prs': sorted(merged), 'fixed_audit_findings': len(fixes),
            'testdesk_bugs_filed': sorted(bugs),
            'tokens_per_merged_pr': ratio([r for r in rows if r['job'] in ('audit', 'issue', 'finisher')], len(merged)),
            'tokens_per_fixed_audit_finding': ratio([r for r in rows if r['job'] == 'audit'], len(fixes)),
            'tokens_per_testdesk_bug': ratio([r for r in rows if r['job'] == 'testdesk-diagnosis'], len(bugs)),
            'claude': claude_summary(claude_rows, start, end),
            'repeated_runs': len(repeat_rows), 'repeated_tokens': totals(repeat_rows)['tokens'],
            'repeated_token_share': round(totals(repeat_rows)['tokens'] / measured['tokens'], 4)
                if coverage >= 7 * 86400 and measured['tokens'] and not measured['incomplete_runs'] else None,
            'notes': [
                'Tokens = input + output; cached input is a subset of input, not added again.',
                'Totals are observed subtotals. Ratios/share are null when usage is incomplete or denominator is zero.',
                'One batch counts once; PR ratio uses audit/issue/finisher spend in the week and PRs merged in that week.',
                'Fix count requires an exact-title fixed-in comment linked to the audit and a later commit touching its file.',
                'A claimed fix is not behavioral verification; unmatched fixes remain uncounted.',
                'Repeated means all targets repeat the preceding reported outcome for the same job/PR, not necessarily waste.',
                'No percentage until ledger events span a week.',
                'claude: Claude desktop turns on this Mac, one run per turn; null until claude_sessions.py '
                'has written its ledger. Outcome links are comments and PRs that gh printed when it posted them. '
                'They are not added to total or to the ratios above.']}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--week', required=True, help='Week start date YYYY-MM-DD (America/Chicago by default)')
    parser.add_argument('--timezone', default='America/Chicago')
    parser.add_argument('--ledger', type=Path, default=usage.DEFAULT_DIR / 'usage.jsonl')
    parser.add_argument('--claude-ledger', type=Path, default=claude_sessions.LEDGER)
    parser.add_argument('--repo', default=REPO)
    args = parser.parse_args(argv)
    try:
        usage.recover(args.ledger.parent, log=lambda message: print(message, file=sys.stderr))
        start = dt.datetime.combine(dt.date.fromisoformat(args.week), dt.time(), ZoneInfo(args.timezone))
        claude_rows = load_rows(args.claude_ledger) if args.claude_ledger.exists() else None
        print(json.dumps(summarize(load_rows(args.ledger), start, GitHub(args.repo), claude_rows), indent=2))
    except Exception as error:
        print(f'Usage report failed: {error}; no summary produced', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
