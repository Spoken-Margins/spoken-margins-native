#!/usr/bin/env python3
"""Test each new tip of the trunk (origin/main) with --plan app, unattended and without a model (#1178).

Stdlib only, Python 3.9+. launchd ticks every 10 minutes. A tip is tested once, by whoever
reports first on #184, when the Mac has room and no lane app tests are waiting for the simulator. Failing tests are re-run twice on the same build
to rule out a flake. Only a confirmed failure calls Claude (`claude -p`, read-only tools,
structured output) to group the failures; the script finds the culprit merge by re-running the failing
tests at the commits since the last PASS (integration_revert.py), opens the revert PR and files the issues
itself. No job is installed by this script; see README.md.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import sm_paths  # noqa: E402
from trunk import trunk_branch  # noqa: E402  (#1492: the branch it tests)

REPO = os.environ.get('SM_INTEGRATION_REPO', 'Spoken-Margins/spoken-margins-native')
REPO_ROOT = sm_paths.repo(__file__)                      # the public checkout it tests (SM_REPO)
HOME_DIR = Path(os.environ.get('SM_INTEGRATION_HOME') or sm_paths.state_dir('integration-run'))
BASE_BRANCH = trunk_branch()
REPORT_ISSUE = 184
RUN_BY = 'integration script'
HOSTED_RUN_BY = 'hosted integration'   # hosted-integration.yml on a GitHub-hosted Mac (#1389)
HOSTED_VARIABLE = 'LANE_HOSTED_APP'    # the repository variable that switches hosted app tests on
HOSTED_WORKFLOW = 'hosted-integration.yml'
HOSTED_GRACE_SECONDS = 5 * 60        # how long a new tip waits for its hosted run to appear before the Mac tests it
LANE_YIELD_SECONDS = 3 * 60 * 60     # lane app tests go first, unless next has gone this long untested
MIN_FREE_GB = 10
PER_BUILD_GB = 4
RERUNS = 2
REPORT_LOOKBACK = dt.timedelta(days=7)
KEEP_EVIDENCE = 20
FAIL_LABELS = 'ready,priority,bug,regression'
CLAUDE = Path(os.environ.get('SM_CLAUDE_CLI', Path.home() / '.local' / 'bin' / 'claude'))
KEYCHAIN_SERVICE = 'claude-code-oauth'
CLAUDE_MODEL = 'opus'
CLAUDE_TOOLS = 'Read,Grep,Glob'
CLAUDE_BUDGET_USD = '10'
CLAUDE_TIMEOUT_S = 30 * 60
NOT_VERIFIED = "not verified (owner's phone): audible content, Bluetooth, Lock Screen, background behaviour"
NOT_RUN = 'not run: agent-driven journeys (they need an attended session)'

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(REPO_ROOT / 'scripts'))
import comment_trust  # noqa: E402  (#1822: whose comments and issues the desk believes)
import integration_revert as revert  # noqa: E402
import journey_promotion  # noqa: E402
import lane_ledger  # noqa: E402
import lane_slots  # noqa: E402
import sim_builds  # noqa: E402  (ready-made simulator builds for desks)
from lane_xcresult_attachments import report_lines  # noqa: E402

REPORT_RE = re.compile(r'^Lane report integration-([0-9a-f]{7,40}) — (PASS|FAIL|INCONCLUSIVE)\b')
LANE_REQUEST_RE = re.compile(r'^\s*/lane\s+T(\d)\b', re.M)  # as scripts/lane-runner.py reads requests
WAITING_STATUSES = {'queued', 'waiting', 'pending', 'requested'}


# Pure decisions and text: no simulator, GitHub or Claude needed in host tests.

def reported(bodies: list[str]) -> list[tuple[str, str]]:
    """(sha7, verdict) for each integration report on #184, oldest first, whoever ran it.

    Reports sit inside a ```text fence, so the fence and blank lines before the first line are
    skipped, as scripts/phone-build reads them."""
    found = []
    for body in bodies:
        lines = [line.strip().replace('**', '') for line in (body or '').splitlines()]
        first = next((line for line in lines if line and not line.startswith('```')), '')
        match = REPORT_RE.match(first)
        if match:
            found.append((match.group(1)[:7], match.group(2)))
    return found


def last_green(reports: list[tuple[str, str]]) -> Optional[str]:
    return next((sha7 for sha7, verdict in reversed(reports) if verdict == 'PASS'), None)


def report_time(comments: list[dict]) -> Optional[float]:
    """When the newest integration report on #184 was posted, whoever ran it."""
    times = [dt.datetime.fromisoformat(c['created_at'].replace('Z', '+00:00')).timestamp()
             for c in comments if reported([c['body']])]
    return max(times, default=None)


def hosted_fail_to_handle(comments: list[dict], handled: dict) -> Optional[dict]:
    """The newest hosted integration report, when it is a confirmed FAIL the Mac hasn't handled yet (#1389).

    Hosted runs never search for the culprit, revert or file issues (a PR opened with the job's token starts
    no workflows, and there is no Claude token there), so the Mac does that for them. Only the newest hosted
    report counts: an older FAIL that a newer tip superseded is not chased. A FAIL that names no failing test
    gives the search nothing to re-run, so it is left alone too."""
    newest = None
    for c in comments:
        if reported([c['body']]) and re.search(rf'^run by: {re.escape(HOSTED_RUN_BY)}\s*$', c['body'], re.M):
            newest = c
    if not newest:
        return None
    sha7, verdict = reported([newest['body']])[0]
    failed = failing_tests(newest['body'])
    if verdict != 'FAIL' or sha7 in handled or not failed:
        return None
    return {'sha7': sha7, 'failed': failed, 'report': newest.get('html_url') or f'#{REPORT_ISSUE}'}


def hosted_cover(sha: str, reports_by_hosted: list[str], runs: Optional[list[dict]], tip_age: float) -> tuple[bool, str]:
    """Whether the hosted run has this tip, and why (#2127). Pushes made with the workflow token (the lane
    runner's merges) start no workflows, so a tip can have no hosted run at all; the Mac must not take its
    silence for a pass. Covered: a hosted report for the tip, or a run for it not yet finished. A run that
    finished without a report, no run at all, or an unreadable run list leaves the tip to the Mac, after a
    short grace for a run GitHub hasn't listed yet."""
    if sha[:7] in reports_by_hosted:
        return True, f'the hosted run reported {sha[:7]}'
    if runs is None:
        return False, f'the {HOSTED_WORKFLOW} runs could not be read'
    live = [r for r in runs if r.get('status') != 'completed']
    if live:
        return True, f"a {HOSTED_WORKFLOW} run for {sha[:7]} is {live[0].get('status')}"
    if runs:
        return False, (f'the {HOSTED_WORKFLOW} run for {sha[:7]} finished '
                       f"({runs[0].get('conclusion')}) without a report")
    if tip_age < HOSTED_GRACE_SECONDS:
        return True, f'{sha[:7]} landed {tip_age / 60:.0f} min ago; waiting for its {HOSTED_WORKFLOW} run'
    return False, f'{sha[:7]} has no {HOSTED_WORKFLOW} run (a push by the workflow token starts none)'


def failing_tests(body: str) -> list[str]:
    """The tests on a report's `failing:` line (report_text writes it)."""
    match = re.search(r'^failing: (.+)$', body or '', re.M)
    return [t.strip() for t in match.group(1).split(',') if t.strip()] if match else []


def lane_requests_waiting(runs: list[dict]) -> list[int]:
    """PRs with a /lane request waiting for a lane runner, from lane.yml's run names (#860 format)."""
    prs = []
    for r in runs:
        match = re.search(r'\bpr=(\d+)\b.*\blane=true\b', r.get('displayTitle') or '')
        if r.get('status') in WAITING_STATUSES and match and int(match.group(1)) not in prs:
            prs.append(int(match.group(1)))
    return prs


def needs_simulator(comment_bodies: list[str]) -> bool:
    """Whether a PR's newest /lane request is T3 or above (app tests on a simulator), not a T2 build."""
    tiers = [int(m) for body in comment_bodies for m in LANE_REQUEST_RE.findall(body or '')]
    return bool(tiers) and tiers[-1] >= 3


def hold_reason(sha: str, state: dict, reports: list[tuple[str, str]], now: float,
                pressure: Optional[int], free_bytes: int, builds: int, slot_busy: bool,
                lane_waiting: list[int] = (), last_tested: Optional[float] = None) -> Optional[str]:
    """Why this tick tests nothing, or None. Cheapest and most final reasons first.

    There is no fixed spacing: a new tip is tested as soon as the Mac has room. Lane app tests
    waiting for the simulator go first, because they decide what merges, unless next has gone
    LANE_YIELD_SECONDS without an integration run (a busy lane must not starve it)."""
    if sha in state.get('results', {}):
        return 'already tested ' + sha[:7]
    if any(sha7 == sha[:7] for sha7, _ in reports):
        return f'#{REPORT_ISSUE} already has an integration report for {sha[:7]}'
    return room_reason(now, pressure, free_bytes, builds, slot_busy, lane_waiting, last_tested)


def room_reason(now: float, pressure: Optional[int], free_bytes: int, builds: int, slot_busy: bool,
                lane_waiting: list[int] = (), last_tested: Optional[float] = None) -> Optional[str]:
    """Why the Mac has no room for a simulator run now, or None."""
    if pressure != 1:
        return f"memory pressure is {lane_slots.PRESSURE_NAMES.get(pressure, 'unreadable')}, not normal"
    need = MIN_FREE_GB + PER_BUILD_GB * builds
    if free_bytes < need * 10**9:
        return f'{free_bytes / 10**9:.0f} GB free, needs {need} GB ({builds} build(s) running)'
    if slot_busy:
        return 'Mac-wide simulator slot is busy'
    if lane_waiting and last_tested is not None and now - last_tested < LANE_YIELD_SECONDS:
        return ('lane app tests are waiting (' + ', '.join(f'#{n}' for n in lane_waiting)
                + '); they go first')
    return None


def summarize(manifest: dict) -> dict:
    """One plan's verdict. Infrastructure trouble is INCONCLUSIVE, never a listener bug."""
    counts = dict.fromkeys(('passed', 'failed', 'skipped'), 0)
    failed, journeys, errors, attachments, crashes = [], {}, [], [], []
    statuses = {}
    incomplete = False
    for step in manifest.get('steps', []):
        errors.extend(step.get('errors', []))
        attachments.extend(step.get('attachments', []))
        crashes.extend(step.get('simulator_crash_reports', []))
        incomplete |= bool(step.get('interrupted') or step.get('simulator_crash_report')
                           or step.get('exit_code') == 124)
        probation = step.get('probation', {})
        journeys.update(step.get('gating', {}))
        journeys.update(probation)
        for name, record in step.get('tests', {}).items():
            status = record['status']
            if status in counts:
                counts[status] += 1
            if name not in probation:
                statuses[name] = status
                if status == 'failed':
                    failed.append(name)
    if incomplete:
        verdict = 'INCONCLUSIVE'
    elif failed:
        verdict = 'FAIL'
    elif manifest.get('status') == 'verified':
        verdict = 'PASS'
    else:
        verdict = 'INCONCLUSIVE'
    return {'verdict': verdict, 'counts': counts, 'failed': sorted(set(failed)), 'tests': statuses,
            'journeys': journeys, 'attachments': attachments, 'crashes': crashes,
            'errors': errors + ([manifest['error']] if manifest.get('error') else [])}


def settle(first: dict, reruns: list[dict]) -> dict:
    """Apply the flake rule to a FAIL: a test that passed in a completed re-run on the same build is flaky.

    A re-run that stopped (INCONCLUSIVE) is no information either way: it can't clear a test, and it can't
    keep a failure confirmed that another re-run's pass has already cleared (#1417). A test that passed in
    one re-run and failed in another is flaky too, but `flaky_notes` says so, because an order-dependent
    failure looks the same."""
    if first['verdict'] != 'FAIL':
        return dict(first, flaky=[])
    completed = [r for r in reruns if r['verdict'] != 'INCONCLUSIVE']
    flaky, notes = [], {}
    for test in first['failed']:
        passes = sum(1 for r in completed if r['tests'].get(test) == 'passed')
        if not passes:
            continue
        flaky.append(test)
        if any(r['tests'].get(test) == 'failed' for r in completed):
            notes[test] = f' (passed in {passes} of {len(completed)} re-runs, failed in the rest)'
    confirmed = [t for t in first['failed'] if t not in flaky]
    return dict(first, verdict='FAIL' if confirmed else 'PASS', failed=confirmed, flaky=flaky, flaky_notes=notes,
                errors=first['errors'] + [e for r in reruns for e in r['errors']] if confirmed else first['errors'])


def script_results(listing: dict, records: dict) -> dict:
    """One outcome per listed scripted journey, including class selectors and unrun scripts."""
    results = {}
    for status in ('gating', 'probation'):
        for entry in listing.get(status, []):
            selector = entry['test'].removesuffix('()')
            covered = [s for t, s in records.items() if t == selector or t.startswith(selector + '/')]
            results[selector] = next((s for s in ('failed', 'missing', 'skipped', 'passed')
                                      if s in covered), 'not_run')
    return results


def scripted_summary(journeys: dict) -> str:
    """The candidate line's words on scripted journeys. "Passed" is only said when every listed script passed;
    otherwise each outcome is counted, so a skipped or unrun script is never rolled into a pass (#1901)."""
    if not journeys:
        return 'scripted journeys not run'
    counts = {'passed': 0, 'failed': 0, 'skipped': 0, 'not run': 0}
    failing = []
    for test, status in sorted(journeys.items()):
        if status == 'passed':
            counts['passed'] += 1
        elif status in ('failed', 'missing'):
            counts['failed'] += 1
            failing.append(test.rsplit('/', 1)[-1])
        elif status == 'skipped':
            counts['skipped'] += 1
        else:
            counts['not run'] += 1
    if counts['passed'] == len(journeys):
        return f"scripted journeys passed ({counts['passed']} of {len(journeys)})"
    if counts['not run'] == len(journeys):
        return 'scripted journeys not run'
    words = ', '.join(f'{n} {name}' for name, n in counts.items())
    return f"scripted journeys {words}" + (f" (failed: {', '.join(failing)})" if failing else '')


def clock(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime('%H:%M')


def report_text(sha: str, result: dict, *, started: float, finished: float, previous: Optional[str],
                suspects: list[str], evidence, hosted: bool = False) -> str:
    c = result['counts']
    day = dt.datetime.fromtimestamp(started).strftime('%Y-%m-%d')
    why = (f'next moved from {previous}, the last tip with an integration report' if previous
           else f'no integration report on #{REPORT_ISSUE} in the last {REPORT_LOOKBACK.days} days')
    lines = ['```text',
             f"Lane report integration-{sha[:7]} — {result['verdict']}",
             f'commit {sha[:8]} (next\'s tip) · integration run: --plan app · '
             f'{clock(started)}–{clock(finished)} local, {day}',
             f'run by: {HOSTED_RUN_BY if hosted else RUN_BY}',
             f'why it ran: {why}; ' + ('a push to next started hosted-integration.yml on a GitHub-hosted Mac.'
                                       if hosted else
                                       'the Mac had room (simulator slot free, memory normal, disk above the line) '
                                       'and no lane app tests were waiting, or next had gone 3 hours untested.'),
             'ran:',
             f"  1. --plan app: {c['passed']} passed, {c['failed']} failed, {c['skipped']} skipped  ← verdict input"]
    if result.get('reruns'):
        lines.append(f"  2. failing tests re-run {result['reruns']} times on the same build")
    if result.get('journeys'):
        lines.append('  scripted journeys (only those on gating are verdict input): '
                     + ', '.join(f'{t.rsplit("/", 1)[-1]} {s}' for t, s in sorted(result['journeys'].items())))
        if result.get('journeys_due'):
            lines.append('  ' + result['journeys_due'])
    if result['failed']:
        lines.append('failing: ' + ', '.join(result['failed']))
    notes = result.get('flaky_notes', {})
    lines.append('flaky: ' + (', '.join(t + notes.get(t, '') for t in result['flaky']) if result.get('flaky')
                              else 'none this run'))
    lines.append('crashes: ' + (', '.join(Path(p).name for p in result['crashes'])
                                if result.get('crashes') else 'none recorded'))
    if result['verdict'] == 'FAIL':
        lines.append('merges since the last PASS: ' + (', '.join(suspects) if suspects else 'unknown'))
    if result['verdict'] == 'INCONCLUSIVE' and result['errors']:
        lines.append('why inconclusive: ' + '; '.join(dict.fromkeys(result['errors']))[:1500])
    lines += [NOT_RUN, NOT_VERIFIED, f'evidence: {evidence}', '```']
    if result.get('attachments'):
        lines += ['', *report_lines(result['attachments'])]
    if result['verdict'] == 'PASS':
        # Say what the pass covers: app tests alone are not a full candidate (#1465).
        journeys = result.get('journeys') or {}
        scripted = scripted_summary(journeys)
        lines += ['', f'{sha[:7]} is the current phone candidate: app tests passed; {scripted}; '
                      'attended journeys not run.']
    return '\n'.join(lines) + '\n'


def dedupe_query(test: str) -> str:
    # GitHub indexes words, not XCTest's slash-separated ID. Quote the method;
    # then verify a token match in the returned issue body/title.
    name = test.rsplit('/', 1)[-1].removesuffix('()')
    return 'is:issue is:open "' + re.sub(r'[^A-Za-z0-9_]', '', name) + '"'


def find_duplicate(issues: list[dict], tests: list[str],
                   all_comments: Optional[Callable[[int], str]] = None) -> Optional[int]:
    """The first open issue that is a failure report for one of the tests (the report issue never counts).

    Naming a test is not enough: a design issue can cite one as an example, and a comment posted there files
    nothing (#1871). An issue is a failure report when it carries `regression` (part of FAIL_LABELS, which
    every filed failure gets) and names the test, or when a "Failing tests:" line in its body or comments
    names the test, as the runs' own issues and an earlier run's comment do. The `regression` label alone is
    not enough, because a regression about something else may still mention the test in passing.

    `issues` are REST issue objects, which carry `author_association`, `user.login` and labels; `gh issue list
    --json` has no association field. Only the team's issues count (#1822), and `all_comments(number)` returns the
    text of that issue's trusted comments, read only when the title and body don't already settle it and the issue
    has some."""
    names = [t.rsplit('/', 1)[-1].removesuffix('()') for t in tests]

    def names_a_test(text: str) -> bool:
        return any(re.search(r'(?<!\w)' + re.escape(name) + r'(?!\w)', text) for name in names)

    def lists_a_failing_test(text: str) -> bool:
        return any(line.startswith('Failing tests:') and names_a_test(line) for line in text.splitlines())

    def is_failure_report(issue: dict, text: str) -> bool:
        labels = {(label.get('name') if isinstance(label, dict) else label) for label in issue.get('labels') or []}
        return lists_a_failing_test(text) or ('regression' in labels and names_a_test(text))

    for issue in issues:
        if issue['number'] == REPORT_ISSUE or not comment_trust.trusted(issue):
            continue  # #1822: a stranger's issue naming a test must not swallow the failure report
        text = '\n'.join([issue.get('title') or '', issue.get('body') or ''])
        if is_failure_report(issue, text):
            return issue['number']
        if all_comments is not None and (issue.get('comments') or 0):
            if is_failure_report(issue, text + '\n' + all_comments(issue['number'])):
                return issue['number']
    return None


GROUP_KEYS = ('title', 'steps', 'expected', 'actual', 'root_cause', 'suspect')
DIAGNOSIS_SCHEMA = {
    'type': 'object', 'required': ['groups'],
    'properties': {'groups': {'type': 'array', 'items': {
        'type': 'object', 'required': ['tests', *GROUP_KEYS],
        'properties': {'tests': {'type': 'array', 'items': {'type': 'string'}},
                       **{k: {'type': 'string'} for k in GROUP_KEYS}}}}}}


def fallback_groups(failed: list[str]) -> list[dict]:
    return [{'tests': [t], 'title': f'{t.rsplit("/", 1)[-1]} fails on next',
             'steps': f'Run `--plan app --only-testing {t}` at the tip below.',
             'expected': 'The test scenario passes its assertions.',
             'actual': 'The scenario fails an assertion in the first run and in both re-runs; '
                       'see xcode-tests.log in the evidence folder.',
             'root_cause': 'Unconfirmed: the Claude diagnosis was unavailable or invalid. Read the test and evidence.',
             'suspect': 'unknown'}
            for t in failed]


def diagnoses(answer: Optional[dict], failed: list[str]) -> list[dict]:
    """Accept only a complete partition of the observed failures; fall back to one issue per test."""
    try:
        groups, seen = answer['groups'], []
        for group in groups:
            if not isinstance(group['tests'], list) or not group['tests'] or not all(
                    isinstance(group[k], str) and group[k].strip() for k in GROUP_KEYS):
                raise ValueError('missing fields')
            seen.extend(group['tests'])
        if sorted(seen) != sorted(failed):
            raise ValueError('not a partition')
        return groups
    except (ValueError, TypeError, KeyError):
        return fallback_groups(failed)


def diagnosis_prompt(sha: str, failed: list[str], suspects: list[str], evidence: Path) -> str:
    return '\n'.join([
        'You are diagnosing confirmed test failures on the merged tip of the trunk (`main`) for Spoken Margins.',
        'Read AGENTS.md first. You are read-only: read the failing tests, the code they exercise and the',
        f'evidence logs under {evidence} (xcode-tests.log in each plan folder). Each test below failed in',
        f'the first run and in {RERUNS} re-runs on the same build, so treat it as real, not flaky.',
        'Group tests only when they share a root cause. For each group give a symptom title a listener',
        'would recognise, the steps, expected and actual behaviour, the root cause (mark what is inference),',
        'and the suspect: the merge below most likely to have caused it, as "#<PR>: <why>", or "unknown".',
        'Every failing ID must appear in exactly one group. Do not invent evidence.',
        '', f'Tip: {sha}', 'Failing IDs:', *[f'- {t}' for t in failed],
        'Merges into next since the last PASS (newest first):', *([f'- {s}' for s in suspects] or ['- unknown'])])


def claude_command(evidence: Path) -> list[str]:
    """Headless, read-only and unable to ask: anything outside the three read tools is refused."""
    return [str(CLAUDE), '-p', '-', '--output-format', 'json', '--model', CLAUDE_MODEL,
            '--permission-mode', 'dontAsk', '--tools', CLAUDE_TOOLS, '--strict-mcp-config',
            '--setting-sources', 'project', '--no-session-persistence',
            '--max-budget-usd', CLAUDE_BUDGET_USD, '--add-dir', str(evidence),
            '--json-schema', json.dumps(DIAGNOSIS_SCHEMA)]


def issue_text(group: dict, sha: str, report: str, evidence: Path, cost: Optional[float]) -> str:
    return '\n'.join([
        f"Failing tests: {', '.join('`' + t + '`' for t in group['tests'])}", '',
        '## Steps', group['steps'], '', '## Expected', group['expected'], '',
        '## Actual', group['actual'], '', '## Root cause (Claude inference)', group['root_cause'], '',
        '## Suspect', group['suspect'], '',
        f'Tip SHA: `{sha}`', 'Build: next at the SHA above (unreleased integration tip).',
        f'Integration report: {report}', f'Evidence on the Mac: `{evidence}`',
        f"Diagnosis cost: ${cost:.2f} (API-equivalent)" if cost is not None else 'Diagnosis: none (fallback text)',
        '', NOT_VERIFIED, ''])


# Side effects: git, gh, simulator, Keychain, Claude.

class Result:
    def __init__(self, returncode: int, stdout: str = '', stderr: str = ''):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def kill_tree(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=20)
    except Exception:
        with contextlib.suppress(Exception):
            os.killpg(proc.pid, signal.SIGKILL)


def default_run(cmd: list, cwd: Optional[Path] = None, timeout: Optional[float] = 300,
                stdin: Optional[str] = None, env: Optional[dict] = None) -> Result:
    proc = subprocess.Popen([str(c) for c in cmd], cwd=str(cwd) if cwd else None, env=env,
                            stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            encoding='utf-8', errors='replace', start_new_session=True)
    try:
        out, err = proc.communicate(input=stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        out, err = proc.communicate()
        return Result(124, out or '', (err or '') + f'\ntimed out after {timeout}s')
    return Result(proc.returncode, out, err)


@contextlib.contextmanager
def exclusive_slot():
    """Reserve the simulator nonblocking under the lane's decision lock, as the Codex Test Desk did.

    Both descriptors go to verify-tests so a parent exit cannot unlock a running child."""
    folder = lane_slots.state_dir()
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / lane_slots.SIMULATOR_DECISION).open('a+') as decision:
        try:
            fcntl.flock(decision, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise TimeoutError('simulator slot decision is busy') from None
        if lane_slots.simulator_job_running():
            raise TimeoutError('Mac-wide simulator slot is busy')
        handle, _, _ = lane_slots.acquire([lane_slots.SIMULATOR_SLOT], 'simulator slot',
                                         'Integration script', max_wait=0)
        try:
            yield (handle.fileno(), decision.fileno())
        finally:
            lane_slots.release_handle(handle)


class Ops:
    def __init__(self, home: Path = HOME_DIR, repo_root: Path = REPO_ROOT,
                 run: Callable = default_run, echo: bool = True):
        self.home, self.repo_root, self.run, self.echo = home, repo_root, run, echo

    def now(self) -> float:
        return time.time()

    def log(self, msg: str) -> None:
        line = f'{dt.datetime.now().astimezone().isoformat(timespec="seconds")} {msg}'
        if self.echo:
            print(line)
        self.home.mkdir(parents=True, exist_ok=True)
        with (self.home / 'log.txt').open('a') as f:
            f.write(line + '\n')

    def must(self, cmd: list, cwd: Optional[Path] = None, timeout: Optional[float] = 300) -> Result:
        res = self.run(cmd, cwd=cwd or self.repo_root, timeout=timeout)
        if res.returncode:
            raise RuntimeError(f'{" ".join(map(str, cmd[:4]))} failed: {(res.stderr or res.stdout)[-400:]}')
        return res

    def gh_json(self, args: list):
        return json.loads(self.must(['gh', *args]).stdout or 'null')

    def report_comments(self) -> list[dict]:
        """#184's recent comments, oldest first, as {'created_at', 'body', 'html_url'}."""
        since = (dt.datetime.now(dt.timezone.utc) - REPORT_LOOKBACK).strftime('%Y-%m-%dT%H:%M:%SZ')
        out = self.must(['gh', 'api', '--paginate',
                         f'repos/{REPO}/issues/{REPORT_ISSUE}/comments?since={since}&per_page=100',
                         '--jq', '.[] | {created_at, body, html_url, author_association, user: {login: .user.login}} | @json']).stdout
        return comment_trust.trusted_only([json.loads(line) for line in out.splitlines() if line.strip()])

    def hosted_on(self) -> bool:
        """Whether hosted app tests are switched on (#1389). Any trouble reading the variable counts as off,
        so a GitHub outage leaves the Mac testing as before."""
        res = self.run(['gh', 'api', f'repos/{REPO}/actions/variables/{HOSTED_VARIABLE}', '--jq', '.value'], timeout=60)
        return res.returncode == 0 and res.stdout.strip() == 'on'

    def hosted_runs(self, sha: str) -> Optional[list[dict]]:
        """hosted-integration runs for this commit, newest first, as {'status', 'conclusion'}; None when GitHub
        can't be read, which leaves the tip to the Mac."""
        res = self.run(['gh', 'api', f'repos/{REPO}/actions/workflows/{HOSTED_WORKFLOW}/runs?head_sha={sha}&per_page=20',
                        '--jq', '[.workflow_runs[] | {status, conclusion}]'], timeout=60)
        if res.returncode:
            self.log('hosted runs unreadable: ' + (res.stderr or res.stdout)[-200:])
            return None
        try:
            return json.loads(res.stdout or '[]')
        except ValueError:
            return None

    def commit_time(self, sha: str) -> float:
        return float(self.must(['git', 'log', '-1', '--format=%ct', sha]).stdout.strip())

    def lane_waiting(self) -> list[int]:
        """PRs whose waiting /lane request needs the simulator. A GitHub error counts as none
        waiting: the simulator slot itself is still taken exclusively, so the lane can't be hurt."""
        try:
            runs = self.gh_json(['run', 'list', '-R', REPO, '--workflow', 'lane.yml', '--limit', '50',
                                 '--json', 'status,displayTitle'])
            return [n for n in lane_requests_waiting(runs or [])
                    if needs_simulator([c.get('body') or '' for c in comment_trust.trusted_only(json.loads(self.must(
                        ['gh', 'api', '--paginate', f'repos/{REPO}/issues/{n}/comments',
                         '--jq', '[.[] | {body, author_association, user: {login: .user.login}}]']).stdout or '[]'))])]
        except (RuntimeError, ValueError) as error:
            self.log('lane queue unreadable, not waiting for it: ' + str(error)[:200])
            return []

    def free_bytes(self) -> int:
        return shutil.disk_usage(self.repo_root).free

    def builds_running(self) -> int:
        res = self.run(['pgrep', '-x', 'xcodebuild'], timeout=10)
        return len(res.stdout.split()) if res.returncode == 0 else 0

    def suspects(self, sha: str, green: Optional[str]) -> list[str]:
        """First-parent merges into next after the last PASS, newest first ('#123 title')."""
        if not green:
            return []
        res = self.run(['git', 'log', '--first-parent', '--merges', '--format=%s', f'{green}..{sha}'],
                       cwd=self.repo_root, timeout=60)
        if res.returncode:
            return []
        found = []
        for subject in res.stdout.splitlines():
            match = re.match(r'Merge pull request #(\d+)[: ]\s*(?:from \S+\s*)?(.*)', subject)
            found.append(f'#{match.group(1)} {match.group(2)}'.strip() if match else subject)
        return found

    def test_plan(self, wt: Path, output: Path, plan: str, fds: tuple, only: tuple = ()) -> dict:
        cmd = ['.venv/bin/python', 'scripts/verify-tests.py', '--plan', plan,
               '--output', str(output), '--simulator-slot-fd', str(fds[0])]
        cmd += [arg for test in only for arg in ('--only-testing', test)]
        if os.environ.get('SM_INTEGRATION_IOS'):  # a hosted image ships its own runtimes (hosted-integration.yml)
            cmd += ['--ios', os.environ['SM_INTEGRATION_IOS']]
        env = {k: v for k, v in os.environ.items() if k != 'CODEX_SANDBOX'}
        output.parent.mkdir(parents=True, exist_ok=True)
        # verify-tests owns timeouts, crash handling and shutdown; no outer timeout may cut its cleanup.
        with (output.parent / f'{output.name}-runner.log').open('w') as log:
            result = subprocess.run(cmd, cwd=wt, env=env, pass_fds=fds,
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        path = output / 'manifest.json'
        if not path.exists():
            return {'status': 'failed_or_incomplete', 'steps': [],
                    'error': f'{plan}: runner exit {result.returncode}, no manifest; see {output.name}-runner.log'}
        return json.loads(path.read_text())

    def post_report(self, body: str, evidence: Path) -> str:
        path = evidence / 'report.md'
        path.write_text(body)
        res = self.must(['gh', 'api', '--method', 'POST',
                         f'repos/{REPO}/issues/{REPORT_ISSUE}/comments', '-F', f'body=@{path}'])
        return json.loads(res.stdout)['html_url']

    def claude_token(self) -> Optional[str]:
        res = self.run(['/usr/bin/security', 'find-generic-password', '-s', KEYCHAIN_SERVICE, '-w'], timeout=30)
        token = res.stdout.strip() if res.returncode == 0 else ''
        return token or None

    def diagnose(self, wt: Path, evidence: Path, sha: str, failed: list[str],
                 suspects: list[str]) -> tuple[list[dict], Optional[float]]:
        token = self.claude_token()
        if not token or not CLAUDE.exists():
            self.log('diagnosis skipped: ' + ('no Claude token in the Keychain' if not token else f'{CLAUDE} missing'))
            return fallback_groups(failed), None
        prompt = diagnosis_prompt(sha, failed, suspects, evidence)
        (evidence / 'diagnosis-prompt.txt').write_text(prompt)
        env = {k: v for k, v in os.environ.items() if k != 'ANTHROPIC_API_KEY'}
        env['CLAUDE_CODE_OAUTH_TOKEN'] = token
        res = self.run(claude_command(evidence), cwd=wt, timeout=CLAUDE_TIMEOUT_S, stdin=prompt, env=env)
        (evidence / 'diagnosis.json').write_text(res.stdout or '')
        try:
            answer = json.loads(res.stdout)
        except ValueError:
            self.log(f'diagnosis failed: exit {res.returncode}: {(res.stderr or res.stdout)[-300:]}')
            return fallback_groups(failed), None
        cost = answer.get('total_cost_usd')
        if answer.get('is_error'):
            self.log(f"diagnosis failed: {answer.get('subtype')}: {str(answer.get('result'))[:300]}")
            return fallback_groups(failed), cost
        return diagnoses(answer.get('structured_output'), failed), cost

    # Culprit search and revert (#1180)

    def commits_since(self, green: str, sha: str) -> list[dict]:
        """First-parent commits after the last PASS up to the tip, oldest first."""
        res = self.run(['git', 'log', '--first-parent', '--reverse', '--format=%H%x1f%P%x1f%s%x1f%b%x1e',
                        f'{green}..{sha}'], cwd=self.repo_root, timeout=60)
        if res.returncode:
            raise RuntimeError('git log failed: ' + (res.stderr or '')[-200:])
        commits = []
        for record in res.stdout.split('\x1e'):
            if record.strip():
                full, parents, subject, body = (record.strip('\n').split('\x1f') + ['', '', '', ''])[:4]
                commits.append({'sha': full, 'parents': parents.split(), 'subject': subject, 'body': body})
        return commits

    def check_commit(self, wt: Path, evidence: Path, commit: dict, failed: list[str], fds: tuple) -> str:
        self.must(['git', 'checkout', '--quiet', '--force', '--detach', commit['sha']], cwd=wt)
        summary = summarize(self.test_plan(wt, evidence / f"culprit-{commit['sha'][:7]}", 'app', fds, tuple(failed)))
        return revert.check_verdict(failed, summary)

    def changed_paths(self, commit: dict) -> list[str]:
        out = self.must(['git', 'diff', '--name-only', '--no-renames', f"{commit['sha']}^1", commit['sha']], timeout=60).stdout
        return [line for line in out.splitlines() if line.strip()]

    def open_revert_prs(self) -> list[str]:
        prs = self.gh_json(['pr', 'list', '-R', REPO, '--state', 'open', '--base', BASE_BRANCH, '--limit', '100',
                            '--json', 'number,title'])
        return [f"#{pr['number']}" for pr in prs or [] if re.match(r'\s*Revert\b', pr.get('title') or '', re.I)]

    def reverted_on_base(self, merge_sha: str) -> Optional[str]:
        res = self.run(['git', 'log', '--format=%H', '-n1', '--fixed-strings',
                        f'--grep=This reverts commit {merge_sha}', f'origin/{BASE_BRANCH}'], cwd=self.repo_root, timeout=60)
        return res.stdout.strip() or None if res.returncode == 0 else None

    def comment(self, number: int, text: str, evidence: Path, name: str) -> None:
        path = evidence / name
        path.write_text(text)
        self.must(['gh', 'api', '--method', 'POST', f'repos/{REPO}/issues/{number}/comments', '-F', f'body=@{path}'])

    def open_revert(self, wt: Path, evidence: Path, commit: dict, sha: str, report: str, failed: list[str],
                    checks: list, prose: list[str]) -> tuple[Optional[str], str]:
        """Revert the culprit merge on the newest next in `wt`, push revert/pr<N>, open the PR with automerge and
        file the re-land issue. Returns (the PR url, '') or (None, why not); nothing is pushed on a failure."""
        number = revert.pr_number(commit['subject'])
        title = revert.pr_title(commit['subject'], commit['body'])
        branch = revert.revert_branch(number)
        git = lambda *args, **kw: self.run(['git', *args], cwd=wt, timeout=kw.get('timeout', 300))  # noqa: E731
        try:
            self.must(['git', 'fetch', '--quiet', 'origin', BASE_BRANCH], timeout=600)
            self.must(['git', 'checkout', '--quiet', '--force', '-B', branch, f'origin/{BASE_BRANCH}'], cwd=wt)
            undone = git('revert', '--no-commit', '-m', '1', commit['sha'])
            if undone.returncode:
                conflicts = git('diff', '--name-only', '--diff-filter=U').stdout.split()
                git('revert', '--abort')
                return None, ('git revert -m 1 does not apply cleanly on the newest next ('
                              + (', '.join(conflicts[:10]) or (undone.stderr or '').strip()[:200]) + ')')
            staged = git('diff', '--cached', '--numstat')
            if git('diff', '--cached', '--quiet').returncode == 0:
                git('revert', '--abort')
                return None, 'reverting it changes nothing: next already undoes it'
            grown = revert.grows_hot_file(staged.stdout)
            reland_url = '(the re-land issue is filed right after this PR opens)'
            message = revert.revert_message(number, title, sha, commit['sha'], report, failed)
            self.must(['git', '-c', 'user.name=SM integration script', '-c', 'user.email=noreply@spokenmargins.invalid',
                       'commit', '--quiet', '-m', message], cwd=wt)
            self.must(['git', 'push', '--quiet', '--force', 'origin', f'HEAD:refs/heads/{branch}'], cwd=wt, timeout=600)
            body = evidence / 'revert-pr.md'
            body.write_text(revert.pr_body(number, title, sha, report, failed, checks, reland_url,
                                           revert.hot_note(grown) if grown else ''))
            labels = ['automerge'] + (['hot-file-ok'] if grown else [])
            created = self.must(['gh', 'pr', 'create', '-R', REPO, '--base', BASE_BRANCH, '--head', branch,
                                 '--title', revert.revert_title(number, title, sha), '--body-file', str(body),
                                 '--label', ','.join(labels)])
            pr_url = (created.stdout or '').strip().splitlines()[-1]
            try:
                issue = evidence / 'reland-issue.md'
                issue.write_text(revert.reland_body(number, title, sha, report, pr_url, failed, prose))
                filed = self.must(['gh', 'issue', 'create', '-R', REPO, '--title', revert.reland_title(number, title),
                                   '--body-file', str(issue), '--label', 'ready,regression'])
                reland = (filed.stdout or '').strip().splitlines()[-1]
                body.write_text(revert.pr_body(number, title, sha, report, failed, checks, reland,
                                               revert.hot_note(grown) if grown else ''))
                self.must(['gh', 'pr', 'edit', pr_url, '-R', REPO, '--body-file', str(body)])
            except (RuntimeError, OSError, IndexError) as error:
                # The revert PR exists and will merge: say so, and leave the re-land issue to the report.
                self.log(f'revert PR {pr_url} is open but the re-land issue or PR text failed: {str(error)[:200]}')
            return pr_url, ''
        except (RuntimeError, OSError, IndexError) as error:
            return None, str(error)[:300]
        finally:
            git('checkout', '--quiet', '--force', '--detach', sha)
            git('branch', '-D', branch)

    def issue_comments(self, number: int) -> str:
        out = self.must(['gh', 'api', '--paginate', f'repos/{REPO}/issues/{number}/comments',
                         '--jq', '.[] | {body, author_association, user: {login: .user.login}} | @json']).stdout or ''
        return '\n'.join(c.get('body') or '' for c in comment_trust.trusted_only(
            [json.loads(line) for line in out.splitlines() if line.strip()]))

    def open_issues_matching(self, test: str) -> list[dict]:
        """Open issues GitHub's search ties to the test, as REST objects (they carry author_association)."""
        out = self.must(['gh', 'api', '-X', 'GET', 'search/issues', '-f', f'q=repo:{REPO} {dedupe_query(test)}',
                         '-f', 'per_page=100', '--jq', '.items[] | @json']).stdout or ''
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def file_failures(self, groups: list[dict], sha: str, report: str, evidence: Path,
                      cost: Optional[float]) -> list[int]:
        filed = []
        for i, group in enumerate(groups):
            duplicate = None
            for test in group['tests']:
                issues = self.open_issues_matching(test)
                duplicate = find_duplicate(issues, [test], self.issue_comments)
                if duplicate is not None:
                    break
            path = evidence / f'issue-{i + 1}.md'
            path.write_text(issue_text(group, sha, report, evidence, cost if i == 0 else None))
            if duplicate is not None:
                self.must(['gh', 'issue', 'comment', str(duplicate), '-R', REPO, '--body-file', str(path)])
                filed.append(duplicate)
            else:
                res = self.must(['gh', 'issue', 'create', '-R', REPO, '--title', group['title'][:120],
                                 '--body-file', str(path), '--label', FAIL_LABELS])
                match = re.search(r'/issues/(\d+)', res.stdout or '')
                if match:
                    filed.append(int(match.group(1)))
        return filed


def save_state(path: Path, state: dict) -> None:
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2) + '\n')
    tmp.replace(path)


def prune_evidence(folder: Path, keep: int = KEEP_EVIDENCE) -> None:
    """Keep the newest runs' evidence; a PASS run's .xcresult bundles go at once (disk is tight)."""
    runs = sorted((p for p in folder.iterdir() if p.is_dir()), key=lambda p: p.name)
    for old in runs[:-keep]:
        shutil.rmtree(old, ignore_errors=True)


def drop_bundles(evidence: Path) -> None:
    for bundle in evidence.rglob('*.xcresult'):
        shutil.rmtree(bundle, ignore_errors=True)


def tip_sim_app(wt: Path, manifest_path: Path, sha: str) -> tuple[Optional[Path], str]:
    """The simulator app the app plan built, when it is exactly `sha`'s and passed bundle-contracts; else why not."""
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('head') != sha:
        return None, f'the app plan built {str(manifest.get("head"))[:7]}, not {sha[:7]}'
    if not any(s.get('name') == 'bundle-contracts' and s.get('exit_code') == 0 for s in manifest.get('steps', [])):
        return None, 'no good simulator build'
    apps = sorted((wt / '.build' / 'verification').glob(f'*/Build/Products/Debug-iphonesimulator/{sim_builds.APP_NAME}'),
                  key=lambda p: p.stat().st_mtime)
    return (apps[-1], '') if apps else (None, 'the build left no app')


def pack_sim_build(wt: Path, manifest_path: Path, sha: str) -> str:
    """On a hosted Mac: zip the tip's simulator app into artifacts/sim-app/ for hosted-integration.yml to upload
    as `sim-app-<sha>`, which scripts/sim-build-latest downloads. The same rule as keep_sim_build. Never raises."""
    try:
        app, why = tip_sim_app(wt, manifest_path, sha)
        if not app:
            return 'not packed: ' + why
        packed = sim_builds.pack(app, sha, BASE_BRANCH, wt / 'artifacts' / 'sim-app', built_by=HOSTED_RUN_BY)
        if not packed['packed']:
            return 'not packed: ' + packed['why']
        return f"packed {packed['size_bytes'] / 1024 ** 2:.0f} MB into a {packed['zip_bytes'] / 1024 ** 2:.0f} MB zip"
    except Exception as error:  # noqa: BLE001 - the report must still go out
        return 'not packed: ' + str(error)[:300]


def keep_sim_build(ops: Ops, wt: Path, manifest_path: Path, sha: str) -> str:
    """Copy the tip's simulator app for desks to install (scripts/sim-build-latest). Never raises.

    Only a build of exactly `sha` that passed bundle-contracts is kept, whatever the tests said: desks
    test the tip, failing or not."""
    try:
        app, why = tip_sim_app(wt, manifest_path, sha)
        if not app:
            return 'not kept: ' + why
        kept = sim_builds.store(app, sha, BASE_BRANCH, sim_builds.root(), free_bytes=ops.free_bytes())
        if not kept['stored']:
            return 'not kept: ' + kept['why']
        return f"kept {kept['app']} ({kept['size_bytes'] / 1024 ** 2:.0f} MB); removed {kept['removed'] or 'none'}"
    except Exception as error:  # noqa: BLE001 - the report must still go out
        return 'not kept: ' + str(error)[:300]


def run_tests(ops: Ops, wt: Path, evidence: Path, fds: tuple) -> dict:
    first = summarize(ops.test_plan(wt, evidence / 'app', 'app', fds))
    reruns = []
    if first['verdict'] == 'FAIL':
        for n in range(1, RERUNS + 1):
            reruns.append(summarize(ops.test_plan(wt, evidence / f'rerun-{n}', 'app', fds, tuple(first['failed']))))
    result = dict(settle(first, reruns), reruns=len(reruns))
    listing_path = wt / 'TestPlans' / 'scripted-journeys.json'
    listing = json.loads(listing_path.read_text()) if listing_path.exists() else {}
    if result['verdict'] != 'INCONCLUSIVE' and (listing.get('gating') or listing.get('probation')):
        journeys = summarize(ops.test_plan(wt, evidence / 'journeys', 'journeys', fds))
        result['journeys'] = script_results(listing, journeys['journeys'])
        result['attachments'] = result['attachments'] + journeys['attachments']
        gating_failed = [t for t, s in result['journeys'].items()
                         if t in {e['test'].removesuffix('()') for e in listing.get('gating', [])} and s != 'passed']
        if gating_failed and result['verdict'] == 'PASS':
            result.update(verdict='FAIL', failed=sorted(gating_failed))
    return result


def search_culprit(ops: Ops, wt: Path, evidence: Path, green: Optional[str], sha: str, failed: list[str],
                   fds: tuple) -> dict:
    """Re-run only the failing tests at the commits since the last PASS while the simulator slot is held.

    Never raises: any trouble is an 'unknown' answer, and the worktree is put back on the tip."""
    if not green:
        return {'status': 'unknown', 'why': 'there is no earlier integration PASS to search from', 'checks': []}
    try:
        commits = ops.commits_since(green, sha)
        return revert.find_culprit(commits, lambda commit: ops.check_commit(wt, evidence, commit, failed, fds))
    except Exception as error:  # noqa: BLE001
        return {'status': 'unknown', 'why': f'the search stopped: {str(error)[:200]}', 'checks': []}
    finally:
        ops.run(['git', 'checkout', '--quiet', '--force', '--detach', sha], cwd=wt, timeout=300)


def act_on_culprit(ops: Ops, wt: Path, evidence: Path, sha: str, report: str, result: dict, groups: list[dict],
                   cost: Optional[float], suspects: list[str]) -> Optional[str]:
    """Open the revert PR for a found culprit, else tell the owner on #184 why not. Returns the PR url or None."""
    culprit = result.get('culprit') or {'status': 'unknown', 'why': 'no search ran', 'checks': []}
    checks = culprit.get('checks', [])
    reasons = []
    commit = culprit.get('commit')
    if culprit['status'] != 'found':
        reasons.append('no single culprit merge: ' + culprit.get('why', 'unknown'))
    else:
        try:
            scope = revert.load_test_scope(ops.repo_root)
            reasons = revert.revert_blockers(commit, ops.changed_paths(commit), scope, ops.repo_root,
                                             ops.open_revert_prs(), ops.reverted_on_base(commit['sha']))
        except Exception as error:  # noqa: BLE001
            reasons.append(f'could not check whether the revert is safe: {str(error)[:200]}')
        if not reasons:
            prose = [issue_text(g, sha, report, evidence, cost if i == 0 else None) for i, g in enumerate(groups)]
            url, why = ops.open_revert(wt, evidence, commit, sha, report, result['failed'], checks, prose)
            if url:
                return url
            reasons.append(why)
    suspect = (f"#{revert.pr_number(commit['subject'])}" if commit and revert.pr_number(commit['subject'])
               else ', '.join(suspects[:5]) or 'unknown')
    try:
        ops.comment(REPORT_ISSUE, revert.not_reverted_comment(sha, report, result['failed'], reasons, suspect, checks),
                    evidence, 'not-reverted.md')
    except RuntimeError as error:
        ops.log('could not tell the owner why nothing was reverted: ' + str(error)[:200])
    return None


def tick(ops: Ops, dry_run: bool = False) -> str:
    say = print if dry_run else ops.log
    now = ops.now()
    if not dry_run:
        ops.home.mkdir(parents=True, exist_ok=True)
        ops.must(['git', 'fetch', '--quiet', 'origin', BASE_BRANCH], timeout=600)
    sha = ops.must(['git', 'rev-parse', f'origin/{BASE_BRANCH}']).stdout.strip()
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError(f'origin/{BASE_BRANCH} did not resolve to a full SHA')
    path = ops.home / 'state.json'
    state = json.loads(path.read_text()) if path.exists() else {'results': {}}
    state['results'] = dict(sorted(state['results'].items(), key=lambda kv: kv[1].get('started', 0))[-200:])
    for record in state['results'].values():
        if record.pop('in_progress', None):
            # The tick holds its lock for the whole run, so this one was cut off (restart, kill).
            record['verdict'] = 'INCONCLUSIVE'
            record['errors'] = record.get('errors', []) + ['run stopped before completion']
    for record in state.get('hosted_handled', {}).values():
        if record.pop('in_progress', None):
            record['confirm'] = 'stopped before completion'
    comments = ops.report_comments()
    reports = reported([c['body'] for c in comments])
    if ops.hosted_on():
        outcome = defer_to_hosted(ops, state, path, comments, reports, now, dry_run, sha)
        if outcome:
            return outcome
    tested = [t for t in (report_time(comments), state.get('last_started')) if t is not None]
    why = hold_reason(sha, state, reports, now, lane_slots.memory_pressure_level(), ops.free_bytes(),
                      ops.builds_running(), lane_slots.simulator_job_running(),
                      ops.lane_waiting(), max(tested, default=None))
    if why:
        say('hold: ' + why)
        return 'held'
    previous = reports[-1][0] if reports else None
    green = last_green(reports)
    if dry_run:
        say(f'Would test {sha[:7]} (last report {previous}, last PASS {green}): detached worktree, '
            f'setup-worktree.sh, --plan app, {RERUNS} re-runs of any failing tests, scripted journeys, '
            f'one report on #{REPORT_ISSUE}; on a confirmed FAIL, the culprit merge, a revert PR with '
            f'automerge and a re-land issue (or a note on #{REPORT_ISSUE} when it is not safe to revert), a read-only '
            f'Claude diagnosis and, otherwise, issues labelled {FAIL_LABELS}. No tests or writes in dry-run.')
        return 'dry-run'
    with contextlib.ExitStack() as stack:
        try:
            fds = stack.enter_context(exclusive_slot())
        except TimeoutError as error:
            say('hold: ' + str(error))
            return 'held'
        wt = ops.home / 'worktree'
        evidence_root = ops.repo_root / 'artifacts' / 'integration-run'
        evidence = evidence_root / f'{int(now)}-{sha[:7]}'
        evidence.mkdir(parents=True, exist_ok=False)
        state['last_started'] = now
        # Recorded before any test starts, so a run cut off part-way is never repeated on this tip.
        state['results'][sha] = {'verdict': 'INCONCLUSIVE', 'started': now, 'evidence': str(evidence),
                                 'in_progress': True}
        save_state(path, state)
        say(f'testing {sha[:7]}')
        added = False
        result = summarize({'error': 'run stopped before completion'})
        try:
            if wt.exists():  # only this job's scratch worktree, left by an interrupted tick
                ops.must(['git', 'worktree', 'remove', '--force', str(wt)])
            ops.must(['git', 'worktree', 'add', '--detach', str(wt), sha])
            added = True
            ops.must(['scripts/setup-worktree.sh'], cwd=wt)
            result = run_tests(ops, wt, evidence, fds)
            ops.log('simulator build ' + keep_sim_build(ops, wt, evidence / 'app' / 'manifest.json', sha))
            if result['verdict'] == 'FAIL':
                result['culprit'] = search_culprit(ops, wt, evidence, green, sha, result['failed'], fds)
        except Exception as error:
            result = dict(summarize({'error': str(error)}), flaky=[])
        finally:
            stack.close()  # the simulator is free before GitHub and Claude work
        suspects = ops.suspects(sha, green) if result['verdict'] == 'FAIL' else []
        if result.get('journeys'):  # streaks toward gating, and the scripts due to move (#1901); never blocks the report
            try:
                state['journeys'] = journey_promotion.update(state.get('journeys', {}), result['journeys'])
                listing = json.loads((wt / 'TestPlans' / 'scripted-journeys.json').read_text())
                result['journeys_due'] = journey_promotion.report_line(
                    journey_promotion.due(listing, state['journeys']))
            except Exception as error:  # noqa: BLE001
                ops.log('journey streaks failed: ' + str(error)[:300])
        state['results'][sha] = {'verdict': result['verdict'], 'started': now, 'evidence': str(evidence),
                                 'failed': result['failed'], 'flaky': result.get('flaky', [])}
        save_state(path, state)
        try:  # the per-test catch ledger (#1789); it must never hold up the report
            lane_ledger.record_tip(lane_slots.state_dir(), ops.repo_root, sha, result['verdict'], result['failed'],
                                   result.get('flaky', []), ops.now() - now)
        except Exception as error:  # noqa: BLE001
            ops.log('catch ledger failed: ' + str(error)[:300])
        try:
            body = report_text(sha, result, started=now, finished=ops.now(), previous=previous,
                               suspects=suspects, evidence=evidence)
            report = ops.post_report(body, evidence)
            state['results'][sha]['report'] = report
            save_state(path, state)
            say(f"{result['verdict']} {sha[:7]}: {report}")
            if result['verdict'] == 'FAIL':
                groups, cost = ops.diagnose(wt, evidence, sha, result['failed'], suspects)
                try:
                    reverted = act_on_culprit(ops, wt, evidence, sha, report, result, groups, cost, suspects)
                except Exception as error:  # noqa: BLE001 - the failure issue below must still be filed
                    ops.log('revert step failed: ' + str(error)[:300])
                    reverted = None
                if reverted:
                    say(f'reverted: {reverted}')
                    state['results'][sha]['revert'] = reverted
                filed = ops.file_failures(groups, sha, report, evidence, cost) if not reverted else []
                state['results'][sha]['issues'] = filed
                save_state(path, state)
                say(f'filed or updated: {filed}')
            elif result['verdict'] == 'PASS':
                drop_bundles(evidence)
            return result['verdict']
        finally:
            if added or wt.exists():
                removed = ops.run(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
                if removed.returncode:
                    ops.log('worktree removal failed: ' + removed.stderr[:300])
            prune_evidence(evidence_root)


def hosted_not_reproduced(sha: str, report: str, failed: list[str], confirm: str, error: str = '') -> str:
    """#184's note when the Mac could not reproduce a hosted FAIL, so it reverted and filed nothing."""
    what = ('the failing tests passed here' if confirm == 'pass' else
            f'the failing tests gave no clear answer here ({confirm}{": " + error[:300] if error else ""})')
    return (f'**Hosted FAIL on `{sha[:7]}` not confirmed on the Mac** ({report})\n\n'
            f'The Mac re-ran {", ".join(f"`{t}`" for t in failed)} at `{sha[:7]}` and {what}. A failure seen only on '
            'the hosted Mac may be the hosted environment, not a merge, so nothing was reverted and no issue was '
            'filed. The next tip is tested on the hosted Mac as usual; if it fails the same way, look at the '
            'hosted run\'s logs (its artifact) next to this.\n')


def defer_to_hosted(ops: Ops, state: dict, path: Path, comments: list[dict], reports: list[tuple[str, str]],
                    now: float, dry_run: bool = False, tip: str = '') -> Optional[str]:
    """While hosted integration is on, the Mac tests no tip the hosted run has. It acts on the newest hosted
    report when that is a confirmed FAIL it hasn't handled: it re-runs the failing tests at that tip, and only
    when they fail here too runs today's culprit search, revert, diagnosis and issues (#1389). Each FAIL is
    handled once. None when the hosted run doesn't have the tip (#2127): the caller tests it as when off."""
    say = print if dry_run else ops.log
    handled = state.setdefault('hosted_handled', {})
    target = hosted_fail_to_handle(comments, handled)
    if not target:
        if not dry_run:
            save_state(path, state)  # keeps a handling run that was cut off closed, never repeated
        by_hosted = [s7 for s7, _ in reported([c['body'] for c in comments if re.search(
            rf'^run by: {re.escape(HOSTED_RUN_BY)}\s*$', c['body'] or '', re.M)])]
        try:
            age = now - ops.commit_time(tip)
        except (RuntimeError, ValueError):
            age = HOSTED_GRACE_SECONDS
        covered, why = hosted_cover(tip, by_hosted, ops.hosted_runs(tip), age)
        if not covered:
            say(f'hosted integration is on ({HOSTED_VARIABLE}) but {why}; the Mac tests it')
            return None
        say(f'hold: hosted integration is on ({HOSTED_VARIABLE}); {why}')
        return 'deferred'
    # A confirmed failure on next goes ahead of waiting lane requests ("revert first", #1180).
    why = room_reason(now, lane_slots.memory_pressure_level(), ops.free_bytes(), ops.builds_running(),
                      lane_slots.simulator_job_running())
    if why:
        say('hold: ' + why)
        return 'held'
    sha7, failed, report = target['sha7'], target['failed'], target['report']
    sha = ops.must(['git', 'rev-parse', '--verify', f'{sha7}^{{commit}}']).stdout.strip()
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError(f'{sha7} did not resolve to a full SHA')
    at = max(i for i, (s7, _) in enumerate(reports) if s7 == sha7)
    green = last_green(reports[:at])
    if dry_run:
        say(f'Would handle the hosted FAIL on {sha7} ({report}): re-run {", ".join(failed)} here; if they fail '
            f'again, search for the culprit since {green}, revert or tell the owner, diagnose and file issues.')
        return 'dry-run'
    with contextlib.ExitStack() as stack:
        try:
            fds = stack.enter_context(exclusive_slot())
        except TimeoutError as error:
            say('hold: ' + str(error))
            return 'held'
        wt = ops.home / 'worktree'
        evidence_root = ops.repo_root / 'artifacts' / 'integration-run'
        evidence = evidence_root / f'{int(now)}-{sha7}-hosted-fail'
        evidence.mkdir(parents=True, exist_ok=False)
        # Recorded before any test starts, so a run cut off part-way is never repeated on this FAIL.
        handled[sha7] = {'started': now, 'report': report, 'evidence': str(evidence), 'in_progress': True}
        save_state(path, state)
        say(f'handling the hosted FAIL on {sha7}: {", ".join(failed)}')
        added, confirm, error, culprit = False, 'unknown', '', None
        try:
            if wt.exists():
                ops.must(['git', 'worktree', 'remove', '--force', str(wt)])
            ops.must(['git', 'worktree', 'add', '--detach', str(wt), sha])
            added = True
            ops.must(['scripts/setup-worktree.sh'], cwd=wt)
            # find_culprit takes the tip as failing, so it must fail here first: a failure seen only on the
            # hosted Mac would otherwise blame the newest merge.
            confirm = revert.check_verdict(failed, summarize(ops.test_plan(wt, evidence / 'confirm', 'app', fds,
                                                                           tuple(failed))))
            if confirm == 'fail':
                culprit = search_culprit(ops, wt, evidence, green, sha, failed, fds)
        except Exception as error_:  # noqa: BLE001
            confirm, error = 'unknown', str(error_)
        finally:
            stack.close()  # the simulator is free before GitHub and Claude work
        record = {'started': now, 'report': report, 'evidence': str(evidence), 'confirm': confirm}
        try:
            if confirm == 'fail':
                suspects = ops.suspects(sha, green)
                groups, cost = ops.diagnose(wt, evidence, sha, failed, suspects)
                try:
                    reverted = act_on_culprit(ops, wt, evidence, sha, report, {'failed': failed, 'culprit': culprit},
                                              groups, cost, suspects)
                except Exception as error_:  # noqa: BLE001 - the failure issue below must still be filed
                    ops.log('revert step failed: ' + str(error_)[:300])
                    reverted = None
                if reverted:
                    record['revert'] = reverted
                record['issues'] = ops.file_failures(groups, sha, report, evidence, cost) if not reverted else []
            else:
                ops.comment(REPORT_ISSUE, hosted_not_reproduced(sha, report, failed, confirm, error), evidence,
                            'hosted-not-reproduced.md')
            say(f'hosted FAIL on {sha7}: {confirm} here; ' + json.dumps({k: record[k] for k in ('revert', 'issues')
                                                                         if k in record}))
            return 'handled'
        finally:
            handled[sha7] = record
            save_state(path, state)
            if added or wt.exists():
                removed = ops.run(['git', 'worktree', 'remove', '--force', str(wt)], cwd=ops.repo_root)
                if removed.returncode:
                    ops.log('worktree removal failed: ' + removed.stderr[:300])
            prune_evidence(evidence_root)


def hosted_run(ops: Ops, sha: str) -> str:
    """Test this checkout on a GitHub-hosted Mac and post #184's report (hosted-integration.yml, #1389).

    The same tests and report as a Mac tick, with less around it: no culprit search, revert, issues or Claude
    (a PR opened with the job's token starts no workflows, and there is no Claude token here; the Mac handles a
    confirmed FAIL, defer_to_hosted), no state, and no .xcresult bundles in the evidence the workflow uploads.
    The tip's simulator app is zipped for the workflow's `sim-app-<sha>` artifact instead of kept on disk."""
    now = ops.now()
    head = ops.must(['git', 'rev-parse', 'HEAD']).stdout.strip()
    if head != sha:
        raise ValueError(f'the checkout is at {head[:7]}, not {sha[:7]}')
    comments = ops.report_comments()
    reports = reported([c['body'] for c in comments])
    if any(sha7 == sha[:7] for sha7, _ in reports):
        ops.log(f'hold: #{REPORT_ISSUE} already has an integration report for {sha[:7]}')
        return 'held'
    previous = reports[-1][0] if reports else None
    green = last_green(reports)
    evidence = ops.repo_root / 'artifacts' / 'integration-run' / f'{int(now)}-{sha[:7]}'
    evidence.mkdir(parents=True, exist_ok=False)
    ops.log(f'testing {sha[:7]} on a hosted Mac')
    try:
        with exclusive_slot() as fds:  # the job's own state folder (SM_LANE_STATE_DIR): only verify-tests' bookkeeping
            result = run_tests(ops, ops.repo_root, evidence, fds)
    except Exception as error:  # noqa: BLE001
        result = dict(summarize({'error': str(error)}), flaky=[])
    ops.log('simulator build ' + pack_sim_build(ops.repo_root, evidence / 'app' / 'manifest.json', sha))
    suspects = ops.suspects(sha, green) if result['verdict'] == 'FAIL' else []
    drop_bundles(evidence)
    run_url = ''
    if os.environ.get('GITHUB_RUN_ID'):
        run_url = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', REPO)}"
                   f"/actions/runs/{os.environ['GITHUB_RUN_ID']} (artifact hosted-integration-{sha})")
    body = report_text(sha, result, started=now, finished=ops.now(), previous=previous, suspects=suspects,
                       evidence=run_url or evidence, hosted=True)
    report = ops.post_report(body, evidence)
    ops.log(f"{result['verdict']} {sha[:7]}: {report}")
    return result['verdict']


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dry-run', action='store_true', help='print the decision; run no tests and change nothing')
    ap.add_argument('--hosted', action='store_true',
                    help='test this checkout once on a GitHub-hosted Mac and post the report (hosted-integration.yml)')
    ap.add_argument('--sha', help="with --hosted: the full SHA of the trunk's tip, which this checkout must be at")
    args = ap.parse_args(argv)
    if args.hosted:
        if not re.fullmatch(r'[0-9a-f]{40}', args.sha or ''):
            ap.error('--hosted needs --sha <full 40-character SHA>')
        verdict = hosted_run(Ops(echo=True), args.sha)
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a') as f:
                f.write(f'Integration run on {args.sha[:7]}: {verdict}\n')
        return 0
    ops = Ops(echo=args.dry_run)
    if args.dry_run:
        tick(ops, dry_run=True)
        return 0
    ops.home.mkdir(parents=True, exist_ok=True)
    with (ops.home / 'tick.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0  # a run is in progress; launchd ticks every 10 minutes
        try:
            tick(ops)
        except Exception as error:
            ops.log('tick error: ' + str(error))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
