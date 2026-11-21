"""The T3 machinery: build the app once, claim a simulator under the lane's boot rules, run the app-hosted test
plans through verify-tests.py, judge the result, and tally retry passes.

Moved out of scripts/lane-runner.py (#4769) when the per-PR lane was retired: lane.yml is disabled and the merge queue
replaced it (#4572, #4573, #4755). The scheduled main-t3 job runs it through scripts/main_t3.py on a fresh simulator
clone with every test of both plans. The boot rules live in scripts/lane_sim.py, the slots in scripts/lane_slots.py.

Stdlib only, Python 3.9-compatible: it runs under /usr/bin/python3.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))


# The app test plans a T3 runs: verify-tests.py --plan key -> TestPlans/<name>.xctestplan.
PLANS = {'app': 'AppBehavior', 'adapters': 'AudioAdapters'}
T3_TIMEOUT = 3600


INTERRUPT_GRACE = 120


RUNNER_SIMULATOR_PREFIX = 'SM Lane Runner '


# How long a T3 waits for the Mac's one simulator slot (a Test Desk job may hold it); keeps the job
# inside lane.yml's 150-minute limit together with the boot and the test run.
RUNNER_SLOT_WAIT = 3600


def duration(seconds: float) -> str:
    minutes, seconds = divmod(int(seconds), 60)
    return f'{minutes}m{seconds:02d}s' if minutes else f'{seconds}s'


STALL_ISSUE = 1802  # the evidence log for app startup stalls and simulator boot stalls (#705 is closed)


BOOT_STALLS = 'boot-stalls.json'  # a T3 boot's stalls (boot_t3_device), for log_recovered_stalls


FRESH_RERUNS = 'fresh-clone-reruns.json'  # plans rerun on a fresh clone after two startup stalls (#2176)


OVERLOAD_RERUNS = 'overload-reruns.json'  # plans rerun once after their test run hit its budget on an overloaded runner (#3374)


# The runner is overloaded when its 1-minute load average is above this many per CPU. On 2026-11-04 a T3 test run
# hit its budget at load 293.6 (#3374). The Mac's launches ran at load 100-200 on busy days and 14% above 200
# (docs/workstreams/test-lane.md, #2176, 2026-10-19), so a line of 8 per CPU (80-96) would be crossed by ordinary
# runs; 16 per CPU (160-192 on 10-12 CPUs) is crossed only by the heavy end. Stated here so the report can say which
# side of the line a run was on. Default taken on #3374 (reversible: change the number).
OVERLOAD_LOAD_PER_CPU = 16


OVERLOAD_WAIT = 600  # at most this long, in seconds, before the one rerun, for the load to come back under the line


OVERLOAD_POLL = 30


def overload_line(cpus: int | None = None) -> int:
    """The 1-minute load average above which the runner counts as overloaded: OVERLOAD_LOAD_PER_CPU per CPU."""
    return OVERLOAD_LOAD_PER_CPU * (cpus or os.cpu_count() or 1)


def overload_text(load: float, line: int) -> str:
    return f'load average {load:g} is above the overload line of {line} ({OVERLOAD_LOAD_PER_CPU} per CPU)'


def runner_overloaded(manifest: dict, cpus: int | None = None) -> dict | None:
    """Whether a verify-tests.py plan stopped on a step's time budget while the runner was overloaded (#3374).

    The step's own load reading (taken as it stopped) must be above the line. A step cut short by a simulator crash
    flood, by the runner's whole-run kill (`signalled`: run_bounded's SIGINT at T3_TIMEOUT) or by anything but its
    own budget is not this. Returns the load and the line, or None."""
    line = overload_line(cpus)
    for step in manifest.get('steps', []):
        if step.get('interrupted') and not step.get('signalled') and not step.get('simulator_crash_report') \
                and step.get('timeout_seconds'):
            readings = step.get('load_average_end') or step.get('load_average_start') or []
            if readings and readings[0] is not None and readings[0] > line:
                return {'step': step.get('name'), 'load_average': readings[0], 'line': line}
    return None


def wait_for_quiet_runner(line: int, max_wait: float = OVERLOAD_WAIT, poll: float = OVERLOAD_POLL,
                          load=lambda: os.getloadavg()[0], sleep=time.sleep) -> tuple[float, float | None]:
    """Wait, at most max_wait seconds, for the 1-minute load average to fall to the line. Returns the seconds
    waited and the last reading (None where the system reports none). The rerun goes ahead either way: it is one
    more try, not a gate."""
    waited, reading = 0.0, None
    while True:
        try:
            reading = load()
        except OSError:
            return waited, None
        if reading <= line or waited >= max_wait:
            return waited, reading
        sleep(poll)
        waited += poll


def startup_stalled_out(manifest: dict) -> bool:
    """Whether a verify-tests.py plan ended INCONCLUSIVE on startup stalls alone: a step stalled twice, no test
    failed, and no crash flood stopped it. A failing test after the stalls is the PR's FAIL, not this (#2176)."""
    if manifest.get('status') == 'verified':
        return False
    return any(len(step.get('startup_stalls') or []) >= 2 and not step.get('simulator_crash_report')
               and not any(r.get('status') == 'failed' for r in (step.get('tests') or {}).values())
               for step in manifest.get('steps', []))


def recovered_startup_stalls(manifest: dict) -> list[dict]:
    """The steps of a verify-tests.py manifest that stalled once at startup, recovered on the first retry and passed.

    Owner's call 2026-10-11: such a step counts as a PASS, and each stall is logged on the evidence log (STALL_ISSUE). Two or more stalls
    before a pass stay a step error, so they never show up here.
    """
    return [{'step': step.get('name'), 'stall': step['startup_stalls'][0],
             'passed': sum(r.get('status') == 'passed' for r in (step.get('tests') or {}).values())}
            for step in manifest.get('steps', [])
            if step.get('startup_recovered') and len(step.get('startup_stalls') or []) == 1 and not step.get('errors')]


TWO_STALLS_RULE = 'verdict stays INCONCLUSIVE (two stalls, owner 2026-10-11/2026-10-23)'


def overload_rerun_note(plan: str, rerun: dict) -> str:
    """The report line for the rerun after an overloaded runner's budget ran out (#3374)."""
    waited = rerun.get('waited_seconds', 0)
    after = rerun.get('load_after')
    line = (f'{plan}: runner overloaded: the first run of this plan ran out of its time budget while the '
            f'{overload_text(rerun["load_average"], rerun["line"])}. A test that hangs in the PR stops at its budget '
            f'too, so the load is a fact, not a proven cause. The lane waited {duration(waited)} '
            f'(load average then {after if after is not None else "unknown"}) and ran the plan once more on the same '
            f'simulator, without a new request; the rerun\'s result is the plan\'s. First run: {rerun["first"]}/; '
            f'rerun: {rerun["output"]}/.')
    if rerun.get('overloaded_again'):
        line += (' The rerun ran out of its budget too, so this stays INCONCLUSIVE. Check the log for the test that '
                 'was running when each run stopped: the same one both times points at the PR, not the machine.')
    return line


def fresh_rerun_outcome(rerun: dict) -> str:
    """What the fresh-clone rerun showed, for the report and the evidence log (#2176).

    Owner, 2026-10-23: "Two stalls keep INCONCLUSIVE per my 2026-10-11 call; the fresh-clone rerun is evidence
    only." So a clean rerun never turns the plan into a PASS. A failing test in the rerun is a FAIL (lead's
    Default taken on PR #2179): that is a real failure, not a startup stall."""
    if rerun.get('boot'):
        return f'the fresh clone did not boot ({rerun["boot"]}); {TWO_STALLS_RULE}'
    if rerun.get('not_ready'):
        return (f'the fresh clone booted but failed its readiness step (verify-tests.py `{rerun["not_ready"]}`), so '
                f'no test ran on it; {TWO_STALLS_RULE}')
    if rerun.get('verdict') == 'FAIL':
        failed = rerun.get('failed') or []
        return (f'fresh-clone rerun: {len(failed)} test(s) failed ({", ".join(failed)}); verdict FAIL (a failing '
                'test, not a startup stall)')
    if rerun.get('stalled_again'):
        shown = 'stalled at startup twice too'
    elif rerun.get('status') == 'verified':
        shown = f'passed {rerun.get("passed", 0)} tests' + (' after 1 recovered startup stall'
                                                            if rerun.get('recovered') else '')
    else:
        shown = f'ended `{rerun.get("status")}` after {rerun.get("passed", 0)} passing test(s)'
    return f'fresh-clone rerun: {shown}; {TWO_STALLS_RULE}'


TALLY_ISSUE = 2176  # retry-passes are tallied here (owner, 2026-10-24); same issue and line format as the hosted integration run


TALLY_PREFIX = 'flake-tally:'


TALLY_WINDOW_DAYS = 7


TALLY_THRESHOLD = 3


TALLY_BOT = 'github-actions[bot]'


TALLY_TRUSTED = ('OWNER', 'MEMBER', 'COLLABORATOR')


def retry_passes(evidence: Path) -> list[str]:
    """Every test that failed and then passed on a rerun, from the verify-* manifests under <evidence>
    (a fresh-clone rerun is evidence only)."""
    return sorted({t for output in evidence.glob('verify-*') if not output.name.endswith('-fresh')
                   for step in _read_manifest(output).get('steps', []) for t in step.get('passed_on_retry') or []})


def _tally_trusted(item: dict) -> bool:
    """A comment or issue from a collaborator or the workflow's bot (#1822). The bot's author_association is NONE,
    so it is matched by login; the lane opens its flake issues and posts its tallies as the bot."""
    return (item.get('user') or {}).get('login') == TALLY_BOT or item.get('author_association') in TALLY_TRUSTED


def tally_counts(comments: list[dict], now: datetime.datetime) -> dict[str, list[str]]:
    """Retry-passes per test in the last 7 days -> their run ids. Only comments from a collaborator or the workflow's
    bot count (#1822), so a stranger's look-alike line can't open an issue. The same run counts once per test.
    The test is everything between the prefix and the last three fields, so a name with spaces still counts."""
    seen: dict[str, dict[str, None]] = {}
    window = datetime.timedelta(days=TALLY_WINDOW_DAYS)
    for comment in comments:
        if not _tally_trusted(comment):
            continue
        first = (comment.get('body') or '').splitlines()[:1]
        parts = first[0].split() if first else []
        if len(parts) < 5 or parts[0] != TALLY_PREFIX:
            continue
        try:
            when = datetime.datetime.strptime(parts[-1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
        if now - window <= when <= now:
            seen.setdefault(' '.join(parts[1:-3]), {})[parts[-2]] = None
    return {test: list(runs) for test, runs in seen.items()}


def log_retry_passes(evidence: Path, repo: str, head: str, run_id: str, tally, now=None) -> list[str]:
    """One comment per retry-pass on #2176, then a `ready` groundwork issue (no milestone; #3636) for any test with 3 or more retry-passes in
    7 days (owner, 2026-10-24; #2596). `tally` offers post(body), comments(), open_markers() and open_issue(title, body).

    Best effort like log_recovered_stalls: the report is already posted, and nothing here can change the verdict.
    Returns the issues opened.
    """
    opened: list[str] = []
    try:
        tests = retry_passes(evidence)
        if not tests:
            return opened
        now = now or datetime.datetime.now(datetime.timezone.utc)
        stamp = now.strftime('%Y-%m-%dT%H:%M:%SZ')
        for test in tests:
            tally.post(f'{TALLY_PREFIX} {test} {head[:7]} {run_id} {stamp}\n\n`{test}` passed on retry in lane run {run_id}.')
        counts = tally_counts(tally.comments(), now)
        marked = tally.open_markers()
        for test in tests:
            if len(counts.get(test, [])) >= TALLY_THRESHOLD and test not in marked:
                name = test.rsplit('/', 1)[-1].removesuffix('()')
                links = '\n'.join(f'- https://github.com/{repo}/actions/runs/{r}' for r in counts[test])
                opened.append(tally.open_issue(
                    'Flaky: ' + name[:110],
                    f'<!-- flake-test: {test.replace("-->", "")} -->\n\n`{test}` failed on its first run and passed on a '
                    f're-run in {len(counts[test])} runs in the last 7 days (tally on #{TALLY_ISSUE}). The run still counted '
                    f'as a pass (owner, 2026-10-24), so fix the test or the code under it rather than leave it to retry.\n\n'
                    f'Runs:\n{links}\n'))
    except Exception as error:  # noqa: BLE001 - the report already names the retry-pass
        print(f'Could not tally the retry-passes on #{TALLY_ISSUE}: {error!r}', flush=True)
    return opened


class RepoTally:
    """log_retry_passes's GitHub side: #2176's comments and the open flake issues."""

    def __init__(self, repo: str):
        self.repo = repo
        self.client = Repo(repo)

    def post(self, body: str) -> None:
        self.client.comment(TALLY_ISSUE, body)

    def comments(self) -> list[dict]:
        return self.client.issue_comments(TALLY_ISSUE)

    def open_markers(self) -> set[str]:
        lines = self.client.api('--paginate', '--jq',
                                '.[] | select(.pull_request == null) | {body, author_association, '
                                'user: {login: .user.login}} | @json',
                                f'repos/{self.repo}/issues?state=open&per_page=100')
        issues = [json.loads(line) for line in lines.splitlines() if line.strip()]
        return {m for issue in issues if _tally_trusted(issue)
                for m in re.findall(r'<!-- flake-test: (.+?) -->', issue.get('body') or '')}

    def open_issue(self, title: str, body: str) -> str:
        done = subprocess.run(['gh', 'issue', 'create', '-R', self.repo, '--title', title, '--body', body,
                               '--label', 'ready', '--label', 'area: groundwork'], capture_output=True, text=True)
        if done.returncode:
            raise RuntimeError(done.stderr.strip()[:200])
        return done.stdout.strip()


# The workflow's command files. A step's processes append to them to set its outputs (the verdict the
# Verdict step reads), environment and summary, so the PR's code must not see them: the lane's own tests
# call main(), and inherited, they wrote their fake verdicts into the job's output after the real one.
WORKFLOW_FILES = ('GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY')


def pr_code_env() -> dict:
    """The environment for the PR's own code (builds, tests): without the GitHub token, so nothing the
    PR changes can use the lane's write access, and without the workflow's command files, so it can't set
    the job's verdict."""
    return {name: value for name, value in os.environ.items()
            if name not in ('GH_TOKEN', 'GITHUB_TOKEN', *WORKFLOW_FILES)}


def run_bounded(command: list[str], log, timeout: float, grace: float = INTERRUPT_GRACE, env=None) -> int | None:
    """Run in a new process group and return its exit code, or None if it timed out.

    On timeout the whole group gets SIGINT first, so verify-tests.py and xcodebuild-lane stop their
    own xcodebuild and record the interruption, then SIGKILL if it's still there after the grace.
    """
    # The child gets default SIGINT handling even if this process was started with it ignored (as
    # background jobs are), or the interrupt below would be silently ignored all the way down.
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                               env=env or pr_code_env(), preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGINT)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return None


def first_errors(log: Path, limit: int = 5) -> list[str]:
    try:
        text = log.read_text(errors='replace')
    except OSError:
        return []
    lines = text.splitlines()
    found = [line.strip() for line in lines if ' error: ' in line or line.startswith('error:') or 'errSec' in line
             or re.match(r'\w+(Error|Exception): ', line)]  # a Python traceback's last line
    if 'The following build commands failed:' in lines:
        for line in lines[lines.index('The following build commands failed:') + 1:]:
            if not line.strip():
                break
            found.append('failed: ' + line.strip())
    if not found:
        # simctl says why in plain lines ("An error was encountered processing the command (domain=…,
        # code=…):" then the reason), which match none of the above: #440's report said only "Process exit 148".
        found = [line.strip()[:300] for line in lines if line.strip()][-2:]
    return list(dict.fromkeys(found))[:limit]


def summarize_manifest(manifest: dict) -> dict:
    """Test counts, failed tests, crash reports and whether a flood or timeout stopped the run.

    A build that was interrupted (timeout or flood) is not a build failure: that's INCONCLUSIVE.
    """
    summary = {'passed': 0, 'failed': [], 'crashes': [], 'flood': False, 'interrupted': False, 'build_failed': False,
               'out_of_time': None, 'overloaded': runner_overloaded(manifest), 'xcresult_unreadable': [],
               'audio_not_run': []}
    for step in manifest.get('steps', []):
        if step.get('xcresult_unreadable'):
            summary['xcresult_unreadable'].append(step['xcresult_unreadable'])
        if step.get('interrupted') and not step.get('simulator_crash_report') and step.get('timeout_seconds'):
            summary['out_of_time'] = (step.get('name'), step.get('timeout_seconds'))
        for test, record in (step.get('tests') or {}).items():
            if record.get('status') == 'passed':
                summary['passed'] += 1
            elif record.get('status') == 'failed':
                summary['failed'].append(test)
        summary['audio_not_run'] += step.get('audio_not_run') or []  # a hosted Mac cannot listen (#3604)
        summary['crashes'] += [Path(p).name for p in step.get('simulator_crash_reports', [])]
        summary['flood'] |= bool(step.get('simulator_crash_report'))
        summary['interrupted'] |= bool(step.get('interrupted'))
        summary['build_failed'] |= (step.get('name') == 'build-for-testing' and bool(step.get('errors'))
                                    and not step.get('interrupted'))
    return summary


def failed_step_errors(manifest: dict, output: Path, limit: int = 3) -> list[str]:
    """The first error lines from the log of the step that stopped verify-tests.py.

    Its log stays on the Mac, so without these a report says only "Process exit 70" (#410).
    """
    for step in manifest.get('steps', []):
        if step.get('exit_code') and not step.get('interrupted'):
            return first_errors(output / f'{step.get("name")}.log', limit)
    return []


def t3_verdict(summaries: list[dict], statuses: list[str]) -> str:
    if statuses and all(status == 'verified' for status in statuses):
        # Every plan in `grouped` holds part of a requested selector, so a plan that is verified yet passed no test ran
        # nothing it was asked to (#2596: a class that "ran" 0 tests in the adapters plan was a PASS).
        empty = [s for s in summaries if not s['passed']]
        # Excused only when the plan held nothing but AudioLoopback selectors: with any other selector in it, an empty
        # plan is a requested test that ran nothing (#2596), whatever else skipped.
        if any(not (s.get('audio_not_run') and s.get('audio_only')) for s in empty):
            return 'FAIL'
        # #3604: a hosted Mac cannot run an AudioLoopback test, so a plan holding only those passed nothing and asked
        # nothing else. The others carry the verdict; when no plan passed a test, nothing ran: INCONCLUSIVE, not a PASS.
        return 'INCONCLUSIVE' if empty and not any(s['passed'] for s in summaries) else 'PASS'
    # A plan that lost its simulator failed for the lane's reasons (#411: exit 70 when the device vanished).
    if any((s['failed'] or s['build_failed']) and not s.get('device_lost') for s in summaries):
        return 'FAIL'
    return 'INCONCLUSIVE'


READINESS_STEPS = ('simulator-boot', 'simulator-ready')


def failed_step_name(manifest: dict) -> str | None:
    """The first step of a verify-tests.py manifest that exited non-zero; a readiness step that ran out of time counts too."""
    return next((step.get('name') for step in manifest.get('steps', []) if step.get('exit_code')), None)


def run_plans(grouped: dict[str, list[str]], run_plan, evidence: Path,
              device_available=lambda: True) -> tuple[list, list, list, list]:
    """Run each plan's selectors; stop at the first crash flood (AGENTS.md: don't reboot in a loop).

    Also stop when a plan ends with the simulator not ready or gone: the next plan would only fail to find
    it (#440: exit 148 at the readiness step, then "No matching supported simulator" for the adapters plan).
    """
    summaries, statuses, ran, details = [], [], [], []
    plans = list(grouped.items())
    for position, (plan, selectors) in enumerate(plans):
        output = evidence / f'verify-{plan}'
        started = time.monotonic()
        manifest = run_plan(plan, selectors, output)
        took = time.monotonic() - started
        rerun = manifest.get('fresh_clone_rerun')
        if rerun:
            stalls = '; '.join(s.get('diagnosis') or 'no diagnosis' for s in rerun.get('stalls', []))
            if rerun.get('boot'):
                details.append(f'{plan}: two startup stalls on clone {rerun.get("stalled")} ({stalls}); a rerun on a '
                               f'fresh clone could not start: {rerun["boot"]}; {TWO_STALLS_RULE} (#2176). '
                               f'Logged on #{STALL_ISSUE}.')
            else:
                if rerun.get('verdict') == 'FAIL':
                    output = Path(rerun['output'])  # the failing tests' evidence is the rerun's
                details.append(f'{plan}: two startup stalls on clone {rerun.get("stalled")} ({stalls}), so the plan ran '
                               f'again on a fresh clone ({rerun.get("fresh")}) in the same job as evidence (#2176): '
                               f'{fresh_rerun_outcome(rerun)}. Logged on #{STALL_ISSUE}. Stalled run: '
                               f'{rerun.get("first")}/; rerun: {rerun.get("output")}/')
        overload_rerun = manifest.get('overload_rerun')
        if overload_rerun:
            output = Path(overload_rerun['output'])  # the rerun's evidence is the plan's
            details.append(overload_rerun_note(plan, overload_rerun))
        summary = summarize_manifest(manifest)
        summary['audio_only'] = bool(selectors) and all('AudioLoopback' in s for s in selectors)  # lane_audio_window.MARKER
        summaries.append(summary)
        statuses.append(manifest.get('status', 'missing'))
        ran.append(f'{", ".join(s.split("/", 1)[1] for s in selectors)} ({summary["passed"]} passed'
                   f'{", " + str(len(summary["failed"])) + " failed" if summary["failed"] else ""}'
                   f'; {plan} plan, build and tests, {duration(took)})')
        attachments = [a for step in manifest.get('steps', []) for a in step.get('attachments', [])]
        if attachments:  # older PR checkouts have no exporter/helper; load only when evidence exists
            from lane_xcresult_attachments import report_lines
            details.extend(report_lines(attachments))
        for found in recovered_startup_stalls(manifest):
            stall = found['stall']
            details.append(f'{plan}: recovered after 1 startup stall ({found["step"]} printed no test output '
                           f'{stall.get("after_seconds")}s after launch); the first retry passed '
                           f'{found["passed"]} test(s), which counts as a PASS (owner\'s call 2026-10-11). Logged '
                           f'on #{STALL_ISSUE}. evidence: {output}/{found["step"]}-stall-{stall.get("attempt")}/')
        retried = sorted({t for step in manifest.get('steps', []) for t in step.get('passed_on_retry') or []})
        for test in summary['failed'][:10]:
            details.append(f'{test} — expected: passes. observed: failed. evidence: {output}/tests.xcresult')
        if summary['out_of_time']:
            step, limit = summary['out_of_time']
            what = {'xcode-tests': 'test run', 'build-for-testing': 'build'}.get(step, step)
            details.append(f'{plan}: the {what} ran out of its own {duration(limit)} budget (verify-tests.py `{step}`) '
                           f'after {summary["passed"]} passing test{"s" if summary["passed"] != 1 else ""}. '
                           'The simulator\'s boot has a separate budget and had finished before it started.')
        if summary['overloaded']:
            found = summary['overloaded']
            details.append(f'{plan}: runner overloaded: the `{found["step"]}` step stopped at its time budget while the '
                           f'{overload_text(found["load_average"], found["line"])}. A test that hangs in the PR stops at its '
                           'budget too, so the load is a fact, not a proven cause: check which test was running.')
        for error in summary['xcresult_unreadable']:
            details.append(f'{plan}: the xcresult could not be read ({error}); the pass count comes from the test log, '
                           f'where all {summary["passed"]} expected test(s) finished and passed (#3374). '
                           f'evidence: {output}/manifest.json')
        if summary['audio_not_run']:
            details.append(f'{plan}: not run on the hosted Mac, which has no audio loopback: '
                           f'{", ".join(t.split("/", 1)[-1] for t in summary["audio_not_run"])}. The audio check is still '
                           'owed (the owner\'s pass, or a run on the Mac); the other tests carry this verdict (#3604).')
        if manifest.get('status') == 'verified' and not summary['passed'] and summary['audio_not_run'] \
                and summary['audio_only']:
            details.append(f'{plan}: no test ran in this plan; only AudioLoopback tests were requested in it (#3604). '
                           f'evidence: {output}/manifest.json')
        elif manifest.get('status') == 'verified' and not summary['passed']:
            details.append(f'{plan}: ran 0 of the requested tests ({", ".join(s.split("/", 1)[-1] for s in selectors)}); '
                           f'a requested test that does not run is a FAIL (#2596). evidence: {output}/manifest.json')
        if manifest.get('status') != 'verified' and not summary['failed']:
            details.append(f'{plan}: {manifest.get("error") or manifest.get("status")}. evidence: {output}/manifest.json')
            details += [f'{plan}: {line}' for line in failed_step_errors(manifest, output)]
        # owner, 2026-10-24 (#2596): fail-then-pass on a rerun is a pass, and every report names it, or says none
        details.append(f'{plan}: passed on retry: {", ".join(retried) if retried else "none"}')
        if summary['flood']:
            skipped = [p for p, _ in plans[position + 1:]]
            if skipped:
                details.append(f'Stopped after the crash flood; not run: {", ".join(skipped)}.')
                statuses.append('not run')
            break
        if manifest.get('status') != 'verified':
            stopped_at = failed_step_name(manifest)
            gone = not device_available()
            # A fresh clone that booted but failed readiness is like one that won't boot: the stalled run's own
            # steps passed readiness, so they can't show it (#2530).
            fresh_unusable = rerun and (rerun.get('boot') or rerun.get('not_ready'))
            if gone or stopped_at in READINESS_STEPS or fresh_unusable:
                summary['device_lost'] = True
                skipped = [p for p, _ in plans[position + 1:]]
                why = ('the fresh simulator is gone (no longer listed by `simctl list devices available`)' if gone
                       else 'the fresh clone for a rerun did not boot' if rerun and rerun.get('boot')
                       else 'the fresh clone for a rerun booted but was not ready '
                            f'(verify-tests.py `{rerun["not_ready"]}`)' if fresh_unusable
                       else f'the fresh simulator was not ready (verify-tests.py `{stopped_at}`)')
                details.append(f'{plan}: {why}, so this is the lane\'s fault, not the PR\'s'
                               + (f'; not run: {", ".join(skipped)}.' if skipped else '.'))
                if skipped:
                    statuses.append('not run')
                break
    return summaries, statuses, ran, details


def boot_t3_device(udid: str, log, replace=None, evidence: Path | None = None, info: dict | None = None) -> tuple:
    """Boot the clone under the lane's boot rules (scripts/lane_sim.py).

    A clone has never booted as itself, so it gets the first-boot tolerance (one SpringBoard change in the
    first 30 s, #184). Without it every clone boot stopped on that change from 06:00 UTC on 2026-10-11 (#1359).
    At a boot stall, replace(old) gives one fresh clone to boot instead (#1802); each stall goes to
    <evidence>/boot-stalls.json, which log_recovered_stalls posts on #1802 with the report's link and verdict.

    Returns (None when ready or the reason it isn't, details such as the memory pressure at boot). info['udid']
    is the device the run holds now, ready or not; pass info to read it even if the boot raises.
    """
    import lane_sim
    info = {} if info is None else info

    def note(label, stalls, outcome):
        if evidence is not None:
            (evidence / BOOT_STALLS).write_text(json.dumps({'label': label, 'stalls': stalls, 'outcome': outcome},
                                                           indent=2) + '\n')

    try:
        lane_sim.boot_with_retry(udid, f'runner boot {udid}', replace, out=log, info=info, first_boot=True,
                                 log_stall=note)
    except lane_sim.BootError as error:
        return str(error), info
    return None, info


def prepare_t3_build(grouped, runtime, evidence):
    """Both T3 plans use SpokenMarginsAppBehavior; prepare it before taking a simulator slot."""
    python = ROOT / '.venv/bin/python'
    output = evidence / 'verify-build'
    command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py',
               '--plan', next(iter(grouped)), '--build-only', '--runtime', runtime, '--output', str(output)]
    started = time.monotonic()
    with (evidence / 'verify-build.log').open('w') as log:
        finished = run_bounded(command, log, T3_TIMEOUT)
    manifest = _read_manifest(output)
    if finished is None:
        manifest.update(status='timed out', error='the runner build budget ran out; interrupted')
    if manifest.get('status') == 'verified':
        return 'PASS', [f'shared build before simulator boot took {duration(time.monotonic() - started)} '
                        f'(reused: {manifest.get("reused_build", False)}); evidence: {output}/manifest.json']
    summary = summarize_manifest(manifest)
    verdict = t3_verdict([summary], [manifest.get('status', 'missing')])
    return verdict, [f'Build before simulator boot: {manifest.get("error") or "no verified build manifest"}; '
                     f'evidence: {output}/manifest.json', *failed_step_errors(manifest, output)]


def _run_t3_grouped(grouped, request_id, evidence):
    """Build first, then take the simulator slot and run the grouped selectors on a clone."""
    import lane_sim
    runtime = lane_sim.newest_runtime()
    if not runtime:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', [f'No iOS {lane_sim.IOS_MAJOR} simulator runtime is installed.'],
                'none', '')
    verdict, build_details = prepare_t3_build(grouped, runtime, evidence)
    if verdict != 'PASS':
        return verdict, 'no simulator', 'nothing', build_details, 'none', ''
    from lane_slots import acquire_simulator_slot, release_handle
    try:
        slot = acquire_simulator_slot(f'runner T3 {request_id}', out=sys.stdout, max_wait=RUNNER_SLOT_WAIT)
    except TimeoutError as error:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The Mac\'s simulator slots stayed busy (a Test Desk job or '
                f'another run, and no room for a second simulator), so this run did not start one: {error}'], 'none', '')
    try:
        verdict, where, ran, details, crashes, cc = _t3_on_fresh_device(grouped, request_id, evidence, runtime)
        return verdict, where, ran, build_details + details, crashes, cc
    except (lane_sim.BootError, OSError, subprocess.SubprocessError) as error:
        note = f'Template or clone failed: {error}'
        if isinstance(error, subprocess.TimeoutExpired):  # a simctl call that never answered (#3374: shutdown, 120 s)
            try:
                load, line = os.getloadavg()[0], overload_line()
            except OSError:
                load = line = 0
            if load > line:
                note += f'. Runner overloaded: the {overload_text(load, line)}; this is the machine, not this PR'
        return 'INCONCLUSIVE', 'no simulator', 'nothing', build_details + [note], 'none', ''
    finally:
        release_handle(slot)


def _t3_on_fresh_device(grouped, request_id, evidence, runtime):
    """The T3 job proper; the caller holds the simulator slot throughout."""
    claim = claim_runner_device(RUNNER_SIMULATOR_PREFIX + request_id)
    try:
        return _t3_on_claimed_device(grouped, request_id, evidence, runtime)
    finally:
        release_runner_device(claim)


def _t3_on_claimed_device(grouped, request_id, evidence, runtime):
    import lane_sim
    clone_started = time.monotonic()
    with (evidence / 'simulator-clone.log').open('w') as log:
        udid = lane_sim.clone_temporary(RUNNER_SIMULATOR_PREFIX + request_id, runtime, out=log)
    clone_seconds = time.monotonic() - clone_started
    phone = lane_sim.device_type(runtime).rsplit('.', 1)[-1].replace('-', ' ')  # the phone clone_temporary chose (#2557)
    where = f'cloned {phone}, {runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")}'
    python = ROOT / '.venv/bin/python'

    def run_plan(plan, selectors, output, log_name=None):
        command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', plan,
                   '--device', udid, '--require-build', '--output', str(output)]
        for selector in selectors:
            command += ['--only-testing', selector]
        with (evidence / (log_name or f'verify-{plan}.log')).open('w') as log:
            if run_bounded(command, log, T3_TIMEOUT) is None:
                return {**_read_manifest(output), 'status': 'timed out',
                        'error': f'the runner\'s {duration(T3_TIMEOUT)} budget for the whole verify-tests.py run '
                                 '(build and tests) ran out; interrupted'}
        return _read_manifest(output) or {'status': 'missing', 'error': 'verify-tests.py wrote no manifest'}

    def replace(stalled):
        lane_sim.release(stalled)
        with (evidence / 'simulator-clone.log').open('a') as log:
            return lane_sim.clone_temporary(RUNNER_SIMULATOR_PREFIX + request_id, runtime, out=log)

    reruns, overload_reruns = [], []
    # Only a device with a SpringBoard watcher on it can be stopped by one. A clone marked unsafe for any other
    # reason (a fresh clone that never booted, say) is not a crash flood and pings nobody (audit on 484c63b).
    watched_devices = []

    def run_plan_or_rerun_on_a_fresh_clone(plan, selectors, output):
        """#2176: a plan that ends on its second startup stall runs once more, on a fresh clone, in this job.

        The verdict stays INCONCLUSIVE whatever a clean rerun shows (owner, 2026-10-23: "Two stalls keep
        INCONCLUSIVE per my 2026-10-11 call; the fresh-clone rerun is evidence only."). The rerun's outcome goes in
        the report and on the evidence log, as evidence on the stalls' cause. Only a failing test in the rerun
        changes the verdict, to FAIL: that is a real failure, not a stall (lead's Default taken, PR #2179). Once per
        job, so a Mac that stalls every launch costs one more plan, not a loop."""
        nonlocal udid
        manifest = run_plan(plan, selectors, output)
        found = runner_overloaded(manifest)
        # Not after the runner's whole-run kill ('timed out': a rerun would run past the job's limit and lose the
        # report), and not after a startup stall (the owner's 2026-10-11 stall rule counts stalls across the job).
        if found and not overload_reruns and manifest.get('status') != 'timed out' \
                and not any(step.get('startup_stalls') for step in manifest.get('steps', [])) \
                and not lane_sim.unsafe_devices().get(udid):
            shown = summarize_manifest(manifest)
            if not shown['failed'] and not shown['flood'] and not shown['build_failed']:
                # #3374: the test run hit its budget on an overloaded runner. The tests did not fail, the machine
                # could not finish them, so the lane waits for it to calm down and runs the plan once more itself.
                rerun = {'plan': plan, 'first': str(output), 'output': str(output.with_name(output.name + '-retry')),
                         **found}
                overload_reruns.append(rerun)
                try:
                    waited, after = wait_for_quiet_runner(found['line'])
                    rerun.update(waited_seconds=waited, load_after=after)
                    retry = run_plan(plan, selectors, Path(rerun['output']), log_name=f'verify-{plan}-retry.log')
                    rerun.update(status=retry.get('status', 'missing'), overloaded_again=bool(runner_overloaded(retry)))
                    return {**retry, 'overload_rerun': rerun}
                finally:
                    (evidence / OVERLOAD_RERUNS).write_text(json.dumps(overload_reruns, indent=2) + '\n')
        if reruns or not startup_stalled_out(manifest) or lane_sim.unsafe_devices().get(udid):
            # A clone the SpringBoard watcher stopped "stalls" at every launch after: switching devices then would
            # get around a simulator crash (AGENTS.md), so the stop decides the verdict below, as before #2176.
            return manifest
        stalls = [stall for step in manifest.get('steps', []) for stall in step.get('startup_stalls') or []]
        rerun = {'plan': plan, 'stalled': udid, 'first': str(output), 'output': str(output.with_name(output.name + '-fresh')),
                 'stalls': [{k: stall.get(k) for k in ('attempt', 'after_seconds', 'diagnosis')} for stall in stalls]}
        reruns.append(rerun)
        try:
            try:
                lane_sim.release(udid)
                with (evidence / 'simulator-clone.log').open('a') as log:
                    udid = lane_sim.clone_temporary(RUNNER_SIMULATOR_PREFIX + request_id, runtime, out=log)
                rerun['fresh'] = udid
                info = {}
                with (evidence / f'fresh-boot-{plan}.log').open('w') as log:
                    try:
                        problem, info = boot_t3_device(udid, log, None, None, info)  # its own boot stall isn't retried
                    finally:
                        udid = info.get('udid', udid)
            except (lane_sim.BootError, OSError, subprocess.SubprocessError) as error:
                problem = f'the fresh clone failed: {error}'
            if problem:
                rerun['boot'] = problem
                return {**manifest, 'fresh_clone_rerun': rerun}  # the stalled run's INCONCLUSIVE stands
            lane_sim.start_watcher(udid, ROOT / 'scripts/lane-sim-boot', crash_window=info.get('boot_window'))
            watched_devices.append(udid)
            # Its own log, so the stalled run's verify-tests.py output stays on record next to it.
            fresh = run_plan(plan, selectors, Path(rerun['output']), log_name=f'verify-{plan}-fresh.log')
            shown = summarize_manifest(fresh)
            rerun.update(status=fresh.get('status', 'missing'), passed=shown['passed'], failed=shown['failed'][:10],
                         recovered=bool(recovered_startup_stalls(fresh)), stalled_again=startup_stalled_out(fresh))
            if shown['failed']:
                rerun['verdict'] = 'FAIL'
                return {**fresh, 'fresh_clone_rerun': rerun}
            if fresh.get('status') != 'verified' and failed_step_name(fresh) in READINESS_STEPS:
                rerun['not_ready'] = failed_step_name(fresh)  # the later plans would only fail to find a ready device (#2530)
                return {**manifest, 'fresh_clone_rerun': rerun}
            if shown['flood']:  # still INCONCLUSIVE (nothing failed), but the flood must stop the later plans
                return {**fresh, 'fresh_clone_rerun': rerun}
            return {**manifest, 'fresh_clone_rerun': rerun}  # two stalls: the stalled run's INCONCLUSIVE stands
        finally:
            (evidence / FRESH_RERUNS).write_text(json.dumps(reruns, indent=2) + '\n')

    try:
        boot_started = time.monotonic()
        boot_info = {}
        with (evidence / 'first-boot.log').open('w') as log:
            try:
                problem, boot_info = boot_t3_device(udid, log, replace, evidence, boot_info)
            finally:
                udid = boot_info.get('udid', udid)  # after a stall, the fresh clone is the one to release
        boot_seconds = time.monotonic() - boot_started  # the boot alone, before any build or test
        if problem:
            details = [f'The cloned simulator did not boot: {problem} evidence: {evidence}/first-boot.log']
            if boot_info.get('period') == 'two-simulator' and 'not ready after' in problem \
                    and lane_sim.back_to_one_simulator(f'a two-simulator T3 boot ({request_id}) timed out: {problem}'):
                details.append('This boot ran while two simulators were up, so the lane is back to one simulator '
                               '(noted on #184).')
            return 'INCONCLUSIVE', where, 'nothing', details, 'watched during boot', ''
        lane_sim.start_watcher(udid, ROOT / 'scripts/lane-sim-boot',  # stops the device at a SpringBoard crash
                               crash_window=boot_info.get('boot_window'))
        watched_devices.append(udid)
        summaries, statuses, ran, details = run_plans(grouped, run_plan_or_rerun_on_a_fresh_clone, evidence,
                                                      lambda: lane_sim.is_available(udid))
        details.insert(0, f'boot of the cloned simulator took {duration(boot_seconds)} (memory pressure at boot: '
                          f'{boot_info.get("pressure", "unknown")}, after waiting {boot_info.get("pressure_waited", 0)}s; '
                          f'{boot_info.get("period", "one-simulator")} period)')
        if boot_info.get('boot_retry'):
            retry = boot_info['boot_retry']
            details.insert(1, f'boot stall on the first clone ({retry["stalled"]}), so it was deleted and one fresh clone '
                              f'({retry["fresh"]}) booted in {retry["seconds"]}s instead, before any app install or test (#1802); the stall is logged on #1802')
        if boot_info.get('tolerated'):
            details.insert(1, f'tolerated one SpringBoard change in the first 30 s of the first boot (owner\'s rule, '
                              f'#184): {boot_info["tolerated"]}')
        details.append(f'template preparation and simulator clone took {duration(clone_seconds)}; '
                       f'evidence: {evidence}/simulator-clone.log')
    finally:
        lane_sim.release(udid)
    watched, unsafe = None, lane_sim.unsafe_devices()
    for device in dict.fromkeys(watched_devices):  # every clone a plan ran on under the watcher
        mark = unsafe.get(device)
        if mark and mark['reason'].startswith('late crash report'):
            # A crash during the boot, reported after it: the device is marked unsafe, but the run itself went on.
            details.append(f'after the run started, a crash report arrived for a crash during the boot of {device} '
                           f'({mark["reason"]}); the device was marked unsafe and deleted')
        elif mark and not watched:
            watched = mark
    crash_names = [c for s in summaries for c in s['crashes']]
    flood = any(s['flood'] for s in summaries) or bool(watched)
    crashes = ('crash flood: ' if flood else '') + (', '.join(crash_names) if crash_names else 'none')
    if watched:
        crashes += f' (the SpringBoard watcher stopped the device: {watched["reason"]})'
        statuses.append('stopped by the SpringBoard watcher')
    elif flood:
        crashes += ' (simulator shut down, run stopped)'
    cc = '@uncomposed: SpringBoard crashed on the lane runner\'s simulator.' if flood else ''
    verdict = 'INCONCLUSIVE' if watched else t3_verdict(summaries, statuses)  # a simulator crash, not the app
    timed_out = any(s['out_of_time'] for s in summaries) or 'timed out' in statuses
    if verdict == 'INCONCLUSIVE' and timed_out and boot_info.get('period') == 'two-simulator' \
            and lane_sim.back_to_one_simulator(f'a two-simulator T3 run ({request_id}) ended INCONCLUSIVE on a timeout.'):
        details.append('This ran while two simulators were up and timed out, so the lane is back to one simulator '
                       '(noted on #184).')
    return verdict, where, '; '.join(ran), details, crashes, cc


def _read_manifest(output: Path) -> dict:
    try:
        return json.loads((output / 'manifest.json').read_text())
    except (OSError, ValueError):
        return {}


def utc(stamp: str):
    """A git or GitHub ISO 8601 time as an aware datetime (Python 3.9 can't read a trailing Z)."""
    import datetime
    return datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).astimezone(datetime.timezone.utc)


class Repo:
    """The repository-wide GitHub calls the auto-revert needs (GitHub above is one PR's)."""

    def __init__(self, repo: str):
        self.repo = repo

    def api(self, *args: str) -> str:
        return subprocess.check_output(['gh', 'api', *args], text=True)

    def comments_since(self, since: str):
        """Every issue and PR comment created since <since>, oldest first, a page at a time."""
        page = 1
        while True:
            batch = json.loads(self.api(f'repos/{self.repo}/issues/comments?since={since}&sort=created'
                                        f'&direction=asc&per_page=100&page={page}'))
            yield from batch
            if len(batch) < 100:
                return
            page += 1

    def issue_comments(self, number: int) -> list[dict]:
        lines = self.api('--paginate', '--jq', '.[] | @json', f'repos/{self.repo}/issues/{number}/comments')
        return [json.loads(line) for line in lines.splitlines() if line.strip()]

    def comment(self, number: int, body: str) -> str:
        return json.loads(self.api(f'repos/{self.repo}/issues/{number}/comments', '-f', f'body={body}'))['html_url']

    def title(self, number: int) -> str:
        return json.loads(self.api(f'repos/{self.repo}/pulls/{number}')).get('title', '')

    def open_issue(self, title: str, body: str, labels: list[str]) -> str:
        args = [f'repos/{self.repo}/issues', '-f', f'title={title}', '-f', f'body={body}']
        for label in labels:
            args += ['-f', f'labels[]={label}']
        return json.loads(self.api(*args))['html_url']


def runner_device_claim(name: str) -> Path:
    from lane_slots import state_dir
    return state_dir() / ('runner-device-' + re.sub(r'[^A-Za-z0-9._-]+', '-', name) + '.lock')


def claim_runner_device(name: str):
    """Lock the name of the device a T3 job is about to create, until the job has deleted it (#440).

    Both runners live on this Mac, and every lane job starts by sweeping leftover runner simulators. Without
    the claim, a job starting on the other runner deleted a T3's device mid-run: exit 148 at the readiness
    step (#440), or xcodebuild's "Unable to find a device" (exit 70, #411). The kernel drops the lock when
    this process exits, however it exits, so a crashed job's device is still swept.
    """
    import fcntl
    path = runner_device_claim(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open('a+')
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def release_runner_device(handle) -> None:
    Path(handle.name).unlink(missing_ok=True)
    handle.close()
