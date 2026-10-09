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
from lane_xcresult_attachments import export_failed_attachments

from check_posterboard_repair import crash_snapshot, new_crash
import host_audio
import lane_sim
import lane_sim_pool
from lane_slots import (acquire_simulator_slot, build_slot, host_test_slot, release_handle,
                        state_dir, SIMULATOR_SLOTS)

from test_inventory import ROOT, plan_tests, swift_tests, target_tests, validate

PLANS = {
    'app': ('SpokenMarginsAppBehavior', 'AppBehavior', 600),
    'adapters': ('SpokenMarginsAppBehavior', 'AudioAdapters', 300),
    'smoke': ('SpokenMarginsUISeams', 'Smoke', 180),
    'ui': ('SpokenMarginsUISeams', 'UISeams', 900),
    'speech-canary': ('SpokenMarginsUISeams', 'SpeechCanary', 1000),
    'release': ('SpokenMarginsReleaseTests', 'Release', 3600),
    # The scripted journeys in TestPlans/scripted-journeys.json, from the Release plan (it holds every UI test).
    'journeys': ('SpokenMarginsReleaseTests', 'Release', 1800),
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
UI_TEST_TARGET = 'SpokenMarginsAppUITests'


def selected(test, selector):
    """Whether an -only-testing selector (Target/Class or Target/Class/method) covers a test ID."""
    return test == selector or test.startswith(selector + '/')


def narrow_selectors(selectors, planned, available):
    """Narrow each selector to the planned tests it covers, unless the plan includes all of them.

    xcodebuild's -only-testing replaces a plan's selectedTests, so a class selector runs the whole
    class even when the plan picks one method of it. AudioAdapters selects one SupertonicSpeechTests
    method; `-only-testing:…/SupertonicSpeechTests` ran all 74, and the 73 outside the plan were
    reported as unexpected (#518).
    """
    narrowed = []
    for selector in selectors:
        covered = sorted(test for test in available if selected(test, selector))
        if all(test in planned for test in covered):
            narrowed.append(selector)
        else:
            narrowed.extend(test for test in covered if test in planned)
    return narrowed


def dedicated_simulator(devices, ios=None):
    """App-hosted tests write into the app's container, so they never share the journey simulator (#164).

    Returns (runner, None) when the runner exists, else (None, template) to create it from: the newest
    supported iPhone, ignoring which simulators happen to be booted. Unless told otherwise it stays on
    the lane's iOS (lane_sim.IOS_MAJOR): picking the newest runtime chose the iOS 27 Test Runner
    31A5C797, and iOS 27's services crash-flood on this Mac (#184).
    """
    ios = lane_sim.IOS_MAJOR if ios is None else ios
    runners = {runtime: [entry for entry in group if entry.get('name') == TEST_RUNNER_NAME]
               for runtime, group in devices.items()}
    try:
        return select_simulator(runners, ios=ios), None
    except RuntimeError:
        unbooted = {runtime: [dict(entry, state='Shutdown') for entry in group]
                    for runtime, group in devices.items()}
        return None, select_simulator(unbooted, ios=ios)


def refuse_unsafe(chosen, unsafe):
    """Never test on a device the lane marked unsafe, however it was chosen (by name or --device)."""
    marked = unsafe.get(chosen['udid'])
    if marked:
        raise RuntimeError(f'{chosen.get("name")} ({chosen["udid"]}) is on the lane\'s unsafe list: {marked["reason"]}. '
                           'Boot a fresh device with scripts/lane-sim-boot --fresh and pass it with --device.')


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def inherited_simulator_slot(fd):
    """Borrow a parent's real locked simulator-slot descriptor; never trust an env flag.

    The parent keeps the decision lock too, excluding a second simulator job for
    an unattended integration run. Closing this duplicate preserves its lock.
    """
    try:
        info = os.fstat(fd)
        for name in SIMULATOR_SLOTS:
            path = state_dir() / name
            if not path.exists():
                continue
            lock_info = path.stat()
            if (info.st_dev, info.st_ino) != (lock_info.st_dev, lock_info.st_ino):
                continue
            with path.open('a+') as probe:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return os.fdopen(os.dup(fd), 'a+')
                fcntl.flock(probe, fcntl.LOCK_UN)
            break
    except OSError:
        pass
    raise ValueError('inherited simulator descriptor must name a held Mac-wide simulator slot')


def input_identity():
    paths = capture(['git', 'ls-files', '--cached', '--others', '--exclude-standard']).splitlines()
    digest = hashlib.sha256()
    for relative in sorted(set(paths)):
        if not (relative.startswith(('App/', 'Packages/', 'Contracts/', 'Config/', 'TestPlans/',
                                     'SpokenMarginsNative.xcodeproj/', 'scripts/', 'validation/',
                                     'Tools/', 'schemas/', 'ops/'))
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


def xcresult_test_records(payload):
    """Read individual XCTest results, independent of interleaved application stdout."""
    records = {}
    statuses = {'Passed': 'passed', 'Failed': 'failed', 'Skipped': 'skipped',
                'Expected Failure': 'passed'}

    def status(node):
        try:
            return statuses[node['result']]
        except KeyError as error:
            raise ValueError(f'Unfinished or unknown xcresult test result: {node.get("result")}') from error

    def worst(results):
        return next(s for s in ('failed', 'skipped', 'passed') if s in results)

    def attempts(node):
        for child in node.get('children', []):
            if child['nodeType'] == 'Test Case Run':
                yield status(child)
            yield from attempts(child)

    def visit(nodes, bundle=None):
        for node in nodes:
            if node['nodeType'] in ('Unit test bundle', 'UI test bundle'):
                bundle = node['name']
            if node['nodeType'] == 'Test Case':
                name = node['nodeIdentifier'].removesuffix('()')
                if not bundle or not re.fullmatch(r'\w+/test\w+', name):
                    raise ValueError(f'Unknown xcresult test identifier: {bundle}/{name}')
                identifier = f'{bundle}/{name}'
                result = {'status': worst([status(node), *attempts(node)]),
                          'seconds': float(node.get('durationInSeconds', 0))}
                if identifier in records:
                    previous = records[identifier]
                    result['status'] = worst([previous['status'], result['status']])
                    result['seconds'] += previous['seconds']
                records[identifier] = result
            else:
                visit(node.get('children', []), bundle)

    visit(payload['testNodes'])
    return records


def completed_test_records(log, result_bundle):
    """Preserve log failures/retries and recover missing completions from the result bundle."""
    records = test_records(log)
    payload = json.loads(subprocess.check_output(
        ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(result_bundle), '--compact'],
        cwd=ROOT, text=True, stderr=subprocess.PIPE, timeout=60))
    structured = xcresult_test_records(payload)
    if not structured:
        raise ValueError('No completed individual tests in xcresult')
    for identifier, result in structured.items():
        if identifier not in records:
            records[identifier] = result
        else:
            previous = records[identifier]
            previous['status'] = next(s for s in ('failed', 'skipped', 'passed')
                                      if s in (previous['status'], result['status']))
    return records, payload


def reconcile(expected, records, allowed_skips=(), probation=()):
    """Errors that fail the step. A test on probation that fails or is missing is reported, not an error."""
    errors = []
    if not records:
        errors.append('No completed tests recorded')
    if expected is not None:
        if missing := expected - records.keys() - set(probation):
            errors.append(f'Missing {len(missing)} tests; first ten: {sorted(missing)[:10]}')
        if extra := records.keys() - expected:
            errors.append(f'Unexpected {len(extra)} tests; first ten: {sorted(extra)[:10]}')
    for name, result in records.items():
        if result['status'] == 'failed' and name not in probation:
            errors.append(f'Failed: {name}')
        if result['status'] == 'skipped' and name not in allowed_skips and name not in probation:
            errors.append(f'Unexpected skip: {name}')
    return errors


def log_errors(text, limit=3, width=300):
    """The first distinct error lines of a failed step's log, so the lane report can say why.

    The runner's reports quote the manifest's error, and the logs stay on the Mac: T3 reports on
    #368 and #408 said only "Process exit 70" (#411).
    """
    lines = text.splitlines()
    found = [line.strip() for line in lines if ' error: ' in line or line.startswith('error:')]
    if 'The following build commands failed:' in lines:
        for line in lines[lines.index('The following build commands failed:') + 1:]:
            if not line.strip():
                break
            found.append('failed: ' + line.strip())
    return [line[:width] for line in dict.fromkeys(found)][:limit]


# Codex runs its shell commands under macOS seatbelt and sets CODEX_SANDBOX there. That sandbox refuses
# to run `ps`, which the lane's own boot tests in scripts/tests need, so runner-tests can't pass inside it
# (#64's Codex run, 2026-10-01: 2 failures and 12 errors, and the plan stopped before the package step).
# Inside it the plan skips runner-tests and ends as verified_in_codex_sandbox, which no gate accepts;
# the Codex worker's own run, outside the sandbox, is the full plan.
CODEX_SANDBOX_SKIPS = {'runner-tests': 'Codex sandbox: `ps` cannot run here, so the lane boot tests cannot'}

# Lane runs hand the plan the PR's changed paths (--changed-files, #862) so it can leave out the lane's own
# Python tests when nothing they read changed. A run without that list runs every step. Each rule fails
# safe: a path none of these names (a new top-level folder, say) leaves the suites on.
# scripts/tests test the lane itself, and the Codex audit reads lane-runner.py: any change under scripts/ or
# .github/ runs every runner test. So does the root .gitignore, which the lane runner's warm-build tests copy.
RUNNER_TEST_TRIGGERS = ('scripts/', '.github/', '.gitignore')
# Some tests also read the repository outside scripts/: the filled-button scans read App/; the inventory and
# contract checks read project.yml, Package.swift, TestPlans/, Contracts/ and validation/; the hot-file test
# checks that the hot files exist under App/; the research harness test reads research/; and the lane
# runner's T3 scope and "only testing" tests, and one lane-sim test, plan against the real TestPlans/ and the
# app test sources; the sharing kit's tests read docs/sharing-test-kit/ and the packet and sharing sources under
# Packages/ and App/ (re-measured 2026-10-09). A diff that touches those inputs (and no lane path) runs just
# these (a module, or a module.Class); the rest of the suite reads only scripts/.
# To re-measure the list, copy scripts/, .github/ and .gitignore into a fresh git repository, run
# `python -m unittest discover -s scripts/tests` there and on a full checkout: the classes that fail only in
# the copy are the readers. Lists like this drift when tests are added, so non-lane runs and the Test Desk's
# run on next, which keep every step, are what catch a missed reader.
RUNNER_TEST_READERS = ('test_filled_button_contrast', 'test_filled_button_labels', 'test_verification',
                       'test_validate_contracts', 'test_hot_file_ratchet', 'test_research_tests',
                       'test_lane_runner.OnlyTestingTests', 'test_lane_runner.ScopeClassTests',
                       'test_lane_runner.T3Tests', 'test_lane_sim.LaneSimTests', 'test_sharing_kit')
RUNNER_TEST_INPUTS = ('App/', 'Packages/', 'Contracts/', 'TestPlans/', 'validation/', 'research/', 'project.yml',
                      'docs/sharing-test-kit/')
# The ops tests read their own folder and scripts/lane-runner.py (the audit's test), test-scope and the release
# files, so they follow the ops tools and anything the runner tests follow, plus the build inputs. The Codex
# audit's tests also check that AGENTS.md is at the repository root. Re-measured 2026-10-09 the same way as
# the runner tests: with only these copied, every ops suite passes.
OPS_TEST_TRIGGERS = ('ops/', 'scripts/', '.github/', 'project.yml', 'TestPlans/', 'AGENTS.md')


def touches(changed, prefixes):
    return any(path == prefix or path.startswith(prefix) for path in changed for prefix in prefixes)


def runner_test_scope(changed):
    """('all'|'readers'|'none', reason) for the runner tests. changed=None means no diff information: all."""
    if not changed:
        return 'all', None
    if touches(changed, RUNNER_TEST_TRIGGERS):
        return 'all', None
    if touches(changed, RUNNER_TEST_INPUTS):
        return 'readers', 'diff touches no lane path; only the tests that read ' + ', '.join(
            p for p in RUNNER_TEST_INPUTS if touches(changed, (p,))) + ' run'
    return 'none', 'diff touches nothing under scripts/, .github/ or the files the runner tests read'


def ops_tests_needed(changed):
    """(run, reason) for the ops tests. changed=None means no diff information: run."""
    if not changed or touches(changed, OPS_TEST_TRIGGERS):
        return True, None
    return False, 'diff touches nothing under ops/, scripts/, .github/ or the files the ops tests read'
# SessionKit tests that encode, play or speak real audio fail in that sandbox and pass outside it
# (AVFoundation 'fmt?' errors, players that never start, speech that never renders; 2026-10-01).
# Inside the sandbox their results are reported but don't fail the package step.
CODEX_SANDBOX_AUDIO_TESTS = frozenset(f'SessionKitTests/{test}' for test in (
    'PodcastEvidenceSignatureLengthTests/testEvidenceFromStereo48kHzAudioStaysQueryableAndPlacesTheMargin',
    'PodcastLateAnchorPlacementTests/testMarginLateInALongEpisodeIsPlaced',
    'RealPlayerMarginMomentTests/testMarginPlaysWhenPlaybackReachesItAndTheEpisodeResumesAfterwards',
    'RealPlayerPodcastEvidenceTests/testContinuousTapCapturesThePreWindowFromAStreamedEpisode',
    'RealPlayerPodcastEvidenceTests/testContinuousTapInstallsOnceTracksLoadAndCapturesThePreWindow',
    'RealPlayerPodcastEvidenceTests/testTapKeepsTheHeardAudioAroundAStreamedMarginForTranscription',
    'SharingTests/testAcousticPauseDetectionFindsEdgesAndProtectsAlignedSpeech',
    'SharingTests/testAcousticResolverDeclinesConflictingSyntheticMatchesAcrossInsertedAd',
    'SharingTests/testAcousticResolverDoesNotPlaceMarginsNextToRepeatedAudio',
    'SharingTests/testAcousticResolverPlacesAMarginAfterAnInsertedAdByTheAdsLength',
    'SharingTests/testBuilderIncludesOnlyExplicitlySelectedOriginalOrCleanedVoice',
    'SharingTests/testPortableListeningMapProposalAndPodcastEvidenceImportWithoutActivatingMap',
    'SharingTests/testSpeechAwarePauseDetectionRemovesAHighEnergyGapWithoutTouchingWords',
    'SupertonicChunkingTests/testSystemVoiceReadsAFlaggedChunkInSupertonicsFormat',
    'SystemNarrationRateTests/testNarrationIsHeardAtTheChosenSpeed',
))


def in_codex_sandbox():
    return bool(os.environ.get('CODEX_SANDBOX'))


def passed_status():
    return 'verified_in_codex_sandbox' if in_codex_sandbox() else 'verified'


def ops_test_folders(root=None):
    """Each folder under ops/ that holds its own Python tests (test_*.py), e.g. ops/dial."""
    base = Path(root or ROOT)
    return sorted({path.parent for path in (base / 'ops').rglob('test_*.py')})


def process_group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False  # macOS: only zombies are left
    return True


def stop_process_group(process, grace=10):
    # The group may already be gone (or, on macOS, hold only zombies, which gives EPERM); that
    # must not replace the error that brought us here.
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(process.pid, signal.SIGTERM)
    # Wait for the whole group, not just its leader: a leader that exits on SIGTERM can leave a
    # descendant that ignores it (Codex audit P2 on dd3e0a4).
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        process.poll()  # reap the leader, so a zombie leader doesn't count as alive
        if not process_group_alive(process.pid):
            break
        time.sleep(0.1)
    else:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, signal.SIGKILL)
    process.wait()


PACKAGE_BUILD_TIMEOUT = 900  # SessionKit build with tests; cold, under load
PACKAGE_TEST_TIMEOUT = 600  # the SessionKit tests alone (#844)
# The runner's own 631 tests took 164.5 s on a quiet Mac (PR #1103's 0c940ba, 2026-10-08) and 172.3 s in a
# detached checkout of it, so the 180 s command default left no room: built beside a simulator job, the step
# was killed (exit 124) and the plan reported "Infrastructure runner executed zero tests", twice on #1103's
# head (#1110). Its own limit leaves headroom for load and for the suite to keep growing.
RUNNER_TESTS_TIMEOUT = 600


# The SessionKit tests that need a running audio output (#909).
REAL_PLAYER_TEST = re.compile(r'/(?:RealPlayer[A-Z]\w*Tests|StreamSeekLifecycleTests)/')


class Run:
    def __init__(self, output, plan, changed=None):
        self.output = output
        self.changed = changed  # the PR's changed paths in a lane run; None runs every step (#862)
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

    def command(self, name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=None):
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
            self.crash_baseline = crash_snapshot(reports)
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
                stop_process_group(process)
                result = 124
                if entry.get('simulator_crash_report'):
                    # A pool device that flooded is retired, not erased and reused (#688): mark it first.
                    lane_sim_pool.retire_after_flood(device, f'crash flood during {name}: {entry["simulator_crash_report"]}')
                    shutdown = subprocess.run(['xcrun', 'simctl', 'shutdown', device],
                                              stdout=log, stderr=subprocess.STDOUT, timeout=20)
                    entry['simulator_shutdown_exit'] = shutdown.returncode
            except BaseException:
                # The runner itself failed: don't leave xcodebuild running orphaned (#767).
                stop_process_group(process)
                raise
        entry.update(exit_code=result, seconds=round(time.monotonic() - start, 3))
        text = (self.output / f'{name}.log').read_text(errors='replace')
        errors = []
        if tests:
            records = test_records(text)
            payload = None
            entry['test_evidence'] = 'log'
            if '-resultBundlePath' in args:
                bundle = args[args.index('-resultBundlePath') + 1]
                entry['result_bundle'] = bundle
                try:
                    records, payload = completed_test_records(text, bundle)
                    (self.output / f'{name}-xcresult.json').write_text(json.dumps(payload, indent=2) + '\n')
                    entry['test_evidence'] = 'log+xcresult'
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
                    errors.append(f'Could not reconcile xcresult individual tests: {error}')
                entry['attachments'] = export_failed_attachments(
                    bundle, records, payload, self.output / f'{name}-attachments')
            entry['tests'] = records
            entry['counts'] = {status: sum(r['status'] == status for r in records.values())
                               for status in ('passed', 'failed', 'skipped')}
            errors.extend(reconcile(expected, records, allowed_skips, probation or ()))
            if probation is not None:  # scripted journeys: each listed test's result, by status
                entry['gating'] = {test: records.get(test, {}).get('status', 'missing')
                                   for test in sorted(set(expected or ()) - probation)}
                entry['probation'] = {test: records.get(test, {}).get('status', 'missing') for test in sorted(probation)}
        if name == 'runner-tests' or name.startswith('ops-'):
            match = re.search(r'Ran (\d+) tests? in ', text)
            entry['executed_count'] = int(match[1]) if match else 0
            if not entry['executed_count']:
                errors.append('Infrastructure runner executed zero tests' if name == 'runner-tests'
                              else f'{name} executed zero tests')
        if name in ('browser', 'share-link'):
            match = re.search(r'^# tests (\d+)$', text, re.M)
            entry['executed_count'] = int(match[1]) if match else 0
            if not entry['executed_count']:
                errors.append('Browser runner executed zero tests' if name == 'browser'
                              else f'{name} executed zero tests')
        if name == 'research':
            match = re.search(r'^research-tests: (\d+) tests in \d+ suites; \d+ skipped', text, re.M)
            entry['executed_count'] = int(match[1]) if match else 0
            entry['skipped'] = re.findall(r'^skipped: (.+)$', text, re.M)
            for reason in entry['skipped']:
                print(f'warning: research skipped: {reason}', flush=True)
            # Name the failing suites and tests in the error, which the lane's report carries.
            errors.extend(re.findall(r'^(?:FAILED|failed test|failed package): .+$', text, re.M)[:5])
            if not entry['executed_count']:
                errors.append('research executed zero tests')
        # A failing probation test makes xcodebuild exit non-zero; that alone doesn't fail the step.
        probation_only = (tests and not errors and not entry.get('interrupted')
                          and any(status != 'passed' for status in entry.get('probation', {}).values()))
        if result and not probation_only:
            if not any(error.startswith('Failed: ') for error in errors):  # failed tests already say why
                errors[:0] = log_errors(text)
            errors.insert(0, f'Process exit {result}')
        entry['errors'] = errors
        self.save()
        print(f'{name}: {entry["seconds"]}s — {"FAILED" if errors else "passed"}', flush=True)
        if errors:
            raise RuntimeError('; '.join(errors) + f' (see {self.output / (name + ".log")})')
        return text

    def fast(self):
        # The host steps share two Mac-wide host-test slots with every session and the runner (#350);
        # the package step's swift test runs inside this run's slot.
        with host_test_slot(f'verify-tests {self.manifest["plan"]} in {ROOT}', out=sys.stdout,
                            max_wait=BUILD_SLOT_WAIT_SECONDS) as held:
            self.manifest['host_test_slot'] = held
            self.save()
            self.host_steps()

    def host_steps(self):
        scope, why = runner_test_scope(self.changed)
        if in_codex_sandbox():
            self.skip('runner-tests')
        elif scope == 'none':
            self.skip('runner-tests', why)
        elif scope == 'readers':
            self.manifest['runner_tests_note'] = why
            # Same runner and the same "Ran N tests" line, so the zero-tests check still applies.
            loader = ('import sys, unittest; sys.path.insert(0, "scripts/tests"); '
                      'result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromNames(sys.argv[1:])); '
                      'sys.exit(not result.wasSuccessful())')
            self.command('runner-tests', [sys.executable, '-c', loader, *RUNNER_TEST_READERS],
                         timeout=RUNNER_TESTS_TIMEOUT)
        else:
            self.command('runner-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests'],
                         timeout=RUNNER_TESTS_TIMEOUT)
        needed, why = ops_tests_needed(self.changed)
        if needed:
            self.ops_steps()
        else:
            self.skip('ops', why)
        self.command('contracts', [sys.executable, 'scripts/validate-contracts.py'])
        self.command('surfaces', [sys.executable, 'scripts/validate-surface-contracts.py'])
        self.command('inventory', [sys.executable, 'scripts/test_inventory.py'])
        if not (ROOT / 'node_modules').exists():
            raise RuntimeError('node_modules is missing in this worktree; run scripts/setup-worktree.sh')
        self.command('browser', ['npm', 'run', 'test:browser-extraction'])
        self.command('share-link', ['npm', 'run', 'test:share-link'])
        # The Go server, the research Python tests and the Caddy script (#1033); a suite that can't run
        # here is reported as skipped with its reason, not passed.
        self.command('research', [sys.executable, 'scripts/research_tests.py'], timeout=300)
        expected = set()
        for target in ('SessionKitCoreTests', 'SessionKitTests', 'SessionKitTraceTests'):
            expected.update(f'{target}/{test}' for test in swift_tests(ROOT / f'Packages/SessionKit/Tests/{target}'))
        # The build gets its own limit, so a cold build under load can't use up the tests' time (#844).
        # The tests' limit covers about 1,000 tests, including real-time AVPlayer tests that took
        # 150 s of a 230 s run with the Mac's load average at 40 to 180 (2026-10-05).
        self.command('package-build', ['bash', 'scripts/run-sessionkit-tests.sh', '--build-only'],
                     timeout=PACKAGE_BUILD_TIMEOUT)
        audio = self.manifest['audio_output'] = host_audio.audio_output()
        try:
            self.command('package', ['bash', 'scripts/run-sessionkit-tests.sh', '--skip-build'],
                         timeout=PACKAGE_TEST_TIMEOUT,
                         expected=expected, tests=True,
                         allowed_skips={'SessionKitTests/SharingTests/testHeldOutPublicDomainPodcastAnchorCorpus'},
                         probation=CODEX_SANDBOX_AUDIO_TESTS & expected if in_codex_sandbox() else None)
        except RuntimeError as error:
            step = self.manifest['steps'][-1]
            failed = [test for test, record in step.get('tests', {}).items() if record['status'] == 'failed']
            # Only test failures: a crash, a timeout or tests that never ran are not explained by the sound.
            only_failures = (not step.get('interrupted')
                             and all(e.startswith(('Failed: ', 'Process exit ')) for e in step.get('errors', [])))
            # #909: with no sound output only the real-player tests fail, for every PR. Say it is the Mac.
            if (not audio['usable'] and only_failures and failed
                    and all(REAL_PLAYER_TEST.search(test) for test in failed)):
                self.manifest['lane_fault'] = f'no audio output: {audio["why"]}'
                self.save()
                raise RuntimeError(f'lane fault, not the PR: {self.manifest["lane_fault"]}; {error}')
            raise

        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed during fast verification')

    def skip(self, name, reason=None):
        reason = reason or CODEX_SANDBOX_SKIPS[name]
        self.manifest['steps'].append({'name': name, 'skipped': reason})
        self.save()
        print(f'{name}: skipped ({reason})', flush=True)

    def ops_steps(self, root=None):
        """The ops tools' own tests (ops/dial, ops/codex), one step per folder: each folder imports its
        module from beside its tests, so each is its own discovery top level."""
        base = Path(root or ROOT)
        for folder in ops_test_folders(base):
            name = 'ops-' + '-'.join(folder.relative_to(base).parts[1:]) if folder != base / 'ops' else 'ops'
            self.command(name, [sys.executable, '-m', 'unittest', 'discover', '-s', str(folder), '-t', str(folder)])

    def xcode(self, plan, device, rebuild, ios=None, only=(), probation=None, simulator_slot_fd=None):
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed before Xcode verification')
        scheme, name, timeout = PLANS[plan]
        # T3 runs a few test classes or methods of a plan. Each selector must name tests in the plan.
        selectors = [s if s.startswith((f'{APP_TEST_TARGET}/', f'{UI_TEST_TARGET}/')) else f'{APP_TEST_TARGET}/{s}'
                     for s in only]
        planned = plan_tests(ROOT, name)
        unmatched = [s for s in selectors if not any(selected(test, s) for test in planned)]
        if unmatched:
            raise RuntimeError(f'Not in the {name} test plan: {", ".join(unmatched)}')
        selectors = narrow_selectors(selectors, planned,
                                     {f'{APP_TEST_TARGET}/{test}' for test in target_tests(ROOT, APP_TEST_TARGET)})
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
        refuse_unsafe(chosen, lane_sim.unsafe_devices())
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
        # A run that boots its own simulator holds a Mac-wide simulator slot until it shuts it down
        # (16 GB Mac: a second simulator job only while memory pressure is normal, #184). A device
        # someone else booted is theirs, and so is the slot.
        slot = inherited_simulator_slot(simulator_slot_fd) if simulator_slot_fd is not None else (
            acquire_simulator_slot(f'verify-tests {plan}', out=sys.stdout, max_wait=BUILD_SLOT_WAIT_SECONDS)
            if booted_here else None)
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
            on_probation = None if probation is None else {
                test for test in expected if any(selected(test, s) for s in probation)}
            self.command('xcode-tests', base + [f'-only-testing:{s}' for s in selectors] + [
                         'test-without-building', '-parallel-testing-enabled', 'NO',
                         '-collect-test-diagnostics', 'never',
                         '-test-timeouts-enabled', 'YES', '-resultBundlePath', str(self.output / 'tests.xcresult')],
                         timeout=timeout, expected=expected, tests=True, probation=on_probation)
        finally:
            if booted_here:
                # Don't leave an idle simulator holding memory after the run.
                subprocess.run(['xcrun', 'simctl', 'shutdown', chosen['udid']],
                               cwd=ROOT, capture_output=True, timeout=60)
            if slot:
                if simulator_slot_fd is not None:
                    slot.close()
                else:
                    release_handle(slot)
        if input_identity() != identity:
            raise RuntimeError('Inputs changed during testing; rerun on a stable source state')


def read_changed_files(path):
    """The changed paths in a --changed-files list, or None (run everything) when it can't be read or is empty."""
    try:
        paths = [line.strip() for line in Path(path).read_text().splitlines() if line.strip()] if path else []
    except OSError:
        return None
    return paths or None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', choices=['fast', *PLANS], default='fast')
    parser.add_argument('--device', help='Supported simulator UDID (including iPad); overrides phone preference')
    parser.add_argument('--ios', type=int, help='Required iOS major version, e.g. 26 or 27; never falls back to another OS')
    parser.add_argument('--simulator-slot-fd', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--rebuild', action='store_true', help='Ignore the compatible build stamp')
    parser.add_argument('--output', type=Path, help='New evidence directory')
    parser.add_argument('--changed-files', type=Path, metavar='FILE',
                        help='Lane runs: the PR\'s changed paths, one per line (renames name both sides). --plan fast then '
                             'skips the runner and ops tests nothing in the diff can affect; without it every step runs')
    parser.add_argument('--list', action='store_true', help='Inspect selection without running tests')
    parser.add_argument('--only-testing', action='append', default=[], metavar='CLASS[/METHOD]',
                        help='Xcode plans: run only these tests of the plan (repeatable); unknown ones fail the run')
    args = parser.parse_args()
    if errors := validate():
        parser.error('; '.join(errors))
    from test_inventory import scripted_journeys  # only the journeys plan reads the list
    journeys = scripted_journeys() if args.plan == 'journeys' else None
    if journeys and args.only_testing:
        parser.error('--plan journeys runs TestPlans/scripted-journeys.json; it takes no --only-testing')
    if args.list:
        print('\n'.join(f'{t} ({status})' for status, tests in journeys.items() for t in tests) if journeys
              else '\n'.join(sorted(plan_tests(ROOT, PLANS[args.plan][1]))) if args.plan in PLANS
              else 'runner-tests, ops tests, contracts, surfaces, inventory, browser, all SessionKit tests')
        return 0
    if journeys is not None and not any(journeys.values()):
        print('No scripted journeys are listed in TestPlans/scripted-journeys.json; nothing to run.')
        return 0
    (ROOT / '.build').mkdir(exist_ok=True)
    with (ROOT / '.build/verification.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output = args.output or ROOT / 'artifacts/test-runs' / (
            datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '-' + args.plan)
        run = Run(output.resolve(), args.plan, read_changed_files(args.changed_files) if args.plan == 'fast' else None)
        try:
            if args.plan in ('fast', 'release'):
                run.fast()
            if args.plan != 'fast':
                if journeys:
                    run.manifest['scripted_journeys'] = journeys
                    run.xcode(args.plan, args.device, args.rebuild, args.ios,
                              journeys['gating'] + journeys['probation'], probation=journeys['probation'],
                              simulator_slot_fd=args.simulator_slot_fd)
                else:
                    run.xcode(args.plan, args.device, args.rebuild, args.ios, args.only_testing,
                              simulator_slot_fd=args.simulator_slot_fd)
            if input_identity() != run.manifest['input_sha256']:
                raise RuntimeError('Inputs changed during verification; rerun on a stable source state')
            run.manifest['status'] = passed_status()
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
