#!/usr/bin/env python3
"""Named verification plans with bounded processes and auditable execution evidence."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
import platform
import plistlib
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from check_posterboard_repair import new_crash
import lane_sim
from lane_slots import acquire_simulator_slot, build_slot, release_handle

from test_inventory import ROOT, plan_tests, swift_tests, validate

PLANS = {
    'app': ('SpokenMarginsAppBehavior', 'AppBehavior', 600),
    'adapters': ('SpokenMarginsAppBehavior', 'AudioAdapters', 300),
    'smoke': ('SpokenMarginsUISeams', 'Smoke', 180),
    'ui': ('SpokenMarginsUISeams', 'UISeams', 900),
    'speech-canary': ('SpokenMarginsUISeams', 'SpeechCanary', 1000),
    'release': ('SpokenMarginsReleaseTests', 'Release', 3600),
}

# A run waits at most this long for a Mac-wide build slot, then fails rather than hanging.
BUILD_SLOT_WAIT_SECONDS = 1800

# Keep aligned with project.yml and the SessionKit iOS deployment target.
MINIMUM_IOS_MAJOR = 26


def select_simulator(devices, device=None, ios=None):
    """Reject unsupported destinations; prefer a booted phone, then newest OS."""
    candidates = []
    for runtime, group in devices.items():
        match = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?', runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version[0] < MINIMUM_IOS_MAJOR or (ios is not None and version[0] != ios):
            continue
        for entry in group:
            if not entry.get('isAvailable', False):
                continue
            if device:
                if entry['udid'] != device:
                    continue
            elif '.iPhone-' not in entry.get('deviceTypeIdentifier', ''):
                continue
            candidates.append((entry['state'] == 'Booted', version, entry['udid'],
                               dict(entry, runtime=runtime)))
    if not candidates:
        raise RuntimeError(f'No matching supported simulator (iOS {MINIMUM_IOS_MAJOR}+). '
                           'Supply --ios or --device with an available supported destination.')
    return sorted(candidates, key=lambda candidate: candidate[:3], reverse=True)[0][3]


TEST_RUNNER_NAME = 'SpokenMargins Test Runner'
APP_TEST_TARGET = 'SpokenMarginsAppTests'


def selected(test, selector):
    """Whether an -only-testing selector (Target/Class or Target/Class/method) covers a test ID."""
    return test == selector or test.startswith(selector + '/')


def dedicated_simulator(devices, ios=None):
    """App-hosted tests write into the app's container, so they never share the journey simulator (#164).

    Returns (runner, None) when the runner exists, else (None, template) to create it from: the newest
    supported iPhone, ignoring which simulators happen to be booted.
    """
    runners = {runtime: [entry for entry in group if entry.get('name') == TEST_RUNNER_NAME]
               for runtime, group in devices.items()}
    try:
        return select_simulator(runners, ios=ios), None
    except RuntimeError:
        unbooted = {runtime: [dict(entry, state='Shutdown') for entry in group]
                    for runtime, group in devices.items()}
        return None, select_simulator(unbooted, ios=ios)


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def input_identity():
    paths = capture(['git', 'ls-files', '--cached', '--others', '--exclude-standard']).splitlines()
    digest = hashlib.sha256()
    for relative in sorted(set(paths)):
        if not (relative.startswith(('App/', 'Packages/', 'Contracts/', 'Config/', 'TestPlans/',
                                     'SpokenMarginsNative.xcodeproj/', 'scripts/', 'validation/',
                                     'Tools/', 'schemas/'))
                or relative in ('project.yml', 'package.json', 'package-lock.json')):
            continue
        path = ROOT / relative
        digest.update(relative.encode() + b'\0')
        digest.update(path.read_bytes() if path.is_file() else b'<deleted>')
    return digest.hexdigest()


def test_records(log):
    records = {}
    for module, name, method, status, seconds in re.findall(
            r"Test Case '-\[(\w+)\.(\w+) (test\w+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)", log):
        identifier = f'{module}/{name}/{method}'
        result = {'status': status, 'seconds': float(seconds)}
        if identifier in records:
            previous = records[identifier]
            attempts = previous.setdefault('attempts', [dict(previous)])
            attempts.append(result)
            # A passing retry must never erase the original failure or skip.
            previous['status'] = next(s for s in ('failed', 'skipped', 'passed')
                                      if any(a['status'] == s for a in attempts))
            previous['seconds'] = sum(a['seconds'] for a in attempts)
        else:
            records[identifier] = result
    return records


def reconcile(expected, records, allowed_skips=()):
    errors = []
    if not records:
        errors.append('No completed tests recorded')
    if expected is not None:
        if missing := expected - records.keys():
            errors.append(f'Missing {len(missing)} tests; first ten: {sorted(missing)[:10]}')
        if extra := records.keys() - expected:
            errors.append(f'Unexpected {len(extra)} tests; first ten: {sorted(extra)[:10]}')
    for name, result in records.items():
        if result['status'] == 'failed':
            errors.append(f'Failed: {name}')
        if result['status'] == 'skipped' and name not in allowed_skips:
            errors.append(f'Unexpected skip: {name}')
    return errors


class Run:
    def __init__(self, output, plan):
        self.output = output
        self.output.mkdir(parents=True, exist_ok=False)
        self.manifest = {'plan': plan, 'head': capture(['git', 'rev-parse', 'HEAD']),
                         'branch': capture(['git', 'branch', '--show-current']),
                         'input_sha256': input_identity(), 'status': 'running', 'steps': []}
        self.crash_baseline = None
        self.crash_times = {}
        self.save()

    def save(self):
        (self.output / 'manifest.json').write_text(json.dumps(self.manifest, indent=2) + '\n')

    # A lone system-process crash is recorded and the run continues. Only a flood of
    # identical crashes (the pattern that spams crash dialogs) stops and shuts down.
    CRASH_FLOOD_COUNT = 3
    CRASH_FLOOD_WINDOW_SECONDS = 60

    def note_crash(self, entry, report):
        try:
            self.crash_baseline[report] = (report.stat().st_mtime_ns, report.stat().st_size)
        except OSError:
            self.crash_baseline[report] = (0, 0)
        process = re.sub(r'-\d{4}-\d{2}-\d{2}-\d{6}.*$', '', report.name)
        now = time.monotonic()
        self.crash_times.setdefault(process, []).append(now)
        entry.setdefault('simulator_crash_reports', []).append(str(report))
        recent = [t for t in self.crash_times[process] if now - t <= self.CRASH_FLOOD_WINDOW_SECONDS]
        if len(recent) >= self.CRASH_FLOOD_COUNT:
            entry['simulator_crash_report'] = str(report)
            return True
        print(f'warning: simulator process crashed once ({process}); continuing', flush=True)
        return False

    def command(self, name, args, timeout=180, expected=None, allowed_skips=(), tests=False):
        entry = {'name': name, 'command': args, 'timeout_seconds': timeout,
                 'expected_tests': sorted(expected) if expected is not None else None}
        self.manifest['steps'].append(entry)
        self.save()
        print(f'{name} …', flush=True)
        device = self.manifest.get('destination', {}).get('udid')
        reports = Path.home() / 'Library/Logs/DiagnosticReports'
        if device and self.crash_baseline is None:
            if not reports.is_dir():
                raise RuntimeError('Simulator crash reports are unavailable')
            self.crash_baseline = {p: (p.stat().st_mtime_ns, p.stat().st_size)
                                   for p in reports.glob('*.ips')}
        # xcodebuild shares the Mac-wide build slots with every session; the wait isn't timed.
        slot = build_slot(f'verify-tests {self.manifest["plan"]} {name}', max_wait=BUILD_SLOT_WAIT_SECONDS) \
            if args[0] == 'xcodebuild' else contextlib.nullcontext()
        with (self.output / f'{name}.log').open('w') as log, slot as held:
            if held:
                entry['build_slot'] = held
            start = time.monotonic()
            process = subprocess.Popen(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                while True:
                    if device and (report := new_crash(reports, self.crash_baseline, device)):
                        if self.note_crash(entry, report):
                            raise InterruptedError('Repeated simulator process crashes')
                    remaining = timeout - (time.monotonic() - start)
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(args, timeout)
                    try:
                        result = process.wait(timeout=min(0.25, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        continue
            except (subprocess.TimeoutExpired, KeyboardInterrupt, InterruptedError):
                entry['interrupted'] = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                result = 124
                if entry.get('simulator_crash_report'):
                    shutdown = subprocess.run(['xcrun', 'simctl', 'shutdown', device],
                                              stdout=log, stderr=subprocess.STDOUT, timeout=20)
                    entry['simulator_shutdown_exit'] = shutdown.returncode
        entry.update(exit_code=result, seconds=round(time.monotonic() - start, 3))
        text = (self.output / f'{name}.log').read_text(errors='replace')
        errors = []
        if tests:
            records = test_records(text)
            entry['tests'] = records
            entry['counts'] = {status: sum(r['status'] == status for r in records.values())
                               for status in ('passed', 'failed', 'skipped')}
            errors = reconcile(expected, records, allowed_skips)
        if name == 'runner-tests':
            match = re.search(r'Ran (\d+) tests? in ', text)
            entry['executed_count'] = int(match[1]) if match else 0
            if not entry['executed_count']:
                errors.append('Infrastructure runner executed zero tests')
        if name == 'browser':
            match = re.search(r'^# tests (\d+)$', text, re.M)
            entry['executed_count'] = int(match[1]) if match else 0
            if not entry['executed_count']:
                errors.append('Browser runner executed zero tests')
        if result:
            errors.insert(0, f'Process exit {result}')
        entry['errors'] = errors
        self.save()
        print(f'{name}: {entry["seconds"]}s — {"FAILED" if errors else "passed"}', flush=True)
        if errors:
            raise RuntimeError('; '.join(errors) + f' (see {self.output / (name + ".log")})')
        return text

    def fast(self):
        self.command('runner-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests'])
        self.command('contracts', [sys.executable, 'scripts/validate-contracts.py'])
        self.command('surfaces', [sys.executable, 'scripts/validate-surface-contracts.py'])
        self.command('inventory', [sys.executable, 'scripts/test_inventory.py'])
        if not (ROOT / 'node_modules').exists():
            raise RuntimeError('node_modules is missing in this worktree; run scripts/setup-worktree.sh')
        self.command('browser', ['npm', 'run', 'test:browser-extraction'])
        expected = set()
        for target in ('SessionKitTests', 'SessionKitTraceTests'):
            expected.update(f'{target}/{test}' for test in swift_tests(ROOT / f'Packages/SessionKit/Tests/{target}'))
        self.command('package', ['bash', 'scripts/run-sessionkit-tests.sh'], timeout=300,
                     expected=expected, tests=True,
                     allowed_skips={'SessionKitTests/SharingTests/testHeldOutPublicDomainPodcastAnchorCorpus'})

        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed during fast verification')

    def xcode(self, plan, device, rebuild, ios=None, only=()):
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed before Xcode verification')
        scheme, name, timeout = PLANS[plan]
        # T3 runs a few test classes or methods of a plan. Each selector must name tests in the plan.
        selectors = [s if s.startswith(f'{APP_TEST_TARGET}/') else f'{APP_TEST_TARGET}/{s}' for s in only]
        planned = plan_tests(ROOT, name)
        unmatched = [s for s in selectors if not any(selected(test, s) for test in planned)]
        if unmatched:
            raise RuntimeError(f'Not in the {name} test plan: {", ".join(unmatched)}')
        if selectors:
            self.manifest['only_testing'] = selectors
        devices = json.loads(capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
        if device:
            chosen = select_simulator(devices, device, ios)
        else:
            chosen, template = dedicated_simulator(devices, ios)
            if chosen is None:
                self.command('simulator-create', ['xcrun', 'simctl', 'create', TEST_RUNNER_NAME,
                             template['deviceTypeIdentifier'], template['runtime']], timeout=60)
                devices = json.loads(capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
                chosen, _ = dedicated_simulator(devices, ios)
                if chosen is None:
                    raise RuntimeError(f'Could not create the {TEST_RUNNER_NAME} simulator')
        self.manifest['destination'] = chosen
        self.command('generate', ['xcodegen', 'generate'])
        identity = input_identity()
        toolchain = capture(['xcodebuild', '-version']) + '\n' + platform.machine() + '\nSDK ' + capture(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'])
        cache_key = hashlib.sha256((identity + toolchain + chosen['runtime'] + scheme + name).encode()).hexdigest()
        derived = ROOT / '.build/verification' / scheme
        stamp = derived / f'{name}.build.json'
        base = ['xcodebuild', '-configuration', 'Debug', '-project', 'SpokenMarginsNative.xcodeproj', '-scheme', scheme,
                '-testPlan', name, '-destination', f'id={chosen["udid"]}', '-derivedDataPath', str(derived)]
        self.manifest.update(input_sha256=identity, toolchain=toolchain, build_key=cache_key)
        reused = not rebuild and stamp.exists() and json.loads(stamp.read_text()).get('key') == cache_key
        self.manifest['reused_build'] = reused
        if not reused:
            stamp.unlink(missing_ok=True)
            self.command('build-for-testing', base + ['build-for-testing'], timeout=900)
        if input_identity() != identity:
            raise RuntimeError('Inputs changed during the build; evidence is not for one source state')
        if not reused:
            stamp.write_text(json.dumps({'key': cache_key}) + '\n')
        self.command('bundle-contracts', [sys.executable, 'scripts/verify-bundle.py',
                     str(derived / 'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app')])
        booted_here = chosen['state'] != 'Booted'
        # A run that boots its own simulator holds the Mac's one simulator slot until it shuts it down
        # (16 GB Mac: two simulator jobs plus builds filled swap, #184). A device someone else booted
        # is theirs, and so is the slot.
        slot = acquire_simulator_slot(f'verify-tests {plan}', out=sys.stdout, max_wait=BUILD_SLOT_WAIT_SECONDS) \
            if booted_here else None
        try:
            if booted_here:
                # Lane boot rules (scripts/lane_sim.py): one boot at a time, no builds meanwhile, no retry
                # after a failed boot, stop at the first crash. Two crash floods followed boots (#184).
                entry = {'name': 'simulator-boot', 'command': ['lane_sim.boot', chosen['udid']]}
                self.manifest['steps'].append(entry)
                self.save()
                try:
                    entry.update(seconds=round(lane_sim.boot(chosen['udid'], f'verify-tests {plan} boot', out=sys.stdout), 3),
                                 exit_code=0, errors=[])
                except lane_sim.BootError as error:
                    entry.update(exit_code=1, errors=[str(error)])
                    raise RuntimeError(f'simulator-boot: {error}')
                finally:
                    self.save()
            self.command('simulator-ready', ['xcrun', 'simctl', 'bootstatus', chosen['udid'], '-b'], timeout=180)
            if chosen.get('name') == TEST_RUNNER_NAME:
                # Start from an empty app container so earlier runs' data can't leak into this one.
                app = derived / 'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app'
                bundle_id = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
                subprocess.run(['xcrun', 'simctl', 'uninstall', chosen['udid'], bundle_id],
                               cwd=ROOT, capture_output=True, timeout=60)
            expected = {test for test in planned if not selectors or any(selected(test, s) for s in selectors)}
            self.command('xcode-tests', base + [f'-only-testing:{s}' for s in selectors] + [
                         'test-without-building', '-parallel-testing-enabled', 'NO',
                         '-collect-test-diagnostics', 'never',
                         '-test-timeouts-enabled', 'YES', '-resultBundlePath', str(self.output / 'tests.xcresult')],
                         timeout=timeout, expected=expected, tests=True)
        finally:
            if booted_here:
                # Don't leave an idle simulator holding memory after the run.
                subprocess.run(['xcrun', 'simctl', 'shutdown', chosen['udid']],
                               cwd=ROOT, capture_output=True, timeout=60)
            if slot:
                release_handle(slot)
        if input_identity() != identity:
            raise RuntimeError('Inputs changed during testing; rerun on a stable source state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', choices=['fast', *PLANS], default='fast')
    parser.add_argument('--device', help='Supported simulator UDID (including iPad); overrides phone preference')
    parser.add_argument('--ios', type=int, help='Required iOS major version, e.g. 26 or 27; never falls back to another OS')
    parser.add_argument('--rebuild', action='store_true', help='Ignore the compatible build stamp')
    parser.add_argument('--output', type=Path, help='New evidence directory')
    parser.add_argument('--list', action='store_true', help='Inspect selection without running tests')
    parser.add_argument('--only-testing', action='append', default=[], metavar='CLASS[/METHOD]',
                        help='Xcode plans: run only these tests of the plan (repeatable); unknown ones fail the run')
    args = parser.parse_args()
    if errors := validate():
        parser.error('; '.join(errors))
    if args.list:
        print('\n'.join(sorted(plan_tests(ROOT, PLANS[args.plan][1]))) if args.plan in PLANS
              else 'runner-tests, contracts, surfaces, inventory, browser, all SessionKit tests')
        return 0
    (ROOT / '.build').mkdir(exist_ok=True)
    with (ROOT / '.build/verification.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output = args.output or ROOT / 'artifacts/test-runs' / (
            datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '-' + args.plan)
        run = Run(output.resolve(), args.plan)
        try:
            if args.plan in ('fast', 'release'):
                run.fast()
            if args.plan != 'fast':
                run.xcode(args.plan, args.device, args.rebuild, args.ios, args.only_testing)
            if input_identity() != run.manifest['input_sha256']:
                raise RuntimeError('Inputs changed during verification; rerun on a stable source state')
            run.manifest['status'] = 'verified'
            return 0
        except (RuntimeError, subprocess.SubprocessError, OSError, KeyboardInterrupt) as error:
            run.manifest.update(status='failed_or_incomplete', error=str(error) or repr(error))
            print(error, file=sys.stderr)
            return 1
        finally:
            run.save()
            print(f'Evidence: {run.output / "manifest.json"}', flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
