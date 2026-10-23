#!/usr/bin/env python3
"""A live snapshot of the open PRs into the trunk (`main`) for status replies (#1597). Stdlib, Python 3.9+. Read-only.

Owner rule 2026-10-14 (AGENTS.md "Check before you report"): any status line, and any "armed", "merged" or
"nothing needs you", rests on a live read of the PR's head checks, latest lane report, audit and mergeable state.
This is that read, in one call:

  scripts/sm_status.py                 one line per open PR, flagged PRs explained underneath
  scripts/sm_status.py --json          the same facts for scripts (scripts/sm_sweep.py reads it)
  scripts/sm_status.py --pr 1575       only these PRs (repeatable)

A line is: number, head sha7, the lane's verdict on that head ("none on head" when the only reports are on older
commits), the audit on that head, mergeable state, the labels that matter, the linked issue, then the title.
Flags (`!!` red, `!` look) mark what a reply must not hide:

  red-on-head         the newest lane report on the head is FAIL, the newest T3 report on it is FAIL, or a check
                      run on it is failing
  t3-held             the PR's T3 request is unanswered or its newest T3 report (on any commit) isn't PASS, which
                      holds the merge (lane-runner.py t3_gate), though the head itself may look quiet
  audit-blocking      the newest Claude or Codex audit of the head has findings (red only for audio, persistence,
                      packet and lane diffs, the kinds the runner consults audits for)
  conflict            the PR doesn't merge cleanly into next
  older-head-only     lane reports exist, but only for commits other than the head: a PASS there says nothing
  inconclusive-on-head  the newest lane report on the head is INCONCLUSIVE (not a pass, and its check stays green)
  armed-no-lane-request  `automerge` is on, the diff needs simulator tests (scripts/test-scope.py, by path) and
                      no `/lane T3` request was ever posted
  audit-pending       the diff is audio, persistence, packet or lane work and no audit names the head yet
  held-by-runner      the newest automerge report on the head carries a "not merged …" line (inherited audit finding,
                      the PR moved on, next kept moving, the push failed): a PASS that did not merge
  t3-unqueued         a /lane T3 request is unanswered and the PR has neither `lane:queued` nor `lane:running`
  scope-unknown       the diff couldn't be classified, so audit and simulator-test needs are not judged
  owner-tap           touches scripts/lane-runner.py or .github/: the runner never merges it, only the owner does
  unreadable          a read for this PR failed, so nothing about it can be called quiet

It only reads GitHub (GET requests) and keeps no state. Needs GH_TOKEN or GITHUB_TOKEN (or `gh auth token`).
Exit codes: 0 snapshot printed, 2 GitHub unreachable or unreadable (nothing partial is shown as a status).

Environment: SM_STATUS_REPO (default Spoken-Margins/spoken-margins-native).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import sm_paths  # noqa: E402

PUBLIC = sm_paths.repo(__file__)  # the public checkout (SM_REPO): test-scope.py
sys.path.insert(0, str(PUBLIC / 'scripts'))
import comment_trust  # noqa: E402  (#1822: who may be believed)
import merge_audit  # noqa: E402  (the lane's report and audit formats live there; reused so they can't drift)
from trunk import trunk_branch  # noqa: E402  (#1492: the branch whose PRs it lists)

REPO = os.environ.get('SM_STATUS_REPO', 'Spoken-Margins/spoken-margins-native')
BASE = trunk_branch()
API = 'https://api.github.com'

LANE_BOT = merge_audit.LANE_BOT
REPORT = merge_audit.REPORT                                   # Lane report <id> — PASS|FAIL|INCONCLUSIVE
MARKER = merge_audit.MARKER                                   # <!-- lane-request: {...} --> in the runner's reports
AUDITS = merge_audit.AUDITS
AUDIT_SHA = merge_audit.AUDIT_SHA
CLEAN_AUDIT = merge_audit.CLEAN_AUDIT
REQUEST = re.compile(r'^\s*/lane\s+(T\d)\b', re.M)            # lane-runner.py REQUEST
IDENTICAL = re.compile(r'^Lane: identical (T\d) request for (\w+) already reported \((PASS|FAIL)\)', re.M)
LANE_NOTE = '<!-- lane-note -->'
DESK_REPORT = re.compile(r'(?i:Lane report)\s+(?:\(T[45]\):?|\S+\s+[—–:-]+)\s*(PASS|FAIL|INCONCLUSIVE)\b')
CLOSING = re.compile(r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)', re.I)
BRANCH_ISSUE = re.compile(r'^ws/(\d+)-')

SHOWN_LABELS = ('automerge', 'needs-mac', 'lane:queued', 'lane:running', 'merge-audit', 'priority')
# Mirrors lane-runner.py AUDITED, OWNER_TAP_FILES and OWNER_TAP_PREFIXES; a test keeps them equal.
AUDITED_CATEGORIES = {'audio': 'audio', 'persistence': 'persistence', 'packet': 'packets'}
OWNER_TAP_FILES = {'scripts/lane-runner.py'}
OWNER_TAP_PREFIXES = ('.github/',)
FAILING = {'failure', 'timed_out', 'startup_failure', 'action_required'}
NO_VERDICT = {'skipped', 'neutral', 'cancelled', 'stale', None, ''}
RED, LOOK = 'red', 'look'


# ---- GitHub reads ---------------------------------------------------------------------------------

class GitHubError(RuntimeError):
    """A read that failed; the snapshot says so instead of guessing."""


def find_token() -> str:
    for name in ('GH_TOKEN', 'GITHUB_TOKEN'):
        if os.environ.get(name):
            return os.environ[name]
    try:
        done = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        done = None
    if done and done.returncode == 0 and done.stdout.strip():
        return done.stdout.strip()
    raise GitHubError('no GitHub token: set GH_TOKEN or GITHUB_TOKEN, or log in with `gh auth login`')


class GitHub:
    """The REST reads (and, for the sweep's --apply, writes) this tool needs. Paths are relative to the repo."""

    def __init__(self, repo: str = REPO, token: str | None = None, retries: int = 2):
        self.repo, self._token, self.retries = repo, token, retries

    @property
    def token(self) -> str:
        if not self._token:
            self._token = find_token()
        return self._token

    def url(self, path: str) -> str:
        if path.startswith('https://'):
            return path
        return f'{API}/{path.lstrip("/")}' if path.startswith(('/', 'repos/')) else f'{API}/repos/{self.repo}/{path}'

    def request(self, method: str, path: str, body: dict | None = None):
        """(parsed JSON, response headers). Retries a dropped connection or a 5xx twice; nothing else."""
        data = json.dumps(body).encode() if body is not None else None
        # A body without Content-Type goes out as form-encoded, and GitHub answers 415 (#2265).
        content_type = {'Content-Type': 'application/json'} if data is not None else {}
        for attempt in range(self.retries + 1):
            req = urllib.request.Request(self.url(path), data=data, method=method, headers={
                'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'sm-status', **content_type})
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    return json.loads(resp.read() or b'null'), resp.headers
            except urllib.error.HTTPError as error:
                if error.code >= 500 and attempt < self.retries:
                    time.sleep(1 + attempt)
                    continue
                detail = error.read().decode('utf-8', 'replace')[:200]
                limited = error.code in (403, 429) and error.headers.get('x-ratelimit-remaining') == '0'
                raise GitHubError(f'{method} {path}: HTTP {error.code}' + (' (rate limit used up)' if limited else '')
                                  + f' {detail}') from error
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                if attempt < self.retries:
                    time.sleep(1 + attempt)
                    continue
                raise GitHubError(f'{method} {path}: {error}') from error
        raise GitHubError(f'{method} {path}: gave up')  # pragma: no cover

    def get(self, path: str):
        return self.request('GET', path)[0]

    def pages(self, path: str, limit: int = 30, partial: bool = False) -> list:
        """Every page of a list endpoint, as GitHub orders it. More than `limit` pages is an error, unless `partial`
        says the first `limit` pages are all that was wanted.

        Pages are asked for by number, not by following the Link header: the header points at
        `repositories/<id>/…`, which the cloud agent proxy refuses.
        """
        found = []
        for page in range(1, limit + 1):
            chunk, _ = self.request('GET', f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}')
            items = chunk if isinstance(chunk, list) else chunk.get('check_runs', [])
            found += items
            if len(items) < 100:
                return found
        if partial:
            return found
        raise GitHubError(f'GET {path}: more than {limit} pages')

    def post(self, path: str, body: dict):
        return self.request('POST', path, body)[0]

    def patch(self, path: str, body: dict):
        return self.request('PATCH', path, body)[0]

    def delete(self, path: str):
        return self.request('DELETE', path)[0]


# ---- Reading one PR's facts -------------------------------------------------------------------------

def parse_time(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def stamp(when: dt.datetime | None) -> str | None:
    return when.strftime('%Y-%m-%dT%H:%M:%SZ') if when else None


def same(a: str, b: str) -> bool:
    return merge_audit.same_commit((a or '').lower(), (b or '').lower())


def comment_user(comment: dict) -> str:
    return (comment.get('user') or {}).get('login') or ''


def runner_reports(comments: list[dict]) -> list[dict]:
    """The lane runner's own reports, oldest first: verdict, tier, id and the commit each one tested.

    Only the runner bot's comments count (agents and the owner post as the owner), the same rule the merge audit
    uses. The commit comes from the hidden marker; a report without one falls back to its `commit <sha>` line.
    A "Lane: identical … already reported" note stands for the report it points at.
    """
    found = []
    for index, comment in enumerate(comments):
        body = (comment.get('body') or '').lstrip()
        if comment_user(comment) != LANE_BOT:
            continue
        at = comment.get('created_at') or ''
        verdict = REPORT.match(body)
        if verdict:
            marker = MARKER.search(body)
            try:
                wanted = json.loads(marker.group(1)) if marker else {}
            except ValueError:
                wanted = {}
            line = re.search(r'^commit ([0-9a-f]{7,40})\b', body, re.M)
            tier = wanted.get('tier') or (re.search(r'tier (\S+)', body) or [None, ''])[1]
            found.append({'index': index, 'verdict': verdict.group(1), 'tier': tier, 'at': at,
                          'id': body.split(' ', 3)[2], 'commit': wanted.get('commit') or (line.group(1) if line else ''),
                          'url': comment.get('html_url') or '',
                          'holds': [text.strip() for text in body.splitlines() if text.startswith('not merged')]})
            continue
        identical = IDENTICAL.search(body)
        if identical and LANE_NOTE in body:
            found.append({'index': index, 'verdict': identical.group(3), 'tier': identical.group(1), 'at': at,
                          'id': 'identical-request', 'commit': identical.group(2), 'url': comment.get('html_url') or ''})
    return found


def lane_requests(comments: list[dict]) -> list[dict]:
    """`/lane Tn` requests, oldest first. The runner's reports and notes are never requests."""
    found = []
    for index, comment in enumerate(comments):
        body = comment.get('body') or ''
        match = REQUEST.search(body)
        if match and comment_user(comment) != LANE_BOT and not DESK_REPORT.match(body.lstrip()):
            commit = re.search(r'^\s*commit\s*:\s*([0-9a-f]{7,40})', body, re.M | re.I)
            found.append({'index': index, 'tier': match.group(1), 'at': comment.get('created_at') or '',
                          'commit': commit.group(1).lower() if commit else ''})
    return found


def audits(comments: list[dict]) -> list[dict]:
    """Claude and Codex audit comments, oldest first, in the formats the lane runner honors (#441)."""
    found = []
    for comment in comments:
        body = (comment.get('body') or '').lstrip()
        heading, _, rest = body.partition('\n')
        if not (body.startswith(AUDITS[:2]) or
                re.fullmatch(r'\*\*Claude audit on `[0-9a-f]{7,40}`\*\*', heading.rstrip())):
            continue
        line = next((text.strip() for text in rest.splitlines() if text.strip()), '')
        found.append({'shas': AUDIT_SHA.findall(heading), 'line': line, 'clean': bool(CLEAN_AUDIT.match(line)),
                      'who': 'Claude' if heading.startswith('**Claude') else 'Codex',
                      'at': comment.get('created_at') or '', 'url': comment.get('html_url') or ''})
    return found


def label_since(events: list[dict], name: str) -> str | None:
    """When a label was last added, if it is still on (from the PR's or issue's label events)."""
    since = None
    for event in events:
        if (event.get('label') or {}).get('name') != name:
            continue
        if event.get('event') == 'labeled':
            since = event.get('created_at')
        elif event.get('event') == 'unlabeled':
            since = None
    return since


def armed_since(events: list[dict]) -> str | None:
    """When `automerge` was last added, if it is still on."""
    return label_since(events, 'automerge')


HANDOFF = 'Handing to the Mac finisher:'
RUNNER_ID = re.compile(r'(pr\d+-r\d+|integration-|journeys-)', re.I)   # desk-batch.py: the runner's report ids


def is_desk_report(comment: dict) -> bool:
    """A Test Desk report: a non-runner comment whose first line is `Lane report <id> — PASS|FAIL|INCONCLUSIVE`
    or `Lane report (T4): …` (the same test scripts/desk-batch.py uses to say a T4 request was answered)."""
    if comment_user(comment) == LANE_BOT:
        return False
    first = next((text.strip().strip('*_#` ') for text in (comment.get('body') or '').splitlines() if text.strip()), '')
    match = DESK_REPORT.match(first)
    if not match:
        return False
    named = re.match(r'(?i:Lane report)\s+(\S+)', first)
    return not (named and RUNNER_ID.match(named.group(1)))


def waiting_t4(comments: list[dict]) -> dict | None:
    """The newest `/lane T4` request with no Test Desk report after it, or None."""
    asked = [r for r in lane_requests(comments) if r['tier'] == 'T4']
    if not asked:
        return None
    last = asked[-1]
    if any(is_desk_report(c) for c in comments[last['index'] + 1:]):
        return None
    return {'at': last['at'], 'commit7': last['commit'][:7]}


def mac_handoff(pull: dict, comments: list[dict], events: list[dict], head_committed_at: str | None) -> dict | None:
    """For a `needs-mac` PR: when it went to the Mac finisher and when the finisher last did anything.

    The hand-off is the newest "Handing to the Mac finisher:" comment (else the time the label went on). The
    finisher's activity is any comment after it that is not the runner's and not another hand-off, or a head commit
    committed after it. The finisher and the coordinator post as the same account, so any such comment counts.
    """
    if 'needs-mac' not in [label['name'] for label in pull.get('labels', [])]:
        return None
    handoffs = [c for c in comments if (c.get('body') or '').lstrip().startswith(HANDOFF)]
    since = handoffs[-1]['created_at'] if handoffs else label_since(events, 'needs-mac')
    seen = []
    if since:
        seen = [c['created_at'] for c in comments if c['created_at'] > since and comment_user(c) != LANE_BOT
                and not (c.get('body') or '').lstrip().startswith(HANDOFF)]
        if head_committed_at and head_committed_at > since:
            seen.append(head_committed_at)
    return {'since': since, 'finisher_active_at': max(seen) if seen else None}


REFERENCE = re.compile(r'\b(?:refs?|part of|for|see)\s+#(\d+)', re.I)
TITLE_ISSUE = re.compile(r'\(#(\d+)\)')


def linked_issues(pull: dict) -> list[int]:
    """Every issue the PR visibly works on: closing words, its `ws/<n>-` branch, "(#n)" in the title and "refs/for/part
    of #n" in the text. The wake sweep never releases a claim that any open PR links, so this errs toward more."""
    text = f'{pull.get("title") or ""}\n{pull.get("body") or ""}'
    found = [int(n) for n in CLOSING.findall(text)]
    branch = BRANCH_ISSUE.match((pull.get('head') or {}).get('ref') or '')
    if branch:
        found.append(int(branch.group(1)))
    found += [int(n) for n in TITLE_ISSUE.findall(pull.get('title') or '')]
    found += [int(n) for n in REFERENCE.findall(text)]
    return list(dict.fromkeys(found))


def linked_issue(pull: dict) -> int | None:
    match = CLOSING.search(pull.get('body') or '') or CLOSING.search(pull.get('title') or '')
    if match:
        return int(match.group(1))
    branch = BRANCH_ISSUE.match((pull.get('head') or {}).get('ref') or '')
    return int(branch.group(1)) if branch else None


def check_summary(check_runs: list[dict]) -> dict:
    """Failing and still-running checks on the head. Per check name only the newest run that gave a verdict counts,
    so a later green run of a check clears its earlier failure; skipped and cancelled runs say nothing."""
    newest: dict[str, dict] = {}
    running = set()
    for run in sorted(check_runs, key=lambda r: r.get('id', 0)):
        name = run.get('name') or ''
        if run.get('status') != 'completed':
            running.add(name)
        elif run.get('conclusion') not in NO_VERDICT:
            newest[name] = run
            running.discard(name)
    failing = sorted(name for name, run in newest.items() if run.get('conclusion') in FAILING)
    return {'failing': failing, 'running': sorted(running), 'ok': len(newest) - len(failing)}


def scope_of(paths: list[str], classify=None) -> dict:
    """What scripts/test-scope.py says about the changed paths: tier, audit kinds, lane paths. Path-based only.

    classify defaults to test-scope.py's own function. If it can't run, the scope is unknown and nothing
    that depends on it is flagged.
    """
    try:
        if classify is None:
            spec = importlib.util.spec_from_file_location('sm_status_test_scope', PUBLIC / 'scripts' / 'test-scope.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            classify = module.classify
        result = classify(paths)
    except Exception as error:  # noqa: BLE001 - an unknown scope must not break the snapshot
        return {'known': False, 'why': f'{type(error).__name__}: {error}'}
    kinds = sorted({AUDITED_CATEGORIES[f['category']] for f in result['files'] if f['category'] in AUDITED_CATEGORIES})
    if result.get('lane_paths'):
        kinds.append('the lane')
    taps = sorted(p for p in paths if p in OWNER_TAP_FILES or p.startswith(OWNER_TAP_PREFIXES))
    return {'known': True, 'tier': result['tier'], 'needs_t3': result['tier'] >= 'T3', 'audit_kinds': kinds,
            'owner_tap': taps}


def fetch_bundle(api, summary: dict, sleep=time.sleep) -> dict:
    """Everything the analysis reads about one open PR. A failed read is kept (under 'errors'), never skipped."""
    number = summary['number']
    errors: dict[str, str] = {}

    def read(name, path, paged=False, default=None):
        try:
            return api.pages(path) if paged else api.get(path)
        except GitHubError as error:
            errors[name] = str(error)
            return default

    pull = read('pull', f'pulls/{number}', default=summary) or summary
    if pull.get('mergeable') is None and pull.get('state', 'open') == 'open' and 'pull' not in errors:
        sleep(2)   # GitHub works out mergeability in the background on the first read
        pull = read('pull', f'pulls/{number}', default=pull) or pull
    head = (pull.get('head') or {}).get('sha') or (summary.get('head') or {}).get('sha') or ''
    committed = None
    if head and any(label['name'] == 'needs-mac' for label in pull.get('labels', [])):
        info = read('head_commit', f'commits/{head}', default={}) or {}   # only the Mac hand-off check needs it
        committed = ((info.get('commit') or {}).get('committer') or {}).get('date')
    return {'pull': pull, 'head_committed_at': committed,
            'comments': read('comments', f'issues/{number}/comments', paged=True, default=[]),
            'events': read('events', f'issues/{number}/events', paged=True, default=[]),
            'files': read('files', f'pulls/{number}/files', paged=True, default=[]),
            'check_runs': read('checks', f'commits/{head}/check-runs', paged=True, default=[]) if head else [],
            'errors': errors}


# ---- Judging one PR -----------------------------------------------------------------------------------

def newest(items: list[dict], keep) -> dict | None:
    chosen = [item for item in items if keep(item)]
    return chosen[-1] if chosen else None


def short(report: dict | None) -> dict | None:
    if not report:
        return None
    return {'verdict': report['verdict'], 'tier': report['tier'], 'id': report['id'], 'at': report['at'],
            'commit7': (report['commit'] or '')[:7], 'url': report['url']}


def mergeable_word(pull: dict) -> str:
    state = pull.get('mergeable_state')
    if pull.get('mergeable') is False or state == 'dirty':
        return 'conflict'
    if pull.get('draft'):
        return 'draft'
    return {'clean': 'clean', 'behind': 'behind', 'blocked': 'blocked', 'unstable': 'unstable'}.get(state, 'unknown')


def analyse(bundle: dict, classify=None) -> dict:
    """The snapshot row for one PR: facts first, then the flags a status reply must not hide."""
    pull = bundle['pull']
    comments = comment_trust.trusted_only(bundle['comments'])  # #1822: a stranger's look-alike comment is data
    head = (pull.get('head') or {}).get('sha') or ''
    head7 = head[:7]
    labels = sorted(label['name'] for label in pull.get('labels', []))
    reports = runner_reports(comments)
    on_head = [r for r in reports if same(r['commit'], head)]
    lane = newest(on_head, lambda r: True)
    t3 = newest(on_head, lambda r: r['tier'] == 'T3')
    requests = lane_requests(comments)
    t3_requests = [r for r in requests if r['tier'] == 'T3']
    t3_reports = [r for r in reports if r['tier'] == 'T3']
    audit_list = audits(comments)
    audit = newest(audit_list, lambda a: any(same(sha, head) for sha in a['shas']))
    other_audit = newest(audit_list, lambda a: a['shas'] and not any(same(sha, head) for sha in a['shas']))
    armed_at = armed_since(bundle['events'])
    armed = 'automerge' in labels
    checks = check_summary(bundle['check_runs'])
    scope = scope_of([f['filename'] for f in bundle['files']], classify) if bundle['files'] else {'known': False,
                                                                                                    'why': 'no file list'}
    flags: list[dict] = []

    def flag(code, severity, detail):
        flags.append({'code': code, 'severity': severity, 'detail': detail})

    held = newest(on_head, lambda r: r['tier'] == 'auto')
    if held and held.get('holds'):
        flag('held-by-runner', LOOK, f'the newest automerge report on {head7} ({held["verdict"]}, {held["id"]}) says: '
             + ' / '.join(text[:160] for text in held['holds']))

    for name, why in sorted(bundle['errors'].items()):
        flag('unreadable', RED, f'could not read the PR\'s {name}: {why}')

    red = []
    if lane and lane['verdict'] == 'FAIL':
        red.append(f'the newest lane report on {head7} is FAIL ({lane["id"]}, tier {lane["tier"]})')
    if t3 and t3['verdict'] == 'FAIL' and not (lane and lane is t3):
        red.append(f'the newest T3 report on {head7} is FAIL ({t3["id"]})')
    if checks['failing']:
        red.append(f'checks failing on {head7}: {", ".join(checks["failing"])}')
    if red:
        flag('red-on-head', RED, '; '.join(red))

    if lane and lane['verdict'] == 'INCONCLUSIVE':
        flag('inconclusive-on-head', LOOK, f'the newest lane report on {head7} is INCONCLUSIVE ({lane["id"]}, '
             f'tier {lane["tier"]}): not a pass, and the lane check stays green')

    if reports and not on_head:
        last = reports[-1]
        flag('older-head-only', LOOK, f'lane reports exist only for other commits (newest: {last["verdict"]} on '
             f'{(last["commit"] or "?")[:7]}, tier {last["tier"]}); none on the head {head7}')

    if t3_requests:
        asked = t3_requests[-1]['index']
        answered = newest(t3_reports, lambda r: True)
        if answered is None or answered['index'] < asked:
            if not (t3 and t3['index'] > asked):
                if not {'lane:queued', 'lane:running'} & set(labels):
                    flag('t3-unqueued', LOOK, 'the newest /lane T3 request has no report and the PR carries neither '
                         '`lane:queued` nor `lane:running`: nothing will run it until the label is (re)added')
                flag('t3-held', LOOK, 'the newest /lane T3 request has no T3 report yet; the runner merges nothing '
                     'until it does')
        elif answered['verdict'] != 'PASS':
            flag('t3-held', RED if answered['verdict'] == 'FAIL' else LOOK,
                 f'the newest T3 report is {answered["verdict"]} (on {(answered["commit"] or "?")[:7]}'
                 f'{"" if same(answered["commit"], head) else ", not the head"}); a PR that asked for T3 merges only '
                 f'on a T3 PASS')

    if audit and not audit['clean']:
        audited = not scope.get('known') or bool(scope['audit_kinds'])   # the runner consults audits for those only
        flag('audit-blocking', RED if audited else LOOK,
             f'the {audit["who"]} audit of {head7} has findings: "{audit["line"][:100]}"'
             + ('' if audited else ' (not an audited kind of change, so the runner ignores it)'))
    elif scope.get('known') and scope['audit_kinds'] and not audit:
        older = f' (the audit on file is for {other_audit["shas"][0][:7]})' if other_audit else ''
        flag('audit-pending', LOOK, f'touches {" and ".join(scope["audit_kinds"])}; no audit names the head '
             f'{head7}{older}, so the runner won\'t merge it')

    word = mergeable_word(pull)
    if word == 'conflict':
        flag('conflict', RED, f'does not merge cleanly into {BASE}')

    if armed and scope.get('known') and scope['needs_t3'] and not t3_requests and not t3_reports:
        flag('armed-no-lane-request', LOOK, f'automerge is on and the diff needs simulator tests ({scope["tier"]} by '
             'path), but no /lane T3 request was posted')

    if not scope.get('known'):
        flag('scope-unknown', LOOK, f'could not work out what the diff touches ({scope.get("why")}), so audit, '
             'simulator-test and owner-tap needs are not judged')
    if scope.get('known') and scope['owner_tap']:
        flag('owner-tap', LOOK, f'touches {", ".join(scope["owner_tap"])}: the runner never merges it; '
             'it waits for the owner\'s tap')

    return {'number': pull.get('number'), 'title': pull.get('title') or '', 'url': pull.get('html_url') or '',
            'head': head, 'head7': head7, 'draft': bool(pull.get('draft')), 'mergeable': word,
            'labels': [label for label in SHOWN_LABELS if label in labels], 'issue': linked_issue(pull),
            'issues': linked_issues(pull),
            'lane': short(lane), 't3': short(t3),
            'lane_elsewhere': short(reports[-1]) if reports and not on_head else None,
            'audit': ({'verdict': 'clean' if audit['clean'] else 'blocking', 'who': audit['who'], 'at': audit['at']}
                      if audit else None),
            'audit_needed': scope.get('audit_kinds', []) if scope.get('known') else [],
            'checks': checks, 'scope_tier': scope.get('tier'), 't3_requested': bool(t3_requests),
            'armed': armed, 'armed_at': armed_at, 't4_waiting': waiting_t4(comments),
            'mac': mac_handoff(pull, comments, bundle['events'], bundle.get('head_committed_at')), 'flags': flags}


# ---- The snapshot ---------------------------------------------------------------------------------------

def snapshot(api, now: dt.datetime | None = None, only: list[int] | None = None, classify=None,
             workers: int = 6, sleep=time.sleep) -> dict:
    """Read every open PR into the trunk and judge it. Raises GitHubError when the PR list itself can't be read."""
    now = now or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    summaries = api.pages(f'pulls?state=open&base={BASE}&sort=created&direction=asc')
    missing = []
    if only:
        missing = sorted(set(only) - {s['number'] for s in summaries})
        summaries = [s for s in summaries if s['number'] in only]
    tip = ''
    try:
        tip = (api.get(f'git/ref/heads/{BASE}').get('object') or {}).get('sha', '')
    except GitHubError:
        pass
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        bundles = list(pool.map(lambda s: fetch_bundle(api, s, sleep), summaries))
    rows = [analyse(bundle, classify) for bundle in bundles]
    counts = {'open': len(rows), 'red': sum(any(f['severity'] == RED for f in r['flags']) for r in rows),
              'look': sum(bool(r['flags']) and not any(f['severity'] == RED for f in r['flags']) for r in rows),
              'armed': sum(r['armed'] for r in rows)}
    return {'as_of': stamp(now), 'repo': getattr(api, 'repo', REPO), 'base': BASE, 'base_tip': tip[:7], 'counts': counts,
            'missing': missing, 'prs': rows}


def lane_text(row: dict) -> str:
    lane, t3 = row['lane'], row['t3']
    if not lane:
        return 'lane none on head' + (f' (only {row["lane_elsewhere"]["verdict"]} on {row["lane_elsewhere"]["commit7"]})'
                                      if row['lane_elsewhere'] else '')
    text = f'lane {lane["verdict"]} ({lane["tier"]})'
    return text + (f', T3 {t3["verdict"]}' if t3 and t3['id'] != lane['id'] else '')


def audit_text(row: dict) -> str:
    if row['audit']:
        return f'audit {row["audit"]["who"]} {row["audit"]["verdict"]}'
    return 'audit none on head' if row['audit_needed'] else 'audit not needed'


def line(row: dict) -> str:
    marks = '!! ' if any(f['severity'] == RED for f in row['flags']) else ('!  ' if row['flags'] else '   ')
    issue = f'closes #{row["issue"]}' if row['issue'] else 'no linked issue'
    labels = ' '.join(row['labels']) or 'no labels'
    title = row['title'] if len(row['title']) <= 60 else row['title'][:59] + '…'
    checks = row['checks']
    shown = ('checks failing ' + ', '.join(checks['failing']) if checks['failing'] else
             'checks running ' + ', '.join(checks['running']) if checks['running'] else 'checks ok')
    return (f'{marks}#{row["number"]} {row["head7"]} | {lane_text(row)} | {audit_text(row)} | {shown} | '
            f'merge {row["mergeable"]} | {labels} | {issue} | {title}')


def render(snap: dict) -> str:
    counts = snap['counts']
    lines = [f'Open PRs into {snap["base"]} as of {snap["as_of"]} (next at {snap["base_tip"] or "?"}): '
             f'{counts["open"]} open, {counts["armed"]} armed, {counts["red"]} red, {counts["look"]} to look at']
    for row in snap['prs']:
        lines.append(line(row))
    for row in snap['prs']:
        for flagged in row['flags']:
            lines.append(f'   #{row["number"]} {flagged["code"]} ({flagged["severity"]}): {flagged["detail"]}')
    for number in snap.get('missing', []):
        lines.append(f'   #{number} is not an open PR into {snap["base"]} (merged, closed or another base)')
    if not snap['prs'] and not snap.get('missing'):
        lines.append('   (no open PRs)')
    lines.append('Lane verdicts count only on the head shown; "none on head" means no runner report tests it yet.')
    return '\n'.join(lines)


def main(argv=None, api=None, now=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--json', action='store_true', help='print the snapshot as JSON')
    parser.add_argument('--pr', type=int, action='append', help='only this PR (repeatable)')
    parser.add_argument('--repo', default=REPO)
    args = parser.parse_args(argv)
    try:
        snap = snapshot(api or GitHub(args.repo), now, args.pr)
    except GitHubError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2
    print(json.dumps(snap, indent=2) if args.json else render(snap))
    return 0


if __name__ == '__main__':
    sys.exit(main())
