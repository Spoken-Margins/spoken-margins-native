#!/usr/bin/env python3
"""Record trimmed GitHub API responses for scripts/tests/test_sm_status.py (#1597).

  python3 scripts/fixtures/sm_status/record.py 1585 1590 1595 1596 1154 1568

Writes `pr-<number>.json` next to this file: the bundle `sm_status.fetch_bundle` reads (pull, comments, events,
files, check_runs), cut to the fields `sm_status.py` and `sm_sweep.py` read. Report, audit and request comments keep
their first lines and every hidden `<!-- ... -->` marker line; other comments keep 300 characters. Needs GH_TOKEN.
A fixture is a record of what GitHub said on the day it was taken, so a test built on it names the PR and the
state it expects, and doesn't follow the live PR.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))
import sm_status  # noqa: E402

MARKER_LINE = re.compile(r'^<!--.*-->$')


def trim_body(body, user):
    lines = (body or '').splitlines()
    structured = user == sm_status.LANE_BOT or body.lstrip().startswith(('/lane', '**Claude audit', '**Codex audit',
                                                                           '## Codex audit', 'Lane report'))
    if not structured:
        return (body or '')[:300]
    kept = lines[:4] + [line for line in lines[4:] if MARKER_LINE.match(line)]
    return '\n'.join(kept)


def trim_comment(comment):
    login = (comment.get('user') or {}).get('login') or ''
    return {'id': comment['id'], 'user': {'login': login}, 'created_at': comment['created_at'],
            'html_url': comment.get('html_url'), 'issue_url': comment.get('issue_url'),
            'body': trim_body(comment.get('body'), login)}


def trim(bundle):
    pull = bundle['pull']
    return {'pull': {key: pull.get(key) for key in ('number', 'title', 'html_url', 'state', 'draft', 'mergeable',
                                                    'mergeable_state')}
            | {'body': (pull.get('body') or '')[:300], 'labels': [{'name': l['name']} for l in pull['labels']],
               'head': {'sha': pull['head']['sha'], 'ref': pull['head']['ref']}},
            'comments': [trim_comment(c) for c in bundle['comments']],
            'events': [{'event': e['event'], 'created_at': e['created_at'], 'label': {'name': e['label']['name']}}
                       for e in bundle['events'] if e.get('label')],
            'files': [{'filename': f['filename']} for f in bundle['files']],
            'check_runs': [{key: r.get(key) for key in ('id', 'name', 'status', 'conclusion')}
                           for r in bundle['check_runs']],
            'errors': bundle['errors']}


def main(numbers):
    api = sm_status.GitHub()
    for number in numbers:
        bundle = sm_status.fetch_bundle(api, {'number': int(number)})
        (HERE / f'pr-{number}.json').write_text(json.dumps(trim(bundle), indent=1, sort_keys=True) + '\n')
        print(f'pr-{number}.json', bundle['pull']['head']['sha'][:7])


if __name__ == '__main__':
    main(sys.argv[1:])
