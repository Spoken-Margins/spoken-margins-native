#!/usr/bin/env python3
"""Reconcile project 6 from live workflow evidence (#1621), without a new worker.

Default is dry-run; --apply writes changed Status/Check health fields, then reads them back.
--issue N narrows claim/release hooks to one issue. No labels, issues, Area or views are edited.
Needs GitHub repository read and project write permissions. Read errors mean unknown, never Todo.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import importlib.machinery
import importlib.util
from functools import lru_cache
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_status

HEALTH = 'Check health'
STATUSES = {'Todo', 'In Progress', 'Checking', 'Needs your check', 'Done'}
VALIDATION = {'needs-human-validation', 'status: needs-human-validation'}
HOLD = {'deferred', 'blocked', 'needs-owner'}
CLAIM = re.compile(r'[*_\s]*Claimed by project thread "([^"]+)"')
STOP = re.compile(r'[*_\s]*Thread "([^"]+)" stopping:')
ROUTINE = re.compile(r'(?:<!--|\*{0,2}(?:Owner phone check|Claude audit|Codex audit|Merge check|'
                     r'Test Desk|Phone build)|Lane[ :]|Released by scripts/|Project sync)', re.I)
STALE = dt.timedelta(hours=6)


class GitHub(sm_status.GitHub):
    """Count each HTTP request; avoid ambiguous mutation retries after a lost response."""
    def __init__(self, repo=sm_status.REPO, token=None):
        super().__init__(repo, token, retries=0)
        self.calls = self.writes = 0

    def request(self, method, path, body=None):
        self.calls += 1
        if method != 'GET' and not (path == '/graphql' and not body['query'].lstrip().startswith('mutation')):
            self.writes += 1
        return super().request(method, path, body)

    def graphql(self, query, **variables):
        result = self.post('/graphql', {'query': query, 'variables': variables})
        if result.get('errors'):
            raise sm_status.GitHubError('GraphQL: ' + json.dumps(result['errors']))
        if not result.get('data'):
            raise sm_status.GitHubError('GraphQL: no data')
        return result['data']


VALUES = '''fieldValues(first:100) { pageInfo { hasNextPage } nodes {
  ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
  ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
} }'''
ITEM = '''id content { __typename ... on Issue { id number state repository { nameWithOwner } } }
''' + VALUES


def fields(item):
    connection = item['fieldValues']
    if connection['pageInfo']['hasNextPage']:
        raise sm_status.GitHubError('more than 100 item fields; incomplete read')
    return {v['field']['name']: v.get('name', v.get('text', '')) for v in connection['nodes'] if v.get('field')}


def project(api, owner, number):
    data = api.graphql('''query($owner:String!, $number:Int!) {
      user(login:$owner) { projectV2(number:$number) { id fields(first:100) {
        pageInfo { hasNextPage } nodes {
          ... on ProjectV2Field { id name dataType }
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      } } }
    }''', owner=owner, number=number)
    board = (data.get('user') or {}).get('projectV2')
    if not board or board['fields']['pageInfo']['hasNextPage']:
        raise sm_status.GitHubError('project/fields missing or incomplete')
    by_name = {f['name']: f for f in board['fields']['nodes'] if f.get('name')}
    status = by_name.get('Status', {})
    options = {o['name']: o['id'] for o in status.get('options', [])}
    if STATUSES - options.keys():
        raise sm_status.GitHubError('Status options missing: ' + ', '.join(sorted(STATUSES - options.keys())))
    health = by_name.get(HEALTH)
    if health and ('options' in health or health.get('dataType', 'TEXT') != 'TEXT'):
        raise sm_status.GitHubError(f'{HEALTH} must be a text field')
    items, cursor = {}, None
    while True:
        data = api.graphql('query($id:ID!, $cursor:String) { node(id:$id) { ... on ProjectV2 { '
                           'items(first:100, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { '
                           + ITEM + ' } } } } }', id=board['id'], cursor=cursor)
        connection = data['node']['items']
        for item in connection['nodes']:
            content = item.get('content') or {}
            if content.get('__typename') != 'Issue' or content['repository']['nameWithOwner'].lower() != api.repo.lower():
                continue  # drafts, PR cards and other repositories are never touched
            n = content['number']
            if n in items:
                raise sm_status.GitHubError(f'duplicate project item for #{n}')
            items[n] = {'id': item['id'], 'values': fields(item), 'state': content.get('state')}
        if not connection['pageInfo']['hasNextPage']:
            break
        next_cursor = connection['pageInfo']['endCursor']
        if not next_cursor or next_cursor == cursor:
            raise sm_status.GitHubError('project pagination did not advance')
        cursor = next_cursor
    return {'id': board['id'], 'status': status['id'], 'options': options,
            'health': health['id'] if health else None, 'items': items}


def decision(status=None, reason='', health=''):
    return {'status': status, 'health': health, 'reason': reason}


def implementation_issues(pull):
    """Closing targets and ws/<issue> branches, not incidental 'see/refs #n' links."""
    numbers = [int(n) for n in sm_status.CLOSING.findall((pull.get('body') or '') + '\n' + (pull.get('title') or ''))]
    branch = sm_status.BRANCH_ISSUE.match((pull.get('head') or {}).get('ref') or '')
    if branch:
        numbers.append(int(branch.group(1)))
    return set(numbers)


@lru_cache(maxsize=1)
def phone_workflow():
    """Reuse the rolling phone plan's classification and explicit 'Owner check: none' parser."""
    loader = importlib.machinery.SourceFileLoader('project_sync_phone', str(Path(__file__).with_name('phone-build')))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def listener_facing(pull, issue, paths):
    phone = phone_workflow()
    shaped = {'title': pull.get('title') or '', 'labels': {'nodes': pull.get('labels', [])},
              'files': {'nodes': [{'path': p} for p in paths]}}
    checks = [check for item in (issue, pull) if (check := phone.check_field(item.get('body') or ''))]
    if checks and all(phone.NO_CHECK.match(check) for check in checks):
        return False
    return phone.listener_facing(shaped)


def claim_activity(api, issue, now):
    n = issue['number']
    events = api.pages(f'issues/{n}/events')
    since = sm_status.label_since(events, 'in-progress')
    comments = api.pages(f'issues/{n}/comments')
    active, seen, stopped_at = {}, [], None
    for comment in comments:
        body, at = comment.get('body') or '', comment['created_at']
        user = comment.get('user') or {}
        if user.get('type') == 'Bot' or user.get('login', '').endswith('[bot]') or ROUTINE.match(body.lstrip()):
            continue
        claim, stop = CLAIM.match(body), STOP.match(body)
        if claim:
            active[claim.group(1)] = user.get('login')
            seen.append(at)
            stopped_at = None
        elif stop:
            active.pop(stop.group(1), None)
            stopped_at = at if not active else None
        elif active and user.get('login') in active.values():
            seen.append(at)
    if stopped_at and (not since or stopped_at >= since):
        return False, 'implementer posted a stop/release note'
    if since:
        seen.append(since)
    # A recent branch commit counts even when the claim note was lost.
    for ref in api.get(f'git/matching-refs/heads/ws/{n}-'):
        commit = api.get(f'commits/{ref["object"]["sha"]}')
        at = ((commit.get('commit') or {}).get('committer') or {}).get('date')
        if not at:
            raise sm_status.GitHubError(f'#{n}: branch commit date missing')
        seen.append(at)
    if not since and not seen:
        raise sm_status.GitHubError(f'#{n}: no claim event or implementer evidence')
    fresh = any(now - sm_status.parse_time(at) < STALE for at in seen)
    return fresh, 'recent claim/implementer activity' if fresh else 'claim quiet for at least six hours'


def closed_card(item, n, only):
    """A closed issue whose card already shows Done with no Check health: nothing would be written, so the project
    read is enough (reading the ~90 closed cards one by one was most of a full run's calls). Any card that would be
    written is read from the issue itself first, so an issue reopened during the run is never set Done, which the
    board's Auto-close workflow would turn into closing it again. An --issue run always reads the issue."""
    values = (item or {}).get('values') or {}
    if only or not item or item.get('state') != 'CLOSED' or values.get('Status') != 'Done' or values.get(HEALTH):
        return None
    return {'number': n, 'state': 'closed', 'labels': []}


def derive(api, issue, pulls, now, cache):
    labels = {l['name'] for l in issue.get('labels', [])}
    if issue.get('state') == 'closed':
        return decision('Done', 'issue closed under the existing completion workflow')
    open_prs = [p for p in pulls if p['state'] == 'open']
    if open_prs:
        rows = []
        for pull in open_prs:
            n = pull['number']
            if n not in cache:
                bundle = sm_status.fetch_bundle(api, pull)
                cache[n] = {'row': sm_status.analyse(bundle), 'pull': bundle['pull']}
            rows.append(cache[n]['row'])
        unreadable = [f['detail'] for r in rows for f in r['flags'] if f['code'] in {'unreadable', 'scope-unknown'}]
        if unreadable:
            return decision(reason='unknown: ' + '; '.join(unreadable))
        # The PR may have merged/closed during this scan. Use its fresh state, not the list entry.
        pulls = [cache[p['number']]['pull'] if p['number'] in cache else p for p in pulls]
        rows = [cache[p['number']]['row'] for p in pulls if p['state'] == 'open']
        if rows:
            return checking(rows, labels)
    merged = [p for p in pulls if p.get('merged_at')]
    latest = max(merged, key=lambda p: p['merged_at']) if merged else None
    if labels & VALIDATION:
        # Claimed again after the merge (a failed check sent it back): the new work shows, until its claim goes quiet.
        if latest and 'in-progress' in labels and resumed_after(api, issue, latest) and claim_activity(api, issue, now)[0]:
            return decision('In Progress', 'reclaimed after the merge; implementation active again')
        return decision('Needs your check', 'protected physical-device validation is pending')
    if labels & HOLD or (issue.get('milestone') or {}).get('title') in {'Later', 'Co-op Experience'}:
        health = ('Needs attention: ' + ', '.join(sorted(labels & {'blocked', 'needs-owner'}))) if labels & {'blocked', 'needs-owner'} else ''
        return decision('Todo', 'issue explicitly held/deferred; a stale claim or old merge does not override it', health)
    if latest:
        # An old partial fix must not hide a new claim/reopened issue.
        if not resumed_after(api, issue, latest):
            file_cache = cache.setdefault('merged_files', {})
            pr = latest['number']
            if pr not in file_cache:
                file_cache[pr] = [f['filename'] for f in api.pages(f'pulls/{pr}/files')]
            paths = file_cache[pr]
            if not paths:
                return decision(reason='unknown: merged PR file list empty')
            # Existing phone workflow distinguishes pure moves/tests/tooling from listener changes.
            if listener_facing(latest, issue, paths) or 'found-on-phone' in labels:
                return decision('Needs your check', f'merged implementation PR #{latest["number"]}; phone acceptance not recorded')
            return decision('Checking', f'merged internal PR #{latest["number"]}; issue not yet closed',
                            'Needs attention: dispatcher completion/closure pending')
    if 'in-progress' in labels:
        fresh, why = claim_activity(api, issue, now)
        return decision('In Progress' if fresh else 'Todo', why)
    return decision('Todo', 'open backlog/released claim; no stronger implementation or validation evidence')


def resumed_after(api, issue, merged_pull):
    """The issue was reopened, or claimed again, after that PR merged (compares label and reopen events with it)."""
    events = api.pages(f'issues/{issue["number"]}/events')
    claim_since = sm_status.label_since(events, 'in-progress')
    return bool(claim_since and claim_since > merged_pull['merged_at']) or any(
        e.get('event') == 'reopened' and e['created_at'] > merged_pull['merged_at'] for e in events)


def checking(rows, labels):
    attention = [f'PR #{r["number"]}: {f["code"]}' for r in rows for f in r['flags']
                 if f['severity'] == sm_status.RED or f['code'] in {
                     'held-by-runner', 'inconclusive-on-head', 't3-unqueued', 'armed-no-lane-request', 'owner-tap'}]
    # Not GitHub's mergeable_state: "blocked", "unstable" and "has_hooks" are normal while reviews or checks are
    # pending and flip between runs. A real conflict or red check is already a flag above.
    if labels & HOLD:
        attention.append('issue: ' + ', '.join(sorted(labels & HOLD)))
    health = ('Needs attention: ' + '; '.join(attention)) if attention else 'Waiting on checks/review'
    return decision('In Progress' if all(r['draft'] for r in rows) else 'Checking',
                    '; '.join(sm_status.line(r) for r in rows), health[:1000])


def create_health(api, board):
    data = api.graphql('''mutation($project:ID!, $name:String!) {
      createProjectV2Field(input:{projectId:$project, dataType:TEXT, name:$name}) {
        projectV2Field { ... on ProjectV2Field { id name } }
      }
    }''', project=board['id'], name=HEALTH)
    board['health'] = data['createProjectV2Field']['projectV2Field']['id']


def write_item(api, board, issue, item, proposed):
    if item is None:
        data = api.graphql('''mutation($project:ID!, $content:ID!) {
          addProjectV2ItemById(input:{projectId:$project, contentId:$content}) { item { id } }
        }''', project=board['id'], content=issue['node_id'])
        item = {'id': data['addProjectV2ItemById']['item']['id'], 'values': {}}
    current = item['values']
    for name, value in [('Status', proposed['status']), (HEALTH, proposed['health'])]:
        if current.get(name, '') == value:
            continue
        field_id = board['status'] if name == 'Status' else board['health']
        if value:
            field_value = {'singleSelectOptionId': board['options'][value]} if name == 'Status' else {'text': value}
            api.graphql('''mutation($project:ID!, $item:ID!, $field:ID!, $value:ProjectV2FieldValue!) {
              updateProjectV2ItemFieldValue(input:{projectId:$project, itemId:$item, fieldId:$field, value:$value}) {
                projectV2Item { id }
              }
            }''', project=board['id'], item=item['id'], field=field_id, value=field_value)
        else:
            api.graphql('''mutation($project:ID!, $item:ID!, $field:ID!) {
              clearProjectV2ItemFieldValue(input:{projectId:$project, itemId:$item, fieldId:$field}) {
                projectV2Item { id }
              }
            }''', project=board['id'], item=item['id'], field=field_id)
    data = api.graphql('query($id:ID!) { node(id:$id) { ... on ProjectV2Item { ' + VALUES + ' } } }', id=item['id'])
    actual = fields(data['node'])
    if actual.get('Status') != proposed['status'] or actual.get(HEALTH, '') != proposed['health']:
        raise sm_status.GitHubError(f'#{issue["number"]}: field read-back did not match')
    return item['id']


def reconcile(api, owner='uncomposed', number=6, apply=False, only=None, now=None):
    started = time.monotonic()
    now = now or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    report = {'apply': apply, 'changes': [], 'field_changes': [], 'unknown': [], 'unchanged': 0}
    try:
        board = project(api, owner, number)
        issues = ({i['number']: i for i in api.pages('issues?state=open&sort=created&direction=asc')
                   if 'pull_request' not in i} if not only else {})
        targets = (set(issues) | set(board['items'])) if not only else set(only)
        # One complete PR scan shared by every issue. No old-head PASS is used here.
        pulls = api.pages(f'pulls?state=all&base={sm_status.BASE}&sort=created&direction=asc')
        by_issue = {}
        for pull in pulls:
            if pull['state'] == 'open' or pull.get('merged_at'):
                for n in implementation_issues(pull) & targets:
                    by_issue.setdefault(n, []).append(pull)
        cache = {}
        for n in sorted(targets):
            try:
                issue = issues.get(n) or closed_card(board['items'].get(n), n, only) or api.get(f'issues/{n}')
                if 'pull_request' in issue:
                    if only:
                        raise sm_status.GitHubError(f'#{n} is a pull request, not an issue')
                    continue
                if issue.get('number') != n or issue.get('state') not in {'open', 'closed'} or 'labels' not in issue:
                    raise sm_status.GitHubError(f'#{n}: issue response missing state/labels/identity')
                proposed = derive(api, issue, by_issue.get(n, []), now, cache)
                if proposed['status'] is None:
                    report['unknown'].append({'issue': n, 'reason': proposed['reason']})
                    continue
                item = board['items'].get(n)
                current = item['values'] if item else {}
                if item and current.get('Status') == proposed['status'] and current.get(HEALTH, '') == proposed['health']:
                    report['unchanged'] += 1
                    continue
                change = {'issue': n, 'missing': item is None, 'from': current.get('Status'), **proposed}
                report['changes'].append(change)
                if proposed['health'] and not board['health'] and not report['field_changes']:
                    report['field_changes'].append({'name': HEALTH, 'data_type': 'TEXT',
                                                    'reason': 'keep check failures distinct from healthy waiting'})
                if apply:
                    if proposed['health'] and not board['health']:
                        create_health(api, board)
                    write_item(api, board, issue, item, proposed)
                    change['verified'] = True
            except (sm_status.GitHubError, KeyError, TypeError, ValueError, OSError, ImportError) as error:
                report['unknown'].append({'issue': n, 'reason': str(error)})
    except (sm_status.GitHubError, KeyError, TypeError, ValueError, OSError, ImportError) as error:
        report['unknown'].append({'issue': None, 'reason': str(error)})
    report.update(api_calls=getattr(api, 'calls', None), writes=getattr(api, 'writes', None),
                  seconds=round(time.monotonic() - started, 3))
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--issue', type=int, action='append')
    parser.add_argument('--repo', default=sm_status.REPO)
    parser.add_argument('--owner', default='uncomposed')
    parser.add_argument('--project', type=int, default=6)
    parser.add_argument('--ledger-state', type=Path, help='existing step-ledger directory; apply runs only')
    args = parser.parse_args(argv)
    if args.apply and args.dry_run:
        parser.error('--apply and --dry-run are mutually exclusive')
    report = reconcile(GitHub(args.repo), args.owner, args.project, args.apply, args.issue)
    if args.apply and args.ledger_state:
        import lane_ledger
        alarms = lane_ledger.record_runs(args.ledger_state, [{
            'step': 'project-sync', 'result': 'fault' if report['unknown'] else 'pass',
            'seconds': report['seconds']}], pr=0, head='project-sync')
        report['ledger_alarms'] = alarms
    print(json.dumps(report, indent=2))
    return 2 if report['unknown'] else 0


if __name__ == '__main__':
    sys.exit(main())
