#!/usr/bin/env python3
"""Pipeline events: what each lane step and hosted job costs and catches, from GitHub, in one event file (#2377).

The facts are scattered: lane verdicts in PR comments, hosted job results in the Actions API, per-test catches in a
cache file on one Mac. This gathers them as one JSON event per line, then counts them. Run by hand; no recurring cost.

    scripts/pipeline_events.py collect --since 2026-10-17     # writes artifacts/pipeline/events.jsonl
    scripts/pipeline_events.py report [--since D] [--until D]  # per-tier, per-step, per-job rates, each with counts

collect reads, from `Spoken-Margins/spoken-margins-native` (SM_STATUS_REPO), with GH_TOKEN, GITHUB_TOKEN or `gh`:
- lane report comments from a trusted author (scripts/comment_trust.py: a look-alike is ignored), through
  `lane_event.collect`: the report's hidden lane-event line when it has one (#2378), else the prose;
- Actions runs and their jobs (`--no-jobs` skips the per-run job calls);
- `test-catches.jsonl` from the lane state folder (`--catches`, default `$SM_LANE_STATE_DIR` or the Mac's cache
  folder) when it exists. It lives on the owner's Mac, so a collect elsewhere reports without it, and says so.

Events (kind): `lane` (one per lane report), `test-failure` (one per failing test named in a failing report),
`run` and `job` (Actions), `catch` (one per line of test-catches.jsonl). Every event has an `id`, so collecting
again replaces an event instead of adding a second one, and the events are written sorted: the same inputs give the
same file. An event holds only ids, enums and numbers: every string passes a short pattern or is dropped, so no
failure message, log text or local path can get in (the same rule as lane_event.py).

Classes are labels, `{"class", "by": "heuristic", "signal"}`, so they can be re-derived or overridden: collect
re-derives every heuristic label from all events in the file and keeps one whose `by` is anything else.

    fault        the lane's or the runner's own trouble: INCONCLUSIVE, a kill (exit -15, 124), a budget, no slot,
                 no tests run; for a job, timed out or failed in job setup
    compile      the app or a test target didn't compile
    trunk-red    the trunk itself is red: the report re-ran the test on plain trunk and it failed there too, or the
                 same test failed on two PRs tested against the same trunk commit, or a job failed on the trunk
    flake        failed, then passed on the same head against the same trunk commit (a job: on a re-run attempt)
    trunk-moved  failed, then passed on the same head once the trunk had moved: the trunk broke it and a later
                 trunk fixed it, or a flake; the data can't say which
    code         failed, and a later head of the same PR passed (the PR changed and the run passed)
    unresolved   failed and nothing passed afterwards (PR closed, superseded, merged by other means), or too recent
    cancelled    a job cancelled (usually superseded by a newer push); not a failure

`report` collapses failures by (test, trunk commit): a red trunk counts once, not once per PR that ran into it.

Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import comment_trust  # noqa: E402  (#1822: whose comments may be believed)
import lane_event  # noqa: E402  (#2378: the report's event line and its prose fallback)
from trunk import trunk_branch  # noqa: E402

REPO = os.environ.get('SM_STATUS_REPO', 'Spoken-Margins/spoken-margins-native')
OUT = Path('artifacts/pipeline')
EVENTS = 'events.jsonl'
VERSION = 1

COMMIT = re.compile(r'[0-9a-f]{7,40}')
TEST_NAME = r'[A-Za-z_]\w*Tests?(?:/\w+)?/test\w+(?![\w…])|test_\w+\.\w+Tests?\.test\w+'
TEST = re.compile(TEST_NAME)
REQUESTED = re.compile(r'\w{1,80}(?:/\w{1,120}){0,2}')
WORKFLOW = re.compile(r'[A-Za-z][\w.-]{0,59}')
JOB = re.compile(r'[A-Za-z][A-Za-z0-9 ()._,:#+-]{0,59}')

TITLE = re.compile(r'^Lane report (\S+) — (PASS|FAIL|INCONCLUSIVE)', re.M)
REQUEST = re.compile(r'<!-- lane-request: (\{.*?\}) -->')
TRUNK_NAME = re.compile(r'\(tested merged with (next|main) at ')
SECOND_LINE_SECONDS = re.compile(r'· (?:(\d+)h(\d+)m|(?:(\d+)m)?(\d+)s)\s*$')
FAILED = [re.compile(r'Failed: (' + TEST_NAME + ')'),
          re.compile(r'(' + TEST_NAME + r') — expected: passes\. observed: failed')]
UNITTEST_FAILED = re.compile(r'^\s*(?:FAIL|ERROR): (test\w+) \(([\w.]+)\)', re.M)
RERUN_ON_TRUNK = re.compile(r're-run on plain (?:next|main) [0-9a-f]{7,}: (.*)')
RERUN_RESULT = re.compile(r'(' + TEST_NAME + r') \(([^)]*)\)')
TRUNK_TOO = re.compile(r'fails on (?:next|main) [0-9a-f]{7,} too')
FAULT = re.compile(r'exit -15|exit 124|ran past its|ran out of its own|Missing \d+ tests|no host-test slot|'
                   r'Build before simulator boot: Process exit|Not in any app test plan|'
                   r'printed no test output|lane error|BUILD INTERRUPTED', re.I)
COMPILE = re.compile(r'\.swift:\d+:\d+: error:|\*\* BUILD FAILED|SwiftCompile|Process exit 65|error: cannot find')
SETUP_STEPS = ('Set up job', 'Initialize containers', 'Complete job')

JOB_THREADS = 8
STEP_RED_PRS = 3  # PRs failing the same step against one trunk commit, with none passing it, read as a red trunk
CLASSES = ('code', 'flake', 'trunk-moved', 'trunk-red', 'compile', 'fault', 'unresolved', 'cancelled')
HEURISTIC = 'heuristic'


# ---- Reading one lane report ---------------------------------------------------------------------

def _head(commit) -> str:
    return commit[:12] if isinstance(commit, str) and COMMIT.fullmatch(commit[:12] or '-') else ''


def _duration(match) -> int | None:
    hours, minutes, minutes_only, seconds = match.groups()
    if hours is not None:
        return int(hours) * 3600 + int(minutes) * 60
    return int(minutes_only or 0) * 60 + int(seconds)


def prose_steps(body: str, verdict: str) -> list[dict]:
    """The steps a pre-#2378 report names in its `ran:` line, in lane_event's shape. Seconds are known only for the
    app plans, whose entries carry them; the others say None. Coarser than the line: one step for both app plans."""
    ran = re.search(r'^ran: (.*)$', body, re.M)
    ran = ran.group(1) if ran else ''
    steps = []
    host = re.search(r'host tests \(.*?\): (passed|fail|inconclusive)', ran)
    if host:
        killed = host.group(1) == 'fail' and bool(FAULT.search(body))
        steps.append({'step': 'host tests', 'seconds': None,
                      'result': 'fault' if killed else {'passed': 'pass', 'fail': 'fail'}.get(host.group(1), 'fault')})
    ops = re.search(r'ops folder tests: (pass|fail)', ran)
    if ops:
        steps.append({'step': 'ops tests', 'seconds': None, 'result': ops.group(1)})
    if re.search(r'hot-file ratchet: failed', ran):
        steps.append({'step': 'hot-file ratchet', 'seconds': None, 'result': 'fail'})
    builds = re.search(r'simulator build \((\w+)\), device build \((\w+)\)', ran)
    if builds:
        steps.append({'step': 'app builds', 'seconds': None,
                      'result': 'pass' if builds.group(1) == builds.group(2) == 'pass' else 'fail'})
    plans = re.findall(r'\((\d+) passed(?:, (\d+) failed)?; (?:app|adapters) plan, build and tests, '
                       r'(?:(\d+)m)?(\d+)s\)', ran)
    if plans:
        failed = any(int(plan[1] or 0) for plan in plans)
        none = not any(int(plan[0]) for plan in plans)
        steps.append({'step': 'app tests (T3)', 'seconds': sum(int(p[2] or 0) * 60 + int(p[3]) for p in plans),
                      'result': 'fail' if failed else ('fault' if none or verdict == 'INCONCLUSIVE' else 'pass')})
    return steps


def failed_tests(body: str) -> dict:
    """{test: trunk-red evidence} for the tests a failing report names. The evidence is True when the report re-ran
    the test on plain trunk and it failed there too, else False. A name must fit TEST, so no log text enters."""
    names = {}
    for pattern in FAILED:
        for match in pattern.finditer(body):
            names[match.group(1)] = False
    for match in UNITTEST_FAILED.finditer(body):
        name = f'{match.group(2)}.{match.group(1)}'
        if TEST.fullmatch(name):
            names[name] = False
    for match in RERUN_ON_TRUNK.finditer(body):
        for name, why in RERUN_RESULT.findall(match.group(1)):
            if 'passed' not in why:
                names[name] = True
    if TRUNK_TOO.search(body):  # "fails on next X too: not this PR": every test it names failed on plain trunk
        names = dict.fromkeys(names, True)
    return names


def _requested(request: dict) -> list[str]:
    tests = request.get('tests')
    return sorted({t for t in tests if isinstance(t, str) and REQUESTED.fullmatch(t)})[:60] \
        if isinstance(tests, list) else []


def lane_events(comments: list[dict]) -> list[dict]:
    """The `lane` and `test-failure` events in a list of GitHub issue comments. Only a comment from the owner, a
    collaborator or the project's bot counts, and only one that starts with `Lane report`."""
    events = []
    for comment in comments:
        body = comment.get('body') or ''
        if not body.startswith('Lane report') or not comment_trust.trusted(comment):
            continue
        found, title = lane_event.collect(body), TITLE.search(body)
        if not found or not title or not isinstance(comment.get('id'), int):
            continue
        request_id = title.group(1)
        try:
            request = json.loads(REQUEST.search(body).group(1))
        except (AttributeError, ValueError):
            request = {}
        request = request if isinstance(request, dict) else {}
        via = 'pr' if re.match(r'pr\d+-', request_id) else (
            'desk' if '-desk-' in request_id else ('integration' if request_id.startswith('integration') else 'other'))
        pr = re.search(r'/issues/(\d+)$', comment.get('issue_url') or '') or re.match(r'pr(\d+)', request_id)
        trunk_name = TRUNK_NAME.search(body)
        second = body.split('\n')[1] if body.count('\n') else ''
        seconds = found['seconds']
        if seconds is None and (took := SECOND_LINE_SECONDS.search(second)):
            seconds = _duration(took)
        steps = found['steps'] or prose_steps(body, found['verdict'])
        event = {
            'kind': 'lane', 'id': f'lane:{comment["id"]}', 'at': comment.get('created_at') or '',
            'pr': int(pr.group(1)) if pr and via == 'pr' else None,
            'via': via,
            'run': int(m.group(1)) if (m := re.search(r'-r(\d+)', request_id)) else None,
            'verdict': found['verdict'], 'tier': found['tier'],
            'head': _head(request.get('commit')) or found['head'], 'trunk': _head(request.get('next')) or found['trunk'],
            'trunk_name': trunk_name.group(1) if trunk_name else '',
            'seconds': seconds, 'queue_seconds': found['queue_seconds'], 'steps': steps,
            'tests': found['tests'], 'requested': _requested(request), 'source': found['source']}
        trunk_red = bool(TRUNK_TOO.search(body))
        names = failed_tests(body) if found['verdict'] != 'PASS' else {}
        signal = _report_signal(body, found['verdict'], trunk_red or any(names.values()))
        if signal:
            event['label'] = {'class': signal[0], 'by': HEURISTIC, 'signal': signal[1]}
        events.append(event)
        for name, red in sorted(names.items()):
            failure = {'kind': 'test-failure', 'id': f'fail:{comment["id"]}:{name}', 'at': event['at'], 'test': name,
                       'pr': event['pr'], 'lane': event['id'], 'tier': event['tier'], 'head': event['head'],
                       'trunk': event['trunk']}
            if red:
                failure['label'] = {'class': 'trunk-red', 'by': HEURISTIC, 'signal': 'trunk-rerun'}
            events.append(failure)
    return events


def _report_signal(body: str, verdict: str, trunk_red: bool):
    """(class, signal) a report settles by itself, or None: a PASS, or a failure that only later runs can classify."""
    if verdict == 'PASS':
        return None
    if trunk_red:
        return 'trunk-red', 'trunk-rerun'
    if COMPILE.search(body):
        return 'compile', 'swift-error' if '.swift:' in body else 'build-failed'
    if verdict == 'INCONCLUSIVE':
        return 'fault', 'inconclusive'
    if FAULT.search(body):
        return 'fault', 'runner-kill'
    return None


# ---- Actions runs and jobs ---------------------------------------------------------------------

def _seconds(start, end) -> int | None:
    try:
        took = (dt.datetime.strptime(end, '%Y-%m-%dT%H:%M:%SZ') - dt.datetime.strptime(start, '%Y-%m-%dT%H:%M:%SZ'))
    except (TypeError, ValueError):
        return None
    return int(took.total_seconds()) if took.total_seconds() >= 0 else None


def _enum(value, choices, default='other'):
    return value if value in choices else default


def run_event(run: dict, trunk: str) -> dict:
    """The event for one workflow run. The workflow is the file name under .github/workflows, when it fits."""
    name = os.path.basename((run.get('path') or '').split('@')[0]).rsplit('.', 1)[0]
    event = _enum(run.get('event'), ('pull_request', 'push', 'schedule', 'workflow_dispatch', 'workflow_run'))
    return {'kind': 'run', 'id': f'run:{run.get("id")}:{run.get("run_attempt") or 1}', 'at': run.get('created_at') or '',
            'run': run.get('id'), 'attempt': run.get('run_attempt') or 1,
            'workflow': name if WORKFLOW.fullmatch(name) else 'other', 'event': event,
            'branch': 'pr' if event == 'pull_request' else ('trunk' if run.get('head_branch') == trunk else 'other'),
            'head': _head(run.get('head_sha')),
            'conclusion': _enum(run.get('conclusion'), ('success', 'failure', 'cancelled', 'skipped', 'timed_out',
                                                        'neutral', 'action_required', 'startup_failure'), 'unknown'),
            'seconds': _seconds(run.get('run_started_at') or run.get('created_at'), run.get('updated_at'))}


def job_event(job: dict, run: dict) -> dict:
    """The event for one job: run, name (when it fits), conclusion, seconds, runner kind and the step that failed."""
    labels = job.get('labels') or []
    hosted = job.get('runner_group_name') == 'GitHub Actions' or any(
        isinstance(label, str) and label.startswith(('ubuntu', 'macos', 'windows')) for label in labels)
    failed_step = next((step.get('name') for step in job.get('steps') or []
                        if step.get('conclusion') == 'failure'), None)
    name = job.get('name') or ''
    return {'kind': 'job', 'id': f'job:{job.get("id")}', 'at': job.get('created_at') or '', 'run': job.get('run_id'),
            'attempt': job.get('run_attempt') or 1, 'workflow': run['workflow'], 'branch': run['branch'],
            'job': name if JOB.fullmatch(name) else 'other', 'head': run['head'],
            'runner': 'self-hosted' if 'self-hosted' in labels else ('hosted' if hosted else 'unknown'),
            'conclusion': _enum(job.get('conclusion'), ('success', 'failure', 'cancelled', 'skipped', 'timed_out',
                                                        'neutral'), 'unknown'),
            'seconds': _seconds(job.get('started_at'), job.get('completed_at')),
            'queue_seconds': _seconds(job.get('created_at'), job.get('started_at')),
            'failed_step': failed_step if isinstance(failed_step, str) and JOB.fullmatch(failed_step) else None}


# ---- test-catches.jsonl ---------------------------------------------------------------------------

def catch_events(lines: list[str]) -> list[dict]:
    """One `catch` event per line of the lane ledger's test-catches.jsonl (lane_ledger.py): the step, the test, the
    PR key, the two commits, the ledger's class (catch, wrong-test, flake, next-moved, other) and seconds."""
    events = []
    for line in lines:
        try:
            raw = json.loads(line)
        except ValueError:
            continue
        if not isinstance(raw, dict):
            continue
        test, step = raw.get('test'), raw.get('step')
        key = raw.get('key') if isinstance(raw.get('key'), str) else ''
        event = {'kind': 'catch', 'step': step if isinstance(step, str) and JOB.fullmatch(step) else 'other',
                 'test': test if isinstance(test, str) and (TEST.fullmatch(test) or re.fullmatch(
                     r'step:[A-Za-z][A-Za-z0-9 ()#.-]{0,39}', test)) else 'other',
                 'pr': int(key[3:]) if re.fullmatch(r'pr:\d+', key) else None,
                 'from': _head(raw.get('from')), 'to': _head(raw.get('to')),
                 'class': _enum(raw.get('class'), ('catch', 'wrong-test', 'flake', 'next-moved', 'other')),
                 'seconds': raw.get('seconds') if isinstance(raw.get('seconds'), (int, float)) else None,
                 'at': dt.datetime.fromtimestamp(raw['at'], dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                 if isinstance(raw.get('at'), (int, float)) and 0 < raw['at'] < 4e9 else ''}
        digest = hashlib.sha1(json.dumps([event['step'], event['test'], event['pr'], event['from'], event['to'],
                                          event['class'], event['at'], event['seconds']]).encode()).hexdigest()[:16]
        event['id'] = f'catch:{digest}'
        events.append(event)
    return events


# ---- Labelling across events ----------------------------------------------------------------------

def _same(a: str, b: str) -> bool:
    return bool(a and b) and a[:7] == b[:7]


def _is_host_test(test: str) -> bool:
    """A SessionKit test (Module/Class/method) or a Python one (module.Class.method); anything else is an app test,
    with or without its SpokenMarginsApp module in the name."""
    return '.' in test or test.startswith('SessionKit')


def _split_module(name: str):
    """(module or None, [Class, method...]) of an app test or request name. A failure names its SpokenMarginsApp...
    module; a request may or may not."""
    parts = name.split('/')
    return (parts[0], parts[1:]) if parts[0].startswith('SpokenMarginsApp') else (None, parts)


def _covers(request: str, test: str) -> bool:
    """Whether a T3 request names the failing app test: its module (when both give one), a class of it or the test."""
    asked_module, asked = _split_module(request)
    module, found = _split_module(test)
    if asked_module and module and asked_module != module:
        return False
    if not asked and not asked_module:
        return False
    return found[:len(asked)] == asked


def _closes(failure: dict, later: dict, test: str | None) -> bool:
    """Whether a later PASS report on the PR ran what the failure ran. Host tests run only in an `auto` report (T2
    runs the builds, T3 the app plans); an app test only in a T3 PASS whose request covers it; a report-level
    failure is closed by a PASS of its own tier."""
    if later['verdict'] != 'PASS' or later['pr'] != failure['pr'] or later['at'] < failure['at']:
        return False
    if test is None:
        return later['tier'] == failure['tier']
    if _is_host_test(test):
        return later['tier'] == 'auto'
    return later['tier'] == 'T3' and any(_covers(request, test) for request in later['requested'])


def _resolve(failure: dict, lanes: list[dict], test: str | None):
    if failure['pr'] is None:
        return 'unresolved', 'no-pr'
    for later in lanes:
        if later['id'] != failure.get('lane', failure['id']) and _closes(failure, later, test):
            if _same(later['head'], failure['head']):
                return ('flake', 'same-head') if _same(later['trunk'], failure['trunk']) else \
                    ('trunk-moved', 'same-head-trunk-moved')
            return 'code', 'later-head'
    return 'unresolved', 'no-later-pass'


def label(events: list[dict]) -> list[dict]:
    """Set the heuristic label on every failure event, from all events together (a later PASS, or the same test
    failing on another PR against the same trunk commit, decides it). A label with another `by` is kept."""
    lanes = sorted((e for e in events if e['kind'] == 'lane'), key=lambda e: (e['at'], e['id']))
    by_pr = collections.defaultdict(list)
    for lane in lanes:
        by_pr[lane['pr']].append(lane)
    red = collections.defaultdict(set)  # (test or step, trunk sha7) -> PRs it failed on
    clean = set()  # (step, trunk sha7) a step passed against
    for event in events:
        if event['kind'] == 'test-failure' and event['trunk']:
            red[(event['test'], event['trunk'][:7])].add(event['pr'])
        elif (event['kind'] == 'lane' and event['verdict'] == 'FAIL' and event['trunk']
              and _report_signal_of(event) is None):
            for step in event['steps']:
                if step['result'] == 'fail':
                    red[('step:' + step['step'], event['trunk'][:7])].add(event['pr'])
        if event['kind'] == 'lane' and event['verdict'] == 'PASS' and event['trunk']:
            for step in event['steps']:
                if step['result'] == 'pass':
                    clean.add((step['step'], event['trunk'][:7]))

    def settable(event):
        return (event.get('label') or {}).get('by', HEURISTIC) == HEURISTIC

    for event in events:
        if event['kind'] == 'lane' and event['verdict'] != 'PASS' and settable(event):
            signal = _report_signal_of(event)
            if not signal and any(step['result'] == 'fail' and (step['step'], event['trunk'][:7]) not in clean
                                  and len(red[('step:' + step['step'], event['trunk'][:7])]) >= STEP_RED_PRS
                                  for step in event['steps']):
                signal = 'trunk-red', 'multi-pr-step'  # a step no PR passed against this trunk commit, on 3 or more
            event['label'] = {'class': signal[0], 'by': HEURISTIC, 'signal': signal[1]} if signal else \
                dict(zip(('class', 'signal'), _resolve(event, by_pr.get(event['pr'], []), None)), by=HEURISTIC)
        elif event['kind'] == 'test-failure' and settable(event):
            if (event.get('label') or {}).get('signal') == 'trunk-rerun':
                continue
            if len(red[(event['test'], event['trunk'][:7])]) >= 2:
                event['label'] = {'class': 'trunk-red', 'by': HEURISTIC, 'signal': 'multi-pr'}
            else:
                event['label'] = dict(zip(('class', 'signal'), _resolve(event, by_pr.get(event['pr'], []),
                                                                        event['test'])), by=HEURISTIC)
    reports = {}
    for lane in lanes:
        if lane['run'] and lane['verdict'] != 'PASS' and 'label' in lane:
            reports.setdefault(lane['run'], lane['label'])
    label_jobs([e for e in events if e['kind'] == 'job'], reports)
    return events


def _report_signal_of(event: dict):
    """What a lane event already carries: its stored label when it is one of the report's own signals."""
    current = event.get('label') or {}
    if current.get('signal') in ('trunk-rerun', 'swift-error', 'build-failed', 'inconclusive', 'runner-kill'):
        return current['class'], current['signal']
    if event['verdict'] == 'INCONCLUSIVE':
        return 'fault', 'inconclusive'
    return None


def label_jobs(jobs: list[dict], reports: dict | None = None) -> None:
    """Class each failed or cancelled job. reports: {workflow run id: the class label of its non-PASS lane report}; a
    failed lane job takes its report's class, since the job fails because the lane's verdict was FAIL."""
    reports = reports or {}
    passed = {(job['run'], job['job']): job['attempt'] for job in jobs if job['conclusion'] == 'success'}
    for job in jobs:
        if (job.get('label') or {}).get('by', HEURISTIC) != HEURISTIC:
            continue
        job.pop('label', None)
        if job['conclusion'] == 'cancelled':
            result = 'cancelled', 'superseded-or-stopped'
        elif job['conclusion'] == 'timed_out':
            result = 'fault', 'timed-out'
        elif job['conclusion'] != 'failure':
            continue
        elif job['failed_step'] in SETUP_STEPS:
            result = 'fault', 'job-setup'
        elif job['workflow'] == 'lane' and job['run'] in reports:
            result = reports[job['run']]['class'], 'lane-report'
        elif job['job'] != 'other' and passed.get((job['run'], job['job']), 0) > job['attempt']:
            result = 'flake', 'rerun-passed'
        elif job['branch'] == 'trunk':
            result = 'trunk-red', 'trunk-job'
        else:
            result = 'code', 'job-failed'
        job['label'] = {'class': result[0], 'by': HEURISTIC, 'signal': result[1]}


# ---- The event file --------------------------------------------------------------------------------

def merge(old: list[dict], new: list[dict]) -> list[dict]:
    """The events by id, a new one replacing an old one, except that an old label set by anyone but the heuristic
    stays. Sorted, so the same inputs write the same file."""
    merged = {event['id']: event for event in old}
    for event in new:
        previous = merged.get(event['id'])
        if previous and (previous.get('label') or {}).get('by', HEURISTIC) != HEURISTIC:
            event = dict(event, label=previous['label'])
        merged[event['id']] = event
    return sorted(merged.values(), key=lambda event: (event.get('at') or '', event['id']))


def read_events(path: Path) -> list[dict]:
    """The events in the file. A line that isn't a JSON object (a truncated last line) is skipped, so one bad line
    doesn't drop the rest and the history a collect rewrites."""
    found = []
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return []
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and isinstance(event.get('id'), str) and isinstance(event.get('kind'), str):
            found.append(event)
    return found


def write_events(path: Path, events: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(''.join(json.dumps(e, sort_keys=True, separators=(',', ':')) + '\n' for e in events))
    temporary.replace(path)  # a collect cut short leaves the old file whole


def collect_events(comments: list[dict], runs: list[tuple], catches: list[str], since: str, existing: list[dict],
                   trunk: str) -> list[dict]:
    """The event list after a collect. runs: [(run, [job, ...])] as the Actions API gives them. Everything older than
    `since` (an ISO date or time) is left out of the new events; the events already in the file stay."""
    fresh = [e for e in lane_events(comments) if e['at'] >= since]
    for run, jobs in runs:
        summary = run_event(run, trunk)
        if summary['at'] >= since:
            fresh.append(summary)
            fresh += [job_event(job, summary) for job in jobs]
    fresh += [e for e in catch_events(catches) if e['at'] >= since]
    return label(merge(existing, fresh))


# ---- Collecting from GitHub ---------------------------------------------------------------------------

def day_after(day: str) -> str:
    return (dt.datetime.strptime(day, '%Y-%m-%d') + dt.timedelta(days=1)).strftime('%Y-%m-%d')


def fetch_comments(github, since: str) -> list[dict]:
    return [c for c in github.pages(f'issues/comments?since={since}', limit=300)
            if (c.get('body') or '').startswith('Lane report')]


def fetch_runs(github, since: str, jobs: bool, trunk: str, log=lambda text: None) -> list[tuple]:
    """[(run, jobs)] for every run created since <since> (a date), a day at a time: the API gives at most 1000
    results a query. Each run's jobs are read on a few threads (one call per run is most of the time collect takes)."""
    found, day, today = [], since[:10], dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')
    while day <= today:
        runs = []
        for page in range(1, 11):
            chunk = github.get(f'actions/runs?created={day}&per_page=100&page={page}').get('workflow_runs', [])
            runs += chunk
            if len(chunk) < 100:
                break
        if len(runs) >= 1000:
            log(f'warning: {day} has 1000 or more runs; the API returns no more than that')
        found += runs
        day = day_after(day)

    def listing(run):
        if not jobs or run.get('conclusion') == 'skipped':
            return []
        try:
            return github.get(f'actions/runs/{run["id"]}/jobs?filter=all&per_page=100').get('jobs', [])
        except RuntimeError as error:  # sm_status.GitHubError: the run stays, without its jobs
            log(f'warning: no jobs for run {run["id"]}: {str(error)[:80]}')
            return []
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOB_THREADS) as pool:
        return list(zip(found, pool.map(listing, found)))


def default_catches() -> Path:
    return Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane') \
        / 'test-catches.jsonl'


def normalise_since(text: str) -> str:
    """An ISO time from a date or a time."""
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}', text):
        return text + 'T00:00:00Z'
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', text):
        return text
    raise SystemExit(f'--since takes YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, not {text!r}')


def command_collect(args) -> int:
    since, out = normalise_since(args.since), Path(args.out) / EVENTS
    runs: list[tuple] = []
    if args.comments_file:
        comments = json.loads(Path(args.comments_file).read_text())
    else:
        import sm_status  # noqa: PLC0415  (the GitHub reads; imported late so tests don't need a token)
        github = sm_status.GitHub(REPO)
        comments = fetch_comments(github, since)
        if not args.no_runs:
            runs = fetch_runs(github, since, not args.no_jobs, trunk_branch(), lambda text: print(text, file=sys.stderr))
    catches_path = Path(args.catches) if args.catches else default_catches()
    catches = catches_path.read_text().splitlines() if catches_path.is_file() else []
    if not catches:
        print(f'note: no test-catches.jsonl at {catches_path}; per-test catches are left out', file=sys.stderr)
    events = collect_events(comments, runs, catches, since, read_events(out), trunk_branch())
    write_events(out, events)
    counts = collections.Counter(e['kind'] for e in events)
    print(f'{out}: {len(events)} events ({", ".join(f"{n} {k}" for k, n in sorted(counts.items()))})')
    return 0


# ---- The report ----------------------------------------------------------------------------------------

def pct(part: int, whole: int) -> str:
    return f'{100 * part / whole:.0f}% ({part}/{whole})' if whole else 'n/a (0)'


def duration(seconds) -> str:
    if seconds is None:
        return '-'
    minutes, seconds = divmod(int(round(seconds)), 60)
    hours, minutes = divmod(minutes, 60)
    return f'{hours}h{minutes:02d}m' if hours else (f'{minutes}m{seconds:02d}s' if minutes else f'{seconds}s')


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def table(header: list[str], rows: list[list]) -> list[str]:
    lines = ['| ' + ' | '.join(header) + ' |', '|' + '|'.join([' --- '] + [' ---: '] * (len(header) - 1)) + '|']
    return lines + ['| ' + ' | '.join(str(cell) for cell in row) + ' |' for row in rows]


def first_tries(lanes: list[dict]) -> list[dict]:
    """The first lane report for each (PR, head): what the author's push got on its first try."""
    seen, first = set(), []
    for lane in sorted(lanes, key=lambda e: (e['at'], e['id'])):
        key = (lane['pr'], lane['head'][:7] or lane['id'])
        if lane['via'] == 'pr' and key not in seen:
            seen.add(key)
            first.append(lane)
    return first


def _passed_later_on_head(lane: dict, lanes: list[dict]) -> bool:
    return any(other['pr'] == lane['pr'] and _same(other['head'], lane['head']) and other['verdict'] == 'PASS'
               and other['at'] > lane['at'] for other in lanes)


def report(events: list[dict]) -> str:
    lanes = [e for e in events if e['kind'] == 'lane']
    failures = [e for e in events if e['kind'] == 'test-failure']
    jobs = [e for e in events if e['kind'] == 'job']
    runs = [e for e in events if e['kind'] == 'run']
    catches = [e for e in events if e['kind'] == 'catch']
    out = ['# Pipeline report', '']
    stamps = sorted(e['at'] for e in events if e.get('at'))
    out.append(f'Window: {stamps[0][:10]} to {stamps[-1][:10]} (UTC), {len(events)} events: {len(lanes)} lane reports '
               f'({sum(l["source"] == "line" for l in lanes)} with a lane-event line, '
               f'{sum(l["source"] == "prose" for l in lanes)} from prose only), {len(failures)} test failures, '
               f'{len(runs)} runs, {len(jobs)} jobs, {len(catches)} ledger catches.' if stamps else 'No events.')
    out += ['', '**Caveats.** Reports from before #2378 have no step seconds, queue wait or test counts, so those '
            'columns count only the reports that carry them (shown in each cell). Classes are heuristic labels '
            '(`by: heuristic`), re-derived on every collect. Reports whose PR is still open, or that nothing passed '
            'after, read `unresolved`.', '']
    if not lanes and not jobs:
        return '\n'.join(out)

    # lane reports by tier
    out += ['## Lane reports by tier', '']
    rows = []
    for tier in ('auto', 'T2', 'T3', 'all'):
        group = [l for l in lanes if tier == 'all' or l['tier'] == tier]
        if group:
            count = collections.Counter(l['verdict'] for l in group)
            rows.append([tier, len(group), pct(count['PASS'], len(group)), pct(count['FAIL'], len(group)),
                         pct(count['INCONCLUSIVE'], len(group)),
                         duration(median(l['seconds'] for l in group)),
                         duration(median(l['queue_seconds'] for l in group))])
    out += table(['tier', 'reports', 'PASS', 'FAIL', 'INCONCLUSIVE', 'median time', 'median queue wait'], rows)

    # first-try
    firsts = first_tries(lanes)
    out += ['', '## First try (the first report for each PR and head)', '']
    days = collections.defaultdict(list)
    for lane in firsts:
        days[lane['at'][:10]].append(lane)
    rows = [[day, len(group), pct(sum(l['verdict'] == 'FAIL' for l in group), len(group)),
             pct(sum(l['verdict'] == 'INCONCLUSIVE' for l in group), len(group))]
            for day, group in sorted(days.items())]
    rows.append(['all', len(firsts), pct(sum(l['verdict'] == 'FAIL' for l in firsts), len(firsts)),
                 pct(sum(l['verdict'] == 'INCONCLUSIVE' for l in firsts), len(firsts))])
    out += table(['day', 'heads', 'first-try FAIL', 'first-try INCONCLUSIVE'], rows)
    pr_firsts = {}
    for lane in sorted((l for l in lanes if l['via'] == 'pr'), key=lambda e: (e['at'], e['id'])):
        pr_firsts.setdefault(lane['pr'], lane)
    out += ['', f'The first report for each PR, FAIL or INCONCLUSIVE (the pooled number a hand count gives): '
            f'{pct(sum(l["verdict"] != "PASS" for l in pr_firsts.values()), len(pr_firsts))}.']

    # what failures were
    out += ['', '## What each non-PASS report was (class labels)', '']
    rows = []
    for verdict in ('FAIL', 'INCONCLUSIVE'):
        group = [l for l in lanes if l['verdict'] == verdict]
        count = collections.Counter((l.get('label') or {}).get('class', 'unlabelled') for l in group)
        rows.append([verdict, len(group)] + [pct(count[c], len(group)) for c in CLASSES[:-1]])
    out += table(['verdict', 'reports'] + list(CLASSES[:-1]), rows)
    fails = [l for l in lanes if l['verdict'] == 'FAIL']
    same_head = sum((l.get('label') or {}).get('class') in ('flake', 'trunk-moved') for l in fails)
    later = sum(_passed_later_on_head(lane, lanes) for lane in fails)
    out += ['', f'FAIL reports that later passed on the same head: {pct(later, len(fails))} (a PASS of any tier); '
            f'{pct(same_head, len(fails))} by the stricter test the labels use (a PASS of a tier that runs it again).']

    # steps
    out += ['', '## Steps (from reports with a lane-event line, and from the `ran:` line of older ones)', '']
    steps = collections.defaultdict(list)
    for lane in lanes:
        for step in lane['steps']:
            steps[step['step']].append((lane, step))
    rows = []
    for name, group in sorted(steps.items(), key=lambda item: -len(item[1])):
        count = collections.Counter(step['result'] for _, step in group)
        timed = [step['seconds'] for _, step in group if step.get('seconds') is not None]
        rows.append([name, len(group), pct(count['pass'], len(group)), pct(count['fail'], len(group)),
                     pct(count['fault'], len(group)), f'{duration(median(timed))} (n={len(timed)})',
                     duration(sum(timed)) if timed else '-'])
    out += table(['step', 'runs', 'pass', 'fail', 'fault', 'median time', 'total time'], rows)

    # test failures, collapsed
    out += ['', '## Test failures, collapsed by (test, trunk commit)', '']
    distinct = {(f['test'], f['trunk'][:7]) for f in failures}
    classes = collections.defaultdict(set)
    for failure in failures:
        classes[(failure.get('label') or {}).get('class', 'unlabelled')].add((failure['test'], failure['trunk'][:7]))
    out.append(f'{len(failures)} failing-test rows are {len(distinct)} distinct (test, trunk commit) pairs.')
    out += [''] + table(['class', 'rows', 'distinct (test, trunk)'],
                        [[c, sum((f.get('label') or {}).get('class', 'unlabelled') == c for f in failures),
                          len(classes[c])] for c in sorted(classes)])
    red = collections.Counter(f['test'] for f in failures if (f.get('label') or {}).get('class') == 'trunk-red')
    if red:
        out += ['', 'Most rows on a red trunk: ' + ', '.join(f'{t} ({n})' for t, n in red.most_common(5))]
    each = collections.Counter(f['test'] for f in failures)
    out += ['', 'Most failing tests: ' + ', '.join(f'{t} ({n})' for t, n in each.most_common(5))] if each else []

    # hosted jobs
    if jobs:
        out += ['', '## Hosted and self-hosted jobs', '']
        groups = collections.defaultdict(list)
        for job in jobs:
            if job['conclusion'] != 'skipped':
                groups[(job['workflow'], job['job'], job['runner'])].append(job)
        rows = []
        for (workflow, name, runner), group in sorted(groups.items(), key=lambda item: -len(item[1])):
            count = collections.Counter((j.get('label') or {}).get('class') or j['conclusion'] for j in group)
            rows.append([f'{workflow} / {name}', runner, len(group), pct(count['success'], len(group)),
                         pct(len(group) - count['success'] - count['cancelled'], len(group)), count['cancelled'],
                         ', '.join(f'{c} {count[c]}' for c in ('code', 'flake', 'trunk-red', 'fault') if count[c]) or '-',
                         duration(median(j['seconds'] for j in group)),
                         duration(median(j['queue_seconds'] for j in group))])
        out += table(['job', 'runner', 'runs', 'success', 'failed', 'cancelled', 'failed by class', 'median time',
                      'median queue'], rows[:25])

    # the ledger's catches
    if catches:
        out += ['', '## Ledger catches (test-catches.jsonl)', '']
        count = collections.Counter(c['class'] for c in catches)
        out += table(['class', 'episodes'], [[c, n] for c, n in count.most_common()])
    else:
        out += ['', 'No test-catches.jsonl was read, so there is no ledger section: the ledger lives on the owner\'s Mac.']
    return '\n'.join(out) + '\n'


def command_report(args) -> int:
    events = read_events(Path(args.out) / EVENTS)
    if args.since:
        since = normalise_since(args.since)
        events = [e for e in events if (e.get('at') or '') >= since]
    if args.until:
        until = normalise_since(args.until)
        events = [e for e in events if (e.get('at') or '') < until]
    print(report(events))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    gather = commands.add_parser('collect', help='read GitHub and write the event file')
    gather.add_argument('--since', required=True, help='YYYY-MM-DD (UTC) or YYYY-MM-DDTHH:MM:SSZ')
    gather.add_argument('--out', default=str(OUT), help='folder for events.jsonl (default artifacts/pipeline)')
    gather.add_argument('--catches', help='test-catches.jsonl (default: the lane state folder)')
    gather.add_argument('--no-runs', action='store_true', help='skip the Actions runs and jobs')
    gather.add_argument('--no-jobs', action='store_true', help='read the runs but not each run\'s jobs')
    gather.add_argument('--comments-file', help='read lane comments from this JSON file instead of GitHub (replay)')
    gather.set_defaults(run=command_collect)
    show = commands.add_parser('report', help='print the rates in the event file')
    show.add_argument('--out', default=str(OUT))
    show.add_argument('--since', help='only events at or after this date')
    show.add_argument('--until', help='only events before this date')
    show.set_defaults(run=command_report)
    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == '__main__':
    sys.exit(main())
