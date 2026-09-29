#!/usr/bin/env python3
"""The lane's deterministic tiers: run a T2 or T3 request from a PR and post the report.

Run by .github/workflows/lane.yml on the Mac's self-hosted runner. The workflow checks out the PR's
head in --tree and runs this script as taken from the base branch (next); the script merges the
newest next into the tree itself, so a report tests the PR against the current next even when
GitHub's merge ref for the PR is stale. Agent sessions can't run it (the lane guard blocks it); they ask
by commenting a request and adding the lane:queued label. Formats: docs/workstreams/test-lane.md.

- The runner takes the newest T2/T3 request it hasn't answered yet. T4 and T5 requests belong to the
  Test Desk: while one is waiting, the runner leaves lane:queued in place so the Test Desk sees it.
- The newest commit wins: if the PR moved on since this run was queued, a newer run tests it.
- A request identical to one that already has a PASS or FAIL report (same head merged into the
  same next, tier and tests) runs once. After an INCONCLUSIVE report, asking again runs again.
- T2 builds for simulator and device (unsigned) through scripts/xcodebuild-lane.
- T3 runs the named app-hosted tests through verify-tests.py on a fresh iOS 26 simulator, created
  for the job and deleted afterwards. It is booted under the lane's boot rules (scripts/lane_sim.py):
  one boot at a time, no builds meanwhile, no retry after a failed boot, a stop at the first crash
  during boot, and a long wait for the first boot's data migration. The job holds the Mac's one
  simulator slot throughout, so it never runs alongside a Test Desk job. A crash flood stops the run.
- A timeout interrupts the whole process group, so no xcodebuild keeps running outside the slots.

Environment: GH_TOKEN and GH_REPO (the workflow's), SM_LANE_EVIDENCE_DIR (where evidence goes,
default ~/Library/Caches/SpokenMarginsLane/evidence), SM_LANE_TOOLS (a checkout whose .venv and
node_modules to link in, default the owner's main checkout).
Stdlib only, Python 3.9-compatible: it runs under /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

QUEUED, RUNNING, DONE = 'lane:queued', 'lane:running', 'lane:done'
RUNNER_TIERS = ('T2', 'T3')
APP_TEST_TARGET = 'SpokenMarginsAppTests'
PLANS = {'app': 'AppBehavior', 'adapters': 'AudioAdapters'}
# The device build compiles without signing: the runner is a background service with no access to
# the login keychain's signing key (errSecInternalComponent), and signing is a release-archive check.
T2_BUILDS = (('simulator', ["-destination", "generic/platform=iOS Simulator", "build-for-testing"]),
             ('device', ["-destination", "generic/platform=iOS", "CODE_SIGNING_ALLOWED=NO", "build"]))
BUILD_TIMEOUT = 1800
T3_TIMEOUT = 3600
INTERRUPT_GRACE = 120
RUNNER_SIMULATOR_PREFIX = 'SM Lane Runner '
# How long a T3 waits for the Mac's one simulator slot (a Test Desk job may hold it); keeps the job
# inside lane.yml's 150-minute limit together with the boot and the test run.
RUNNER_SLOT_WAIT = 3600
MARKER = re.compile(r'<!-- lane-request: (\{.*?\}) -->')
NOTE = '<!-- lane-note -->'
REQUEST = re.compile(r'^\s*/lane\s+(T\d)\b', re.M)
REPORT = re.compile(r'^Lane report \S+ — (PASS|FAIL|INCONCLUSIVE)', re.M)


# ---- Requests -----------------------------------------------------------------------------------

def parse_request(body: str) -> dict | None:
    """The /lane line and the `key: value` lines after it, or None if the comment isn't a request."""
    lines = body.replace('\r\n', '\n').split('\n')
    for index, line in enumerate(lines):
        match = REQUEST.match(line)
        if not match:
            continue
        request = {'tier': match.group(1)}
        for extra in lines[index + 1:]:
            field = re.match(r'^\s*([a-z][a-z ]*?)\s*:\s*(.*)$', extra)
            if field:
                request[field.group(1)] = re.sub(r'\s+#.*$', '', field.group(2)).strip()
        # test-lane.md's example once read `run: J1, J7   # or: tests: …`, so `run: tests: A, B` is
        # accepted too; a separate `tests:` line wins.
        inline = re.match(r'^tests\s*:\s*(.*)$', request.get('run', ''))
        if inline and not request.get('tests'):
            request['tests'] = inline.group(1)
        request['tests'] = [t for t in re.split(r'[,\s]+', request.get('tests', '')) if t]
        return request
    return None


def is_runner_comment(body: str) -> bool:
    return bool(MARKER.search(body)) or NOTE in body


def pending_requests(comments: list[dict]) -> tuple[dict | None, bool]:
    """The newest T2/T3 request the runner hasn't answered, and whether a T4/T5 request is waiting.

    A runner request is answered once a runner report or note comes after it. A Test Desk request
    is waiting until a report that isn't the runner's (the Test Desk's) comes after it.
    """
    runner_request, runner_answered, desk_request, desk_answered = None, -1, -1, -1
    for index, comment in enumerate(comments):
        body = comment.get('body') or ''
        if is_runner_comment(body):
            runner_answered = index
            continue
        if REPORT.search(body):
            desk_answered = index
            continue
        request = parse_request(body)
        if not request:
            continue
        if request['tier'] in RUNNER_TIERS:
            runner_request = (index, dict(request, url=comment.get('html_url'),
                                          author=(comment.get('user') or {}).get('login')))
        else:
            desk_request = index
    newest = runner_request[1] if runner_request and runner_request[0] > runner_answered else None
    return newest, desk_request > desk_answered


def identity(tier: str, commit: str, base: str, tests: list[str]) -> dict:
    """What a report covers: the PR head merged into this next commit (a moved next runs again)."""
    return {'tier': tier, 'commit': commit, 'next': base, 'tests': sorted(tests)}


def earlier_report(comments: list[dict], wanted: dict) -> tuple[str, str] | None:
    """(URL, verdict) of a PASS or FAIL lane report already posted for this exact request.

    INCONCLUSIVE doesn't count: that request runs again.
    """
    for comment in comments:
        body = comment.get('body') or ''
        match, verdict = MARKER.search(body), REPORT.search(body)
        if not match or not verdict or verdict.group(1) == 'INCONCLUSIVE':
            continue
        try:
            if json.loads(match.group(1)) == wanted:
                return comment.get('html_url') or 'an earlier comment', verdict.group(1)
        except ValueError:
            continue
    return None


# ---- Reports ------------------------------------------------------------------------------------

def duration(seconds: float) -> str:
    minutes, seconds = divmod(int(seconds), 60)
    return f'{minutes}m{seconds:02d}s' if minutes else f'{seconds}s'


def report(request_id: str, verdict: str, head: str, base: str, tier: str, where: str, seconds: float,
           ran: str, details: list[str], crashes: str, evidence: str, not_verified: str, wanted: dict,
           cc: str = '', base_name: str = 'next') -> str:
    lines = [f'Lane report {request_id} — {verdict}',
             f'commit {head[:7]} (tested merged with {base_name} at {base[:7]}) · tier {tier} · {where} · {duration(seconds)}',
             f'ran: {ran}', *details, f'crashes: {crashes}', f'evidence: {evidence} (on the Mac)',
             f'not verified: {not_verified}']
    if cc:
        lines.append(cc)
    return '\n'.join(lines) + f'\n<!-- lane-request: {json.dumps(wanted, sort_keys=True)} -->\n'


# ---- Processes ----------------------------------------------------------------------------------

def run_bounded(command: list[str], log, timeout: float, grace: float = INTERRUPT_GRACE) -> int | None:
    """Run in a new process group and return its exit code, or None if it timed out.

    On timeout the whole group gets SIGINT first, so verify-tests.py and xcodebuild-lane stop their
    own xcodebuild and record the interruption, then SIGKILL if it's still there after the grace.
    """
    # The child gets default SIGINT handling even if this process was started with it ignored (as
    # background jobs are), or the interrupt below would be silently ignored all the way down.
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                               preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
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


# ---- T2 -----------------------------------------------------------------------------------------

def first_errors(log: Path, limit: int = 5) -> list[str]:
    try:
        text = log.read_text(errors='replace')
    except OSError:
        return []
    lines = text.splitlines()
    found = [line.strip() for line in lines if ' error: ' in line or line.startswith('error:') or 'errSec' in line]
    if 'The following build commands failed:' in lines:
        for line in lines[lines.index('The following build commands failed:') + 1:]:
            if not line.strip():
                break
            found.append('failed: ' + line.strip())
    return list(dict.fromkeys(found))[:limit]


def run_t2(evidence: Path, runner=run_bounded) -> tuple[str, str, list[str]]:
    results, details = [], []
    for name, args in T2_BUILDS:
        log = evidence / f't2-{name}.log'
        command = [str(ROOT / 'scripts/xcodebuild-lane'), '-project', 'SpokenMarginsNative.xcodeproj',
                   '-scheme', 'SpokenMarginsApp', *args]
        with log.open('w') as handle:
            code = runner(command, handle, BUILD_TIMEOUT)
        if code == 0:
            results.append(f'{name} build (pass)')
        else:
            results.append(f'{name} build ({"timed out" if code is None else "fail"})')
            details.append(f'{name} build — expected: succeeds. observed: '
                           f'{"no result after " + duration(BUILD_TIMEOUT) if code is None else f"exit {code}"}. '
                           f'evidence: {log}')
            details += [f'  {line}' for line in first_errors(log)]
    failed = [r for r in results if not r.endswith('(pass)')]
    verdict = 'PASS' if not failed else ('INCONCLUSIVE' if all('timed out' in r for r in failed) else 'FAIL')
    return verdict, ', '.join(results), details


# ---- T3 -----------------------------------------------------------------------------------------

def plan_for_tests(selectors: list[str], plans: dict[str, set]) -> tuple[dict[str, list[str]], list[str]]:
    """Group selectors by the plan holding them; selectors no plan holds are returned separately."""
    grouped, unknown = {}, []
    for selector in selectors:
        full = selector if selector.startswith(APP_TEST_TARGET + '/') else f'{APP_TEST_TARGET}/{selector}'
        plan = next((p for p, tests in plans.items()
                     if any(t == full or t.startswith(full + '/') for t in tests)), None)
        if plan:
            grouped.setdefault(plan, []).append(full)
        else:
            unknown.append(selector)
    return grouped, unknown


def summarize_manifest(manifest: dict) -> dict:
    """Test counts, failed tests, crash reports and whether a flood or timeout stopped the run.

    A build that was interrupted (timeout or flood) is not a build failure: that's INCONCLUSIVE.
    """
    summary = {'passed': 0, 'failed': [], 'crashes': [], 'flood': False, 'interrupted': False, 'build_failed': False,
               'out_of_time': None}
    for step in manifest.get('steps', []):
        if step.get('interrupted') and not step.get('simulator_crash_report') and step.get('timeout_seconds'):
            summary['out_of_time'] = (step.get('name'), step.get('timeout_seconds'))
        for test, record in (step.get('tests') or {}).items():
            if record.get('status') == 'passed':
                summary['passed'] += 1
            elif record.get('status') == 'failed':
                summary['failed'].append(test)
        summary['crashes'] += [Path(p).name for p in step.get('simulator_crash_reports', [])]
        summary['flood'] |= bool(step.get('simulator_crash_report'))
        summary['interrupted'] |= bool(step.get('interrupted'))
        summary['build_failed'] |= (step.get('name') == 'build-for-testing' and bool(step.get('errors'))
                                    and not step.get('interrupted'))
    return summary


def t3_verdict(summaries: list[dict], statuses: list[str]) -> str:
    if statuses and all(status == 'verified' for status in statuses):
        return 'PASS'
    if any(s['failed'] or s['build_failed'] for s in summaries):
        return 'FAIL'
    return 'INCONCLUSIVE'


def run_plans(grouped: dict[str, list[str]], run_plan, evidence: Path) -> tuple[list, list, list, list]:
    """Run each plan's selectors; stop at the first crash flood (AGENTS.md: don't reboot in a loop)."""
    summaries, statuses, ran, details = [], [], [], []
    plans = list(grouped.items())
    for position, (plan, selectors) in enumerate(plans):
        output = evidence / f'verify-{plan}'
        manifest = run_plan(plan, selectors, output)
        summary = summarize_manifest(manifest)
        summaries.append(summary)
        statuses.append(manifest.get('status', 'missing'))
        ran.append(f'{", ".join(s.split("/", 1)[1] for s in selectors)} ({summary["passed"]} passed'
                   f'{", " + str(len(summary["failed"])) + " failed" if summary["failed"] else ""})')
        for test in summary['failed'][:10]:
            details.append(f'{test} — expected: passes. observed: failed. evidence: {output}/tests.xcresult')
        if summary['out_of_time']:
            step, limit = summary['out_of_time']
            what = {'xcode-tests': 'test run', 'build-for-testing': 'build'}.get(step, step)
            details.append(f'{plan}: the {what} ran out of its own {duration(limit)} budget (verify-tests.py `{step}`) '
                           f'after {summary["passed"]} passing test{"s" if summary["passed"] != 1 else ""}. '
                           'The simulator\'s boot has a separate budget and had finished before it started.')
        if manifest.get('status') != 'verified' and not summary['failed']:
            details.append(f'{plan}: {manifest.get("error") or manifest.get("status")}. evidence: {output}/manifest.json')
        if summary['flood']:
            skipped = [p for p, _ in plans[position + 1:]]
            if skipped:
                details.append(f'Stopped after the crash flood; not run: {", ".join(skipped)}.')
                statuses.append('not run')
            break
    return summaries, statuses, ran, details


def first_boot(udid: str, log) -> tuple:
    """Boot the fresh simulator under the lane's boot rules (scripts/lane_sim.py).

    Returns (None when ready or the reason it isn't, details such as the memory pressure at boot).
    """
    import lane_sim
    info = {}
    try:
        lane_sim.boot(udid, f'runner boot {udid}', out=log, info=info, first_boot=True)
    except lane_sim.BootError as error:
        return str(error), info
    return None, info


def run_t3(tests: list[str], request_id: str, evidence: Path) -> tuple[str, str, str, list[str], str, str]:
    """Returns verdict, where, ran, details, crashes, cc."""
    from test_inventory import plan_tests
    if not tests:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The T3 request names no tests. Add `tests: Class/method, …` '
                '(scripts/test-scope.py suggests them).'], 'none', '')
    plans = {plan: plan_tests(ROOT, name) for plan, name in PLANS.items()}
    grouped, unknown = plan_for_tests(tests, plans)
    if unknown:
        return ('FAIL', 'no simulator', 'nothing', [f'Not in any app test plan: {", ".join(unknown)}. A named test '
                'that does not exist is a failure (verify-tests.py rule).'], 'none', '')
    import lane_sim
    runtime = lane_sim.newest_runtime()
    if not runtime:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', [f'No iOS {lane_sim.IOS_MAJOR} simulator runtime is installed.'],
                'none', '')
    from lane_slots import acquire_simulator_slot, release_handle
    try:
        slot = acquire_simulator_slot(f'runner T3 {request_id}', out=sys.stdout, max_wait=RUNNER_SLOT_WAIT)
    except TimeoutError as error:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The Mac\'s simulator slots stayed busy (a Test Desk job or '
                f'another run, and no room for a second simulator), so this run did not start one: {error}'], 'none', '')
    try:
        return _t3_on_fresh_device(grouped, request_id, evidence, runtime)
    finally:
        release_handle(slot)


def _t3_on_fresh_device(grouped, request_id, evidence, runtime):
    """The T3 job proper; the caller holds the simulator slot throughout."""
    import lane_sim
    udid = lane_sim.create_temporary(RUNNER_SIMULATOR_PREFIX + request_id)
    where = f'fresh iPhone 17, {runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")}'
    python = ROOT / '.venv/bin/python'

    def run_plan(plan, selectors, output):
        command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', plan,
                   '--device', udid, '--output', str(output)]
        for selector in selectors:
            command += ['--only-testing', selector]
        with (evidence / f'verify-{plan}.log').open('w') as log:
            if run_bounded(command, log, T3_TIMEOUT) is None:
                return {**_read_manifest(output), 'status': 'timed out',
                        'error': f'the runner\'s {duration(T3_TIMEOUT)} budget for the whole verify-tests.py run '
                                 '(build and tests) ran out; interrupted'}
        return _read_manifest(output) or {'status': 'missing', 'error': 'verify-tests.py wrote no manifest'}

    try:
        boot_started = time.monotonic()
        with (evidence / 'first-boot.log').open('w') as log:
            problem, boot_info = first_boot(udid, log)
        boot_seconds = time.monotonic() - boot_started  # the boot alone, before any build or test
        if problem:
            details = [f'The fresh simulator did not boot: {problem} evidence: {evidence}/first-boot.log']
            if boot_info.get('period') == 'two-simulator' and 'not ready after' in problem \
                    and lane_sim.back_to_one_simulator(f'a two-simulator T3 boot ({request_id}) timed out: {problem}'):
                details.append('This boot ran while two simulators were up, so the lane is back to one simulator '
                               '(noted on #184).')
            return 'INCONCLUSIVE', where, 'nothing', details, 'watched during boot', ''
        lane_sim.start_watcher(udid, ROOT / 'scripts/lane-sim-boot',  # stops the device at a SpringBoard crash
                               crash_window=boot_info.get('boot_window'))
        summaries, statuses, ran, details = run_plans(grouped, run_plan, evidence)
        details.insert(0, f'first boot of the fresh simulator took {duration(boot_seconds)} (memory pressure at boot: '
                          f'{boot_info.get("pressure", "unknown")}, after waiting {boot_info.get("pressure_waited", 0)}s; '
                          f'{boot_info.get("period", "one-simulator")} period)')
        if boot_info.get('tolerated'):
            details.insert(1, f'tolerated one SpringBoard change in the first 30 s of the first boot (owner\'s rule, '
                              f'#184): {boot_info["tolerated"]}')
    finally:
        lane_sim.release(udid)
    watched = lane_sim.unsafe_devices().get(udid)
    if watched and watched['reason'].startswith('late crash report'):
        # A crash during the boot, reported after it: the device is marked unsafe, but the run itself went on.
        details.append(f'after the run started, a crash report arrived for a crash during the boot ({watched["reason"]}); '
                       'the device was marked unsafe and deleted')
        watched = None
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


# ---- GitHub -------------------------------------------------------------------------------------

class GitHub:
    def __init__(self, repo: str, pr: int):
        self.repo, self.pr = repo, pr

    def api(self, *args: str) -> str:
        return subprocess.check_output(['gh', 'api', *args], text=True)

    def pull(self) -> dict:
        return json.loads(self.api(f'repos/{self.repo}/pulls/{self.pr}'))

    def comments(self) -> list[dict]:
        lines = self.api('--paginate', '--jq', '.[] | @json', f'repos/{self.repo}/issues/{self.pr}/comments')
        return [json.loads(line) for line in lines.splitlines() if line.strip()]

    def comment(self, body: str) -> str:
        return json.loads(self.api(f'repos/{self.repo}/issues/{self.pr}/comments', '-f', f'body={body}'))['html_url']

    def relabel(self, remove: str | None, add: str | None) -> None:
        if remove:
            subprocess.run(['gh', 'api', '-X', 'DELETE',
                            f'repos/{self.repo}/issues/{self.pr}/labels/{remove.replace(":", "%3A")}'],
                           capture_output=True)
        if add:
            self.api('-X', 'POST', f'repos/{self.repo}/issues/{self.pr}/labels', '-f', f'labels[]={add}')


# ---- Main ---------------------------------------------------------------------------------------

def sweep_runner_simulators() -> None:
    """Delete simulators a previous runner job left behind (only this one runner makes them)."""
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    for group in devices.get('devices', {}).values():
        for device in group:
            if device.get('name', '').startswith(RUNNER_SIMULATOR_PREFIX):
                subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], capture_output=True, timeout=120)
                subprocess.run(['xcrun', 'simctl', 'delete', device['udid']], capture_output=True, timeout=120)
                print(f'Deleted leftover simulator {device["name"]}')


def cleanup(github: GitHub, run_url: str) -> int:
    """After a failed or cancelled job: remove leftovers, say so on the PR, and free the labels."""
    sweep_runner_simulators()
    _, desk_waiting = pending_requests(github.comments())
    github.comment(f'Lane: the runner stopped before reporting ({run_url}). If it is still needed, comment '
                   f'the request again and add lane:queued.\n{NOTE}')
    github.relabel(RUNNING, None)
    if not desk_waiting:
        github.relabel(QUEUED, None)
    return 0


def fetch_base(tree: Path, base: str) -> str:
    """Fetch the newest base branch into the tree and return its commit."""
    subprocess.run(['git', '-C', str(tree), 'fetch', '--no-tags', '--quiet', 'origin', base], check=True)
    return subprocess.check_output(['git', '-C', str(tree), 'rev-parse', f'origin/{base}'], text=True).strip()


def merge_base_branch(tree: Path, base: str) -> list[str]:
    """Merge origin/<base> into the checked-out PR head. Returns the conflicting files, if any."""
    git = ['git', '-C', str(tree)]
    merged = subprocess.run(git + ['-c', 'user.name=Spoken Margins lane', '-c', 'user.email=lane@localhost',
                                   'merge', '--no-edit', '--quiet', f'origin/{base}'], capture_output=True, text=True)
    if merged.returncode == 0:
        return []
    conflicts = subprocess.run(git + ['diff', '--name-only', '--diff-filter=U'], capture_output=True,
                               text=True).stdout.split()
    subprocess.run(git + ['merge', '--abort'], capture_output=True)
    return conflicts or [merged.stderr.strip().splitlines()[-1] if merged.stderr.strip() else 'the merge failed']


def record_outcome(verdict: str) -> None:
    """Hand the verdict to the workflow, whose last step makes the check red unless it is PASS (#184).

    The script itself exits 0 once it has reported, so a lane.yml from before this change (on a PR that
    hasn't merged next) stays green on FAIL, as before, instead of posting "stopped before reporting".
    """
    outputs = os.environ.get('GITHUB_OUTPUT')
    if outputs:
        with open(outputs, 'a') as handle:
            handle.write(f'reported=true\nverdict={verdict}\n')


def link_tools(source: Path) -> None:
    for name in ('.venv', 'node_modules'):
        if not (ROOT / name).exists() and (source / name).exists():
            (ROOT / name).symlink_to(source / name)


def main(argv=None) -> int:
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--event-head', required=True, help='head SHA the triggering event saw')
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--tree', type=Path, default=ROOT, help='checkout of the PR head to test')
    parser.add_argument('--base', default='next', help='branch the PR merges into')
    parser.add_argument('--cleanup', action='store_true', help='tidy up after a cancelled or failed job')
    args = parser.parse_args(argv)
    ROOT = args.tree.resolve()
    sys.path.insert(0, str(ROOT / 'scripts'))
    repo = os.environ['GH_REPO']
    github = GitHub(repo, args.pr)
    run_url = f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{repo}/actions/runs/{args.run_id}'
    if args.cleanup:
        return cleanup(github, run_url)
    sweep_runner_simulators()
    head = github.pull()['head']['sha']
    if head != args.event_head:
        print(f'The PR moved on to {head[:7]} since this run was queued; the newer run tests it.')
        return 0
    comments = github.comments()
    request, desk_waiting = pending_requests(comments)
    if request is None:
        if not desk_waiting:
            github.comment('Lane: lane:queued is set, but there is no `/lane T2` or `/lane T3` request comment newer '
                           'than the last lane report, so nothing ran. Comment the request (format in '
                           f'docs/workstreams/test-lane.md), then add lane:queued.\n{NOTE}')
            github.relabel(QUEUED, None)
        print('No unanswered T2/T3 request; nothing to do.')
        return 0
    base_sha = fetch_base(ROOT, args.base)
    wanted = identity(request['tier'], head, base_sha, request['tests'])
    done_before = earlier_report(comments, wanted)
    if done_before:
        url, earlier_verdict = done_before
        github.comment(f'Lane: identical {request["tier"]} request for {head[:7]} already reported '
                       f'({earlier_verdict}): {url}\n{NOTE}')
        if not desk_waiting:
            github.relabel(QUEUED, DONE)
        record_outcome(earlier_verdict)  # a repeated FAIL stays red
        return 0
    request_id = f'pr{args.pr}-r{args.run_id}'
    evidence = Path(os.environ.get('SM_LANE_EVIDENCE_DIR') or
                    Path.home() / 'Library/Caches/SpokenMarginsLane/evidence') / request_id
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'request.json').write_text(json.dumps(dict(request, head=head, base=args.base, base_sha=base_sha),
                                                      indent=2))
    if not desk_waiting:  # a waiting T4/T5 keeps lane:queued so the Test Desk still sees it
        github.relabel(QUEUED, RUNNING)
    link_tools(Path(os.environ.get('SM_LANE_TOOLS') or Path.home() / 'Documents/GitHub/spoken-margins-native'))
    started = time.monotonic()
    requested = request.get('commit', '')
    moved = [f'requested {requested[:7]}, tested the newest commit {head[:7]}'] \
        if requested and not head.startswith(requested) else []
    cc = ''
    try:
        conflicts = merge_base_branch(ROOT, args.base)
        if conflicts:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no simulator', 'nothing', 'none'
            details = [f'The PR does not merge cleanly into {args.base} ({base_sha[:7]}): {", ".join(conflicts[:10])}. '
                       f'Merge {args.base} into your branch, push, and ask again.']
        elif request['tier'] == 'T2':
            verdict, ran, details = run_t2(evidence)
            where, crashes = 'no simulator (compile only)', 'none'
        else:
            verdict, where, ran, details, crashes, cc = run_t3(request['tests'], request_id, evidence)
    except Exception as error:  # noqa: BLE001 - any lane fault is reported, never silent
        verdict, where, ran, crashes = 'INCONCLUSIVE', 'lane error', 'nothing', 'unknown'
        details = [f'The lane itself failed: {error!r}. evidence: {evidence}']
    body = report(request_id, verdict, head, base_sha, request['tier'], where, time.monotonic() - started,
                  ran, moved + details, crashes, str(evidence),
                  'journeys and anything a listener notices (T4), audible content (owner)', wanted, cc, args.base)
    (evidence / 'report.md').write_text(body)
    print(body)
    github.comment(body)  # if this fails, the job fails and the tidy step says so on the PR
    record_outcome(verdict)
    _, desk_waiting = pending_requests(github.comments())
    github.relabel(RUNNING, QUEUED if desk_waiting else DONE)
    shutil.rmtree(ROOT / '.build/dd', ignore_errors=True)
    shutil.rmtree(ROOT / '.build/verification', ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
