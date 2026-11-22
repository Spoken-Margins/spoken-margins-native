#!/usr/bin/env python3
"""Real-use proof: a listener-facing issue closes only after someone ran it the way a listener would (#4979).

Owner call 2026-11-22, after Apple Podcasts share links (#4783) were his top priority for two days: two web fixes
merged after fixture-only tests in desktop Chrome, the app's sender side was never touched, the issue was parked as
"needs the owner's phone data", and his real link still failed. Nothing asked whether anyone had used the real thing.

What counts as proof is a record, written as a PR-body section or a comment on the issue or the PR by someone the lane
trusts (scripts/comment_trust.py):

    **Real-use proof**
    Real input: the link, file or screen a listener has (a real Apple Podcasts share URL, not a fixture)
    Path: every hop from where the listener starts to where they see or hear the result
    Steps: what was done, in order
    Result: PASS - what was seen (or FAIL - what was seen)
    Commit: the commit it ran on (7 or more hex digits)

or, for work with no listener surface, one line `Real-use proof waived: <reason in three words or more>`. The newest
record decides, so a later FAIL undoes an earlier PASS. docs/workstreams/real-use-proof.md has the longer text.

Three uses, one reading of that record:
  scripts/merge_policy.py   holds a PR whose body says `Closes #N` for a listener-facing issue with no valid proof.
  --issue N [--pr M]        exit 0 when issue N (plus PR M, the one that closed it) holds a proof or a waiver.
  --sweep [--apply]         issues closed as completed from 2026-11-23 in a listener-facing area with no proof; with
                            --apply it reopens each with a comment. Run by the hourly dispatch.
  --parked [--json]         open `bug` or `found-on-phone` issues parked on `needs-owner` with neither an
                            **Owner check** nor a **Repro attempt** comment (rule: a repro attempt comes before "needs
                            the owner's phone or data").

Stdlib only, Python 3.9-compatible. Exit 0 whatever the sweep found; 2 when a read failed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import comment_trust  # noqa: E402

FLOOR = '2026-11-23'   # the sweep never reopens an issue closed before the rule took effect (the day after the owner's call)
FIELDS = ('real input', 'path', 'steps', 'result', 'commit')
NOT_LISTENER_AREA = 'area: groundwork'   # the one area that is not a listener's: every other label, or none, is listener-facing
MARKER = '<!-- real-use-proof-sweep -->'
REPRO_FIELDS = ('tried', 'result')
GRACE = dt.timedelta(minutes=30)   # the sweep leaves an issue alone this long after it closes: the proof may be a minute behind
SHIPPED_AREAS = ('App/', 'Packages/', 'Contracts/')   # notes under these ship in the app, so they are not just notes

START = re.compile(r'^[ \t#*_-]*real[- ]use proof[ \t*_]*:?[ \t*_]*$', re.I)
WAIVER = re.compile(r'^[ \t#*_-]*real[- ]use proof[ \t*_]+(?:waived|not needed)[ \t*_]*[:—–-][ \t*_]*(\S.*?)[ \t*_]*$', re.I)
FIELD = re.compile(r'^[ \t*_-]*(real input|path|steps|result|commit|issue)[ \t*_]*:[ \t*_]*(.*?)[ \t*_]*$', re.I)
REPRO_START = re.compile(r'^[ \t#*_-]*repro attempt[ \t*_]*:?[ \t*_]*$', re.I)
REPRO_FIELD = re.compile(r'^[ \t*_-]*(tried|result|needs from owner)[ \t*_]*:[ \t*_]*(.*?)[ \t*_]*$', re.I)
HEADING = re.compile(r'^[ \t]*(?:#{1,6}[ \t]|\*\*[^*\n:]+\*\*[ \t]*$)')   # a # heading, or a line that is only bold text
LIST_ITEM = re.compile(r'^[ \t]*(?:[-*+]|\d+[.)])[ \t]')
OWNER_PASS = re.compile(r'^[ \t#*_-]*owner pass on phone pass\b', re.I)   # scripts/daily-phone-plan's close comment: his own phone is the strongest proof
OWNER_CHECK = re.compile(r'^[ \t>#*_-]*owner check(?![ \t*_:]*(?:not|none|n/a)\b)\b', re.I | re.M)
PLACEHOLDER = re.compile(r'^(?:tbd|todo|n/?a|none|nothing|-+|\.{2,}|…)$', re.I)
ANGLE = re.compile(r'<[^<>\n]+>')   # an unfilled template slot such as <what you observed>
FIXTURE = re.compile(r'\b(?:fixtures?|mocks?|mocked|stubs?|stubbed|fake|synthetic|simulated|canned|hand-?written|sample|test data)\b|\bfixtures?/', re.I)
NEGATION = re.compile(r'\b(?:not|no|never|isn\'t|wasn\'t|instead of|rather than|without)\b[^.\n]{0,25}$', re.I)
CONTRADICTION = re.compile(r'\b(?:but|however|except|fails?|failed|failing|broken|not working)\b', re.I)
FENCE = re.compile(r'^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$', re.M | re.S)
COMMENT = re.compile(r'<!--.*?-->', re.S)
CODE_SPAN = re.compile(r'`[^`\n]*`')
QUOTE = re.compile(r'^[ \t]*>.*$', re.M)

# GitHub's closing keywords, as scripts/pr_issue_link.py reads them; a test keeps the keyword list equal.
CLOSING = re.compile(
    r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[ \t]*:?[ \t]+'
    r'(?:#(?P<n>\d+)|(?P<slug>[\w.-]+/[\w.-]+)#(?P<sn>\d+)|https://github\.com/(?P<url>[\w.-]+/[\w.-]+)/issues/(?P<un>\d+))', re.I)


class Entry:
    """One record found in a text: a proof (fields) or a waiver (reason). pr_side: it came from a PR, not the issue."""

    def __init__(self, kind: str, fields: Optional[dict] = None, reason: str = '', pr_side: bool = False):
        self.kind, self.fields, self.reason, self.pr_side = kind, fields or {}, reason, pr_side
        self.repeated: list[str] = []   # fields that appear twice in one record: which one counts is unclear, so it is held


class Verdict:
    """status: proved, waived, invalid (a record that fails its own rules), none (no record at all)."""

    def __init__(self, status: str, problems: Optional[list] = None, commit: str = ''):
        self.status, self.problems, self.commit = status, problems or [], commit

    @property
    def ok(self) -> bool:
        return self.status in ('proved', 'waived')


def visible(text: Optional[str]) -> str:
    """The text a reader sees as the author's own words: no code fences, HTML comments or quoted lines. A record or a
    closing keyword in one of those is a template, a note or someone else's words, not a claim."""
    return QUOTE.sub('', COMMENT.sub('', FENCE.sub('', (text or '').replace('\r\n', '\n').replace('\r', '\n'))))


def parse(text: Optional[str], pr_side: bool = False) -> list[Entry]:
    """Every proof record and waiver in <text>, in order. A record runs to the next heading or the next record."""
    entries: list[Entry] = []
    current: Optional[Entry] = None
    last = ''
    blank = False
    for line in visible(text).splitlines():
        if not line.strip():
            blank = True
            continue
        if OWNER_PASS.match(line):
            current = None
            entries.append(Entry('owner_pass', pr_side=pr_side))
            continue
        waiver = WAIVER.match(line)
        if waiver:
            current = None
            entries.append(Entry('waiver', reason=waiver.group(1), pr_side=pr_side))
            continue
        if START.match(line):
            current = Entry('proof', pr_side=pr_side)
            entries.append(current)
            last = ''
            blank = False
            continue
        if current is None:
            continue
        if HEADING.match(line):
            current = None
            continue
        field = FIELD.match(line)
        if field:
            name = field.group(1).lower()
            if name in current.fields:
                last = ''
                if name not in current.repeated:
                    current.repeated.append(name)   # held in problems_of: a PASS then a later FAIL line must not pass
            else:
                last = name
                current.fields[name] = field.group(2)
        elif last and (not blank or LIST_ITEM.match(line)):
            current.fields[last] = (current.fields[last] + '\n' + line.strip()).strip()
        else:
            last = ''   # a paragraph after a blank line is not part of the field above it
        blank = False
    return entries


def _empty(value: str) -> bool:
    return not value.strip() or bool(PLACEHOLDER.match(value.strip().replace('`', '')))


def _label(name: str) -> str:
    return 'Real input' if name == 'real input' else name.title()


def _fixture_problem(value: str) -> bool:
    for match in FIXTURE.finditer(value):
        if not NEGATION.search(value[:match.start()]):
            return True
    return False


def commit_of(value: str) -> str:
    """The commit hash a Commit line starts with (after any quoting), or ''. Only the first word counts."""
    match = re.match(r'^(?:main\W+)?([0-9a-f]{7,40})\b', (value or '').strip().lstrip('`*_ '), re.I)
    return match.group(1).lower() if match else ''


def problems_of(fields: dict, repeated: Optional[list] = None) -> list[str]:
    """Why a proof record does not count, or [] when it does."""
    found = [f'its `{_label(name)}:` line appears twice; keep one value, or start a new record' for name in repeated or []]
    for name in FIELDS:
        if name not in fields:
            found.append(f'it has no `{_label(name)}:` line')
        elif _empty(fields[name]):
            found.append(f'its `{_label(name)}:` line is empty or a placeholder')
        elif ANGLE.search(fields[name]):
            found.append(f'its `{_label(name)}:` line still has a template slot like `<...>` to fill in')
    real = fields.get('real input', '')
    if real and _fixture_problem(real):
        found.append('its Real input is a fixture, a mock, a sample or made-up data; use the real link, file or screen')
    result = fields.get('result', '').strip().lstrip('`*_ ')
    if result and not _empty(result):
        if re.match(r'^fail', result, re.I):
            found.append('its Result is FAIL: the run did not work')
        elif not re.match(r'^pass(?:ed)?(?![\w-])', result, re.I):
            found.append('its Result must start with PASS or FAIL')
        elif CONTRADICTION.search(result):
            found.append('its Result says PASS but also describes a failure or a "but"; say FAIL, or say what worked without it')
    commit = fields.get('commit', '')
    if commit.strip() and not _empty(commit) and not commit_of(commit):
        found.append('its Commit line must start with the commit hash (7 or more hex digits)')
    return found


def waiver_problem(reason: str) -> Optional[str]:
    words = [w.lower().strip('.,;:!') for w in reason.split()]
    real = [w for w in words if w and not PLACEHOLDER.match(w)]
    if len(set(real)) < 3 or len(reason) < 15:
        return 'the waiver gives no real reason (three different words, say why no listener sees this)'
    return None


def judge(entries: list[Entry]) -> Verdict:
    """The newest record decides: a later FAIL undoes an earlier PASS, and a later waiver stands in for both. An
    `Owner PASS on phone pass` comment (the daily phone plan's close comment) is the owner's own run and proves it."""
    if not entries:
        return Verdict('none')
    last = entries[-1]
    if last.kind == 'waiver':
        problem = waiver_problem(last.reason)
        return Verdict('invalid', [problem]) if problem else Verdict('waived')
    if last.kind == 'owner_pass':
        return Verdict('proved')
    found = problems_of(last.fields, last.repeated)
    if found:
        return Verdict('invalid', found)
    return Verdict('proved', commit=commit_of(last.fields['commit']))


HUMAN_REPORT_LABELS = {'bug', 'found-on-phone', 'owner-asked', 'priority', 'needs-human-validation', 'agent-verify', 'validate-by-use'}


def listener_facing(labels) -> bool:
    """Whether an issue is a listener's. Any area label but `area: groundwork` says yes, and so does a groundwork label
    beside a product one. With no area label it depends on who wrote it: a `bug`, `found-on-phone`, `owner-asked` or
    validation label is a person's report about the app, so yes; an issue with none of those is a pipeline alarm that
    scripts open and close themselves (the "Main T3 failed" regression issue, "Merging has stalled"), so no. Triage
    sets the area within a day, and a listener's bug carries `bug` from the start."""
    names = {(label.get('name') if isinstance(label, dict) else label or '').lower() for label in labels or []}
    areas = {n for n in names if n.startswith('area:')}
    if areas:
        return areas != {NOT_LISTENER_AREA}
    return bool(names & HUMAN_REPORT_LABELS)


def area_of(labels) -> str:
    names = sorted({(label.get('name') if isinstance(label, dict) else label or '') for label in labels or []})
    areas = [n for n in names if n.lower().startswith('area:')]
    return ', '.join(areas) if areas else 'no area label, but a bug or owner label'


def closing_issues(body: Optional[str], own_number: int, repo: str) -> list[int]:
    """The issues of <repo> whose closing keyword the text carries (not the PR's own number, not other repositories).
    Keywords inside code, quotes and HTML comments are ignored, as GitHub ignores them."""
    found = []
    for match in CLOSING.finditer(CODE_SPAN.sub('', visible(body))):
        slug = match.group('slug') or match.group('url') or ''
        number = match.group('n') or match.group('sn') or match.group('un')
        if slug and slug.lower() != repo.lower():
            continue
        if number and int(number) != own_number:
            found.append(int(number))
    return list(dict.fromkeys(found))


def timed_items(pull: dict, trusted_comments: list) -> list[tuple]:
    """(time, text, pr_side) for a PR: its body when its author is trusted, and its trusted comments."""
    items = []
    if comment_trust.trusted_author(pull.get('author_association'), (pull.get('user') or {}).get('login')):
        items.append((pull.get('created_at') or '', pull.get('body') or '', True))
    items.extend((c.get('created_at') or '', c.get('body') or '', True) for c in trusted_comments)
    return items


def entries_for(items: list[tuple], target: int, several: bool = False) -> list[Entry]:
    """The records in <items> in the order they were written, that speak for issue <target>. A PR-side proof that names
    issues in an `Issue:` line speaks only for those; when the PR closes several listener-facing issues (<several>)
    a PR-side proof must say which, so one run can't stand in for all of them. Waivers speak for the PR."""
    entries: list[Entry] = []
    for _, text, pr_side in sorted(items, key=lambda item: item[0]):
        for entry in parse(text, pr_side):
            if entry.kind == 'proof' and entry.pr_side:
                named = {int(n) for n in re.findall(r'\d+', entry.fields.get('issue', ''))}
                if (named and target not in named) or (not named and several):
                    continue
            entries.append(entry)
    return entries


def exempt_path(path: str) -> bool:
    """Files a later push may change without making an earlier proof stale: notes and tests. A note under App/,
    Packages/ or Contracts/ ships in the app (a bundled checklist, a contract doc), so it is not exempt."""
    parts = path.split('/')
    if path.startswith(SHIPPED_AREAS) and not any(p == 'Tests' or p == 'tests' or p.endswith('Tests') for p in parts[:-1]):
        return False
    return path.lower().endswith('.md') or parts[0] == 'docs' or any(p in ('tests', 'Tests') or p.endswith('Tests') for p in parts[:-1])


def stale_after(commit: str, own_commits: list[str], paths_after: Callable[[str], list[str]]) -> Optional[str]:
    """Why a proof run on <commit> does not cover the PR as it stands, or None. The commit must be one of the PR's own;
    anything the PR changed after it, other than notes and tests, means the run is out of date."""
    matches = [c for c in own_commits if c.lower().startswith(commit.lower())]
    if not matches:
        return f'its commit `{commit[:7]}` is not one of this PR\'s own commits'
    changed = sorted({p for p in paths_after(matches[0]) if p and not exempt_path(p)})
    if changed:
        shown = ', '.join(f'`{p}`' for p in changed[:3]) + (f' and {len(changed) - 3} more' if len(changed) > 3 else '')
        return f'the PR changed {shown} after commit `{commit[:7]}`, so run it again on the head'
    return None


def message(number: int, area: str, verdict: Verdict) -> str:
    why = '; '.join(verdict.problems) if verdict.status == 'invalid' else 'none is recorded'
    return (f'it says `Closes #{number}`, a listener-facing issue ({area}), and its real-use proof does not count: {why}. '
            'Run it the way a listener would (a real link, file or screen, not a fixture) and add a `**Real-use proof**` '
            f'record (Real input, Path, Steps, Result: PASS, Commit) to the PR body or a new comment on the PR or #{number}; '
            f'or write `Part of #{number}` if it cannot be run before the merge; or `Real-use proof waived: <reason>` if it '
            'has no listener surface. This check re-runs when a label changes, so after adding the record remove and re-add '
            'the `automerge` label (docs/workstreams/real-use-proof.md)')


def pr_blockers(api, number: int, pull: dict, comments: list, own_commits: Callable[[], list],
                paths_after: Callable[[str], list], extra_text: str = '') -> list[str]:
    """Why PR <number> may not merge for want of real-use proof, one reason per closing issue. api needs `repo`,
    `issue(n)` and `issue_comments(n)` (trusted comments only); own_commits and paths_after read the PR's git history.
    <extra_text> is more text GitHub reads closing keywords in (the PR's commit messages)."""
    targets = []
    for target in closing_issues((pull.get('body') or '') + '\n' + extra_text, number, api.repo):
        issue = api.issue(target)
        if 'pull_request' not in issue and listener_facing(issue.get('labels')):
            targets.append((target, issue))
    reasons = []
    for target, issue in targets:
        items = timed_items(pull, comments) + [(c.get('created_at') or '', c.get('body') or '', False) for c in api.issue_comments(target)]
        verdict = judge(entries_for(items, target, several=len(targets) > 1))
        if verdict.status == 'proved' and verdict.commit:
            stale = stale_after(verdict.commit, own_commits(), paths_after)
            if stale:
                verdict = Verdict('invalid', [stale])
        if not verdict.ok:
            reasons.append(message(target, area_of(issue.get('labels')), verdict))
    return reasons


def repro_attempted(comments: list) -> bool:
    """Whether a trusted comment records a repro attempt (Tried and Result filled in) or an Owner check."""
    for comment in comment_trust.trusted_only(comments):
        text = comment.get('body') or ''
        if OWNER_CHECK.search(text):
            return True
        fields: dict = {}
        active = False
        for line in text.splitlines():
            if REPRO_START.match(line):
                active, fields = True, {}
            elif active and (field := REPRO_FIELD.match(line)):
                fields[field.group(1).lower()] = field.group(2)
        if active and all(not _empty(fields.get(name, '')) for name in REPRO_FIELDS):
            return True
    return False


class Gh:
    """`gh api` for the sweep. run is injected in tests."""

    def __init__(self, repo: str, run=subprocess.run):
        self.repo, self.run = repo, run

    def api(self, path: str, paginate: bool = False, method: str = 'GET', fields: Optional[dict] = None):
        args = ['gh', 'api', '-X', method, f'repos/{self.repo}/{path}']
        for key, value in (fields or {}).items():
            args += ['-f', f'{key}={value}']
        if paginate:
            args += ['--paginate', '--jq', '.[]']
        done = self.run(args, capture_output=True, text=True, timeout=120)
        if done.returncode:
            raise RuntimeError(f'gh api {path}: {(done.stderr or "").strip()[:200]}')
        if paginate:
            return [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
        return json.loads(done.stdout) if done.stdout.strip() else {}

    def issue(self, number: int) -> dict:
        return self.api(f'issues/{number}')

    def issue_comments(self, number: int) -> list:
        return comment_trust.trusted_only(self.api(f'issues/{number}/comments?per_page=100', paginate=True))


def issue_items(comments: list) -> list[tuple]:
    return [(c.get('created_at') or '', c.get('body') or '', False) for c in comments]


def closing_items(gh, number: int) -> list[tuple]:
    """The PR-side records that speak for issue <number> after it closed, as (time, text, pr_side) items. This is the
    one reader the sweep and `--issue N --pr M` share: every merged PR of this repository that the issue's timeline ties
    to it (the PR of the closing commit, and each merged PR the timeline shows referencing it), whatever keyword it used,
    because a change that couldn't be run first says `Part of #N` and gets its proof after the merge. Their bodies count
    when the author is trusted, their comments when trusted; an `Issue:` line in a record limits which issues it covers."""
    events = gh.api(f'issues/{number}/timeline?per_page=100', paginate=True)
    closed = [e for e in events if e.get('event') == 'closed']
    sha = (closed[-1].get('commit_id') if closed else None) or ''
    pulls: dict[int, dict] = {}
    if sha:
        for pull in gh.api(f'commits/{sha}/pulls?per_page=20', paginate=True):
            pulls[pull['number']] = pull
    for event in events:
        source = (event.get('source') or {}).get('issue') or {}
        if event.get('event') != 'cross-referenced' or 'pull_request' not in source or source.get('number') in pulls:
            continue
        repo = (source.get('repository') or {}).get('full_name')
        if repo and repo.lower() != gh.repo.lower():
            continue   # another repository's PR (ops-private) that mentions this number
        try:
            pull = gh.api(f'pulls/{source["number"]}')
        except RuntimeError:
            continue   # not a PR of this repository
        if pull.get('merged_at'):
            pulls[pull['number']] = pull
    found: list[tuple] = []
    for pull in pulls.values():
        comments = comment_trust.trusted_only(gh.api(f'issues/{pull["number"]}/comments?per_page=100', paginate=True))
        found.extend(timed_items(pull, comments))
    return found


def sweep(gh, since: dt.datetime, apply: bool = False, now: Optional[dt.datetime] = None) -> dict:
    now = now or dt.datetime.now(dt.timezone.utc)
    report = {'apply': apply, 'reopened': [], 'flagged': [], 'again': [], 'proved': 0, 'waived': 0, 'unknown': []}
    floor = max(since, dt.datetime.fromisoformat(FLOOR + 'T00:00:00+00:00'))
    closed = gh.api(f'issues?state=closed&since={floor.strftime("%Y-%m-%dT%H:%M:%SZ")}&per_page=100&sort=updated', paginate=True)
    for issue in closed:
        number = issue['number']
        if 'pull_request' in issue or issue.get('state_reason') in ('not_planned', 'duplicate'):
            continue
        closed_at = issue.get('closed_at') or ''
        stamp = dt.datetime.fromisoformat(closed_at.replace('Z', '+00:00')) if closed_at else None
        if stamp is None or stamp < floor or now - stamp < GRACE:
            continue
        if not listener_facing(issue.get('labels')):
            continue
        try:
            comments = gh.issue_comments(number)
            items = issue_items(comments)
            verdict = judge(entries_for(items, number))
            if not verdict.ok:   # the proof may sit on the PR that closed it
                verdict = judge(entries_for(items + closing_items(gh, number), number))
            if verdict.status == 'proved':
                report['proved'] += 1
            elif verdict.status == 'waived':
                report['waived'] += 1
            elif any(MARKER in (c.get('body') or '') for c in comments):
                report['again'].append(number)   # reopened once already and closed again by hand: not reopened twice
            else:
                report['flagged'].append({'issue': number, 'title': issue.get('title'), 'why': verdict.problems or ['no proof recorded']})
                if apply:
                    gh.api(f'issues/{number}', method='PATCH', fields={'state': 'open', 'state_reason': 'reopened'})
                    gh.api(f'issues/{number}/comments', method='POST', fields={'body': reopen_comment(verdict)})
                    report['reopened'].append(number)
        except (RuntimeError, KeyError, TypeError, ValueError, OSError) as error:
            report['unknown'].append({'issue': number, 'reason': str(error)[:200]})
    return report


def reopen_comment(verdict: Verdict) -> str:
    why = '; '.join(verdict.problems) if verdict.problems else 'no `**Real-use proof**` record is on this issue or on the PR that closed it'
    return (f'{MARKER}\nReopened: this is a listener-facing issue and it was closed without real-use proof ({why}). '
            'Merged is not fixed. Run it the way a listener would (a real link, file or screen, not a fixture) and comment '
            'a `**Real-use proof**` record (Real input, Path, Steps, Result: PASS, Commit), then close it; or comment '
            '`Real-use proof waived: <reason>` if it has no listener surface. The rule is in AGENTS.md and '
            'docs/workstreams/real-use-proof.md (#4979).\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_')


def parked(gh) -> list[dict]:
    """Open `bug` / `found-on-phone` issues on `needs-owner` with no Owner check and no Repro attempt."""
    found = []
    for issue in gh.api('issues?state=open&labels=needs-owner&per_page=100', paginate=True):
        names = {label['name'] for label in issue.get('labels') or []}
        if 'pull_request' in issue or not names & {'bug', 'found-on-phone'}:
            continue
        if not repro_attempted(gh.api(f'issues/{issue["number"]}/comments?per_page=100', paginate=True)):
            found.append({'issue': issue['number'], 'title': issue.get('title')})
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', default='Spoken-Margins/spoken-margins-native')
    parser.add_argument('--issue', type=int, help='check one issue')
    parser.add_argument('--pr', type=int, help='with --issue: the PR that closed it')
    parser.add_argument('--sweep', action='store_true')
    parser.add_argument('--parked', action='store_true')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--days', type=int, default=3, help='sweep: how far back to look (never before %s)' % FLOOR)
    args = parser.parse_args(argv)
    gh = Gh(args.repo)
    try:
        if args.issue:
            issue = gh.issue(args.issue)
            if not listener_facing(issue.get('labels')):
                print(f'#{args.issue} is not listener-facing ({area_of(issue.get("labels"))}): no proof needed.')
                return 0
            items = issue_items(gh.issue_comments(args.issue))
            if args.pr:
                pull = gh.api(f'pulls/{args.pr}')
                items += timed_items(pull, comment_trust.trusted_only(gh.api(f'issues/{args.pr}/comments?per_page=100', paginate=True)))
            entries = entries_for(items, args.issue)
            verdict = judge(entries)
            print(f'#{args.issue}: {verdict.status}' + (': ' + '; '.join(verdict.problems) if verdict.problems else ''))
            return 0 if verdict.ok else 1
        if args.sweep:
            since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.days)
            report = sweep(gh, since, args.apply)
            print(json.dumps(report, indent=2))
            return 2 if report['unknown'] else 0
        if args.parked:
            print(json.dumps(parked(gh), indent=2))
            return 0
    except (RuntimeError, OSError, ValueError) as error:
        print(json.dumps({'unknown': [{'reason': str(error)[:200]}]}))
        return 2
    parser.error('one of --issue, --sweep or --parked is required')
    return 2


if __name__ == '__main__':
    sys.exit(main())
