#!/usr/bin/env python3
"""Copy the `area:` labels onto the board's Area field, once (#2173).

The owner chose the board's Area field over the `area:` labels (2026-10-19). This fills the field on
open issues that already have a card and no Area, from the labels that map without a judgment call.
It never overwrites an Area that is set, never edits labels or issues, and leaves the rest for
the nightly triage (the project's rule: when the area isn't clear, leave "No Area").

Default is dry-run; --apply writes, then reads each value back. Needs project write permission, so it
runs on the Mac (GraphQL is not available from cloud sessions). Unmapped labels are listed, not guessed.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_project_sync as sync
import sm_status

AREA = 'Area'
# Default taken (#2173): only labels whose area is not a judgment call. `anchors`, `collaboration` and `rights`
# each span several areas (collaboration is both "Answer it" and "Pass it on"), so those cards stay in "No Area".
LABEL_TO_AREA = {
    'area: sharing': 'Pass it on',
    'area: groundwork': 'Groundwork',
}
AREA_LABELS = LABEL_TO_AREA.keys() | {'area: anchors', 'area: collaboration', 'area: rights'}


def propose(labels, current):
    """(area or None, reason). Never proposes over an existing Area."""
    if current:
        return None, 'has Area'
    named = sorted(label for label in labels if label in AREA_LABELS)
    if not named:
        return None, 'no area label'
    areas = {LABEL_TO_AREA[label] for label in named if label in LABEL_TO_AREA}
    if not areas:
        return None, 'unmapped label: ' + ', '.join(named)
    if len(areas) > 1:
        return None, 'labels disagree: ' + ', '.join(named)
    return areas.pop(), ''


def board(api, owner, number):
    data = api.graphql('''query($owner:String!, $number:Int!) {
      user(login:$owner) { projectV2(number:$number) { id fields(first:100) {
        pageInfo { hasNextPage } nodes {
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      } } }
    }''', owner=owner, number=number)
    found = (data.get('user') or {}).get('projectV2')
    if not found or found['fields']['pageInfo']['hasNextPage']:
        raise sm_status.GitHubError('project/fields missing or incomplete')
    area = next((f for f in found['fields']['nodes'] if f.get('name') == AREA), None)
    if not area:
        raise sm_status.GitHubError('the board has no Area single-select field')
    options = {o['name']: o['id'] for o in area['options']}
    missing = set(LABEL_TO_AREA.values()) - options.keys()
    if missing:
        raise sm_status.GitHubError('Area options missing: ' + ', '.join(sorted(missing)))
    items, cursor = {}, None
    while True:
        page = api.graphql('query($id:ID!, $cursor:String) { node(id:$id) { ... on ProjectV2 { '
                           'items(first:100, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { '
                           + sync.ITEM + ' } } } } }', id=found['id'], cursor=cursor)['node']['items']
        for item in page['nodes']:
            content = item.get('content') or {}
            if content.get('__typename') == 'Issue' and content['repository']['nameWithOwner'].lower() == api.repo.lower():
                items[content['number']] = {'id': item['id'], 'area': sync.fields(item).get(AREA, '')}
        if not page['pageInfo']['hasNextPage']:
            break
        cursor = page['pageInfo']['endCursor']
        if not cursor:
            raise sm_status.GitHubError('project pagination did not advance')
    return {'id': found['id'], 'field': area['id'], 'options': options, 'items': items}


def write(api, target, item, name):
    api.graphql('''mutation($project:ID!, $item:ID!, $field:ID!, $value:ProjectV2FieldValue!) {
      updateProjectV2ItemFieldValue(input:{projectId:$project, itemId:$item, fieldId:$field, value:$value}) {
        projectV2Item { id }
      }
    }''', project=target['id'], item=item['id'], field=target['field'],
        value={'singleSelectOptionId': target['options'][name]})
    data = api.graphql('query($id:ID!) { node(id:$id) { ... on ProjectV2Item { ' + sync.VALUES + ' } } }', id=item['id'])
    if sync.fields(data['node']).get(AREA) != name:
        raise sm_status.GitHubError('Area read-back did not match')


def reconcile(api, owner='uncomposed', number=6, apply=False):
    started = time.monotonic()
    report = {'apply': apply, 'set': [], 'skipped': [], 'no_card': [], 'unknown': []}
    try:
        target = board(api, owner, number)
        for issue in api.pages('issues?state=open&sort=created&direction=asc'):
            if 'pull_request' in issue:
                continue
            n = issue['number']
            labels = [label['name'] for label in issue['labels']]
            item = target['items'].get(n)
            if not item:
                if any(label in AREA_LABELS for label in labels):
                    report['no_card'].append(n)  # project sync adds the card; the next run fills it
                continue
            name, reason = propose(labels, item['area'])
            if name is None:
                if reason.startswith(('unmapped', 'labels disagree')):
                    report['skipped'].append({'issue': n, 'reason': reason})
                continue
            change = {'issue': n, 'area': name}
            report['set'].append(change)
            if apply:
                try:
                    write(api, target, item, name)
                    change['verified'] = True
                except (sm_status.GitHubError, KeyError, TypeError, ValueError, OSError) as error:
                    report['unknown'].append({'issue': n, 'reason': str(error)})
    except (sm_status.GitHubError, KeyError, TypeError, ValueError, OSError) as error:
        report['unknown'].append({'issue': None, 'reason': str(error)})
    report['seconds'] = round(time.monotonic() - started, 3)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--repo', default=sm_status.REPO)
    parser.add_argument('--owner', default='uncomposed')
    parser.add_argument('--project', type=int, default=6)
    args = parser.parse_args(argv)
    report = reconcile(sync.GitHub(args.repo), args.owner, args.project, args.apply)
    print(json.dumps(report, indent=2))
    return 2 if report['unknown'] else 0


if __name__ == '__main__':
    sys.exit(main())
