#!/usr/bin/env python3
"""Everything waiting on the owner, with its full card, from one live read (#3898). Stdlib. Read-only.

A wait on him is written in five places: the `needs-owner` label, a card in an issue comment, a validation label,
the `needs-owner-tap` flag on a PR, and a session's closing message. Nothing read them all, so "what is waiting on
me?" found the merge taps and stopped. This reads the first four (the fifth is a message, not a record) and prints
four lists:

  scripts/sm_owner_queue.py                      the lists, each decision and step with its full card
  scripts/sm_owner_queue.py --json               the same facts for scripts
  scripts/sm_owner_queue.py --speak queue.md     also write a short Markdown file made for listening

The lists: decisions (a `**Decision for Cole**` card), steps on his accounts or machines (a `**Step for Cole**`
card), merge taps (open PRs labelled `needs-owner-tap`), phone checks (`status: needs-human-validation` or
`needs-human-validation`). `needs-owner` with no card is listed apart as "needs a card": the owner has nothing to
answer yet, and `scripts/owner_card_guard.py` tells the thread.

The fixed card (the owner overlay, "A question he can answer"): a line starting `**Decision for Cole**` (or
`**Step for Cole**`), then what this is in one sentence, the question, the pick, the other options with their
cost, and what it blocks. The card runs to the next line that is only `---`. A card inside a code block or a quoted
line is not a card. Only a card from a trusted author counts (scripts/comment_trust.py, #1822): a stranger's
look-alike is data and is ignored. A trusted comment that contains `<!-- owner-answered -->` after the card ends it.

Exit 0 the queue printed, 2 GitHub unreachable (nothing partial is shown as the queue).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import comment_trust
import sm_status

NEEDS_OWNER = 'needs-owner'
NEEDS_DESIGN = 'needs-design'
TAP_LABEL = 'needs-owner-tap'
VALIDATION_LABELS = ('status: needs-human-validation', 'needs-human-validation')
ANSWERED = '<!-- owner-answered -->'
HEADING = re.compile(r'^[ \t]*\*\*(Decision|Step) for Cole\*\*', re.I)
FENCE = re.compile(r'^[ \t]*(```|~~~)')

ISSUES_QUERY = '''
query($cursor: String, $owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 50, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url body createdAt authorAssociation author { login __typename }
        labels(first: 40) { nodes { name } }
        comments(last: 50) { nodes { body createdAt url authorAssociation author { login __typename } } }
      }
    }
  }
}'''


def fetch_issues(api: sm_status.GitHub) -> list[dict]:
    """Every open issue (not PRs) with its labels and newest 50 comments, in the `gh --json` shape."""
    owner, name = api.repo.split('/')
    found, cursor = [], None
    while True:
        data = api.graphql(ISSUES_QUERY, {'cursor': cursor, 'owner': owner, 'name': name})
        page = data['repository']['issues']
        for node in page['nodes']:
            node['labels'] = [x['name'] for x in node['labels']['nodes']]
            node['comments'] = node['comments']['nodes']
            found.append(node)
        if not page['pageInfo']['hasNextPage']:
            return found
        cursor = page['pageInfo']['endCursor']


def fetch_taps(api: sm_status.GitHub) -> list[dict]:
    """Open PRs labelled `needs-owner-tap` (scripts/owner_tap_alert.py sets it)."""
    items = api.pages(f'issues?state=open&labels={TAP_LABEL}')
    return [{'number': i['number'], 'title': i['title'], 'url': i['html_url'], 'createdAt': i['created_at']}
            for i in items if 'pull_request' in i]


def cards_in(text: str | None) -> list[dict]:
    """The cards in one text: {'kind', 'text'}. Fenced code and quoted lines never start one."""
    lines, found, fenced = (text or '').splitlines(), [], False
    i = 0
    while i < len(lines):
        line = lines[i]
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced and not line.lstrip().startswith('>'):
            match = HEADING.match(line)
            if match:
                end = i + 1
                while end < len(lines) and lines[end].strip() != '---':
                    end += 1
                found.append({'kind': match.group(1).lower(), 'text': '\n'.join(lines[i:end]).strip()})
                i = end
                continue
        i += 1
    return found


def newest_card(issue: dict) -> dict | None:
    """The newest card from a trusted author in the issue's body or comments, or None. Adds 'when', 'url' and
    'answered' (a later trusted comment carries the answered marker)."""
    sources = []
    if comment_trust.trusted(issue):
        sources.append((issue.get('createdAt') or '', issue.get('body'), issue.get('url')))
    trusted_comments = comment_trust.trusted_only(issue.get('comments'))
    sources += [(c.get('createdAt') or '', c.get('body'), c.get('url')) for c in trusted_comments]
    best = None
    for when, body, url in sources:
        cards = cards_in(body)
        if cards and (best is None or when >= best['when']):
            best = {**cards[-1], 'when': when, 'url': url}
    if best:
        best['answered'] = any(ANSWERED in (c.get('body') or '') and (c.get('createdAt') or '') > best['when']
                               for c in trusted_comments)
    return best


def age_days(created: str | None, now: dt.datetime) -> int | None:
    try:
        return (now - sm_status.parse_time(created)).days
    except (TypeError, ValueError):
        return None


def build_queue(issues: list[dict], taps: list[dict], now: dt.datetime | None = None) -> dict:
    """The four lists plus 'needs_card', 'answered_label_on' and 'on_design'. One entry per issue: a live card
    first, else a validation label, else `needs-owner` with no card."""
    now = now or dt.datetime.now(dt.timezone.utc)
    queue = {'decisions': [], 'steps': [], 'merge_taps': [], 'phone_checks': [], 'needs_card': [],
             'answered_label_on': [], 'on_design': []}
    for issue in sorted(issues, key=lambda i: i['number']):
        labels = set(issue.get('labels') or [])
        card = newest_card(issue)
        live = card if card and not card['answered'] else None
        entry = {'number': issue['number'], 'title': issue.get('title', ''), 'url': issue.get('url', ''),
                 'age_days': age_days(issue.get('createdAt'), now), 'labels': sorted(labels)}
        if live:
            queue['decisions' if live['kind'] == 'decision' else 'steps'].append(
                {**entry, 'card': live['text'], 'card_url': live['url'], 'has_label': NEEDS_OWNER in labels,
                 'card_age_days': age_days(live['when'], now)})
        elif labels & set(VALIDATION_LABELS):
            queue['phone_checks'].append(entry)
        elif NEEDS_OWNER in labels and card:
            queue['answered_label_on'].append(entry)
        elif NEEDS_OWNER in labels and NEEDS_DESIGN in labels:
            queue['on_design'].append(entry)
        elif NEEDS_OWNER in labels:
            queue['needs_card'].append(entry)
    for pr in sorted(taps, key=lambda p: p['number']):
        queue['merge_taps'].append({**pr, 'age_days': age_days(pr.get('createdAt'), now)})
    return queue


def count(queue: dict) -> int:
    return sum(len(queue[k]) for k in ('decisions', 'steps', 'merge_taps', 'phone_checks'))


def _age(item: dict) -> str:
    days = item.get('age_days')
    return '' if days is None else f' ({days} days old)'


def render(queue: dict) -> str:
    out = [f"Waiting on you: {len(queue['decisions'])} decisions, {len(queue['steps'])} steps on your accounts or "
           f"machines, {len(queue['merge_taps'])} merge taps, {len(queue['phone_checks'])} phone checks."]
    for key, title in (('decisions', 'Decisions'), ('steps', 'Steps on your accounts or machines')):
        out += ['', f'== {title} ({len(queue[key])}) ==']
        for item in queue[key]:
            note = '' if item['has_label'] else '  [no needs-owner label yet]'
            out += ['', f"#{item['number']} {item['title']}{_age(item)}{note}", item['url'], '', item['card']]
    out += ['', f"== Merge taps ({len(queue['merge_taps'])}) =="]
    out += [f"#{p['number']} {p['title']}{_age(p)}  {p['url']}" for p in queue['merge_taps']]
    out += ['', f"== Phone checks ({len(queue['phone_checks'])}) =="]
    out += [f"#{p['number']} {p['title']}{_age(p)}  {p['url']}" for p in queue['phone_checks']]
    for key, title, why in (
            ('needs_card', 'Needs a card', 'needs-owner but no card: nothing for you to answer yet, a thread must write it'),
            ('answered_label_on', 'Answered, label still on', 'a thread should take needs-owner off'),
            ('on_design', 'On the design pass', 'needs-owner and needs-design: a taste call, not yours')):
        if queue[key]:
            out += ['', f'== {title} ({len(queue[key])}): {why} ==']
            out += [f"#{p['number']} {p['title']}  {p['url']}" for p in queue[key]]
    return '\n'.join(out) + '\n'


def speak(queue: dict) -> str:
    """Short Markdown for listening: plain sentences, numbered, issue numbers at the end."""
    lines = ['# What is waiting on you', '']
    total = count(queue)
    if not total:
        return '\n'.join(lines + ['Nothing is waiting on you.', ''])
    lines += [f'{total} things are waiting on you.', '']
    n, numbers = 0, []
    for key, what in (('decisions', 'A decision'), ('steps', 'A step on your accounts or machines'),
                      ('merge_taps', 'A merge tap'), ('phone_checks', 'A phone check')):
        for item in queue[key]:
            n += 1
            numbers.append(f"#{item['number']}")
            text = f"{n}. {what}: {item['title']}."
            if 'card' in item:
                body = [x.strip(' *') for x in item['card'].splitlines()[1:] if x.strip()]
                text += ' ' + ' '.join(b if b.endswith(('.', '?')) else b + '.' for b in body)
            lines.append(text)
    return '\n'.join(lines + ['', 'Issue numbers: ' + ', '.join(numbers), ''])


def main(argv=None, api=None, now=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--speak', metavar='FILE')
    parser.add_argument('--repo', default=sm_status.REPO)
    args = parser.parse_args(argv)
    try:
        api = api or sm_status.GitHub(args.repo)
        queue = build_queue(fetch_issues(api), fetch_taps(api), now)
    except (sm_status.GitHubError, KeyError, TypeError) as error:
        print(f'unknown: could not read GitHub ({error}); nothing is shown as the queue', file=sys.stderr)
        return 2
    print(json.dumps(queue, indent=2) if args.json else render(queue), end='\n' if args.json else '')
    if args.speak:
        Path(args.speak).write_text(speak(queue))
    return 0


if __name__ == '__main__':
    sys.exit(main())
