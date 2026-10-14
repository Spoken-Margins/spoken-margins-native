#!/usr/bin/env python3
"""Coordinator wake sweep (#1598). Read-only unless --apply releases stale claims.

Run with Python 3.9+ and authenticated gh. --json prints the action list and evidence.
--runtime accepts a fresh machine-status JSON file (for #1597):
{"observed_at": "…Z", "mac_idle": true, "test_desk_running": false}.
Without it, machine availability is explicitly an inference from #337 and thread notes;
unknown/stale observations ask the coordinator to check, never assert idle capacity.
No process inspection, simulator operations, dispatch, re-arming or merging happens here.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
REPO = 'uncomposed/spoken-margins-native'
HOUR = dt.timedelta(hours=1)
CLAIM_WINDOW = 6 * HOUR


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dial = load('sweep_dial', ROOT / 'ops/dial/dial_gate.py')
desk = load('sweep_desk', ROOT / 'scripts/desk-batch.py')
parse_time = dial.parse_time


def labels(item):
    return {label['name'] for label in item.get('labels', [])}


def stamp(value):
    return value.isoformat().replace('+00:00', 'Z')


def linked(pr, number):
    # Include references, not only closing keywords: holding too much is safer than
    # releasing an issue whose implementation PR is still open.
    return (bool(re.match(rf'ws/{number}(?:-|$)', pr['head']['ref'])) or
            bool(re.search(rf'(?<![\w/])#{number}\b|/issues/{number}\b',
                           (pr.get('body') or '') + '\n' + pr.get('title', ''))))


def stale(issue, pulls, events, now):
    """All activity must be strictly older than six hours. Missing evidence holds."""
    if (issue.get('state') != 'open' or 'in-progress' not in labels(issue)
            or not issue.get('evidence_complete') or issue.get('open_pr')):
        return False
    cutoff = now - CLAIM_WINDOW
    times = [issue.get('updated_at'), issue.get('created_at')]
    times += [c.get('updated_at') or c.get('created_at') for c in issue['comments']]
    times += [e.get('created_at') for e in issue['timeline']]
    times += issue.get('commit_times', [])
    for pr in pulls:
        if linked(pr, issue['number']):
            if pr['state'] == 'open':
                return False
            times.append(pr.get('updated_at'))
    for event in events:
        if (event.get('type') == 'PushEvent' and
                re.match(rf"refs/heads/ws/{issue['number']}(?:-|$)",
                         (event.get('payload') or {}).get('ref', ''))):
            times.append(event.get('created_at'))
    try:
        return all(value and parse_time(value) < cutoff for value in times)
    except (ValueError, TypeError):
        return False


def red_head(pr):
    failed = {'failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure'}
    # The collector queries the head, never the PR's old commits.
    if pr.get('status', {}).get('state') in {'failure', 'error'}:
        return True
    newest = {}
    for check in pr.get('checks', []):
        key = (check.get('app', {}).get('id'), check['name'])
        if key not in newest or check['id'] > newest[key]['id']:
            newest[key] = check
    if any(c.get('conclusion') in failed for c in newest.values()):
        return True
    reports = []
    for comment in pr['comments']:
        body = comment.get('body', '')
        named = re.search(r'\bcommit\s+`?([0-9a-f]{7,40})\b', body)
        if (desk.first_line(body).startswith('Lane report') and named
                and pr['head']['sha'].startswith(named.group(1))):
            reports.append(comment)
    latest = max(reports, key=lambda c: c['created_at'], default=None)
    return bool(latest and re.search(r'[—–:-]\s*FAIL\b', desk.first_line(latest['body'])))


def machine_facts(snapshot, threads, now):
    runtime = snapshot.get('runtime')
    if runtime and any(runtime.get(key) not in (True, False, None)
                       for key in ('mac_idle', 'test_desk_running')):
        raise ValueError('runtime availability must be boolean or null')
    if runtime and dt.timedelta(0) <= now - parse_time(runtime['observed_at']) <= HOUR:
        return runtime.get('mac_idle'), runtime.get('test_desk_running'), 'machine-status JSON'
    active = [t for t in threads if t['state'] == 'active']
    desk_active = any(re.search(r'test[ -]desk', t['title'], re.I) for t in active)
    ticks = [c for c in snapshot['comments'] if dial.issue_number(c) == 337 and '(Mac tick)' in c['body']]
    tick = max(ticks, key=lambda c: c.get('updated_at') or c['created_at'], default=None)
    idle = None
    if tick and dt.timedelta(0) <= now - parse_time(tick.get('updated_at') or tick['created_at']) <= HOUR:
        running = re.search(r'runner:\s*(\d+) running,\s*(\d+) queued,\s*(\d+) pending', tick['body'])
        mac_issues = {i['number'] for i in snapshot['issues'] if 'where:mac' in labels(i)}
        mac_thread = any(mac_issues.intersection(t['issues']) for t in active)
        if running:
            idle = (not any(map(int, running.groups())) and 'simulator slot: free' in tick['body']
                    and not mac_thread and not desk_active)
    return idle, True if desk_active else None, 'inferred from GitHub notes; confirm machine/session availability'


def sweep(snapshot, now):
    actions = []

    def add(rule, message, numbers=()):
        actions.append(dict(rule=rule, message=message, numbers=list(numbers)))

    config = dial.parse_dial(snapshot['dial_body'])
    comments = sorted(snapshot['comments'], key=lambda c: (c['created_at'], c['id']))
    threads = dial.parse_threads(comments, snapshot['events'], now)
    halted = dial.parse_usage(comments)['halted_by']
    counts = {p: dial.active_count(threads, p) for p in dial.PROVIDERS}
    free = max(0, config['threads'] - counts['claude'])
    if free and config['mode'] != 'off' and 'claude' not in halted:
        add('free-slots', f"Fill {free} Claude slots: {counts['claude']}/{config['threads']} active; "
            f"Codex {counts['codex']} active, counted separately. Check Dial pacing and #337 before dispatch.")
    idle, desk_running, evidence = machine_facts(snapshot, threads, now)
    mac_ready = [i['number'] for i in snapshot['issues'] if {'ready', 'where:mac'} <= labels(i)
                 and not {'in-progress', 'blocked'} & labels(i)]
    if mac_ready and idle is not False:
        add('mac-idle' if idle else 'check-mac',
            f"{'Dispatch Mac-only ready work' if idle else 'Check Mac availability for ready work'} "
            f"({evidence}).", mac_ready)
    for issue in snapshot['issues']:
        if stale(issue, snapshot['pulls'], snapshot['events'], now):
            add('stale-claim', 'Release to ready with a note: no activity in six hours.', [issue['number']])
        elif 'in-progress' in labels(issue) and not issue.get('evidence_complete'):
            add('check-claim', 'Claim held: incomplete activity evidence; inspect before releasing.', [issue['number']])
    for pr in snapshot['pulls']:
        if pr['state'] != 'open' or pr['base']['ref'] != 'next':
            continue
        number = pr['number']
        if 'automerge' in labels(pr) and red_head(pr):
            add('red-head', f"Dispatch a fix: armed PR failing on head {pr['head']['sha'][:7]}.", [number])
        if 'needs-mac' in labels(pr):
            additions = [e['created_at'] for e in pr['timeline'] if e.get('event') == 'labeled'
                         and e.get('label', {}).get('name') == 'needs-mac']
            activity = additions or [pr['created_at']]
            activity += [c.get('updated_at') or c['created_at'] for c in pr['comments']
                         if re.match(r'(?:Mac )?Finisher\b', desk.first_line(c['body']), re.I)]
            activity += pr.get('commit_times', [])
            if now - max(map(parse_time, activity)) > HOUR:
                add('needs-mac', 'Dispatch finisher: no finisher activity for over an hour.', [number])
    for request in desk.pending_requests(comments, {}):
        pr = next((p for p in snapshot['pulls'] if p['number'] == request['number']), None)
        if (pr and (pr['state'] == 'open' or pr.get('merged_at'))
                and now - parse_time(request['created']) > HOUR and desk_running is not True):
            add('t4-wait', f"{'Start' if desk_running is False else 'Check/start'} a Test Desk: "
                f"T4 waiting over an hour ({evidence}).", [request['number']])
    return dict(observed_at=stamp(now), provider_active=counts, actions=actions)


class GitHub:
    def __init__(self, repo=REPO):
        self.repo = repo

    def request(self, path, method='GET', payload=None):
        command = ['gh', 'api', f'repos/{self.repo}/{path}', '--method', method]
        if payload is not None:
            command += ['--input', '-']
        result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                                text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(f'{method} {path}: {result.stderr.strip()}')
        return json.loads(result.stdout) if result.stdout.strip() else None

    def pages(self, path, key=None):
        found = []
        for page in range(1, 301):
            result = self.request(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            chunk = result[key] if key else result
            found.extend(chunk)
            if len(chunk) < 100:
                return found
            if path == 'events' and page == 3:
                # GitHub exposes only the latest 300 repository events. Never mistake
                # that server limit for complete six-hour push evidence.
                return found
        raise RuntimeError(f'pagination incomplete: {path}')


def events_cover_window(events, now):
    return len(events) < 300 or min(parse_time(e['created_at']) for e in events) < now - CLAIM_WINDOW


def local_commit_times(number):
    """Protect unpushed commits on this checkout's issue branches; never fetch or write git state."""
    result = subprocess.run(['git', 'for-each-ref', '--format=%(refname) %(committerdate:iso-strict)',
                             'refs/heads/ws/', 'refs/remotes/origin/ws/'],
                            cwd=ROOT, text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise RuntimeError(f'cannot check local claim commits: {result.stderr.strip()}')
    times = []
    for line in result.stdout.splitlines():
        ref, _, date = line.partition(' ')
        if re.fullmatch(rf'refs/(?:heads|remotes/origin)/ws/{number}(?:-.*)?', ref):
            times.append(date)
    return times


def activity(api, item, branches=None):
    item = dict(item)
    number = item['number']
    item['comments'] = api.pages(f'issues/{number}/comments')
    item['timeline'] = api.pages(f'issues/{number}/timeline')
    item['commit_times'] = local_commit_times(number)
    item['open_pr'] = False
    # The repository event feed can lag a push. Read matching remote branch heads
    # directly as well, including commits whose messages never mention the issue.
    for branch in api.pages('branches') if branches is None else branches:
        if re.fullmatch(rf'ws/{number}(?:-.*)?', branch['name']):
            commit = api.request(f"commits/{branch['commit']['sha']}")
            item['commit_times'].append(commit['commit']['committer']['date'])
    # A timeline reference can be old even when its commit was just made/pushed.
    for event in item['timeline']:
        if event.get('commit_id'):
            commit = api.request(f"commits/{event['commit_id']}")
            item['commit_times'].append(commit['commit']['committer']['date'])
        source = event.get('source', {}).get('issue', {})
        if source.get('pull_request'):
            url = source['pull_request']['url']
            prefix = f'https://api.github.com/repos/{api.repo}/'
            if not url.startswith(prefix):
                raise RuntimeError(f'cannot check cross-repository PR evidence: {url}')
            pull = api.request(url[len(prefix):])
            item['open_pr'] |= pull['state'] == 'open'
            item['commit_times'].append(pull.get('updated_at'))
    item['evidence_complete'] = True
    return item


def collect(api, now, runtime=None):
    dial_body = api.request('issues/589')['body'] or ''
    since = quote(stamp(now - dt.timedelta(days=10)))
    comments = api.pages(f'issues/comments?since={since}&sort=created&direction=asc')
    events = api.pages('events')
    issues = [i for i in api.pages('issues?state=open') if 'pull_request' not in i]
    pulls = api.pages('pulls?state=open')
    # Include merged PRs with an unanswered request: round two remains work after merge.
    numbers = {r['number'] for r in desk.pending_requests(comments, {})}
    # A merged PR can retain lane:queued for T4 indefinitely. Its request must not
    # disappear just because it is older than the recent-comment window.
    numbers.update(i['number'] for i in api.pages('issues?state=closed&labels=lane:queued')
                   if 'pull_request' in i)
    for number in sorted(numbers - {p['number'] for p in pulls}):
        pulls.append(api.request(f'pulls/{number}'))
    branches = None
    for index, issue in enumerate(issues):
        if ('in-progress' in labels(issue)
                and now - parse_time(issue['updated_at']) > CLAIM_WINDOW
                and not any(linked(p, issue['number']) for p in pulls if p['state'] == 'open')):
            if branches is None:
                branches = api.pages('branches')
            issues[index] = activity(api, issue, branches)
            issues[index]['evidence_complete'] = events_cover_window(events, now)
        else:
            issues[index] = dict(issue, evidence_complete=True, comments=[], timeline=[])
    for index, pr in enumerate(pulls):
        pr = dict(pr, comments=api.pages(f"issues/{pr['number']}/comments"), timeline=[], commit_times=[])
        if pr['state'] == 'open':
            sha = pr['head']['sha']
            if 'automerge' in labels(pr):
                pr['status'] = api.request(f'commits/{sha}/status')
                pr['checks'] = api.pages(f'commits/{sha}/check-runs?filter=latest', 'check_runs')
            if 'needs-mac' in labels(pr):
                pr['timeline'] = api.pages(f"issues/{pr['number']}/timeline")
                pr['commit_times'] += [c['commit']['committer']['date']
                                       for c in api.pages(f"pulls/{pr['number']}/commits")]
        pulls[index] = pr
        # Full open-PR histories preserve T4 requests older than the global window.
        for comment in pr['comments']:
            comments.append(dict(comment, issue_url=f'https://api.github.com/repos/{api.repo}/issues/{pr["number"]}'))
    comments = list({c['id']: c for c in comments}.values())
    return dict(dial_body=dial_body, comments=comments, events=events,
                issues=issues, pulls=pulls, runtime=runtime)


def apply_claims(api, report, now):
    released = []
    for action in report['actions']:
        if action['rule'] != 'stale-claim':
            continue
        number = action['numbers'][0]
        # Re-read all safety evidence, including PRs opened since the sweep.
        pulls = api.pages('pulls?state=open')
        events = api.pages('events')
        issue = activity(api, api.request(f'issues/{number}'))
        issue['evidence_complete'] = events_cover_window(events, now)
        if not stale(issue, pulls, events, now):
            action['message'] = 'Claim held: activity changed during sweep.'
            continue
        api.request(f'issues/{number}/comments', 'POST', {'body':
            'Wake sweep (#1598): releasing this stale claim to `ready`. No commit, open PR or '
            'comment found in the last six hours. Per the 2026-10-14 housekeeping standing call.'})
        api.request(f'issues/{number}/labels', 'POST', {'labels': ['ready']})
        api.request(f'issues/{number}/labels/in-progress', 'DELETE')
        released.append(number)
        action['message'] = 'Released stale claim to ready with a note.'
    report['released'] = released


def main(argv=None, api=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--runtime', type=Path)
    parser.add_argument('--repo', default=REPO)
    args = parser.parse_args(argv)
    api = api or GitHub(args.repo)
    now = now or dt.datetime.now(dt.timezone.utc)
    try:
        runtime = json.loads(args.runtime.read_text()) if args.runtime else None
        report = sweep(collect(api, now, runtime), now)
        if args.apply:
            apply_claims(api, report, now)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            print(f"Wake sweep: {len(report['actions'])} actions.")
            for index, action in enumerate(report['actions'], 1):
                refs = ', '.join(f'#{n}' for n in action['numbers'])
                print(f"{index}. {action['message']} {refs}".rstrip())
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'Wake sweep ERROR: {error}. Do not treat this as an empty queue.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
