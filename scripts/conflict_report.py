#!/usr/bin/env python3
"""Real merge conflicts per file per week, counted from the conflict notices the pipeline already posts (#2398).

Git history cannot show them: a PR that conflicted was fixed by a merge or a rebase, and the merge commit that
lands on trunk reads as clean. What is left on the record is the pipeline's own notice on the PR, in two shapes:

- the hosted conflict check (`scripts/lane_conflicts.py`, #683): "Handing to the Mac finisher: the PR does not merge
  cleanly into `main` (`2bd3335`) at its head `a3cf501`. Conflicting files: `a`, `b`.";
- the lane runner's report (`scripts/lane-runner.py`): "The PR does not merge cleanly into main (2bd3335): a, b. Merge ...".

One event is one PR meeting one trunk tip: both notices for the same PR and trunk tip count once, and a PR that
conflicts again after trunk moved counts again. A file counts once per event. Each notice names at most 10 files,
so a conflict in a PR with more is undercounted; the report says how many notices hit that cap.

What it cannot see: a PR with no lane label (the hosted check looks only at armed PRs), and a conflict the author
resolves before arming. Both are real conflicts missing from the table, so the counts are a floor.

    python3 scripts/conflict_report.py --repo OWNER/NAME --since 2026-09-28 > report.md
    python3 scripts/conflict_report.py --comments-file comments.json --since 2026-09-28   # offline

The comments are read with `gh api`, paged by hand (`--paginate` follows repository-id links the proxy refuses).
Churn (commits touching each file per week) comes from `git log` in the current checkout, which must have the
history for the window (`git fetch --unshallow`).
"""
import argparse
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
import json
from pathlib import Path
import re
import subprocess
import sys

HOSTED = re.compile(
    r'does not merge cleanly into `?(?P<base>[\w./-]+?)`? \(`?(?P<sha>[0-9a-f]{7,40})`?\)(?: at its head `[0-9a-f]+`)?\.'
    r' Conflicting files: (?P<files>.+?)\.(?:\n|$)')
RUNNER = re.compile(
    r'does not merge cleanly into (?P<base>[\w./-]+) \((?P<sha>[0-9a-f]{7,40})\): (?P<files>.+?)\. Merge ')
CAP = 10  # the notices name at most this many files
MORE = re.compile(r'\s+and \d+ more$')


def parse_notice(body):
    """(base, base_sha7, files, capped) for a conflict notice, else None."""
    for pattern in (HOSTED, RUNNER):
        found = pattern.search(body or '')
        if not found:
            continue
        text = found.group('files')
        capped = bool(MORE.search(text))
        text = MORE.sub('', text)
        files = [name.strip().strip('`') for name in re.split(r',\s*', text) if name.strip().strip('`')]
        if not files:
            return None
        return found.group('base'), found.group('sha')[:7], files, capped or len(files) >= CAP
    return None


def week_of(day):
    """The Monday that starts day's week."""
    return day - timedelta(days=day.weekday())


def events_from(comments, since=None):
    """One event per (PR, base sha). Returns a list of dicts: pr, week, base, files, capped."""
    seen = {}
    for comment in sorted(comments, key=lambda item: item['created_at']):
        parsed = parse_notice(comment.get('body'))
        if not parsed:
            continue
        base, sha, files, capped = parsed
        day = datetime.strptime(comment['created_at'][:10], '%Y-%m-%d').date()
        if since and day < since:
            continue
        pr = int(comment['issue_url'].rstrip('/').rsplit('/', 1)[-1])
        key = (pr, base, sha)
        if key in seen:
            # The second notice for the same PR and tip may list files the first one capped.
            known = seen[key]
            known['files'] = known['files'] + [name for name in files if name not in known['files']]
            known['capped'] = known['capped'] and capped
            continue
        seen[key] = {'pr': pr, 'week': week_of(day), 'base': base, 'sha': sha, 'files': list(files), 'capped': capped}
    return list(seen.values())


def tally(events):
    """({file: Counter(week -> events)}, {week: events}, capped_events)."""
    per_file = defaultdict(Counter)
    per_week = Counter()
    for event in events:
        per_week[event['week']] += 1
        for name in set(event['files']):
            per_file[name][event['week']] += 1
    return per_file, per_week, sum(1 for event in events if event['capped'])


def churn(root, since, trunk):
    """{file: Counter(week -> commits touching it)} from git log on trunk since `since`."""
    out = subprocess.run(
        ['git', '-C', str(root), 'log', trunk, f'--since={since.isoformat()}', '--no-merges', '--name-only',
         '--format=@@%ad', '--date=short'], text=True, capture_output=True, check=True).stdout
    per_file = defaultdict(Counter)
    week = None
    for line in out.splitlines():
        if line.startswith('@@'):
            week = week_of(datetime.strptime(line[2:], '%Y-%m-%d').date())
        elif line and week:
            per_file[line][week] += 1
    return per_file


def weeks_between(first, last):
    week, found = week_of(first), []
    while week <= last:
        found.append(week)
        week += timedelta(days=7)
    return found


def render(events, per_file_churn, since, today, top=12):
    per_file, per_week, capped = tally(events)
    weeks = weeks_between(since, today)
    lines = [f'Real merge conflicts, {since.isoformat()} to {today.isoformat()}: {len(events)} events across '
             f'{len({event["pr"] for event in events})} PRs; {capped} notices named {CAP} files (more may be missing).', '',
             'One event is one PR meeting one trunk tip. Weeks start on Monday.', '']
    lines.append('**Events per week**\n')
    lines.append('| Week of | ' + ' | '.join(week.strftime('%m-%d') for week in weeks) + ' | Total |')
    lines.append('|---|' + '---:|' * (len(weeks) + 1))
    lines.append('| Events | ' + ' | '.join(str(per_week[week]) for week in weeks) + f' | {len(events)} |')
    lines.append('')
    ranked = sorted(per_file.items(), key=lambda item: (-sum(item[1].values()), item[0]))[:top]
    lines.append(f'**Conflicts per file per week (top {len(ranked)})**\n')
    lines.append('| File | ' + ' | '.join(week.strftime('%m-%d') for week in weeks)
                 + ' | Conflicts | Commits touching | Conflicts per 100 commits |')
    lines.append('|---|' + '---:|' * (len(weeks) + 3))
    for name, counts in ranked:
        touched = sum(per_file_churn.get(name, {}).values())
        total = sum(counts.values())
        rate = f'{100 * total / touched:.1f}' if touched else 'n/a'
        lines.append(f'| `{name}` | ' + ' | '.join(str(counts[week]) if counts[week] else '' for week in weeks)
                     + f' | {total} | {touched} | {rate} |')
    return '\n'.join(lines) + '\n'


def fetch_comments(repo, since):
    """Every issue and PR comment updated since `since`, newest pages last."""
    comments, page = [], 1
    while True:
        out = subprocess.run(
            ['gh', 'api', '-X', 'GET', f'repos/{repo}/issues/comments', '-f', f'since={since.isoformat()}T00:00:00Z',
             '-f', 'per_page=100', '-f', f'page={page}'], text=True, capture_output=True, timeout=60)
        if out.returncode:
            raise RuntimeError(f'gh api failed on page {page}: {out.stderr.strip()[:200]}')
        items = json.loads(out.stdout)
        if not items:
            return comments
        comments += [{'created_at': item['created_at'], 'issue_url': item['issue_url'], 'body': item['body']}
                     for item in items if 'does not merge cleanly' in (item['body'] or '')]
        page += 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--repo', default='Spoken-Margins/spoken-margins-native')
    parser.add_argument('--since', required=True, help='first day counted, YYYY-MM-DD')
    parser.add_argument('--trunk', default='origin/main')
    parser.add_argument('--comments-file', help='JSON list of {created_at, issue_url, body}; skips the GitHub read')
    parser.add_argument('--top', type=int, default=12)
    args = parser.parse_args(argv)
    since = datetime.strptime(args.since, '%Y-%m-%d').date()
    if args.comments_file:
        comments = json.loads(Path(args.comments_file).read_text())
    else:
        comments = fetch_comments(args.repo, since)
    root = Path(__file__).resolve().parents[1]
    sys.stdout.write(render(events_from(comments, since), churn(root, since, args.trunk), since, date.today(), args.top))


if __name__ == '__main__':
    main()
