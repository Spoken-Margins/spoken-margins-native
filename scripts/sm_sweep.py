#!/usr/bin/env python3
"""Wake sweep (#1598): what is idle or stuck right now, as a short action list. Stdlib, Python 3.9+.

The coordinator acts only when something wakes it, and stalled work used to wait for the owner to notice (56 stale
`in-progress` claims on 2026-10-14, the Mac idle beside eight Mac-only ready issues, a Test Desk check nobody
started, a finisher skipping PRs). Run this on every wake (an owner message, a Dial fire, the hourly dispatch),
act on what it prints, then reply:

  scripts/sm_sweep.py                  print the action list; change nothing
  scripts/sm_sweep.py --apply          also release the stale claims (the one housekeeping step it takes)
  scripts/sm_sweep.py --json           the same facts for scripts
  scripts/sm_sweep.py --status-json F  use a saved `scripts/sm_status.py --json` output (F or - for stdin)

It looks for thirteen things:
  1. free Claude slots against the Dial (#589): its Threads box less the Claude threads active from their claim
     and stop notes (ops/dial/dial_gate.py's own reading), with the ready issues to start; Codex workers are
     counted against Codex's box and never against Claude's
  2. the Mac idle while Mac-only `ready` issues exist: no `where:mac` issue is in progress and not stale
  3. stale claims: an open `in-progress` issue with no comment, no open PR, no commit on a `ws/<n>-` branch and no
     newly added label inside 6 hours, and whose claiming thread isn't active (owner's housekeeping call 2026-10-14)
  4. armed PRs red on their head (from the PR snapshot, scripts/sm_status.py)
  5. open PRs with a `/lane T4` request unanswered for over an hour, or the Mac tick's `Test Desk: GO`, with no
     Test Desk seen working for an hour
  6. `needs-mac` PRs with no finisher comment or commit for an hour after the hand-off
  7. open issues triage hasn't finished with, however old: no `area:` label (or two), or no state label (2026-10-16:
     the daily triage looked only at issues filed since its last run, so 136 piled up unseen). Not the milestone: since
     2026-11-07 a milestone is only for a release on deck, so "no milestone" read 133 of 278 on every run (#3885)
  8. ready issues whose fix already merged (2026-10-22): a `Closes`, `Fixes` or `Resolves #N` PR is merged into the
     trunk, no open PR touches the issue and no claim is recent
  Drift between GitHub and the code (#3350, report only; the 2026-11-04 audit found each by hand):
  9. an open issue that a merged `Closes #N` PR into the trunk or `next` names, unless the issue was reopened after
     that merge or the PR was reverted (#3218 stayed open after #3315 merged; GitHub did not close it, and rule 8
     sees only `ready` issues)
  10. a `Revert #P` merged in the last 14 days where an issue #P names has no trusted comment since that mentions the
     revert (#3310 was reverted by #3320 and re-landed by #3323 with nothing on #460)
  11. an open issue whose newest trusted comment holds it on a PR that has merged since, or waits on `next`, which
     is frozen (#1612's newest note held it on #1154, merged into `next` on 2026-10-20)
  12. (folded into rule 7, #3885) an open issue with a milestone other than Later and no state label (#3521: #3391
     sat unseen for 39 hours); triage gives it a state, and only a person picks `ready`
  13. a `needs-owner` issue filed by a person or agent since 2026-11-10 with no `Checked:` line in its body or newest
     comments (#3872: on 2026-11-08 a stale record became a phone test the owner had already done)
  Silent `in-progress` claims (#3247, #1507) are rule 3.

--apply also closes those (rule 8), commenting once and removing only `ready` and `in-progress`. Every other label,
including `found-on-phone`, `needs-human-validation`, `agent-verify`, `validate-by-use` and `priority`, stays on the
closed issue, and a failed validation reopens it with `regression` (owner, 2026-10-22). Readers of validation work
must therefore read closed issues too (#2448).

--apply releases a stale claim by removing `in-progress`, adding `ready` (unless the issue is `blocked`,
`needs-owner`, `deferred`, `validate-by-use`, `agent-verify` or `status: needs-human-validation`) and commenting why. It re-reads the issue's comments just before writing and does
nothing if any arrived. Every other finding is printed for the coordinator to dispatch; nothing else is written.

Limits, stated so the output isn't over-trusted: the sweep reads GitHub, not sessions. A Test Desk or thread that has
posted nothing for an hour looks idle; confirm with the session list before starting a second. A claim whose thread
works on a branch not named `ws/<n>-…` and says nothing for 6 hours is released, as the standing call allows.
Anything it can't read is reported as unreadable and never turned into a release.

Exit codes: 0 the sweep ran (actions or none), 2 GitHub unreachable or unreadable (nothing partial is printed as
"nothing to do"). Needs GH_TOKEN or GITHUB_TOKEN (or `gh auth token`); --apply needs write access to issues.
About 40 to 80 GitHub calls a run, none of them model tokens. Rules 9 to 13 add about 6: GraphQL pages of the open
issues with their last three comments (100 a page), one page of PRs merged into `next`, one GraphQL lookup of the PRs
a hold names, and at most DRIFT_READ_CAP issue-comment reads for reverts; what the cap leaves out is printed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'ops' / 'dial'))
import comment_trust  # noqa: E402  (#1822: only the owner's, collaborators' and the bot's comments are believed)
import dial_gate  # noqa: E402  (the Dial's own reading of the tick boxes, claim notes and usage breaker)
import sm_status  # noqa: E402
from trunk import trunk_branch  # noqa: E402

DIAL_ISSUE, TICK_ISSUE, DESK_ISSUE = 589, 337, 184
STALE_AFTER = dt.timedelta(hours=6)          # a claim with no sign of life this long is released (2026-10-14)
T4_WAIT = dt.timedelta(hours=1)
FINISHER_WAIT = dt.timedelta(hours=1)
DESK_QUIET = dt.timedelta(hours=1)
TICK_STALE = dt.timedelta(hours=3)           # dial_gate.USAGE_MAX_AGE: past this the Mac counts as offline
USAGE_WINDOW = dt.timedelta(hours=12)         # dial_gate.main reads #337 this far back for the usage breaker
SNAPSHOT_MAX_AGE = dt.timedelta(minutes=10)  # --apply refuses a saved snapshot older than this
FINISHER_BUSY = 30                           # minutes: a finisher active more recently than this means the Mac is working
COMMENT_WINDOW = dt.timedelta(hours=24)      # the Dial gate's own window for claim and stop notes
CARD_RULE_FROM = '2026-11-10T00:00:00Z'    # rule 13 starts here; older cards were written before it existed
CHECKED_LINE = re.compile(r'^\W*checked:', re.I | re.M)
SKIP_LABELS = {'in-progress', 'needs-owner', 'deferred', 'blocked'}
OUTSIDE_LABEL = 'needs-triage-review'          # an issue by an untrusted author; only a collaborator can make it `ready`
HOLD_LABELS = {'blocked', 'needs-owner', 'deferred', 'validate-by-use', 'agent-verify',
               'status: needs-human-validation'}   # a released claim isn't made `ready` with one of these
STATE_LABELS = {'ready', 'in-progress', 'needs-owner', 'deferred', 'blocked', 'parked', 'later', 'tracker',
                'validate-by-use', 'agent-verify', 'needs-human-validation', 'status: needs-human-validation',
                'type: research', OUTSIDE_LABEL}   # rule 7: any of these says what happens to the issue next
PARKED_MILESTONE = 'Later'                     # rule 7: the milestone itself is the state
AREA_PREFIX = 'area: '                         # rule 7: exactly one of these (docs/areas.md); none or two is untriaged
DEAD = ('mac-tick-stale',)
MERGED_PR_PAGES = 3                            # the newest 300 closed PRs into the trunk are as far back as a fix is looked for
FROZEN_BASE = 'next'                           # frozen since 2026-10-20 (#1492); its merged PRs never closed an issue
NEXT_PR_PAGES = 1                              # nothing new merges into it, so its newest 100 closed PRs are enough
OPEN_ISSUE_PAGES = 5                           # GraphQL pages of 100 open issues (about 270 on 2026-11-04)
REVERT_WINDOW = dt.timedelta(days=14)
DRIFT_READ_CAP = 10                            # REST comment reads for rule 10; past it a revert is listed as unchecked
LOOKUP_CAP = 100                               # PR numbers one GraphQL lookup may ask about
REVERT = re.compile(r'\breverts?\s+(?:PR\s+)?(?:[\w.-]+/[\w.-]+)?#(\d+)', re.I)
# A hold names its PR right after the hold word ("hold on PR #1154", "blocked behind #12", "until #12 merges"), so
# "PR #3306 armed · waiting on the owner's answers" is not read as a hold on #3306.
_HOLD = r'\b(?:hold|holds|held|holding|blocked|blocker|behind|until|waits?|waiting|depends|depending)'
HOLD_ON_PR = re.compile(_HOLD + r'(?:\s+(?:on|for|by|behind))?\s+(?:the\s+)?(?:PR\s+)?#(\d+)', re.I)
HOLD_ON_NEXT = re.compile(_HOLD + r'\b[^.\n]{0,60}?(?:`next`|\binto next\b|\bnext branch\b)', re.I)

RED, LOOK = sm_status.RED, sm_status.LOOK


def when(text):
    return dial_gate.parse_time(text) if text else None


def ago(now, then):
    minutes = int((now - then).total_seconds() // 60)
    return f'{minutes} min' if minutes < 120 else f'{minutes / 60:.1f} h'


# ---- Reading the Dial, the Mac tick and the queue ----------------------------------------------------------

def codex_slots(dial_body):
    """The Codex workers box: the lowest ticked number (two ticks take the cautious one), 0 when none."""
    group, ticked = None, []
    for line in dial_body.splitlines():
        heading = re.match(r'\s*\*\*(.+?)\*\*', line)
        if heading and not line.lstrip().startswith('-'):
            group = heading.group(1).strip().lower()
        elif line.strip() == '---':
            group = None
        box = re.match(r'\s*[-*]\s*\[[xX]\]\s*(\d+)', line)
        if box and group and group.startswith('codex workers'):
            ticked.append(int(box.group(1)))
    return min(ticked) if ticked else 0


def dial_now(status_comments):
    """The Dial gate status comment's `Now:` line (edited in place by the gate), or None when it isn't there."""
    for comment in reversed(status_comments):
        body = comment.get('body') or ''
        if dial_gate.STATUS_MARK in body:
            found = re.search(r'^- Now: (.*)$', body, re.M)
            return found.group(1).strip() if found else None
    return None


def latest_tick(comments):
    """The newest Mac tick on #337: when it posted, the Test Desk verdict line, and the finisher's last activity."""
    ticks = [c for c in comments if '(Mac tick' in ((c.get('body') or '').splitlines() or [''])[0]]
    if not ticks:
        return None
    body = ticks[-1]['body']
    desk = re.search(r'^\s*-\s*Test Desk:\s*(GO|STOP)\b', body, re.M)
    finisher = re.search(r'Mac finisher last active (\d+)\s*(min|minutes|h|hours)\b', body)
    runner = re.search(r'runner: (\d+) running, (\d+) queued', body)
    return {'at': ticks[-1]['created_at'], 'test_desk': desk.group(1) if desk else None,
            'finisher_idle_minutes': (int(finisher.group(1)) * (60 if finisher.group(2).startswith('h') else 1)
                                      if finisher else None),
            'runner_running': int(runner.group(1)) if runner else None,
            'runner_queued': int(runner.group(2)) if runner else None}


def issue_row(issue):
    return {'number': issue['number'], 'title': issue.get('title') or '', 'created_at': issue.get('created_at') or '',
            'labels': sorted(label['name'] for label in issue.get('labels', [])),
            'milestone': (issue.get('milestone') or {}).get('title')}


def queue_key(issue):
    """The coordinator's order (project instructions): `priority` first, then regressions, `found-on-phone`, then oldest."""
    labels = set(issue['labels'])
    return ('priority' not in labels, 'regression' not in labels, 'found-on-phone' not in labels, issue['created_at'])


def startable(ready, in_progress):
    """Ready issues a thread may take: none of the skip labels, and no second `hot-file` thread at a time."""
    hot_busy = any('hot-file' in issue['labels'] for issue in in_progress)
    return sorted((i for i in ready if not set(i['labels']) & SKIP_LABELS
                   and not ('hot-file' in i['labels'] and hot_busy)), key=queue_key)


# ---- Stale claims ---------------------------------------------------------------------------------------------

def claim_state(evidence, now, window=STALE_AFTER):
    """('active' | 'stale' | 'unknown', why, last sign of life) for one `in-progress` issue.

    Active wins over unknown: a sign of life is certain even when another read failed. Unknown never releases.
    """
    seen = [t for t in (evidence.get('last_comment_at'), evidence.get('label_since'),
                        evidence.get('branch_commit_at')) if t]
    last = max(seen) if seen else None
    if evidence.get('open_pr'):
        return 'active', f'open PR #{evidence["open_pr"]}', last
    if evidence.get('thread_active'):
        return 'active', f'its thread "{evidence["thread_active"]}" is active', last
    if last and now - when(last) < window:
        return 'active', f'a sign of life {ago(now, when(last))} ago', last
    if evidence.get('unknown'):
        return 'unknown', '; '.join(evidence['unknown']), last
    return 'stale', (f'nothing since {last} ({ago(now, when(last))} ago)' if last else 'no sign of life on record'), last


def gather_claim(api, number, now, ctx):
    """Collect the signs of life for one claimed issue, cheapest first, stopping at the first that proves it active."""
    evidence = {'number': number, 'last_comment_at': ctx['last_comment'].get(number),
                'open_pr': ctx['pr_for_issue'].get(number), 'thread_active': ctx['thread_for_issue'].get(number),
                'label_since': None, 'branch_commit_at': None, 'unknown': []}
    if not ctx['comments_complete']:
        evidence['unknown'].append('the repo-wide comment read was incomplete')
    if claim_state(evidence, now)[0] == 'active':
        return evidence
    try:
        evidence['label_since'] = sm_status.label_since(api.pages(f'issues/{number}/events'), 'in-progress')
        if evidence['label_since'] is None:
            evidence['unknown'].append('no "in-progress labeled" event found')
    except sm_status.GitHubError as error:
        evidence['unknown'].append(f'issue events unreadable: {error}')
    if claim_state(evidence, now)[0] == 'active':
        return evidence
    try:
        newest = None
        for ref in api.get(f'git/matching-refs/heads/ws/{number}-'):
            commit = api.get(f'commits/{ref["object"]["sha"]}')
            date = ((commit.get('commit') or {}).get('committer') or {}).get('date')
            newest = max(newest, date) if newest and date else (date or newest)
        evidence['branch_commit_at'] = newest
    except (sm_status.GitHubError, KeyError, TypeError) as error:
        evidence['unknown'].append(f'branches unreadable: {error}')
    return evidence


def release_note(issue, why, window=STALE_AFTER):
    hours = int(window.total_seconds() // 3600)
    held = sorted(set(issue['labels']) & HOLD_LABELS)
    back = (f'Not set back to `ready`: it carries {", ".join("`" + l + "`" for l in held)}.' if held
            else 'Back on the queue as `ready`.')
    return (f'Released by scripts/sm_sweep.py: this claim has had no commit, open PR or comment for {hours} hours '
            f'({why}). {back} (Owner\'s housekeeping call, 2026-10-14.) A thread that is still working on it can '
            f'claim it again.')


def merged_fix_note(pr_number, merged_at):
    return (f'Closed by scripts/sm_sweep.py: fix merged in #{pr_number} on {merged_at[:10]}. Validation labels stay on; '
            'a failed check reopens it (2026-10-22 call).')


def release_merged_fix(api, row, now, window=STALE_AFTER):
    """Close one ready issue whose fix merged, keeping its labels but `ready` and `in-progress`. Re-reads the issue
    and its comments first; never raises."""
    number = row['number']
    try:
        since = (now - window).strftime('%Y-%m-%dT%H:%M:%SZ')
        if api.pages(f'issues/{number}/comments?since={since}'):
            return 'skipped: a comment arrived while the sweep ran'
        current = api.get(f'issues/{number}')
        names = {label['name'] for label in current.get('labels', [])}
        if current.get('state') != 'open' or 'ready' not in names:
            return 'skipped: no longer an open ready issue'
        api.post(f'issues/{number}/comments', {'body': merged_fix_note(row['pr'], row['merged_at'])})
        api.patch(f'issues/{number}', {'state': 'closed', 'state_reason': 'completed'})
        if 'in-progress' in names:
            api.delete(f'issues/{number}/labels/in-progress')
        api.delete(f'issues/{number}/labels/ready')
        return 'closed'
    except sm_status.GitHubError as error:
        return f'error: {error}'


def closed_pulls(api, base, pages):
    """The newest closed PRs into one base, each tagged with it; one batched read, not a search per issue."""
    found = api.pages(f'pulls?state=closed&base={urllib.parse.quote(base)}&sort=updated&direction=desc',
                      limit=pages, partial=True)
    return [dict(pull, _base=base) for pull in found]


def merged_fixes(pulls, ready, ctx):
    """Ready issues a merged trunk PR says it closes, with no open PR on them and no recent claim: [{..issue, pr, merged_at}].

    `pulls` is the closed-PR read of the trunk; None when it couldn't be read, and then so is the answer.
    """
    if pulls is None:
        return None
    if not ready:
        return []
    fixed = {}
    for pull in pulls:
        if not pull.get('merged_at'):
            continue
        for number in {int(n) for n in sm_status.CLOSING.findall(f'{pull.get("title") or ""}\n{pull.get("body") or ""}')}:
            if number not in fixed or pull['merged_at'] > fixed[number]['merged_at']:
                fixed[number] = {'pr': pull['number'], 'merged_at': pull['merged_at']}
    found = []
    for row in ready:
        fix = fixed.get(row['number'])
        if not fix or ctx['pr_for_issue'].get(row['number']):
            continue
        evidence = {'last_comment_at': ctx['last_comment'].get(row['number']),
                    'thread_active': ctx['thread_for_issue'].get(row['number'])}
        if claim_state(evidence, ctx['now'])[0] == 'active':
            continue
        found.append(dict(row, **fix))
    return found


# ---- Drift between GitHub and the code (rules 9 to 12, report only) --------------------------------------------

OPEN_ISSUES = """query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $after, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title body createdAt
        author { __typename }
        milestone { title }
        labels(first: 30) { nodes { name } }
        timelineItems(last: 1, itemTypes: [REOPENED_EVENT]) { nodes { ... on ReopenedEvent { createdAt } } }
        comments(last: 3) { nodes { createdAt body authorAssociation author { __typename login } } }
      }
    }
  }
}"""


def owner_name(api):
    owner, _, name = api.repo.partition('/')
    return {'owner': owner, 'name': name}


def open_issues(api):
    """Every open issue with its labels, its last reopening and its last three comments, in a few GraphQL pages."""
    rows, after = [], None
    for _ in range(OPEN_ISSUE_PAGES):
        page = api.graphql(OPEN_ISSUES, dict(owner_name(api), after=after))['repository']['issues']
        for node in page['nodes']:
            reopened = [n.get('createdAt') for n in node['timelineItems']['nodes'] if n.get('createdAt')]
            rows.append({'number': node['number'], 'title': node.get('title') or '', 'body': node.get('body') or '',
                         'created_at': node.get('createdAt') or '', 'by_bot': (node.get('author') or {}).get('__typename') == 'Bot',
                         'labels': sorted(l['name'] for l in node['labels']['nodes']),
                         'milestone': (node.get('milestone') or {}).get('title'),
                         'reopened_at': max(reopened) if reopened else None,
                         'comments': sorted(node['comments']['nodes'], key=lambda c: c['createdAt'])})
        if not page['pageInfo']['hasNextPage']:
            return rows
        after = page['pageInfo']['endCursor']
    raise sm_status.GitHubError(f'more than {OPEN_ISSUE_PAGES * 100} open issues')


def lookup_pulls(api, numbers):
    """{number: {number, merged_at, _base, title, body, head}} for the PRs among `numbers`, in one GraphQL read.
    Issue numbers come back as nothing. The first LOOKUP_CAP numbers are asked about."""
    numbers = sorted(set(numbers))[:LOOKUP_CAP]
    if not numbers:
        return {}
    fields = ' '.join(f'n{n}: issueOrPullRequest(number: {n}) {{ ... on PullRequest {{ number mergedAt baseRefName '
                      f'headRefName title body }} }}' for n in numbers)
    data = api.graphql(f'query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ {fields} }} }}',
                       owner_name(api))['repository']
    found = {}
    for node in data.values():
        if node and node.get('number'):
            found[node['number']] = {'number': node['number'], 'merged_at': node.get('mergedAt'),
                                     '_base': node.get('baseRefName'), 'title': node.get('title') or '',
                                     'body': node.get('body') or '', 'head': {'ref': node.get('headRefName') or ''}}
    return found


def pull_text(pull):
    return f'{pull.get("title") or ""}\n{pull.get("body") or ""}'


def reverts_of(pulls):
    """{reverted PR number: the newest merged PR that reverts it}."""
    found = {}
    for pull in pulls:
        if not pull.get('merged_at'):
            continue
        for number in {int(n) for n in REVERT.findall(pull_text(pull))}:
            if number not in found or pull['merged_at'] > found[number]['merged_at']:
                found[number] = pull
    return found


def merged_but_open(pulls, issues, skip=()):
    """Rule 9: open issues a merged closing PR names, newest fix first per issue. Skips an issue reopened after the
    merge (a failed validation reopens with `regression`, 2026-10-22) and a PR that was reverted."""
    reverted = set(reverts_of(pulls))
    fixed = {}
    for pull in pulls:
        if not pull.get('merged_at') or pull['number'] in reverted:
            continue
        for number in {int(n) for n in sm_status.CLOSING.findall(pull_text(pull))}:
            if number not in fixed or pull['merged_at'] > fixed[number]['merged_at']:
                fixed[number] = {'pr': pull['number'], 'merged_at': pull['merged_at'], 'base': pull.get('_base')}
    found = []
    for row in issues:
        fix = fixed.get(row['number'])
        if not fix or row['number'] in skip:
            continue
        if row.get('reopened_at') and row['reopened_at'] > fix['merged_at']:
            continue
        found.append({'number': row['number'], 'title': row['title'], **fix})
    return found


def unnoted_reverts(api, pulls, now, budget):
    """Rule 10: [{issue, pr, revert, merged_at}] for reverts merged in the window whose PR's issues say nothing of
    them since, and [(revert, pr)] the read budget left unchecked. `budget` is a one-item list, spent in place."""
    known = {pull['number']: pull for pull in pulls}
    recent = {number: revert for number, revert in reverts_of(pulls).items()
              if now - when(revert['merged_at']) <= REVERT_WINDOW}
    missing = [number for number in recent if number not in known]
    if missing:
        known.update(lookup_pulls(api, missing))
    found, unchecked = [], []
    for number, revert in sorted(recent.items()):
        original = known.get(number)
        issues = [n for n in sm_status.linked_issues(original) if n not in (number, revert['number'])] if original else []
        for issue_number in issues:
            if budget[0] <= 0:
                unchecked.append((revert['number'], number))
                break
            budget[0] -= 1
            since = comment_trust.trusted_only(api.pages(f'issues/{issue_number}/comments?since={revert["merged_at"]}'))
            if any(f'#{revert["number"]}' in (c.get('body') or '') or
                   (re.search(r'\brevert', c.get('body') or '', re.I) and f'#{number}' in (c.get('body') or ''))
                   for c in since):
                continue
            found.append({'issue': issue_number, 'pr': number, 'revert': revert['number'],
                          'merged_at': revert['merged_at']})
    return found, unchecked


def stale_holds(api, issues, pulls):
    """Rule 11: open issues whose newest trusted comment holds them on a PR merged after that comment, or on `next`."""
    newest = {}
    for row in issues:
        trusted = comment_trust.trusted_only(row['comments'])
        if trusted:
            newest[row['number']] = trusted[-1]
    known = {pull['number']: pull for pull in pulls if pull.get('merged_at')}
    named = {int(n) for number, comment in newest.items() for n in HOLD_ON_PR.findall(comment.get('body') or '')
             if int(n) != number}
    missing = [n for n in named if n not in known]
    if missing:
        known.update({n: p for n, p in lookup_pulls(api, missing).items() if p.get('merged_at')})
    found = []
    for row in issues:
        comment = newest.get(row['number'])
        if not comment:
            continue
        said, body, hit = comment['createdAt'], comment.get('body') or '', None
        for n in (int(x) for x in HOLD_ON_PR.findall(body)):
            pull = known.get(n)
            if n != row['number'] and pull and pull['merged_at'] > said:
                hit = {'pr': n, 'merged_at': pull['merged_at'], 'base': pull.get('_base')}
                break
        if not hit and HOLD_ON_NEXT.search(body):
            hit = {'pr': None, 'merged_at': None, 'base': FROZEN_BASE}
        if hit:
            found.append(dict(hit, number=row['number'], title=row['title'], said_at=said))
    return found


def needs_triage(issues):
    """Rule 7: an open issue without exactly one `area:` label, or without a state (a state label, or the Later
    milestone). The milestone itself says nothing, because most triaged issues keep none (#3885). Issues awaiting a
    collaborator's review (OUTSIDE_LABEL) are listed apart. Oldest first, as the scan reads them."""
    def untriaged(row):
        areas = [label for label in row['labels'] if label.startswith(AREA_PREFIX)]
        stateless = row['milestone'] != PARKED_MILESTONE and not STATE_LABELS.intersection(row['labels'])
        return len(areas) != 1 or stateless
    return [row for row in issues if OUTSIDE_LABEL not in row['labels'] and untriaged(row)]


def unchecked_cards(issues):
    """Rule 13: cards for the owner that don't say where their facts came from. Scripts' own notices aren't cards."""
    def checked(row):
        return any(CHECKED_LINE.search(text or '') for text in [row['body']] + [c.get('body') for c in row['comments']])
    return [row for row in issues if 'needs-owner' in row['labels'] and not row['by_bot']
            and row['created_at'] >= CARD_RULE_FROM and not checked(row)]


def drift(api, now, pulls, skip=()):
    """Rules 9 to 13. Each part is None when its read failed, so a failure reads as unreadable, never as clean."""
    out = {'merged_open': None, 'reverts': None, 'reverts_unchecked': [], 'holds': None,
           'unchecked_cards': None, 'errors': []}
    try:
        issues = open_issues(api)
    except (sm_status.GitHubError, KeyError, TypeError) as error:
        issues = None
        out['errors'].append(f'open issues: {error}')
    if issues is not None:
        out['unchecked_cards'] = unchecked_cards(issues)
    if issues is not None and pulls is not None:
        out['merged_open'] = merged_but_open(pulls, issues, skip)
    if pulls is not None:
        try:
            out['reverts'], out['reverts_unchecked'] = unnoted_reverts(api, pulls, now, [DRIFT_READ_CAP])
        except (sm_status.GitHubError, KeyError, TypeError) as error:
            out['errors'].append(f'reverts: {error}')
    if issues is not None:
        try:
            out['holds'] = stale_holds(api, issues, pulls or [])
        except (sm_status.GitHubError, KeyError, TypeError) as error:
            out['errors'].append(f'holds: {error}')
    if pulls is None:
        out['errors'].append('the merged-PR read failed')
    return out


def release(api, issue, why, now, window=STALE_AFTER):
    """Release one stale claim. Re-reads the issue's comments first; returns what happened, never raises."""
    number = issue['number']
    try:
        since = (now - window).strftime('%Y-%m-%dT%H:%M:%SZ')
        if api.pages(f'issues/{number}/comments?since={since}'):
            return 'skipped: a comment arrived while the sweep ran'
        current = api.get(f'issues/{number}')
        names = {label['name'] for label in current.get('labels', [])}
        if current.get('state') != 'open' or 'in-progress' not in names:
            return 'skipped: no longer an open in-progress issue'
        # in-progress comes off last, so a failed step leaves the claim in place for the next sweep to retry
        if not names & HOLD_LABELS:
            api.post(f'issues/{number}/labels', {'labels': ['ready']})
        api.post(f'issues/{number}/comments', {'body': release_note({'labels': sorted(names)}, why, window)})
        api.delete(f'issues/{number}/labels/{urllib.parse.quote("in-progress", safe="")}')
        return 'released'
    except sm_status.GitHubError as error:
        return f'error: {error}'


# ---- Collecting the facts ---------------------------------------------------------------------------------

def collect(api, now, snapshot=None):
    """Read everything the sweep needs. Raises GitHubError when a read the whole sweep depends on fails."""
    iso = lambda moment: moment.strftime('%Y-%m-%dT%H:%M:%SZ')
    snapshot = snapshot or sm_status.snapshot(api, now)
    dial_body = api.get(f'issues/{DIAL_ISSUE}').get('body') or ''
    dial = dial_gate.parse_dial(dial_body)
    dial['codex_threads'] = codex_slots(dial_body)
    status_comments = comment_trust.trusted_only(
        api.pages(f'issues/{DIAL_ISSUE}/comments?since={iso(now - dt.timedelta(hours=3))}'))
    tick_comments = comment_trust.trusted_only(api.pages(f'issues/{TICK_ISSUE}/comments?since={iso(now - USAGE_WINDOW)}'))
    usage = dial_gate.parse_usage(tick_comments)

    comments_complete = True
    try:
        comments = comment_trust.trusted_only(
            api.pages(f'issues/comments?since={iso(now - COMMENT_WINDOW)}&sort=created&direction=asc', limit=60))
    except sm_status.GitHubError:
        comments, comments_complete = [], False
    try:
        events = api.pages('events', limit=3, partial=True)
    except sm_status.GitHubError:
        events = []
    threads = dial_gate.parse_threads(comments, events, now)

    last_comment, desk_seen = {}, None
    for comment in comments:
        number = dial_gate.issue_number(comment)
        if number is not None:
            # an edited comment is a sign of life too (the pre-write re-check reads by update time)
            last_comment[number] = max(last_comment.get(number, ''), comment['created_at'],
                                       comment.get('updated_at') or '')
        if sm_status.is_desk_report(comment) or (number == DESK_ISSUE and
                                                 sm_status.comment_user(comment) != sm_status.LANE_BOT):
            desk_seen = max(desk_seen or '', comment['created_at'])

    def listing(label):
        found = api.pages(f'issues?state=open&labels={urllib.parse.quote(label)}')
        return [issue_row(i) for i in found if 'pull_request' not in i]
    ready, in_progress = listing('ready'), listing('in-progress')
    try:    # every open issue, however old: the daily triage once looked only at new ones. REST, not the GraphQL scan
        # rules 9 to 13 use, because GraphQL is not available from a Claude Code cloud session and rule 7 must work there
        open_rows = [issue_row(i) for i in api.pages('issues?state=open') if 'pull_request' not in i]
    except sm_status.GitHubError:
        open_rows = None
    untriaged = outside = None    # outside: opened by someone we don't trust, left for a collaborator (#1822)
    if open_rows is not None:
        untriaged = needs_triage(open_rows)
        outside = [row for row in open_rows if OUTSIDE_LABEL in row['labels']]

    active = [t for t in dial_gate.of_provider(threads) if t['state'] == 'active']
    codex_active = [t for t in dial_gate.of_provider(threads, 'codex') if t['state'] == 'active']
    ctx = {'last_comment': last_comment, 'comments_complete': comments_complete,
           'pr_for_issue': {n: row['number'] for row in snapshot['prs']
                            for n in (row.get('issues') or ([row['issue']] if row.get('issue') else []))},
           'thread_for_issue': {n: t['title'] for t in active + codex_active for n in t['issues']}}
    ctx['now'] = now
    trunk_pulls, pulls = None, None
    try:
        trunk_pulls = closed_pulls(api, trunk_branch(), MERGED_PR_PAGES)
        pulls = list(trunk_pulls)
        if trunk_branch() != FROZEN_BASE:
            pulls += closed_pulls(api, FROZEN_BASE, NEXT_PR_PAGES)
    except sm_status.GitHubError:
        pass    # trunk_pulls stays as read; pulls stays None, so rules 9 and 10 report unreadable
    merged = merged_fixes(trunk_pulls, ready, ctx)
    drifted = drift(api, now, pulls, skip={row['number'] for row in merged or []})
    claims = []
    for issue in in_progress:
        evidence = gather_claim(api, issue['number'], now, ctx)
        state, why, last = claim_state(evidence, now)
        claims.append(dict(issue, state=state, why=why, last_seen=last))

    return {'now': now, 'snapshot': snapshot, 'dial': dial, 'dial_now': dial_now(status_comments), 'usage': usage,
            'tick': latest_tick(tick_comments), 'ready': ready, 'in_progress': claims, 'untriaged': untriaged, 'outside': outside, 'merged_fixes': merged, 'drift': drifted,
            'claude_active': [t['title'] for t in active], 'codex_active': [t['title'] for t in codex_active],
            'desk_seen': desk_seen, 'comments_complete': comments_complete}


# ---- Deciding what to do ----------------------------------------------------------------------------------------

def slots(facts):
    dial, usage = facts['dial'], facts['usage']
    allowed, active = dial['threads'], len(facts['claude_active'])
    held = None
    if dial['mode'] == 'off' or allowed == 0:
        held = 'the Dial is Off'
    elif usage['halted']:
        held = 'HALT (usage breaker)'
    elif (facts['dial_now'] or '').startswith(('Holding', 'Off', 'Paced, but')):
        held = f'the Dial gate says: {facts["dial_now"]}'
    return {'mode': dial['mode'], 'claude_allowed': allowed, 'claude_active': active,
            'claude_free': 0 if held else max(0, allowed - active), 'held': held,
            'codex_allowed': dial['codex_threads'], 'codex_active': len(facts['codex_active'])}


def decide(facts, window=STALE_AFTER):
    """The action list, from the facts alone. Each action: rule, severity, detail, issues, prs."""
    now, actions = facts['now'], []

    def act(rule, severity, detail, issues=(), prs=(), **extra):
        actions.append(dict({'rule': rule, 'severity': severity, 'detail': detail, 'issues': list(issues),
                             'prs': list(prs)}, **extra))

    slot = slots(facts)
    claims = facts['in_progress']
    live = [c for c in claims if c['state'] != 'stale']
    ready = startable(facts['ready'], live)

    if facts['usage']['halted']:
        act('halt', RED, 'HALT (usage breaker): start nothing, and tell running threads to finish their commit, '
            'push, post their stop note and stop.')

    tick = facts['tick']
    if tick is None or now - when(tick['at']) > TICK_STALE:
        act('mac-tick-stale', LOOK, ('no Mac tick on #337 in 12 hours' if tick is None
                                     else f'the latest Mac tick is {ago(now, when(tick["at"]))} old') +
            ': the Mac may be offline, so the usage breaker and the Mac queue can\'t be read.')

    cloud = [i for i in ready if 'where:mac' not in i['labels']]
    if slot['claude_free'] and cloud:
        take = cloud[:slot['claude_free']]
        act('free-slots', LOOK, f'{slot["claude_free"]} Claude slot(s) free ({slot["claude_active"]} of '
            f'{slot["claude_allowed"]} active, Dial {slot["mode"]}): start a thread on ' +
            ', '.join(f'#{i["number"]} {i["title"][:50]}' for i in take) +
            f' ({len(cloud)} cloud-eligible ready)', issues=[i['number'] for i in take])
    elif slot['claude_free'] and not cloud:
        act('free-slots', LOOK, f'{slot["claude_free"]} Claude slot(s) free but no cloud-eligible ready issue.')

    mac_ready = [i for i in ready if 'where:mac' in i['labels']]
    mac_busy = [c for c in live if 'where:mac' in c['labels']]
    finisher = (tick or {}).get('finisher_idle_minutes')
    if finisher is not None and finisher < FINISHER_BUSY:
        mac_busy.append({'number': 0})     # the Mac finisher is working a hand-off
    if mac_ready and not mac_busy:
        act('mac-idle', LOOK, f'the Mac is idle with {len(mac_ready)} Mac-only ready issue(s) ' +
            ', '.join(f'#{i["number"]}' for i in mac_ready[:6]) + ('…' if len(mac_ready) > 6 else '') +
            ': no `where:mac` issue is in progress. ' + ('A Claude slot is free for a Mac thread.' if slot['claude_free']
                                                         else f'No Claude slot is free ({slot["held"] or "all busy"}).'),
            issues=[i['number'] for i in mac_ready[:6]])

    untriaged = facts.get('untriaged') or []
    if untriaged:
        oldest = min(untriaged, key=lambda row: row['created_at'])
        act('untriaged', LOOK, f'{len(untriaged)} open issue(s) lack exactly one `area:` label or a state label (oldest '
            f'#{oldest["number"]}, filed {oldest["created_at"][:10]}): the daily triage must label every one, not only the '
            'issues filed since its last run (AGENTS.md, Current focus: areas are labels).',
            issues=[row['number'] for row in untriaged[:10]])

    outside = facts.get('outside') or []
    if outside:
        act('outside-issues', LOOK, f'{len(outside)} open issue(s) from outside the team wait for a collaborator to '
            f'read them and add `ready` by hand ({OUTSIDE_LABEL}); triage never does (#1822).',
            issues=[row['number'] for row in outside[:10]])

    for fix in facts.get('merged_fixes') or []:
        act('fix-merged', LOOK, f'#{fix["number"]} {fix["title"][:60]}: fix merged in #{fix["pr"]} on '
            f'{fix["merged_at"][:10]} and the issue is still `ready`; close it, keeping its validation labels', issues=[fix['number']], fix=fix)

    gone = facts.get('drift') or {}
    for row in gone.get('merged_open') or []:
        act('merged-still-open', LOOK, f'#{row["number"]} {row["title"][:60]}: #{row["pr"]} says it closes it and merged '
            f'into `{row["base"]}` on {row["merged_at"][:10]}, but the issue is open; close it, keeping its validation '
            'labels (2026-10-22 call), or say on it why it stays open', issues=[row['number']], prs=[row['pr']])
    for row in gone.get('reverts') or []:
        act('revert-unnoted', LOOK, f'#{row["revert"]} reverted #{row["pr"]} on {row["merged_at"][:10]} and #{row["issue"]} '
            f'has no comment since that says so; note the revert (and any re-land) on #{row["issue"]}',
            issues=[row['issue']], prs=[row['revert'], row['pr']])
    if gone.get('reverts_unchecked'):
        act('revert-unchecked', LOOK, 'the read cap left these reverts unchecked: ' +
            ', '.join(f'#{r} of #{p}' for r, p in gone['reverts_unchecked']))
    for row in gone.get('holds') or []:
        why = (f'holds it on #{row["pr"]}, which merged into `{row["base"]}` on {row["merged_at"][:10]}' if row['pr']
               else f'waits on `{FROZEN_BASE}`, which is frozen since 2026-10-20')
        act('hold-lifted', LOOK, f'#{row["number"]} {row["title"][:60]}: its newest note ({row["said_at"][:10]}) {why}; '
            'check the code and close it or say what it waits on now', issues=[row['number']],
            prs=[row['pr']] if row['pr'] else [])
    cards = gone.get('unchecked_cards') or []
    if cards:
        act('unchecked-card', LOOK, f'{len(cards)} `needs-owner` issue(s) have no `Checked:` line (oldest #{cards[0]["number"]} '
            f'{cards[0]["title"][:60]}): check each fact (scripts/sm_live.py, docs/decisions.md), then add where it came from, '
            'or drop the ask if he has already answered (#3872)', issues=[row['number'] for row in cards[:10]])
    if gone.get('errors'):
        act('drift-unreadable', LOOK, 'rules 9 to 12 could not read everything, so missing findings are not a clean '
            'bill: ' + '; '.join(gone['errors']))

    for claim in claims:
        if claim['state'] == 'stale':
            act('stale-claim', LOOK, f'#{claim["number"]} {claim["title"][:60]}: {claim["why"]}; release to `ready`',
                issues=[claim['number']], claim=claim)
        elif claim['state'] == 'unknown':
            act('claim-unreadable', LOOK, f'#{claim["number"]}: could not tell if the claim is stale ({claim["why"]}); '
                'not released', issues=[claim['number']])

    for row in facts['snapshot']['prs']:
        red = [f for f in row['flags'] if f['severity'] == RED]
        if row['armed'] and red:
            act('armed-red', RED, f'#{row["number"]} is armed but red on {row["head7"]}: ' +
                '; '.join(f'{f["code"]}: {f["detail"]}' for f in red), prs=[row['number']])

    waiting = [row for row in facts['snapshot']['prs']
               if row.get('t4_waiting') and now - when(row['t4_waiting']['at']) >= T4_WAIT]
    desk_running = bool(facts['desk_seen']) and now - when(facts['desk_seen']) < DESK_QUIET
    # a GO older than the desk's last sign has been acted on
    go = bool(tick and tick['test_desk'] == 'GO' and not (facts['desk_seen'] and facts['desk_seen'] > tick['at']))
    if (waiting or go) and not desk_running:
        why = [f'/lane T4 on #{row["number"]} waiting {ago(now, when(row["t4_waiting"]["at"]))}' for row in waiting]
        if go:
            why.append('the Mac tick says Test Desk: GO')
        seen = (f'last Test Desk sign {ago(now, when(facts["desk_seen"]))} ago' if facts['desk_seen']
                else 'no Test Desk sign in 24 hours')
        act('start-desk', LOOK, f'start a managed Test Desk (work list: scripts/desk-batch.py): {"; ".join(why)}; {seen}.',
            prs=[row['number'] for row in waiting])

    for row in facts['snapshot']['prs']:
        mac = row.get('mac')
        if mac and mac['since'] and not mac['finisher_active_at'] and now - when(mac['since']) >= FINISHER_WAIT:
            act('needs-mac-stuck', LOOK, f'#{row["number"]} went to the Mac finisher {ago(now, when(mac["since"]))} ago '
                'and has no finisher comment or commit since: ask the finisher\'s thread why it hasn\'t taken it '
                '(a pause explains an idle finisher, not a skipped PR).', prs=[row['number']])
    return actions, slot


def summary_line(slot, facts):
    codex = (f'; Codex {slot["codex_active"]} of {slot["codex_allowed"]} workers' if slot['codex_allowed'] else '')
    held = f' (not starting: {slot["held"]})' if slot['held'] else ''
    stale = sum(c['state'] == 'stale' for c in facts['in_progress'])
    return (f'Dial {slot["mode"]}: Claude {slot["claude_active"]} of {slot["claude_allowed"]} active, '
            f'{slot["claude_free"]} free{held}{codex}. Ready {len(facts["ready"])}, in progress '
            f'{len(facts["in_progress"])} ({stale} stale).')


def render(facts, actions, slot):
    lines = [f'Wake sweep {facts["now"].strftime("%Y-%m-%d %H:%MZ")}', summary_line(slot, facts)]
    if not actions:
        lines.append('Nothing to do.')
    for index, action in enumerate(actions, 1):
        applied = f' [{action["applied"]}]' if action.get('applied') else ''
        lines.append(f'{index}. {action["rule"].upper()}{" (!!)" if action["severity"] == RED else ""}: '
                     f'{action["detail"]}{applied}')
    if not facts['comments_complete']:
        lines.append('Note: the repo-wide comment read was incomplete, so no claim was judged stale.')
    return '\n'.join(lines)


def as_json(facts, actions, slot):
    return {'as_of': facts['now'].strftime('%Y-%m-%dT%H:%M:%SZ'), 'slots': slot, 'tick': facts['tick'],
            'dial_now': facts['dial_now'], 'counts': {'ready': len(facts['ready']), 'in_progress':
                                                      len(facts['in_progress'])},
            'actions': [{k: v for k, v in a.items() if k not in ('claim', 'fix')} for a in actions]}


def main(argv=None, api=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--apply', action='store_true', help='release stale claims and close ready issues whose fix merged (the only writes)')
    parser.add_argument('--json', action='store_true', help='print the actions as JSON')
    parser.add_argument('--status-json', metavar='FILE', help='a saved `sm_status.py --json` output; - is stdin')
    parser.add_argument('--repo', default=sm_status.REPO)
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    try:
        api = api or sm_status.GitHub(args.repo)
        saved = None
        if args.status_json:
            if args.status_json == '-':
                saved = json.load(sys.stdin)
            else:
                with open(args.status_json) as handle:
                    saved = json.load(handle)
        if args.apply and args.status_json and now - when(saved.get('as_of') or '1970-01-01T00:00:00Z') > SNAPSHOT_MAX_AGE:
            raise ValueError('--apply with --status-json needs a snapshot taken in the last 10 minutes: a stale one '
                             'cannot see PRs opened since, and their claims would look abandoned')
        facts = collect(api, now, saved)
        actions, slot = decide(facts)
        if args.apply:
            for action in actions:
                if action['rule'] == 'stale-claim':
                    action['applied'] = release(api, action['claim'], action['claim']['why'], now)
                elif action['rule'] == 'fix-merged':
                    action['applied'] = release_merged_fix(api, action['fix'], now)
    except (sm_status.GitHubError, OSError, ValueError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2
    print(json.dumps(as_json(facts, actions, slot), indent=2) if args.json else render(facts, actions, slot))
    return 0


if __name__ == '__main__':
    sys.exit(main())
