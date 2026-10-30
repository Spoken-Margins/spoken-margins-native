#!/usr/bin/env python3
"""Pipeline dashboard: a daily snapshot of what the pipeline costs and catches, kept on a data branch (#2379).

`scripts/pipeline_events.py` gathers the facts when someone runs it. This keeps them: once a day the
`pipeline-dashboard` workflow is the single writer that

1. reads the events already on the orphan `metrics` branch (`events-YYYY-MM.jsonl`, one file a month),
2. collects what is new from GitHub (a few days back, so late results and re-derived labels settle),
3. writes the month files back, and
4. rewrites the body of one issue, "Pipeline value: ...", so the owner sees counts without asking an agent.

    scripts/pipeline_dashboard.py publish --metrics metrics [--dry-run] [--body-out body.md]
    scripts/pipeline_dashboard.py render  --metrics metrics               # print the body from the files

The issue's body is rewritten in place; nothing is commented, so nothing notifies. Colours are Okabe-Ito, and every
series is also named in words and numbers, so colour alone never carries meaning.

What the body holds: one line per lane step and per hosted job with its counts, a batching verdict for the simulator
tier (T3), the five noisiest tests and the five slowest tests that never failed, escapes by source, and a trend chart.

Events hold only ids, enums and numbers: `clean` keeps the keys each kind is known to have and drops an event whose
string does not fit its key's shape (a test id, a hex commit, an enum, a short name; a sentence fits none) or whose value
is a nested object it does not know, so a collector change can't start storing a failure message or a log line. Skipped runs and jobs say nothing about cost or catches, and a run that succeeded or was cancelled is told by its
jobs, so none of those are stored.

The year's files are held under YEAR_BYTES (20 MB). That counts the files as they stand, not git's history of them (each day's
commit adds a delta to a month file, which git packs far smaller). A write that would pass it is not made: the issue says so and
the run fails, so the owner decides what to thin out instead of the branch growing without a limit.

Needs GITHUB_TOKEN (or GH_TOKEN) with actions: read, issues: write and contents: read. The workflow's own git steps
push the branch; this script only edits files in the checked-out `metrics` folder. Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import statistics
import sys
import urllib.parse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import comment_trust  # noqa: E402  (#1822: a stranger's look-alike issue is not ours)
import pipeline_events as pe  # noqa: E402
from trunk import trunk_branch  # noqa: E402

TITLE = 'Pipeline value: what each step and test catches (updated daily)'
MARKER = '<!-- pipeline-dashboard v1 -->'
YEAR_BYTES = 20 * 1024 * 1024
WINDOW_DAYS = 30
TREND_DAYS = 14
BACKFILL_DAYS = 14   # the first run, with no events on the branch yet
OVERLAP_DAYS = 3     # each run collects this far back from its newest event
BODY_LIMIT = 60000   # GitHub takes 65,536 characters in an issue body

# Okabe-Ito: blue, orange. Both are named in words wherever they appear.
BLUE, ORANGE = '#0072B2', '#E69F00'

# The T3 batching verdict: batch when requests wait long and arrive often. Defaults; the counts are printed beside them.
BATCH_WAIT_SECONDS = 15 * 60
BATCH_PER_DAY = 5
BATCH_MIN_REPORTS = 10
BATCH_MIN_WAITS = 5

FAILED = ('failure', 'timed_out', 'startup_failure')
MONTH_FILE = re.compile(r'events-(\d{4})-(\d{2})\.jsonl')

# ---- What an event may hold ---------------------------------------------------------------------------

KEYS = {
    'lane': {'id', 'at', 'pr', 'via', 'run', 'verdict', 'tier', 'head', 'trunk', 'trunk_name', 'seconds',
             'queue_seconds', 'steps', 'tests', 'requested', 'source', 'label'},
    'test-failure': {'id', 'at', 'test', 'pr', 'lane', 'tier', 'head', 'trunk', 'label'},
    'run': {'id', 'at', 'run', 'attempt', 'workflow', 'event', 'branch', 'head', 'conclusion', 'seconds'},
    'job': {'id', 'at', 'run', 'attempt', 'workflow', 'branch', 'job', 'head', 'runner', 'conclusion', 'seconds',
            'queue_seconds', 'failed_step', 'label'},
    'catch': {'id', 'at', 'step', 'test', 'pr', 'from', 'to', 'class', 'seconds'},
    'escape': {'id', 'at', 'source', 'sha', 'reverts', 'pr', 'issue', 'label'},
    'slow': {'id', 'at', 'test', 'seconds', 'reports'},
}
NESTED = {'steps': {'step', 'seconds', 'result'}, 'tests': {'ran', 'failed'}, 'label': {'class', 'by', 'signal', 'step'}}
MAX_STRING = 200
MAX_LIST = 80


# What a string may look like, per key. A key not listed takes WORD: no spaces, so no sentence. Names that CI and the
# lane choose (a job, a step) may hold spaces but are short, start with a letter and carry no quote, slash or pipe.
WORD = r'[\w.:#-]{0,64}'
NAME = r'[A-Za-z][A-Za-z0-9 ()#._,:+-]{0,59}'
TEST = r'[\w.]{1,160}(?:/[\w.]{1,160}){0,2}|step:[A-Za-z][A-Za-z0-9 ()#.-]{0,39}'
HEX = r'[0-9a-f]{0,40}'
STRING_RULES = {
    'id': r'[\w:./#-]{1,260}', 'lane': r'[\w:.-]{1,40}', 'at': r'|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
    'head': HEX, 'trunk': HEX, 'sha': HEX, 'reverts': HEX, 'from': HEX, 'to': HEX,
    'test': TEST, 'requested': r'\w{1,80}(?:/\w{1,120}){0,2}', 'job': NAME, 'failed_step': NAME, 'step': NAME,
    'workflow': r'[A-Za-z][\w.-]{0,59}',
    'verdict': r'PASS|FAIL|INCONCLUSIVE', 'tier': r'auto|T2|T3', 'via': r'pr|desk|integration|other',
    'source': r'line|prose|revert|regression|found-on-phone', 'trunk_name': r'|next|main',
    'result': r'pass|fail|fault', 'runner': r'hosted|self-hosted|unknown', 'branch': r'pr|trunk|other',
    'event': r'pull_request|push|schedule|workflow_dispatch|workflow_run|other',
    'conclusion': r'success|failure|cancelled|skipped|timed_out|neutral|action_required|startup_failure|unknown',
    'class': r'code|flake|trunk-moved|trunk-red|compile|fault|unresolved|cancelled|catch|wrong-test|next-moved|other',
    'by': r'heuristic|human',
}
STRING_RULES = {key: re.compile(rule) for key, rule in STRING_RULES.items()}
DEFAULT_RULE = re.compile(WORD)


def _string_ok(key: str, value) -> bool:
    return isinstance(value, str) and len(value) <= MAX_STRING and \
        (STRING_RULES.get(key) or DEFAULT_RULE).fullmatch(value) is not None


def _scalar(value, key: str = '') -> bool:
    if value is None or isinstance(value, (bool, int)):
        return True
    if isinstance(value, float):
        return math.isfinite(value)
    return _string_ok(key, value)


def clean(event) -> dict | None:
    """The event with only the keys its kind has, or None when it can't be stored: an unknown kind, a value that is
    not a short single-line string or a number, or a nested shape the kind does not have. This is the only way an
    event reaches the branch, so no collector change can add a text field to the file."""
    if not isinstance(event, dict) or event.get('kind') not in KEYS:
        return None
    found = {'kind': event['kind']}
    for key in KEYS[event['kind']]:
        if key not in event:
            continue
        value = event[key]
        if key in NESTED and value is not None:
            allowed = NESTED[key]
            items = value if isinstance(value, list) else [value]
            if not isinstance(value, (dict, list)) or len(items) > MAX_LIST:
                return None
            rows = []
            for item in items:
                if not isinstance(item, dict) or not all(_scalar(v, k) for k, v in item.items() if k in allowed):
                    return None
                rows.append({k: v for k, v in item.items() if k in allowed})
            found[key] = rows if isinstance(value, list) else rows[0]
        elif isinstance(value, list):
            if len(value) > MAX_LIST or not all(isinstance(v, str) and _string_ok(key, v) for v in value):
                return None
            found[key] = value
        elif _scalar(value, key):
            found[key] = value
        else:
            return None
    return found if isinstance(found.get('id'), str) and found['id'] else None


def storable(event) -> dict | None:
    """`clean`, and nothing for what the dashboard never reads: a skipped run or job, and a run that succeeded or was
    cancelled (its jobs say the same, and runs are the most numerous events). A run that failed, timed out or never
    started stays, because it may have no jobs to say so."""
    found = clean(event)
    if found and found['kind'] in ('run', 'job') and found.get('conclusion') == 'skipped':
        return None
    if found and found['kind'] == 'run' and found.get('conclusion') in ('success', 'cancelled'):
        return None
    return found


# ---- The branch's files ------------------------------------------------------------------------------

def month_of(event: dict) -> str:
    stamp = event.get('at') or ''
    return stamp[:7] if re.fullmatch(r'\d{4}-\d{2}', stamp[:7]) else 'undated'


def load(metrics: Path) -> list[dict]:
    found = []
    for path in sorted(Path(metrics).glob('events-*.jsonl')):
        found += pe.read_events(path)
    return found


def serialise(events: list[dict]) -> str:
    return ''.join(json.dumps(e, sort_keys=True, separators=(',', ':')) + '\n' for e in events)


def plan_files(events: list[dict]) -> dict:
    """{file name: text}, one file a month; an event with no usable time goes to events-undated.jsonl."""
    months = collections.defaultdict(list)
    for event in events:
        months[month_of(event)].append(event)
    return {f'events-{month}.jsonl': serialise(group) for month, group in sorted(months.items())}


def year_bytes(files: dict) -> dict:
    """{year: bytes} of the files a plan would leave on the branch."""
    sizes: dict = collections.defaultdict(int)
    for name, text in files.items():
        match = MONTH_FILE.fullmatch(name)
        sizes[match.group(1) if match else 'undated'] += len(text.encode())
    return dict(sizes)


def over_budget(sizes: dict, limit: int | None = None) -> list[str]:
    limit = YEAR_BYTES if limit is None else limit
    return sorted(year for year, size in sizes.items() if size > limit)


def write_files(metrics: Path, files: dict) -> list[str]:
    """Write the files that changed; the names written. Files the plan no longer names stay (nothing is deleted)."""
    metrics.mkdir(parents=True, exist_ok=True)
    changed = []
    for name, text in files.items():
        path = metrics / name
        if path.is_file() and path.read_text() == text:
            continue
        temporary = path.with_name(path.name + '.tmp')
        temporary.write_text(text)
        temporary.replace(path)
        changed.append(name)
    return changed


# ---- Reading the events -----------------------------------------------------------------------------

def parse_time(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def stamp(moment: dt.datetime) -> str:
    return moment.strftime('%Y-%m-%dT%H:%M:%SZ')


def in_window(events: list[dict], now: dt.datetime, days: int) -> list[dict]:
    start = stamp(now - dt.timedelta(days=days))
    return [e for e in events if start <= (e.get('at') or '') <= stamp(now)]


def collect_since(events: list[dict], now: dt.datetime) -> str:
    """Where this run's collect starts: a day's beginning (the day events of a `slow` kind are whole days), a few
    days before the newest event on the branch, or BACKFILL_DAYS ago when there is none."""
    newest = max((e['at'] for e in events if e.get('at')), default='')
    anchor = parse_time(newest) - dt.timedelta(days=OVERLAP_DAYS) if newest else now - dt.timedelta(days=BACKFILL_DAYS)
    return anchor.strftime('%Y-%m-%dT00:00:00Z')


def fmt_seconds(seconds) -> str:
    return pe.duration(seconds)


def step_lines(lanes: list[dict]) -> list[str]:
    """One line per lane step: runs, results, and what the failing reports turned out to be (code catches are FAILs a
    later head of the same PR fixed, flakes passed on the same head, faults are the lane's own trouble)."""
    steps = collections.defaultdict(list)
    for lane in lanes:
        for step in lane['steps']:
            steps[step['step']].append((lane, step))
    lines = []
    for name, group in sorted(steps.items(), key=lambda item: (-len(item[1]), item[0])):
        results = collections.Counter(step['result'] for _, step in group)
        classes = collections.Counter((lane.get('label') or {}).get('class') for lane, step in group
                                      if step['result'] != 'pass')
        timed = [step['seconds'] for _, step in group if step.get('seconds') is not None]
        why = ', '.join(f'{classes[c]} {c}' for c in ('code', 'flake', 'trunk-moved', 'trunk-red', 'compile', 'fault',
                                                       'unresolved') if classes[c])
        lines.append(f'- **{name}**: {len(group)} runs, {results["pass"]} pass, {results["fail"]} fail, '
                     f'{results["fault"]} fault'
                     + (f' ({why})' if why else '') + (f', median {fmt_seconds(statistics.median(timed))}' if timed else ''))
    return lines


def job_lines(jobs: list[dict], limit: int = 12) -> list[str]:
    groups = collections.defaultdict(list)
    for job in jobs:
        groups[(job['workflow'], job['job'], job['runner'])].append(job)
    lines = []
    for (workflow, name, runner), group in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0]))[:limit]:
        count = collections.Counter((j.get('label') or {}).get('class') or j['conclusion'] for j in group)
        failed = sum(j['conclusion'] in FAILED for j in group)
        why = ', '.join(f'{count[c]} {c}' for c in ('code', 'flake', 'trunk-red', 'fault') if count[c])
        times = [j['seconds'] for j in group if j.get('seconds') is not None]
        lines.append(f'- **{workflow} / {name}** ({runner}): {len(group)} runs, {failed} failed'
                     + (f' ({why})' if why else '') + f', {count["cancelled"]} cancelled'
                     + (f', median {fmt_seconds(statistics.median(times))}' if times else ''))
    return lines


def noisy_tests(failures: list[dict], limit: int = 5) -> list[str]:
    """The tests that most often failed and then passed on a rerun (class flake or trunk-moved)."""
    noisy = collections.Counter(f['test'] for f in failures if (f.get('label') or {}).get('class') in ('flake', 'trunk-moved'))
    total = collections.Counter(f['test'] for f in failures)
    return [f'{n}. `{test}`: {count} flaky failures of {total[test]} failures'
            for n, (test, count) in enumerate(sorted(noisy.items(), key=lambda i: (-i[1], -total[i[0]], i[0]))[:limit], 1)]


def slow_never_failed(slow: list[dict], failed_ever: set, limit: int = 5) -> list[str]:
    """The slowest tests (by their typical daily longest time) that no retained event shows failing."""
    seconds = collections.defaultdict(list)
    for event in slow:
        if event['test'] not in failed_ever:
            seconds[event['test']].append(event['seconds'])
    ranked = sorted(seconds.items(), key=lambda i: (-statistics.median(i[1]), i[0]))[:limit]
    return [f'{n}. `{test}`: typically {fmt_seconds(statistics.median(values))}, seen on {len(values)} days'
            for n, (test, values) in enumerate(ranked, 1)]


def batching_verdict(lanes: list[dict], days: int) -> str:
    """T3 (simulator) requests on PRs: batch them when they wait long and arrive often, else leave them. The
    thresholds are the module's defaults and are printed with the counts they were applied to."""
    t3 = [lane for lane in lanes if lane['tier'] == 'T3' and lane['via'] == 'pr']
    waits = [lane['queue_seconds'] for lane in t3 if lane['queue_seconds'] is not None]
    facts = f'{len(t3)} T3 reports in {days} days ({len(t3) / days:.1f} a day)'
    if len(t3) < BATCH_MIN_REPORTS or len(waits) < BATCH_MIN_WAITS:
        return f'**Not enough data** to say: {facts}, {len(waits)} with a queue wait (needs {BATCH_MIN_REPORTS} and {BATCH_MIN_WAITS}).'
    wait = statistics.median(waits)
    batch = wait >= BATCH_WAIT_SECONDS and len(t3) / days >= BATCH_PER_DAY
    return (f'**{"Batch T3 requests" if batch else "Leave T3 requests unbatched"}**: {facts}, median queue wait '
            f'{fmt_seconds(wait)} (batch at {fmt_seconds(BATCH_WAIT_SECONDS)} or more and {BATCH_PER_DAY} or more a day).')


def daily_series(lanes: list[dict], jobs: list[dict], now: dt.datetime, days: int = TREND_DAYS) -> list[tuple]:
    """[(MM-DD, first-try FAIL %, hosted job failed %)] for the last `days` days, oldest first. 0 means no data that day."""
    first = collections.defaultdict(list)
    for lane in pe.first_tries(lanes):
        first[lane['at'][:10]].append(lane)
    hosted = collections.defaultdict(list)
    for job in jobs:
        if job['runner'] == 'hosted' and job['conclusion'] not in ('skipped', 'cancelled'):
            hosted[job['at'][:10]].append(job)
    rows = []
    for back in range(days - 1, -1, -1):
        day = (now - dt.timedelta(days=back)).strftime('%Y-%m-%d')
        fails = sum(l['verdict'] == 'FAIL' for l in first[day])
        failed = sum(j['conclusion'] in FAILED for j in hosted[day])
        rows.append((day[5:], round(100 * fails / len(first[day])) if first[day] else 0,
                     round(100 * failed / len(hosted[day])) if hosted[day] else 0))
    return rows


def trend_chart(rows: list[tuple]) -> list[str]:
    days = ', '.join(f'"{day}"' for day, _, _ in rows)
    return ['```mermaid',
            f'%%{{init: {{"themeVariables": {{"xyChart": {{"plotColorPalette": "{BLUE}, {ORANGE}"}}}}}}}}%%',
            'xychart-beta',
            '    title "Blue bars: lane first-try FAIL %. Orange line: hosted job failed %."',
            f'    x-axis [{days}]', '    y-axis "percent (0 = no runs that day)" 0 --> 100',
            f'    bar [{", ".join(str(first) for _, first, _ in rows)}]',
            f'    line [{", ".join(str(job) for _, _, job in rows)}]', '```']


def render(events: list[dict], now: dt.datetime, sizes: dict | None = None, notes: list[str] | None = None) -> str:
    """The issue body for these events (all the branch holds), read as of `now`."""
    recent = in_window(events, now, WINDOW_DAYS)
    lanes = [e for e in recent if e['kind'] == 'lane']
    jobs = [e for e in recent if e['kind'] == 'job' and e['conclusion'] != 'skipped']
    failures = [e for e in recent if e['kind'] == 'test-failure']
    escapes = [e for e in recent if e['kind'] == 'escape']
    failed_ever = {e['test'] for e in events if e['kind'] == 'test-failure'}
    out = [MARKER, f'**Updated {now.strftime("%Y-%m-%d")} (UTC).** The last {WINDOW_DAYS} days: {len(lanes)} lane reports, '
           f'{len(jobs)} hosted and self-hosted jobs, {len(failures)} test failures, {len(escapes)} escapes. '
           'The raw events are on the [`metrics` branch](../tree/metrics); this body is rewritten once a day by the '
           '`pipeline-dashboard` workflow (#2379), so nothing here notifies.']
    out += [''] + [f'> {note}' for note in notes or []]
    out += ['', '## Lane steps', ''] + (step_lines(lanes) or ['No lane reports with steps in the window.'])
    out += ['', '## Hosted and self-hosted jobs (the 12 busiest)', ''] + (job_lines(jobs) or ['No jobs in the window.'])
    out += ['', '## Batching T3 requests', '', batching_verdict(lanes, WINDOW_DAYS)]
    out += ['', '## Noisiest tests', ''] + (noisy_tests(failures) or ['None: no failing test passed on a rerun in the window.'])
    out += ['', '## Slowest tests that never failed', ''] + (
        slow_never_failed([e for e in recent if e['kind'] == 'slow'], failed_ever)
        or ['No slow-test data yet: it comes from lane reports that carry a lane-event line.'])
    by_source = collections.Counter(e['source'] for e in escapes)
    out += ['', '## What got past the pipeline', '',
            ', '.join(f'{by_source[s]} {s}' for s in ('revert', 'regression', 'found-on-phone')) + ' in the window.']
    out += ['', '## Trend, last 14 days', ''] + trend_chart(daily_series(lanes, jobs, now))
    if sizes is not None:
        used = sizes.get(now.strftime('%Y'), 0)
        out += ['', f'Branch size this year: {used / 1048576:.1f} MB of {YEAR_BYTES // 1048576} MB.']
    body = '\n'.join(out) + '\n'
    return body if len(body) <= BODY_LIMIT else body[:BODY_LIMIT].rsplit('\n', 1)[0] + '\n\n(cut to fit GitHub\'s limit)\n'


# ---- Publishing ---------------------------------------------------------------------------------------

def gather(github, since: str, existing: list[dict], log=lambda text: None) -> list[dict]:
    """The events after collecting everything new since <since>, on top of <existing>."""
    comments = pe.fetch_comments(github, since)
    runs = pe.fetch_runs(github, since, True, trunk_branch(), log)
    escapes = pe.fetch_escapes(github, since, trunk_branch())
    catches = pe.default_catches()
    lines = catches.read_text().splitlines() if catches.is_file() else []
    return pe.collect_events(comments, runs, lines, since, existing, trunk_branch(), escapes)


def find_issue(github):
    """Our newest dashboard issue (open or closed), by title search, trusted authors only."""
    query = urllib.parse.quote(f'repo:{github.repo} is:issue in:title "Pipeline value"')
    found = github.get(f'/search/issues?q={query}&sort=created&order=desc&per_page=30')
    for issue in comment_trust.trusted_only(found.get('items', [])):
        if 'pull_request' not in issue and issue.get('title') == TITLE:
            return issue
    return None


def publish_issue(github, body: str):
    issue = find_issue(github)
    if issue:
        github.request('PATCH', f'issues/{issue["number"]}', {'body': body})
        return issue['number']
    created, _ = github.request('POST', 'issues', {'title': TITLE, 'body': body})
    try:  # pinning needs GraphQL; the owner can pin it by hand if this is refused
        github.request('POST', '/graphql', {'query': 'mutation($id:ID!){pinIssue(input:{issueId:$id}){issue{number}}}',
                                              'variables': {'id': created['node_id']}})
    except RuntimeError as error:
        print(f'note: could not pin the issue ({str(error)[:80]}); pin it from the issue page', file=sys.stderr)
    return created['number']


def command_publish(args) -> int:
    metrics, now = Path(args.metrics), dt.datetime.now(dt.timezone.utc)
    existing = [e for e in (storable(e) for e in load(metrics)) if e]
    since = collect_since(existing, now)
    import sm_status  # noqa: PLC0415  (imported late so the tests need no token)
    github = sm_status.GitHub(pe.REPO)
    events = gather(github, since, existing, lambda text: print(text, file=sys.stderr))
    kept = [e for e in (storable(e) for e in events) if e]
    refused = sum(clean(e) is None for e in events)
    files = plan_files(kept)
    sizes = year_bytes(files)
    notes, failed = [], False
    if refused:
        notes.append(f'{refused} events held a value that does not fit its field (not a number, id or short name) and were not stored.')
    if over_budget(sizes):
        failed = True
        notes.append(f'**The `metrics` branch is full for {", ".join(over_budget(sizes))}** (over {YEAR_BYTES // 1048576} MB): '
                     'nothing was written this run. Thin out the oldest job events or raise YEAR_BYTES in `scripts/pipeline_dashboard.py`.')
    else:
        changed = write_files(metrics, files)
        print(f'{metrics}: {len(kept)} events, {len(changed)} files written ({", ".join(changed) or "none"})')
    body = render(kept, now, sizes, notes)
    if args.body_out:
        Path(args.body_out).write_text(body)
    if not args.dry_run:
        print(f'Updated issue #{publish_issue(github, body)}.')
    return 1 if failed else 0


def command_render(args) -> int:
    events = [e for e in (storable(e) for e in load(Path(args.metrics))) if e]
    now = dt.datetime.now(dt.timezone.utc)
    print(render(events, now, year_bytes(plan_files(events))))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    publish = commands.add_parser('publish', help='collect, write the data branch files, update the issue')
    publish.add_argument('--metrics', default='metrics', help='the checked-out metrics branch')
    publish.add_argument('--dry-run', action='store_true', help='write the files and the body, change no issue')
    publish.add_argument('--body-out', help='also write the issue body here')
    publish.set_defaults(run=command_publish)
    show = commands.add_parser('render', help='print the issue body from the files')
    show.add_argument('--metrics', default='metrics')
    show.set_defaults(run=command_render)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == '__main__':
    sys.exit(main())
