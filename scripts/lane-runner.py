#!/usr/bin/env python3
"""The lane's deterministic tiers: run a T2 or T3 request from a PR and post the report.

Run by .github/workflows/lane.yml on the Mac's self-hosted runner, in a checkout of the PR merged
into next. Agent sessions can't run it (the lane guard blocks it); they ask by commenting a request
and adding the lane:queued label. Formats: docs/workstreams/test-lane.md.

- T4 and T5 requests belong to the Test Desk and are left alone.
- The newest commit wins: if the PR moved on since this run was queued, a newer run tests it.
- An identical request (same commit, tier and tests) that already has a report runs once.
- T2 builds for simulator and device (unsigned) through scripts/xcodebuild-lane.
- T3 runs the named app-hosted tests through verify-tests.py on a temporary iOS 26 simulator,
  created for the job and deleted afterwards (iOS 27's Apple Intelligence services crash-flood
  on this Mac, #184).

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
T3_IOS_MAJOR = 26
T3_DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
MARKER = re.compile(r'<!-- lane-request: (\{.*?\}) -->')
REQUEST = re.compile(r'^\s*/lane\s+(T\d)\b', re.M)


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
        request['tests'] = [t for t in re.split(r'[,\s]+', request.get('tests', '')) if t]
        return request
    return None


def latest_request(comments: list[dict]) -> dict | None:
    """The newest comment that is a lane request, with its URL; reports are never requests."""
    for comment in reversed(comments):
        body = comment.get('body') or ''
        if body.lstrip().startswith('Lane report') or MARKER.search(body):
            continue
        request = parse_request(body)
        if request:
            return dict(request, url=comment.get('html_url'), author=(comment.get('user') or {}).get('login'))
    return None


def identity(tier: str, commit: str, merge: str, tests: list[str]) -> dict:
    """What a report covers: the PR head as merged into next (so a changed next or lane runs again)."""
    return {'tier': tier, 'commit': commit, 'merge': merge, 'tests': sorted(tests)}


def earlier_report(comments: list[dict], wanted: dict) -> str | None:
    """URL of a lane report already posted for this exact commit, tier and tests."""
    for comment in comments:
        match = MARKER.search(comment.get('body') or '')
        if match:
            try:
                if json.loads(match.group(1)) == wanted:
                    return comment.get('html_url') or 'an earlier comment'
            except ValueError:
                continue
    return None


# ---- Reports ------------------------------------------------------------------------------------

def duration(seconds: float) -> str:
    minutes, seconds = divmod(int(seconds), 60)
    return f'{minutes}m{seconds:02d}s' if minutes else f'{seconds}s'


def report(request_id: str, verdict: str, head: str, merge: str, tier: str, where: str, seconds: float,
           ran: str, details: list[str], crashes: str, evidence: str, not_verified: str, wanted: dict,
           cc: str = '') -> str:
    lines = [f'Lane report {request_id} — {verdict}',
             f'commit {head[:7]} (tested merged into next as {merge[:7]}) · tier {tier} · {where} · {duration(seconds)}',
             f'ran: {ran}', *details, f'crashes: {crashes}', f'evidence: {evidence} (on the Mac)',
             f'not verified: {not_verified}']
    if cc:
        lines.append(cc)
    return '\n'.join(lines) + f'\n<!-- lane-request: {json.dumps(wanted, sort_keys=True)} -->\n'


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


def run_t2(evidence: Path, runner=subprocess.run) -> tuple[str, str, list[str]]:
    results, details = [], []
    for name, args in T2_BUILDS:
        log = evidence / f't2-{name}.log'
        command = [str(ROOT / 'scripts/xcodebuild-lane'), '-project', 'SpokenMarginsNative.xcodeproj',
                   '-scheme', 'SpokenMarginsApp', *args]
        with log.open('w') as handle:
            try:
                code = runner(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT,
                              timeout=BUILD_TIMEOUT).returncode
            except subprocess.TimeoutExpired:
                code = None
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
    """Test counts, failed tests, crash reports and whether a flood or timeout stopped the run."""
    summary = {'passed': 0, 'failed': [], 'crashes': [], 'flood': False, 'interrupted': False, 'build_failed': False}
    for step in manifest.get('steps', []):
        for test, record in (step.get('tests') or {}).items():
            if record.get('status') == 'passed':
                summary['passed'] += 1
            elif record.get('status') == 'failed':
                summary['failed'].append(test)
        summary['crashes'] += [Path(p).name for p in step.get('simulator_crash_reports', [])]
        summary['flood'] |= bool(step.get('simulator_crash_report'))
        summary['interrupted'] |= bool(step.get('interrupted'))
        summary['build_failed'] |= step.get('name') == 'build-for-testing' and bool(step.get('errors'))
    return summary


def t3_verdict(summaries: list[dict], statuses: list[str]) -> str:
    if all(status == 'verified' for status in statuses):
        return 'PASS'
    if any(s['failed'] or s['build_failed'] for s in summaries):
        return 'FAIL'
    return 'INCONCLUSIVE'


def newest_runtime(major: int) -> str | None:
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json'], text=True))
    usable = [r for r in runtimes.get('runtimes', [])
              if r.get('isAvailable') and r.get('platform') == 'iOS' and r.get('version', '').split('.')[0] == str(major)]
    usable.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
    return usable[-1]['identifier'] if usable else None


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
    runtime = newest_runtime(T3_IOS_MAJOR)
    if not runtime:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', [f'No iOS {T3_IOS_MAJOR} simulator runtime is installed.'],
                'none', '')
    name = f'SM Lane Runner {request_id}'
    udid = subprocess.check_output(['xcrun', 'simctl', 'create', name, T3_DEVICE_TYPE, runtime], text=True).strip()
    where = f'temporary iPhone 17, {runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")}'
    python = ROOT / '.venv/bin/python'
    summaries, statuses, ran, details = [], [], [], []
    try:
        for plan, selectors in grouped.items():
            output = evidence / f'verify-{plan}'
            command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', plan,
                       '--device', udid, '--output', str(output)]
            for selector in selectors:
                command += ['--only-testing', selector]
            with (evidence / f'verify-{plan}.log').open('w') as log:
                try:
                    subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=T3_TIMEOUT)
                except subprocess.TimeoutExpired:
                    details.append(f'{plan}: no result after {duration(T3_TIMEOUT)}; stopped.')
            try:
                manifest = json.loads((output / 'manifest.json').read_text())
            except (OSError, ValueError):
                manifest = {'status': 'missing', 'error': 'verify-tests.py wrote no manifest'}
            summary = summarize_manifest(manifest)
            summaries.append(summary)
            statuses.append(manifest.get('status', 'missing'))
            ran.append(f'{", ".join(s.split("/", 1)[1] for s in selectors)} ({summary["passed"]} passed'
                       f'{", " + str(len(summary["failed"])) + " failed" if summary["failed"] else ""})')
            for test in summary['failed'][:10]:
                details.append(f'{test} — expected: passes. observed: failed. evidence: {output}/tests.xcresult')
            if manifest.get('status') != 'verified' and not summary['failed']:
                details.append(f'{plan}: {manifest.get("error") or manifest.get("status")}. evidence: {output}/manifest.json')
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], capture_output=True, timeout=120)
        subprocess.run(['xcrun', 'simctl', 'delete', udid], capture_output=True, timeout=120)
    crash_names = [c for s in summaries for c in s['crashes']]
    flood = any(s['flood'] for s in summaries)
    crashes = ('crash flood: ' if flood else '') + (', '.join(crash_names) if crash_names else 'none')
    if flood:
        crashes += ' (simulator shut down, run stopped)'
    cc = '@uncomposed: crash flood on the lane runner.' if flood else ''
    return t3_verdict(summaries, statuses), where, '; '.join(ran), details, crashes, cc


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

def cleanup(github: GitHub) -> int:
    """After a cancelled or crashed job: delete leftover runner simulators and clear lane:running."""
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    for group in devices.get('devices', {}).values():
        for device in group:
            if device.get('name', '').startswith('SM Lane Runner '):
                subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], capture_output=True, timeout=120)
                subprocess.run(['xcrun', 'simctl', 'delete', device['udid']], capture_output=True, timeout=120)
                print(f'Deleted leftover simulator {device["name"]}')
    if RUNNING in {label['name'] for label in github.pull().get('labels', [])}:
        github.relabel(RUNNING, None)
        github.comment('Lane: the run was cancelled or crashed before its report. Request it again if it is '
                       'still needed.')
    return 0


def link_tools(source: Path) -> None:
    for name in ('.venv', 'node_modules'):
        if not (ROOT / name).exists() and (source / name).exists():
            (ROOT / name).symlink_to(source / name)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--event-head', required=True, help='head SHA the triggering event saw')
    parser.add_argument('--merge-sha', required=True, help='the merge commit this checkout is on')
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--cleanup', action='store_true', help='tidy up after a cancelled or crashed job')
    args = parser.parse_args(argv)
    github = GitHub(os.environ['GH_REPO'], args.pr)
    if args.cleanup:
        return cleanup(github)
    pull = github.pull()
    labels = {label['name'] for label in pull.get('labels', [])}
    head = pull['head']['sha']
    if QUEUED not in labels:
        print('No lane:queued label; nothing to do.')
        return 0
    if head != args.event_head:
        print(f'The PR moved on to {head[:7]} since this run was queued; the newer run tests it.')
        return 0
    comments = github.comments()
    request = latest_request(comments)
    if request is None:
        github.comment('Lane: this PR has the lane:queued label but no `/lane T…` request comment. '
                       'See docs/workstreams/test-lane.md for the format.')
        github.relabel(QUEUED, None)
        return 0
    if request['tier'] not in RUNNER_TIERS:
        print(f'{request["tier"]} requests are the Test Desk\'s; leaving it queued.')
        return 0
    wanted = identity(request['tier'], head, args.merge_sha, request['tests'])
    done_before = earlier_report(comments, wanted)
    if done_before:
        github.comment(f'Lane: identical {request["tier"]} request for {head[:7]} already reported: {done_before}')
        github.relabel(QUEUED, DONE)
        return 0
    request_id = f'pr{args.pr}-r{args.run_id}'
    evidence = Path(os.environ.get('SM_LANE_EVIDENCE_DIR') or
                    Path.home() / 'Library/Caches/SpokenMarginsLane/evidence') / request_id
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'request.json').write_text(json.dumps(dict(request, head=head, merge=args.merge_sha), indent=2))
    github.relabel(QUEUED, RUNNING)
    link_tools(Path(os.environ.get('SM_LANE_TOOLS') or Path.home() / 'Documents/GitHub/spoken-margins-native'))
    started = time.monotonic()
    requested = request.get('commit', '')
    moved = [f'requested {requested[:7]}, tested the newest commit {head[:7]}'] \
        if requested and not head.startswith(requested) else []
    cc = ''
    try:
        if request['tier'] == 'T2':
            verdict, ran, details = run_t2(evidence)
            where, crashes = 'no simulator (compile only)', 'none'
        else:
            verdict, where, ran, details, crashes, cc = run_t3(request['tests'], request_id, evidence)
    except Exception as error:  # noqa: BLE001 - any lane fault is reported, never silent
        verdict, where, ran, crashes = 'INCONCLUSIVE', 'lane error', 'nothing', 'unknown'
        details = [f'The lane itself failed: {error!r}. evidence: {evidence}']
    body = report(request_id, verdict, head, args.merge_sha, request['tier'], where, time.monotonic() - started,
                  ran, moved + details, crashes, str(evidence),
                  'journeys and anything a listener notices (T4), audible content (owner)', wanted, cc)
    (evidence / 'report.md').write_text(body)
    print(body)
    try:
        github.comment(body)
    finally:
        github.relabel(RUNNING, DONE)
    shutil.rmtree(ROOT / '.build/dd', ignore_errors=True)
    shutil.rmtree(ROOT / '.build/verification', ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
