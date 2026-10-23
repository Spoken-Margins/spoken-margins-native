"""One machine-readable event line per lane report (#2378).

The lane's reports are prose, and the collector that measures the pipeline (#2376) had to parse it. Prose can't
tell a runner fault from a failure, doesn't say how long a step took or how long the request waited, and names no
test that ran. So each report now ends with a hidden comment, written from the step runs the job already holds:

    <!-- lane-event v1 {"v":1,"verdict":"PASS",...} -->

The line holds ids, enums and numbers only, never a path, an assertion message or a log line: every string in it
is built from a short pattern (a step name, a hex commit, a Module/Class[/method] test id), and a value that
doesn't match is dropped, not escaped. `parse` checks the same patterns, so a line someone else wrote into a
comment can't smuggle text through the collector. The visible report doesn't change.

Fields:
- verdict: PASS, FAIL or INCONCLUSIVE. `fault` is true for INCONCLUSIVE, the runner's own trouble, as opposed
  to a FAIL on the PR's code. Each step also says pass, fail or fault (lane_ledger.outcome).
- tier (auto, T2, T3), head and trunk (the commit the job tested against), seconds, and queue_seconds from the
  request to the job's start (null for an automerge run, whose request is a label).
- steps: [{step, result, seconds}] in the order they ran.
- tests: how many tests ran and failed. classes: {Module/Class: [ran, failed]}, and slowest: the 20 slowest tests
  as [id, seconds], both from the verify-tests.py manifests under the evidence folder.

The line is capped (MAX_BYTES). Over the cap, the passing classes go first, then the slowest list, then the failing
classes, so the verdict, steps and totals always fit. Stdlib only, Python 3.9-compatible: lane-runner.py runs under
/usr/bin/python3.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

VERSION = 1
MAX_BYTES = 6000
SLOWEST = 20
VERDICTS = ('PASS', 'FAIL', 'INCONCLUSIVE')
RESULTS = ('pass', 'fail', 'fault')
TIERS = ('auto', 'T2', 'T3')

LINE = re.compile(r'<!-- lane-event v(\d+) (\{.*?\}) -->')
STEP = re.compile(r'[A-Za-z][A-Za-z0-9 ()#.-]{0,39}')
COMMIT = re.compile(r'[0-9a-f]{7,40}')
CLASS = re.compile(r'\w{1,80}/\w{1,120}')
TEST = re.compile(r'\w{1,80}/\w{1,120}/\w{1,160}')


def _count(value) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def _seconds(value):
    """Whole seconds, or None when the value is not a non-negative number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value or value < 0:
        return None
    return int(round(value))


def test_records(evidence: Path) -> dict:
    """{test id: {'status', 'seconds'}} from the verify-tests.py manifests one folder below <evidence> (the host
    plans' and each T3 plan's). An id that isn't Module/Class/method is left out, so a log line can't enter."""
    records = {}
    for path in sorted(Path(evidence).glob('*/manifest.json')):
        try:
            manifest = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for step in manifest.get('steps', []) if isinstance(manifest, dict) else []:
            if not isinstance(step, dict) or step.get('superseded'):
                continue
            tests = step.get('tests')
            for name, record in (tests.items() if isinstance(tests, dict) else ()):
                if isinstance(record, dict) and record.get('status') != 'skipped' \
                        and isinstance(name, str) and TEST.fullmatch(name):
                    records[name] = record
    return records


def build(verdict: str, tier: str, head: str, trunk: str, seconds, queue_seconds, runs, records) -> dict:
    """The event for one lane report. runs: the job's step runs (lane-runner STEP_RUNS), records: test_records().
    Anything that doesn't fit the patterns is dropped."""
    import lane_ledger
    verdict = verdict if verdict in VERDICTS else 'INCONCLUSIVE'
    classes, slowest, ran, failed = {}, [], 0, 0
    for name, record in records.items():
        if not TEST.fullmatch(name):
            continue
        name_class = name.rsplit('/', 1)[0]
        entry = classes.setdefault(name_class, [0, 0])
        entry[0] += 1
        ran += 1
        if record.get('status') == 'failed':
            entry[1] += 1
            failed += 1
        took = _seconds(record.get('seconds'))
        if took is not None:
            slowest.append([name, took])
    slowest.sort(key=lambda item: (-item[1], item[0]))
    steps = []
    for run in runs:
        step, took = run.get('step'), _seconds(run.get('seconds'))
        if isinstance(step, str) and STEP.fullmatch(step) and took is not None:
            steps.append({'step': step,
                          'result': lane_ledger.outcome(run.get('verdict'), bool(run.get('zero_tests'))),
                          'seconds': took})
    event = {'v': VERSION, 'verdict': verdict, 'fault': verdict == 'INCONCLUSIVE',
             'tier': tier if tier in TIERS else 'auto',
             'head': head[:12] if COMMIT.fullmatch(head[:12] or '-') else '',
             'trunk': trunk[:12] if COMMIT.fullmatch(trunk[:12] or '-') else '',
             'seconds': _seconds(seconds) or 0, 'queue_seconds': _seconds(queue_seconds),
             'steps': steps, 'tests': {'ran': ran, 'failed': failed},
             'classes': dict(sorted(classes.items())), 'slowest': slowest[:SLOWEST]}
    return _fit(event)


def _fit(event: dict) -> dict:
    """Trim the event to MAX_BYTES: passing classes first, then the slowest list, then the failing classes."""
    def size():
        return len(json.dumps(event, sort_keys=True, separators=(',', ':')))
    if size() > MAX_BYTES:
        event['classes'] = {name: counts for name, counts in event['classes'].items() if counts[1]}
        event['classes_trimmed'] = True
    while size() > MAX_BYTES and event['slowest']:
        event['slowest'] = event['slowest'][:len(event['slowest']) // 2]
    while size() > MAX_BYTES and event['classes']:
        event['classes'].popitem()
    return event


def note(event: dict) -> str:
    """The hidden line for a report. JSON with ASCII escapes only, so it can't contain `-->`."""
    return f'<!-- lane-event v{VERSION} {json.dumps(event, sort_keys=True, separators=(",", ":"))} -->'


def parse(body: str):
    """The validated event in a report body, or None when there's no line or it doesn't fit the format. Unknown
    fields are dropped and a field that fails its pattern invalidates the line: a collector must not take text
    it can't trust from a comment."""
    match = LINE.search(body or '')
    if not match or int(match.group(1)) != VERSION:
        return None
    try:
        raw = json.loads(match.group(2))
    except ValueError:
        return None
    if not isinstance(raw, dict) or raw.get('v') != VERSION:
        return None
    try:
        steps = [{'step': _pattern(item['step'], STEP), 'result': _choice(item['result'], RESULTS),
                  'seconds': _count(item['seconds'])} for item in raw['steps']]
        tests = raw['tests']
        event = {'v': VERSION, 'verdict': _choice(raw['verdict'], VERDICTS), 'fault': raw['fault'] is True,
                 'tier': _choice(raw['tier'], TIERS), 'head': _pattern(raw['head'], COMMIT, True),
                 'trunk': _pattern(raw['trunk'], COMMIT, True), 'seconds': _count(raw['seconds']),
                 'queue_seconds': None if raw['queue_seconds'] is None else _count(raw['queue_seconds']),
                 'steps': steps, 'tests': {'ran': _count(tests['ran']), 'failed': _count(tests['failed'])},
                 'classes': {_pattern(name, CLASS): [_count(counts[0]), _count(counts[1])]
                             for name, counts in raw['classes'].items()},
                 'slowest': [[_pattern(name, TEST), _count(took)] for name, took in raw['slowest']]}
    except (KeyError, TypeError, ValueError, IndexError, AttributeError):
        return None
    if raw.get('classes_trimmed') is True:
        event['classes_trimmed'] = True
    return event


def _pattern(value, pattern, allow_empty: bool = False) -> str:
    if isinstance(value, str) and (pattern.fullmatch(value) or (allow_empty and value == '')):
        return value
    raise ValueError(value)


def _choice(value, choices):
    if value in choices:
        return value
    raise ValueError(value)


PROSE_TOP = re.compile(r'^Lane report (\S+) — (PASS|FAIL|INCONCLUSIVE)\s*$', re.M)
# Each piece on its own: an older report whose base was not a commit ("at unknown") still gives its head and tier.
PROSE_HEAD = re.compile(r'^commit ([0-9a-f]{7,40}) ', re.M)
PROSE_TRUNK = re.compile(r'^commit \S+ \(tested merged with \S+ at ([0-9a-f]{7,40})\)', re.M)
PROSE_TIER = re.compile(r'^commit .* · tier (T2|T3|auto) · ', re.M)


def collect(body: str):
    """The event for a lane report: the line when it has a valid one, else what the prose gives (verdict, tier,
    head and trunk; no steps, no test counts), marked 'source': 'prose'. None when the body isn't a lane report.

    It doesn't look at who wrote the comment: a caller reads only comments that scripts/comment_trust.py trusts (#1822)."""
    event = parse(body)
    if event:
        return dict(event, source='line')
    top = PROSE_TOP.search(body or '')
    if not top:
        return None
    head, trunk, tier = (pattern.search(body) for pattern in (PROSE_HEAD, PROSE_TRUNK, PROSE_TIER))
    return {'v': VERSION, 'verdict': top.group(2), 'fault': top.group(2) == 'INCONCLUSIVE',
            'tier': tier.group(1) if tier else 'auto', 'head': head.group(1) if head else '',
            'trunk': trunk.group(1) if trunk else '',
            'seconds': None, 'queue_seconds': None, 'steps': [], 'tests': None, 'classes': {}, 'slowest': [],
            'source': 'prose'}
