#!/usr/bin/env python3
"""Named verification plans with bounded processes and auditable execution evidence."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from test_inventory import ROOT, plan_tests, swift_tests, validate

PLANS = {
    'app': ('SpokenMarginsAppBehavior', 'AppBehavior', 600),
    'adapters': ('SpokenMarginsAppBehavior', 'AudioAdapters', 300),
    'smoke': ('SpokenMarginsUISeams', 'Smoke', 180),
    'ui': ('SpokenMarginsUISeams', 'UISeams', 900),
    'speech-canary': ('SpokenMarginsUISeams', 'SpeechCanary', 1000),
    'release': ('SpokenMarginsReleaseTests', 'Release', 3600),
}


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
        self.save()

    def save(self):
        (self.output / 'manifest.json').write_text(json.dumps(self.manifest, indent=2) + '\n')

    def command(self, name, args, timeout=180, expected=None, allowed_skips=(), tests=False):
        entry = {'name': name, 'command': args, 'timeout_seconds': timeout,
                 'expected_tests': sorted(expected) if expected is not None else None}
        self.manifest['steps'].append(entry)
        self.save()
        print(f'{name} …', flush=True)
        start = time.monotonic()
        with (self.output / f'{name}.log').open('w') as log:
            process = subprocess.Popen(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                result = process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                entry['interrupted'] = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                result = 124
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
        self.command('browser', ['npm', 'run', 'test:browser-extraction'])
        expected = set()
        for target in ('SessionKitTests', 'SessionKitTraceTests'):
            expected.update(f'{target}/{test}' for test in swift_tests(ROOT / f'Packages/SessionKit/Tests/{target}'))
        self.command('package', ['bash', 'scripts/run-sessionkit-tests.sh'], timeout=300,
                     expected=expected, tests=True,
                     allowed_skips={'SessionKitTests/SharingTests/testHeldOutPublicDomainPodcastAnchorCorpus'})

        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed during fast verification')

    def xcode(self, plan, device, rebuild):
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed before Xcode verification')
        scheme, name, timeout = PLANS[plan]
        devices = json.loads(capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
        available = [dict(d, runtime=runtime) for runtime, group in devices.items() for d in group]
        chosen = next((d for d in available if d['udid'] == device), None) if device else next(
            (d for d in available if d['name'].startswith('iPhone')), None)
        if chosen is None:
            raise RuntimeError('No matching simulator. Supply --device with an available simulator UDID.')
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
        if chosen['state'] != 'Booted':
            self.command('simulator-boot', ['xcrun', 'simctl', 'boot', chosen['udid']], timeout=60)
        self.command('simulator-ready', ['xcrun', 'simctl', 'bootstatus', chosen['udid'], '-b'], timeout=180)
        expected = plan_tests(ROOT, name)
        self.command('xcode-tests', base + ['test-without-building', '-parallel-testing-enabled', 'NO',
                     '-test-timeouts-enabled', 'YES', '-resultBundlePath', str(self.output / 'tests.xcresult')],
                     timeout=timeout, expected=expected, tests=True)
        if input_identity() != identity:
            raise RuntimeError('Inputs changed during testing; rerun on a stable source state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', choices=['fast', *PLANS], default='fast')
    parser.add_argument('--device', help='Simulator UDID; defaults to the first available iPhone')
    parser.add_argument('--rebuild', action='store_true', help='Ignore the compatible build stamp')
    parser.add_argument('--output', type=Path, help='New evidence directory')
    parser.add_argument('--list', action='store_true', help='Inspect selection without running tests')
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
                run.xcode(args.plan, args.device, args.rebuild)
            if input_identity() != run.manifest['input_sha256']:
                raise RuntimeError('Inputs changed during verification; rerun on a stable source state')
            run.manifest['status'] = 'verified'
            return 0
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            run.manifest.update(status='failed_or_incomplete', error=str(error))
            print(error, file=sys.stderr)
            return 1
        finally:
            run.save()
            print(f'Evidence: {run.output / "manifest.json"}', flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
