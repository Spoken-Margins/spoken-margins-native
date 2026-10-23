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
import shutil
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from xml.etree import ElementTree
from lane_xcresult_attachments import export_failed_attachments

from check_posterboard_repair import crash_snapshot, new_crash
import host_audio
import lane_audio_window
import lane_conditions
import lane_sim
import sm_build_cache
import sessionkit_pass
import lane_sim_pool
import third_party_notices
import xcodebuild_finish
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

# Xcode's compilation cache for the app build-for-testing (#1331). Every T3 builds in fresh DerivedData, so
# without it each one recompiled every module. Measured on the lane Mac (Xcode 27.0, 2026-10-12): 57-73 s
# cold; with the cache 46 s after a one-line SessionKit edit, 39 s after an app-only edit, 18-25 s with
# nothing changed. The store is shared by every checkout on this Mac: the extra prefix map makes paths
# inside the tree the same in each, which took a second worktree from 23 to all 104 Swift compiles hit.
# Xcode bounds the store: past the limit it starts a new chunk and drops the oldest, so it stays under
# about twice the limit (measured: a 1G limit held it to 1.4 GB).
COMPILATION_CACHE_LIMIT = '3G'

# Settings that describe the machine or the lane job, not the code under test. A step must not inherit them:
# with SM_TRUNK=main exported (the lane and the Mac set it after #1492), suites whose fixtures were written
# for the default trunk failed, and every merge run came back INCONCLUSIVE.
STEP_ENV_DROPS = ('SM_TRUNK',)


def step_env(environ=None):
    """The environment a test step runs in: the caller's, without STEP_ENV_DROPS."""
    env = dict(os.environ if environ is None else environ)
    for name in STEP_ENV_DROPS:
        env.pop(name, None)
    return env


def compilation_cache_settings(root=None):
    """The build settings that turn on Xcode's compilation cache, in the lane's state folder."""
    root = root or ROOT
    mapping = f'"{root}=/^tree"'
    return ['COMPILATION_CACHE_ENABLE_CACHING=YES',
            f'COMPILATION_CACHE_CAS_PATH={state_dir() / "compilation-cache"}',
            f'COMPILATION_CACHE_LIMIT_SIZE={COMPILATION_CACHE_LIMIT}',
            'SWIFT_ENABLE_PREFIX_MAPPING=YES', 'SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES',
            'CLANG_ENABLE_PREFIX_MAPPING=YES', 'CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES',
            f'SWIFT_OTHER_PREFIX_MAPPINGS={mapping}', f'CLANG_OTHER_PREFIX_MAPPINGS={mapping}']


def compilation_cache_hits(log):
    """Xcode's own count, e.g. '441 hits / 508 cacheable tasks (87%)', or None when it printed none."""
    found = re.findall(r'note: (\d+ hits / \d+ cacheable tasks \(\d+%\))', log)
    return found[-1] if found else None

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


def t3_selection(only, plan_name, root=None):
    """The -only-testing selectors for a T3 request of `only` (Class or Class/method) in a test plan, the plan's
    tests, and the tests the run must complete. A selector that names nothing in the plan is refused, so a
    misspelled name fails before anything builds instead of running nothing (#2138). Shared with the hosted Mac
    (scripts/hosted_t3_check.py), so both judge a T3 by one rule."""
    root = ROOT if root is None else root
    selectors = [s if s.startswith((f'{APP_TEST_TARGET}/', f'{UI_TEST_TARGET}/')) else f'{APP_TEST_TARGET}/{s}'
                 for s in only]
    planned = plan_tests(root, plan_name)
    unmatched = [s for s in selectors if not any(selected(test, s) for test in planned)]
    if unmatched:
        raise RuntimeError(f'Not in the {plan_name} test plan: {", ".join(unmatched)}')
    selectors = narrow_selectors(selectors, planned,
                                 {f'{APP_TEST_TARGET}/{test}' for test in target_tests(root, APP_TEST_TARGET)})
    expected = {test for test in planned if not selectors or any(selected(test, s) for s in selectors)}
    return selectors, planned, expected


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


INPUT_ROOTS = ('App/', 'Packages/', 'Contracts/', 'Config/', 'TestPlans/', 'SpokenMarginsNative.xcodeproj/',
               'scripts/', 'validation/', 'Tools/', 'schemas/', 'ops/')
INPUT_FILES = ('project.yml', 'package.json', 'package-lock.json')


def input_digests():
    """The hash of every file the verification depends on, by path (tracked and untracked, not ignored)."""
    paths = capture(['git', 'ls-files', '--cached', '--others', '--exclude-standard']).splitlines()
    digests = {}
    for relative in sorted(set(paths)):
        if not (relative.startswith(INPUT_ROOTS) or relative in INPUT_FILES):
            continue
        path = ROOT / relative
        digests[relative] = hashlib.sha256(path.read_bytes() if path.is_file() else b'<deleted>').hexdigest()
    return digests


def input_identity(digests=None):
    digest = hashlib.sha256()
    for relative, file_digest in (input_digests() if digests is None else digests).items():
        digest.update(relative.encode() + b'\0' + file_digest.encode())
    return digest.hexdigest()


def inputs_changed_message(prefix, before, limit=5):
    """`prefix`, then the first few paths whose hash differs from `before` (#1773), so a lane report names the file.

    SwiftPM rewrites Packages/SessionKit/Package.resolved when the committed copy doesn't match Package.swift (a
    branch that committed the Linux-resolved copy did exactly that), so that case says how to fix it."""
    after = input_digests()
    paths = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    if not paths:
        return prefix + ' (no file hash differs now: it changed and changed back)'
    shown = ', '.join(paths[:limit]) + (f' and {len(paths) - limit} more' if len(paths) > limit else '')
    message = f'{prefix}: {shown}'
    if 'Packages/SessionKit/Package.resolved' in paths:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from trunk import trunk_ref  # #1492: the branch the fix restores from
        message += ('. SwiftPM rewrote Package.resolved during the build, so the copy committed on this branch does not '
                    'match Package.swift on the Mac (a Linux `swift test` rewrites it). Restore it with '
                    f'`git checkout {trunk_ref()} -- Packages/SessionKit/Package.resolved` and push; if this branch '
                    'changes dependencies on purpose, run `swift package resolve` on a Mac instead')
    return message


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


TEST_STARTED = re.compile(r"Test Case '-\[(\w+)\.(\w+) (test\w+)\]' started\.")


def unfinished_test(log):
    """The last XCTest test that printed "started" and no result after it, as Module/Class/method, or None (#1956)."""
    started = list(TEST_STARTED.finditer(log))
    if not started:
        return None
    module, name, method = started[-1].groups()
    finished = re.search(rf"Test Case '-\[{module}\.{name} {method}\]' (?:passed|failed|skipped)",
                         log[started[-1].end():])
    return None if finished else f'{module}/{name}/{method}'


def xunit_records(path):
    """Test results from a `swift test --xunit-output` file, keyed like test_records (Module/Class/method).

    `swift test --parallel` doesn't print a line per passing test, so its results come from this file.
    A missing or unreadable file gives no records, which the caller's reconcile reports as a failure."""
    try:
        suite = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError):
        return {}
    records = {}
    for case in suite.iter('testcase'):
        module, _, name = case.get('classname', '').partition('.')
        method = case.get('name', '').removesuffix('()')
        if not (re.fullmatch(r'\w+', module) and re.fullmatch(r'\w+', name) and re.fullmatch(r'test\w+', method)):
            continue
        status = ('failed' if case.find('failure') is not None or case.find('error') is not None
                  else 'skipped' if case.find('skipped') is not None else 'passed')
        identifier = f'{module}/{name}/{method}'
        try:
            seconds = float(case.get('time', 0))
        except ValueError:
            seconds = 0.0
        if identifier in records:  # a repeated case keeps its worst result
            previous = records[identifier]
            status = next(s for s in ('failed', 'skipped', 'passed') if s in (previous['status'], status))
            seconds += previous['seconds']
        records[identifier] = {'status': status, 'seconds': seconds}
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


def unittest_failures(text):
    """Each failing test in a unittest log as (test, "path:line", message), so a red runner or ops step names it.

    unittest prints `FAIL: name (id)` or `ERROR: name (id)` between `=====` rules, then a traceback whose last
    `File` line is the assertion (or the crash) and whose unindented lines after it are the message (#2457).
    A subTest failure repeats the header with its parameters, so each is its own entry.
    """
    failures = []
    for block in re.split(r'^={70}$', text, flags=re.M)[1:]:
        header, _, body = block.strip().partition('\n')
        if not re.match(r'(FAIL|ERROR): ', header):
            continue
        trace = re.split(r'^-{70}$', body, flags=re.M)[1] if body.count('-' * 70) else body  # the last block ends in the summary
        if 'Traceback (most recent call last):' in trace:  # a chained exception: the last one is the failure
            trace = trace[trace.rindex('Traceback (most recent call last):'):]
        frames = re.findall(r'^\s*File "([^"]+)", line (\d+)', trace, re.M)
        ours = [frame for frame in frames if frame[0].startswith(str(ROOT))]  # the test's line, not a library's
        where = ('{}:{}'.format(Path((ours or frames)[-1][0]).as_posix(), (ours or frames)[-1][1])
                 if frames else 'no traceback')
        message = [line.strip() for line in trace.splitlines() if line.strip() and not line[0].isspace()
                   and not line.startswith('Traceback')][:2]
        failures.append((header.split(': ', 1)[1], where, ' | '.join(message)[:300]))
    return failures


def report_unittest_failures(name, failures, limit=10):
    """The failures as manifest error lines, and (on GitHub) as the job's step summary."""
    lines = [f'Failed: {test} at {where}' + (f' — {message}' if message else '')
             for test, where, message in failures]
    if (summary := os.environ.get('GITHUB_STEP_SUMMARY')) and failures:
        with open(summary, 'a') as handle:
            handle.write(f'### {name}: {len(failures)} failing test(s)\n\n'
                         + ''.join(f'- `{test}` at `{where}`' + (f': {message}' if message else '') + '\n'
                                   for test, where, message in failures))
    if len(lines) > limit:
        lines[limit:] = [f'Failed: and {len(lines) - limit} more (see the step log)']
    return lines


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
# Some tests also read the repository outside scripts/: the filled-button and mini player keep-out scans read
# App/ (and the accessibility source scans read App/ Swift files, #2041); the inventory and
# contract checks read project.yml, Package.swift, TestPlans/, Contracts/ and validation/; the hot-file test
# checks that the hot files exist under App/; the research harness test reads research/; and the lane
# runner's T3 scope and "only testing" tests, and one lane-sim test, plan against the real TestPlans/ and the
# app test sources; the sharing kit's tests read docs/sharing-test-kit/ and the packet and sharing sources under
# Packages/ and App/; the BUILDING.md test reads that file, README.md, package.json, .gitattributes,
# the hosted workflow and the App Group names in App/; the SessionKit pass key's reader guard reads every
# Swift file of the package (re-measured 2026-10-09; the guard added 2026-10-10, #1328), and the
# starter-catalog test reads Site/onboarding/ and research/B1/ (#1732). A diff that touches those inputs
# (and no lane path) runs just
# these (a module, or a module.Class); the rest of the suite reads only scripts/.
# To re-measure the list, copy scripts/, .github/ and .gitignore into a fresh git repository, run
# `python -m unittest discover -s scripts/tests` there and on a full checkout: the classes that fail only in
# the copy are the readers. Lists like this drift when tests are added, so non-lane runs and the Test Desk's
# run on next, which keep every step, are what catch a missed reader.
RUNNER_TEST_READERS = ('test_filled_button_contrast', 'test_filled_button_labels', 'test_verification',
                       'test_validate_contracts', 'test_hot_file_ratchet', 'test_research_tests',
                       'test_lane_runner.OnlyTestingTests', 'test_lane_runner.ScopeClassTests',
                       'test_lane_runner.T3Tests', 'test_lane_sim.LaneSimTests', 'test_sharing_kit',
                       'test_sessionkit_pass', 'test_mini_player_keep_out', 'test_package_resolved',
                       'test_building_md', 'test_third_party_notices', 'test_main_thread_reads',
                       'test_starter_catalog',
                       # The accessibility source scans read App/ Swift files (#2041).
                       'test_screen_change_cue', 'test_selected_trait', 'test_screen_title_heading',
                       'test_row_accessibility_actions', 'test_voiceover_label_nits',
                       'test_increase_contrast_wiring', 'test_reduce_motion', 'test_tap_target_styles',
                       # The article-entry inventory reads App/ Swift files (#2363).
                       'test_article_entry_followups')
RUNNER_TEST_INPUTS = ('App/', 'Packages/', 'Contracts/', 'TestPlans/', 'validation/', 'research/', 'project.yml',
                      'docs/sharing-test-kit/', 'BUILDING.md', 'README.md', 'package.json', '.gitattributes',
                      # test_third_party_notices reads the dependency manifests and its own list (#1823).
                      'docs/legal/', 'THIRD_PARTY_NOTICES.md', 'requirements-dev.txt', 'Site/', 'Tools/',
                      'Config/', 'fixtures/', 'traces/', 'schemas/', 'Design/SpokenMarginsOverhaul/package.json',
                      'Design/UXProposal20260909/package.json')
# The ops tests read their own folder and scripts/lane-runner.py (the audit's test), test-scope and the release
# files, so they follow the ops tools and anything the runner tests follow, plus the build inputs. The Codex
# audit's tests also check that AGENTS.md is at the repository root. Re-measured 2026-10-09 the same way as
# the runner tests: with only these copied, every ops suite passes.
OPS_TEST_TRIGGERS = ('ops/', 'scripts/', '.github/', 'project.yml', 'TestPlans/', 'AGENTS.md')

# --plan fast-portable (#1847): the fast plan's steps that need neither Swift nor an Apple tool, for a hosted
# Linux job (.github/workflows/hosted-portable.yml). Every step the fast plan can run is named here, either to
# run (PORTABLE_STEPS) or with the reason it is left out (PORTABLE_LEFT_OUT); the run prints the left-out ones as
# skipped. test_verification fails when the plan code names a step that is in neither table.
PORTABLE_STEPS = ('runner-tests', 'ops', 'contracts', 'public-tree', 'surfaces', 'inventory', 'main-thread-reads', 'browser', 'share-link', 'research')
PORTABLE_LEFT_OUT = {
    'package-build': 'needs the Swift toolchain on macOS; hosted-sessionkit-linux.yml builds the Foundation-only modules on Linux',
    'package-core': 'needs the Swift toolchain on macOS (SessionKitCoreTests also run in hosted-sessionkit-linux.yml)',
    'package-core-serial': 'needs the Swift toolchain on macOS',
    'package': 'needs the Swift toolchain, AVFoundation and a sound output; only the Mac lane runs the whole package',
    'shipped-compat': 'builds SessionKit and Build 29\'s persistence code with Swift on macOS; only the Mac lane runs it',
    'hot-file-ratchet': 'the author\'s own fast run checks it, and the lane runner checks next\'s copy with the PR\'s labels',
}
# Inside runner-tests and ops, the tests that drive an Apple tool. Each is matched as a test id prefix (module,
# class or test) in scripts/tests, or as a folder under ops/.
PHONE_BUILD_NEEDS_MAC = 'builds an app with xcodebuild and a fake xcrun on a Mac'
PORTABLE_RUNNER_TESTS_LEFT_OUT = {
    'test_phone_build.InstallerTests.': 'runs the zsh phone installer, which calls plutil and xcrun',
    'test_phone_build.PhoneBuildTests.test_a_failed_release_build_opens_one_item_updates_it_and_the_next_success_closes_it': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_a_merge_check_that_passed_and_pushed_this_commit_skips_the_host_checks': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_a_merge_check_that_pushed_another_commit_does_not_count_so_the_host_checks_run': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_a_merge_check_that_says_fail_does_not_count_so_the_host_checks_run': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_a_safe_remerge_builds_release_without_repeating_host_or_simulator_checks': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_builds_writes_plan_and_points_latest': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_if_changed_skips_when_latest_is_the_tip': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_plan_starts_at_the_installed_build': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_release_cache_and_source_survive_and_are_reused_for_the_next_tip': PHONE_BUILD_NEEDS_MAC,
    'test_phone_build.PhoneBuildTests.test_untested_commit_runs_host_checks_first': PHONE_BUILD_NEEDS_MAC,
    'test_lane_slots.VerifyTestsSlotTests.test_runner_xcodebuild_steps_take_a_slot_and_record_it': 'runs xcodebuild',
    'test_sim_builds.': 'packs and unpacks app builds with macOS ditto',
    # The runner (lane-runner.py) runs only on the Mac; Ubuntu 22.04's git 2.34 on the VPS runner is too old (#2160).
    'test_lane_hosted_fast.HostedChecksStandTests.': 'needs git merge-tree --write-tree (git 2.38 or later)',
}
PORTABLE_OPS_LEFT_OUT = {'ops/disk': 'measures macOS volumes, Time Machine snapshots and the Mac-only caches'}
# --plan fast-hosted-sessionkit and --plan fast-mac-rest (#1389): the fast plan split three ways once the repo is
# public. hosted-portable.yml runs fast-portable on Linux and fast-hosted-sessionkit (SessionKit's build and
# SessionKitCoreTests) on a GitHub-hosted Mac, on GitHub's merge commit of the PR. The lane runner accepts those two
# PASSes for the commit it would push (lane-runner.py hosted_fast_checks) and runs only fast-mac-rest on the lane
# Mac: the runner and ops tests that drive Apple tools or measure the Mac, and the SessionKitTests and
# SessionKitTraceTests targets, whose real-time AVFoundation tests need a sound output (PORTABLE_LEFT_OUT 'package').
# Between them the three plans run every fast-plan step (test_fast_split.py checks it).
FAST_SPLIT_PLANS = ('fast-portable', 'fast-hosted-sessionkit', 'fast-mac-rest')
HOSTED_SESSIONKIT_STEPS = ('package-build', 'package-core', 'package-core-serial')
MAC_REST_STEPS = ('hot-file-ratchet', 'runner-tests', 'ops', 'package-build', 'package', 'shipped-compat')
# runner-tests without the tests above: discover scripts/tests as the plain step does, then drop the listed ids.
PORTABLE_RUNNER_LOADER = '''
import sys, unittest
sys.path.insert(0, "scripts/tests")
left_out = tuple(sys.argv[1:])
def tests(suite):
    for item in suite:
        yield from tests(item) if isinstance(item, unittest.TestSuite) else [item]
kept = unittest.TestSuite(t for t in tests(unittest.defaultTestLoader.discover("scripts/tests"))
                          if not t.id().startswith(left_out))
sys.exit(not unittest.TextTestRunner().run(kept).wasSuccessful())
'''
# fast-mac-rest's runner-tests: only the tests PORTABLE_RUNNER_TESTS_LEFT_OUT names, the inverse of the loader above.
MAC_REST_RUNNER_LOADER = '''
import sys, unittest
sys.path.insert(0, "scripts/tests")
only = tuple(sys.argv[1:])
def tests(suite):
    for item in suite:
        yield from tests(item) if isinstance(item, unittest.TestSuite) else [item]
kept = unittest.TestSuite(t for t in tests(unittest.defaultTestLoader.discover("scripts/tests"))
                          if t.id().startswith(only))
sys.exit(not unittest.TextTestRunner().run(kept).wasSuccessful())
'''


# The last shipped build's compatibility checks (#1899): the frozen packet reader still matches the tag, and a
# database this tree writes opens in that build's own persistence code. .github/workflows/shipped-build-compat.yml
# runs them too, but the runner pushes a merge commit it built itself, so no required check can stand on it and a
# red workflow never stopped a PR landing. They run here instead, in the plan the runner merges on, for a diff that
# touches a file that workflow's `paths` names. They need the Mac (the writer builds SessionKit's test target),
# so they are a Mac step in the split plans.
SHIPPED_COMPAT_WORKFLOW = '.github/workflows/shipped-build-compat.yml'
SHIPPED_COMPAT_COMMAND = 'scripts/freeze-shipped-reader.sh --check && scripts/check-build29-database.sh'
SHIPPED_COMPAT_TIMEOUT = 2400  # the workflow's own 40-minute budget


def shipped_compat_paths(root):
    """The `paths` globs of the compatibility workflow in <root>, or None when the tree has no such workflow."""
    workflow = Path(root) / SHIPPED_COMPAT_WORKFLOW
    if not workflow.is_file():
        return None
    text = workflow.read_text()
    if '    paths:\n' not in text:
        raise RuntimeError(f'{SHIPPED_COMPAT_WORKFLOW} has no `paths:` list; shipped_compat_paths cannot read it')
    block = text.split('    paths:\n', 1)[1].split('\npermissions:', 1)[0]
    paths = [m.group(1) for m in re.finditer(r"^\s*-\s*'([^'!][^']*)'\s*(?:#.*)?$", block, re.M)]
    entries = [line for line in block.splitlines() if line.strip().startswith('-')]
    if len(entries) != len(paths):  # a double-quoted, unquoted or `!negated` entry would be dropped, not matched
        raise RuntimeError(f'{SHIPPED_COMPAT_WORKFLOW} has a `paths:` entry that is not a plain single-quoted glob')
    if not paths:
        raise RuntimeError(f'{SHIPPED_COMPAT_WORKFLOW} lists no paths; shipped_compat_paths cannot read it')
    return paths


def github_glob_matches(pattern, path):
    """GitHub's path glob: `*` stays inside a folder, `**` crosses folders."""
    regex = re.escape(pattern).replace(r'\*\*', '\0').replace(r'\*', '[^/]*').replace('\0', '.*')
    return re.fullmatch(regex, path) is not None


def shipped_compat_needed(changed, root=None):
    """(run, reason) for the compatibility checks. changed=None means no diff information: run, as every other
    step does, so the Test Desk's run on the trunk's tip and an author's own --plan fast keep them."""
    if not changed:
        return True, 'no list of changed paths, so every step runs'
    patterns = shipped_compat_paths(root or ROOT)
    if patterns is None:
        return False, f'this tree has no {SHIPPED_COMPAT_WORKFLOW} to take the watched paths from'
    hit = [path for path in changed if any(github_glob_matches(pattern, path) for pattern in patterns)]
    if hit:
        return True, 'the diff touches ' + ', '.join(hit[:3]) + (f' and {len(hit) - 3} more' if len(hit) > 3 else '')
    return False, 'the diff touches none of the files shipped-build-compat.yml watches'


def touches(changed, prefixes):
    return any(path == prefix or path.startswith(prefix) for path in changed for prefix in prefixes)


def adds_licence_surface(path):
    """True for a dependency manifest, model or font file anywhere in the tree: the notices check reads the whole
    repository, so the PR that adds one must be the PR that runs it (#1823)."""
    p = Path(path)
    return bool(third_party_notices.MANIFEST_NAMES.match(p.name)) or p.suffix.lower() in third_party_notices.MODEL_SUFFIXES


def runner_test_scope(changed):
    """('all'|'readers'|'none', reason) for the runner tests. changed=None means no diff information: all."""
    if not changed:
        return 'all', None
    if touches(changed, RUNNER_TEST_TRIGGERS):
        return 'all', None
    if touches(changed, RUNNER_TEST_INPUTS):
        return 'readers', 'diff touches no lane path; only the tests that read ' + ', '.join(
            p for p in RUNNER_TEST_INPUTS if touches(changed, (p,))) + ' run'
    surface = [path for path in changed if adds_licence_surface(path)]
    if surface:
        return 'readers', 'diff touches no lane path; only the tests that read ' + ', '.join(surface[:3]) + ' run'
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

# MainThreadHangProbeTests time the probe against wall-clock time. On a host so busy that a 10 ms sleep ran 40 ms
# late they skip rather than judge it (#2210), so a skip there is not an unexpected one.
HANG_PROBE_TIMING_TESTS = frozenset(f'SessionKitCoreTests/MainThreadHangProbeTests/{test}' for test in (
    'testAFourHundredMillisecondBlockRecordsOneHangWithItsLabel',
    'testAThreeHundredFiftyMillisecondBlockIsStillRecorded',
    'testAHundredMillisecondBlockRecordsNothing',
    'testNestedLabelsReadOutermostFirstAndAnUnlabelledHangHasNone',
    'testAStoppedProbeRecordsNothingAndASecondHangAfterAFirstIsCounted',
))

# StoreReadMeterTests skip by design (#2258): the Library list is a known-oversized read that skips with its measured
# bytes until #2102's fix fails it on purpose, and the cost table builds the large fixtures only when asked for.
READ_METER_SKIPS = frozenset(f'SessionKitCoreTests/StoreReadMeterTests/{test}' for test in (
    'testTheLibraryListDoesNotDecodeEveryArticleText',
    'testReadCostTableAtEveryScale',
))
CORE_ALLOWED_SKIPS = HANG_PROBE_TIMING_TESTS | READ_METER_SKIPS

# Pocket's render tests need ~131 MB of git-ignored weights (research/C2/pocket/fetch_weights.sh). Without them they
# skip with "skipped: weights not fetched", which is how the lane Mac runs them. The renderer's logic tests, with
# their own fixtures, still run everywhere.
POCKET_WEIGHT_TESTS = frozenset(f'SessionKitTests/PocketRendererTests/{test}' for test in (
    'testTokenizerAndSplitterMatchPythonOnTheExportsFiles',
    'testRendersAndRefusesEmptyAndCancelledText',
    'testRendersTheThreeC2PassagesFasterThanRealTimeOnOneThread',
    'testProsePassagesAreSpokenWithinTwoPointsOfThePyTorchWordError',
))


# Supertonic's render tests need its model, which is a download since #1820, in neither the repository nor the app.
# Without `scripts/voice-catalog fetch supertonic-3-int8` (or SESSIONKIT_SUPERTONIC_DIR) they skip, naming the
# supertonicModel input; SM_REQUIRE_MODELS makes them fail instead.
SUPERTONIC_MODEL_TESTS = frozenset(f'SessionKitTests/{test}' for test in (
    'SupertonicChunkingTests/testNumberHeavyTableSpanRendersNoChunkNearTheBabbleLength',
    'SupertonicChunkingTests/testSystemVoiceReadsAFlaggedChunkInSupertonicsFormat',
    'SupertonicDownloadedModelTests/testThePinnedTreeHashIsTheDownloadedModels',
    'SupertonicNarrationTests/testDiscardDeletesOnlyAudioTheRendererGenerated',
    'SupertonicNarrationTests/testRealRenderComesBackTrimmedToItsSpeech',
    'SupertonicNarrationTests/testRealRendersArePacedByWhoAskedNotBySharedState',
    'SupertonicVoiceSelectionTests/testJamesAndLilyReadTheSameSentenceInTheirOwnAudibleVoices',
))

# The real speech recognizer needs SpeechTranscriber and a model for the host's locale. GitHub's hosted macOS image
# has neither, so the test skips there, naming why; the owner's call is that this skip "is expected" (#2469, 2026-10-23).
SPEECH_MODEL_TESTS = frozenset({'SessionKitTests/RealSpeechTranscriberTests/testRealTranscriberHearsSynthesizedSpeech'})


# The one app-hosted test that runs Supertonic's real model, in the adapters plan. The model is a download since #1820,
# so the run fetches it (pinned by sha256 in Contracts/voice-models/sources.json) into a cache outside the checkout,
# once per Mac, and hands it to the app's tests; a fetch that fails fails the run instead of letting the test skip.
SUPERTONIC_APP_MODEL_TEST = 'SupertonicSpeechTests/testDownloadedRendererSynthesizesJamesAndLilyAndReusesSessions'
SUPERTONIC_MODEL_VOICE = 'supertonic-3-int8'


def supertonic_model_cache():
    """Where the lane keeps the fetched model: SM_VOICE_CACHE, else the user's Caches folder (about 150 MB)."""
    return Path(os.environ.get('SM_VOICE_CACHE') or Path.home() / 'Library/Caches/SpokenMargins/voice-catalog')


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


def load_average():
    """The 1, 5 and 15 minute load averages, or None where the system doesn't report them."""
    try:
        return [round(value, 1) for value in os.getloadavg()]
    except OSError:
        return None


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def stop_process_group(process, grace=10):
    # #1956: SwiftPM runs xctest in a process group of its own, so the group's signal alone left a hung xctest
    # running under launchd. Its descendants in other groups get the same signals, found before the group stops.
    # Best effort: looking for them must not replace the error that brought us here.
    try:
        strays = [pid for pid, _ in descendants(process.pid)]
    except Exception:  # noqa: BLE001
        strays = []

    def signal_all(number):
        # The group may already be gone (or, on macOS, hold only zombies, which gives EPERM); that
        # must not replace the error that brought us here.
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, number)
        for pid in strays:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, number)
    signal_all(signal.SIGTERM)
    # Wait for the whole group, not just its leader: a leader that exits on SIGTERM can leave a
    # descendant that ignores it (Codex audit P2 on dd3e0a4).
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        process.poll()  # reap the leader, so a zombie leader doesn't count as alive
        if not process_group_alive(process.pid) and not any(process_alive(pid) for pid in strays):
            break
        time.sleep(0.1)
    else:
        signal_all(signal.SIGKILL)
    process.wait()


def feed_new_lines(path, offset, watch):
    """Feed the complete lines written to `path` since byte `offset` to `watch`; returns the new offset."""
    with path.open('rb') as handle:
        handle.seek(offset)
        data = handle.read()
    end = data.rfind(b'\n') + 1
    for line in data[:end].splitlines():
        watch.feed(line.decode(errors='replace'))
    return offset + end


PACKAGE_BUILD_TIMEOUT = 900  # SessionKit build with tests; cold, under load
PACKAGE_TEST_TIMEOUT = 600  # the SessionKit tests alone (#844)
# #1767: on a busy Mac the same tests run two to three times slower than the 230 s they take on a quiet one, and
# three PRs were failed ("Process exit 124", hundreds of tests missing, no failing test) while the suite was still
# working through its classes. The limit above stays the budget; a step that is still printing results when it
# runs out may go on until the ceiling, and one that has printed nothing for the stall time is a hang and stops.
PACKAGE_TEST_CEILING = 1500
PACKAGE_STALL_SECONDS = 240
# The lane (scripts/lane-runner.py FAST_TIMEOUT, 2400 s) starts its clock before this process, so the plan's wait for
# a host-test slot counts there. A step's ceiling is cut to fit what is left of it, so the step ends itself with its
# own note instead of the lane interrupting the whole plan without one.
FAST_PLAN_SECONDS = 2340
# SessionKitCoreTests run in parallel (#1328); the other two targets hold the real-time AVFoundation tests and
# stay serial. A parallel run that fails for any reason is run again serially, and that result decides.
PARALLEL_CORE_TIMEOUT = 300
# #1767: on the three timed-out runs this step was killed at 62-76% done, its results (written at the end) were lost, and
# the serial rerun took another 364-379 s. Its progress lines stream as it goes, so it gets the same rule as the
# serial steps: a run still printing at 300 s goes on, one silent for the stall time is a hang and is rerun serially.
PARALLEL_CORE_CEILING = 900
PARALLEL_CORE_STALL_SECONDS = 120
PACKAGE_RUNNER = ['bash', 'scripts/run-sessionkit-tests.sh']
# The runner's own 631 tests took 164.5 s on a quiet Mac (PR #1103's 0c940ba, 2026-10-08) and 172.3 s in a
# detached checkout of it, so the 180 s command default left no room: built beside a simulator job, the step
# was killed (exit 124) and the plan reported "Infrastructure runner executed zero tests", twice on #1103's
# head (#1110). Its own limit leaves headroom for load and for the suite to keep growing.
RUNNER_TESTS_TIMEOUT = 600
# #2488: by 2026-10-22 the step took 482-519 s on a busy day and was killed at 600 s at load 138-150, its log still a
# stream of passing dots, so two runs of #2409 failed with "executed zero tests". It gets #1767's rule: a run still
# printing at its budget goes on until the ceiling; one silent for the stall time is a hang and stops.
RUNNER_TESTS_CEILING = 1200
RUNNER_TESTS_STALL_SECONDS = PACKAGE_STALL_SECONDS  # one test compiles Swift, silent for minutes at high load
RUNNER_TESTS_LIMITS = {'timeout': RUNNER_TESTS_TIMEOUT, 'ceiling': RUNNER_TESTS_CEILING,
                       'stall_seconds': RUNNER_TESTS_STALL_SECONDS}

# #705: the startup stall below follows the simulator having just been busy. On 2026-10-14, in the lane's artifacts:
# - 18 of the 20 app-plan stalls launched the host app 1-16 s after the simulator finished booting (median 5 s, from
#   boot-events.log and the stall folders' launchd_sim ages); the 375 runs that did not stall launched it no earlier than
#   about 8 s after the boot finished, and mostly minutes after, because a build ran in between;
# - an adapters plan that began 8 s or less after the app plan's xcodebuild ended on the same simulator stalled in 18
#   of 46 runs; one that began later stalled in 2 of 57 (the second plan always starts about 3-7 s after the first).
# So the host app is not launched until the simulator has been quiet for 20 s: since its boot finished (lane_sim.boot
# marks it) or its last app-hosted test run ended (below). The cause inside Xcode or the simulator is still unknown;
# this removes the window where it shows. The wait is the remainder, usually none: a device with no marker (booted by
# hand) or a retry 90 s later waits 0 s.
SETTLE_SECONDS = 20
SETTLE_LIMIT_SECONDS = 60  # a clock jump or a bad marker never holds a run longer than this


def settle_before_tests(udid, sleep=time.sleep):
    """Wait out the window where the host app stalls at startup (#705). Returns what it saw and how long it waited."""
    quiet_for = lane_sim.seconds_quiet(udid)
    wait = 0.0 if quiet_for is None else min(max(0.0, SETTLE_SECONDS - quiet_for), SETTLE_LIMIT_SECONDS)
    if wait > 0:
        print(f'settling the simulator for {wait:.0f}s before launching the host app '
              f'(quiet for {quiet_for:.0f}s)', flush=True)
        sleep(wait)
    return {'seconds_quiet': None if quiet_for is None else round(quiet_for, 1), 'waited_seconds': round(wait, 1)}


# #2176: of the host-app launches the lane recorded on 2026-10-20, those that began while the Mac reported memory
# pressure "warn" stalled about 3 times in 4 (10 of 12 from 11:27 to 12:41), against about 1 in 5 at "normal". The
# boot already waits for normal pressure; the launch did not. Wait here too, bounded and never failing: the launch
# goes ahead when the wait ends, so a Mac that stays pressured costs at most this long per launch, and the run is
# still judged by the stall rule below.
LAUNCH_PRESSURE_WAIT_SECONDS = 90


def hold_for_launch(wait=lane_sim.wait_for_normal_pressure, limit=None):
    """Wait (bounded) for normal memory pressure before a host-app launch; returns what it saw and the wait."""
    level, waited = wait(LAUNCH_PRESSURE_WAIT_SECONDS if limit is None else limit)
    if waited >= 1:
        print(f'held the host-app launch {waited:.0f}s for memory pressure (now {level})', flush=True)
    return {'memory_pressure': level, 'waited_seconds': round(waited, 1)}


# #705: on intermittent runs the AudioAdapters step launched the app (AcquiredPID) and then sat until its 5m00s
# budget with no test-runner handshake: no "Test Suite" line, 0 tests, exit 124, an unreadable xcresult. Runs that
# start normally print their first Test Suite line about 7 s after launch and finish in 8-30 s. A step that has
# printed none after this long has stalled at startup: record what the host app was doing, then launch the same
# test command once more inside the same budget. The retry runs the same real tests; nothing is skipped or widened.
STARTUP_STALL_SECONDS = 90
STARTUP_RETRIES = 1
# A simulator wedged at launch can leave `simctl terminate` hanging too (#1807). It normally returns at once,
# so a short wait keeps the retry inside the step's budget.
TERMINATE_TIMEOUT_SECONDS = 20
TESTS_STARTED = re.compile(r"^Test (?:Suite|Case) '", re.M)


class StartupStall(Exception):
    pass


# #1161: the 32 stall folders read on 2026-10-14 showed three shapes, none of them the app's own startup code.
# 19 host apps had started and sat idle in the run loop with no XCTest library loaded (none of the libraries in
# xcodebuild's DYLD_INSERT_LIBRARIES, so nothing in the app could connect to the test runner); 12 had no host
# app process at all (the session log ends at "Launching app"); 1 had launched late (the simulator took about 70 s
# to launch it) and was still in dyld, stopped for the debugger, when the watchdog sampled it. Each stall now
# records which shape it was.
XCTEST_INJECTED = re.compile(r'libXCTestBundleInject|XCTestCore\b|/XCTest\.framework/')
NO_HOST_APP = 'no host app process: the launch into the simulator never completed'
LAUNCHED_LATE = 'host app launched late and still starting in dyld when sampled (slow launch into the simulator)'


def stall_diagnosis(sample_text, state=''):
    """One line naming what a stalled host app was doing, from its `sample` output and its ps state."""
    graph = sample_text.split('Binary Images:', 1)
    images = graph[1].strip() if len(graph) == 2 else ''
    # The first thread in the call graph is the main thread; its block ends where the next thread starts.
    main = re.search(r'^Call graph:\n(\s+)(\d+) Thread_.*\n((?:\1[ +!:|].*\n)*)', graph[0], re.M)
    block = main.group(3) if main else ''
    if state.startswith('T'):
        return LAUNCHED_LATE
    if not block:
        return 'host app sample unreadable (no main thread in its call graph)'

    def most(pattern):  # a frame seen in at least half the main thread's samples, not a one-off branch
        return any(int(count) * 2 >= int(main.group(2))
                   for count in re.findall(rf'^[\s+!:|]*(\d+) [^\n]*(?:{pattern})', block, re.M))
    if most(r'_dyld_start|dyld4::prepare'):
        return LAUNCHED_LATE
    injected = 'XCTest loaded' if XCTEST_INJECTED.search(images) else 'XCTest never injected'
    if not images:
        injected = 'XCTest load unknown (no image list)'
    idle = most('__CFRunLoopServiceMachPort') and \
        not most('semaphore_wait|_dispatch_sync_f_slow|__ulock_wait|psynch_mutexwait|psynch_cvwait')
    return f'host app {"idle in its run loop" if idle else "busy or blocked on its main thread"}; {injected}'


# #705, read on 2026-10-15: in all 26 kept stalled result bundles whose host app was running, the session log's
# "Launched app ... (pid = N)" was the pid the watchdog sampled, so no other launcher raced xcodebuild. In
# pr1647-r38684087699 that launch asked for DYLD_INSERT_LIBRARIES and started 45 ms after "Launching app", yet none of
# those libraries were loaded. Our inference: the simulator's launch of that very process lost its settings. Each
# stall now records how far xcodebuild's session log got and whose launch it sampled.
SESSION_STEP = re.compile(r'Installing app|Installed app|Launching app|Launched app with identifier: \S+ \(pid = (\d+)\)'
                          r'|Transitioning from state \w+ to \w+')


def session_progress(result_bundle):
    """The last launch step in xcodebuild's session log for this attempt, and the pid it launched; {} without a log."""
    try:
        logs = list(Path(result_bundle).rglob('Session-*.log')) if result_bundle else []
        text = max(logs, key=lambda log: log.stat().st_mtime).read_text(errors='replace') if logs else ''
    except OSError:
        return {}
    steps = list(SESSION_STEP.finditer(text))
    if not steps:
        return {'session_last_step': None} if logs else {}
    found = {'session_last_step': steps[-1].group(0)}
    launched = [step.group(1) for step in steps if step.group(1)]
    if launched:
        found['launched_pid'] = int(launched[-1])
    return found


def stall_evidence(udid, folder, sample_seconds=3, result_bundle=None):
    """Best effort: which processes of this simulator are alive and what the host app is doing. Never raises."""
    folder.mkdir(parents=True, exist_ok=True)
    found = session_progress(result_bundle)
    try:
        ps = subprocess.run(['ps', '-axo', 'pid=,etime=,stat=,command='], capture_output=True, text=True, timeout=20).stdout
        mine = [line for line in ps.splitlines() if udid and udid in line]
        (folder / 'processes.txt').write_text('\n'.join(mine) + '\n')
        found['processes'] = len(mine)
        diagnoses = []
        for line in mine:
            fields = line.split(None, 3)
            if len(fields) == 4 and 'SpokenMarginsApp.app/SpokenMarginsApp' in fields[3]:
                pid = fields[0]
                path = folder / f'sample-{pid}.txt'
                sampled = subprocess.run(['sample', pid, str(sample_seconds), '-file', str(path)],
                                         capture_output=True, text=True, timeout=sample_seconds + 30)
                found.setdefault('samples', []).append({'pid': int(pid), 'exit': sampled.returncode})
                try:
                    text = path.read_text(errors='replace') if path.is_file() else ''
                except OSError:
                    text = ''
                diagnosis = stall_diagnosis(text, fields[2])
                if 'launched_pid' in found:
                    diagnosis += ('; xcodebuild\'s own launch' if found['launched_pid'] == int(pid)
                                  else f'; not the pid xcodebuild launched ({found["launched_pid"]})')
                diagnoses.append(diagnosis)
        found['diagnosis'] = '; '.join(diagnoses) if diagnoses else NO_HOST_APP
        if found.get('session_last_step'):
            found['diagnosis'] += f'; session log ends at "{found["session_last_step"]}"'
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        found['error'] = repr(error)
    return found


# #1956: in every hung package run the log ended at "409 results" with PublicPodcastLinkResolverTests next, but the test
# that hung ran later (RealPlayerMarginMomentTests, stuck starting a sound output that never started): XCTest's output to
# a file is block-buffered, so its last lines never reached the log. And SwiftPM starts xctest in a process group of
# its own, so stopping the step's group left that xctest running under launchd. A host test step that runs out of time
# now samples its xctest first and says which test is stuck and in what call; the step's stop reaches the xctest too.
TEST_FRAME = re.compile(r'^([ +!:|]*)\d+ (\w+)\.(test\w*)\(\) +\(in ', re.M)
SAMPLE_FRAME = re.compile(r'^([ +!:|]*)\d+ (.+?) +\(in ')
AUDIO_DEVICE_START = re.compile(r'AudioDeviceStart|HALB_IOThread::StartAndWaitForState|AudioOutputUnitStart')


def descendants(pid):
    """Every live process under `pid` by parent link, whatever its process group, as (pid, command) pairs."""
    try:
        # -A (every process) means the same to BSD and procps ps; the hosted Linux runner uses this too (#1956).
        ps = subprocess.run(['ps', '-A', '-o', 'pid=,ppid=,command='], capture_output=True, text=True,
                            timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    children = {}
    for line in ps.splitlines():
        fields = line.split(None, 2)
        if len(fields) >= 2 and fields[0].isdigit() and fields[1].isdigit():
            children.setdefault(int(fields[1]), []).append((int(fields[0]), fields[2] if len(fields) == 3 else ''))
    found, queue = [], [pid]
    while queue:
        for child in children.get(queue.pop(), []):
            found.append(child)
            queue.append(child[0])
    return found


def hang_diagnosis(sample_text):
    """Where a hung xctest is stuck, from its `sample` call graph: the test method, the call it waits in, and
    whether that call is a sound output starting."""
    test = TEST_FRAME.search(sample_text)
    if not test:
        return {'diagnosis': 'no XCTest test method in the sample\'s call graph'}
    # The calls it made follow it, each indented further; sample lists the busiest branch first at each level.
    calls, depth = [], len(test.group(1))
    for line in sample_text[test.start():].splitlines()[1:]:
        frame = SAMPLE_FRAME.match(line)
        if not frame or len(frame.group(1)) <= depth:
            break
        calls.append(frame.group(2))
        depth = len(frame.group(1))
    name = f'{test.group(2)}.{test.group(3)}'
    waiting = calls[-1] if calls else 'its own body'
    audio = bool(AUDIO_DEVICE_START.search('\n'.join(calls)))
    first = f'{calls[0]} → … → ' if len(calls) > 1 else ''
    return {'test': name, 'waiting_in': waiting[:160], 'audio_device': audio,
            'diagnosis': f'{name} is stuck in {first}{waiting[:160]}'
                         + ('; a sound output that never started' if audio else '')}


def hang_evidence(pid, folder, sample_seconds=3, sampler_tool=None):
    """Best effort, before a hung host test step is stopped: sample each xctest under it. Never raises.

    macOS's `sample` gives the call graph. A host without it (the hosted Linux runner) still records each hung
    xctest, with a note file saying why there is no call graph, so the step names the process it stopped and one
    missing tool or failed sampler never drops the others (#1956)."""
    found, samplers = {}, []
    tool = sampler_tool if sampler_tool is not None else shutil.which('sample')
    try:
        # A parallel run has an xctest per worker: sample them all at once, so the stop waits one sample, not several.
        for child, command in descendants(pid):
            if command.split(' ', 1)[0].endswith('/xctest'):
                folder.mkdir(parents=True, exist_ok=True)
                path = folder / f'sample-{child}.txt'
                sampler, reason = None, f'no `sample` tool on this host ({platform.system()})'
                if tool:
                    try:
                        sampler = subprocess.Popen([tool, str(child), str(sample_seconds), '-file', str(path)],
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except OSError as error:
                        reason = f'`sample` did not start: {error!r}'
                if sampler is None:
                    path.write_text(f'{reason}\n{child} {command}\n')
                    found.setdefault('samples', []).append(
                        {'pid': child, 'exit': None, 'diagnosis': f'xctest {child}: {reason}, so no call graph'})
                    continue
                samplers.append((child, path, sampler))
        deadline = time.monotonic() + sample_seconds + 30
        for child, path, sampler in samplers:
            try:
                code = sampler.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                sampler.kill()
                code = sampler.wait()
            text = path.read_text(errors='replace') if path.is_file() else ''
            found.setdefault('samples', []).append({'pid': child, 'exit': code, **hang_diagnosis(text)})
        samples = found.get('samples', [])
        found['diagnosis'] = '; '.join(s['diagnosis'] for s in samples) or 'no xctest process under the step'
        found['audio_device'] = any(s.get('audio_device') for s in samples)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        found['error'] = repr(error)
    finally:
        for _, _, sampler in samplers:
            if sampler.poll() is None:
                sampler.kill()
                sampler.wait()
    return found


# The SessionKit tests that need a running audio output (#909).
REAL_PLAYER_TEST = re.compile(r'/(?:RealPlayer[A-Z]\w*Tests|StreamSeekLifecycleTests)/')


class Run:
    def __init__(self, output, plan, changed=None):
        self.output = output
        self.changed = changed  # the PR's changed paths in a lane run; None runs every step (#862)
        self.output.mkdir(parents=True, exist_ok=False)
        self.input_files = input_digests()  # what the manifest's hash is made of, to name what changed (#1773)
        self.manifest = {'plan': plan, 'head': capture(['git', 'rev-parse', 'HEAD']),
                         'branch': capture(['git', 'branch', '--show-current']),
                         'input_sha256': input_identity(self.input_files), 'status': 'running', 'steps': []}
        self.crash_baseline = None
        self.crash_times = {}
        self.started = time.monotonic()
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

    def command(self, name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=None,
                startup=None, record_source=None, ceiling=None, stall_seconds=None):
        """Run one step. `timeout` is its time budget. With `ceiling` and `stall_seconds`, a step that has written to
        its log within the last `stall_seconds` when the budget runs out goes on, until `ceiling` seconds in all (#1767)."""
        entry = {'name': name, 'command': args, 'timeout_seconds': timeout,
                 'expected_tests': sorted(expected) if expected is not None else None}
        if ceiling:
            entry['ceiling_seconds'], entry['stall_seconds'] = ceiling, stall_seconds
        entry['load_average_start'] = load_average()
        self.manifest['steps'].append(entry)
        self.save()
        print(f'{name} …', flush=True)
        device = self.manifest.get('destination', {}).get('udid')
        reports = Path.home() / 'Library/Logs/DiagnosticReports'
        if device and self.crash_baseline is None:
            if not reports.is_dir():
                raise RuntimeError('Simulator crash reports are unavailable')
            self.crash_baseline = crash_snapshot(reports)
        # Only compilation needs a build slot. Tests run under the simulator slot (#1330).
        slot = build_slot(f'verify-tests {self.manifest["plan"]} {name}', max_wait=BUILD_SLOT_WAIT_SECONDS) \
            if args[0] == 'xcodebuild' and 'test-without-building' not in args else contextlib.nullcontext()
        with (self.output / f'{name}.log').open('w') as log, slot as held:
            if held:
                entry['build_slot'] = held
            attempt = 1

            def hold_launch():
                # The wait is the host's, not the step's: it does not use up the step's own time.
                if not (startup and startup.get('hold')):
                    return 0.0
                held = startup['hold']()
                entry.setdefault('launch_holds', []).append({'attempt': attempt, **held})
                return held['waited_seconds']
            hold_launch()
            start = attempt_start = last_output = time.monotonic()
            if ceiling and self.manifest['plan'] in ('fast', 'fast-mac-rest'):
                ceiling = max(timeout, min(ceiling, FAST_PLAN_SECONDS - (start - self.started)))
                entry['ceiling_seconds'] = round(ceiling)
            log_size = 0
            watching = startup is not None
            # #2176: the host's conditions as each launch starts, when its tests start and when it stalls.
            conditions = startup.get('conditions') if startup else None

            def note_conditions(at, **extra):
                if conditions:
                    entry.setdefault('launch_conditions', []).append({'attempt': attempt, 'at': at, **extra,
                                                                      **conditions()})
            note_conditions('start')
            scan_from = 0  # each launch is judged by its own part of the shared log
            # #2053: an xcodebuild test run that has printed its summary and then goes quiet is finished, not hung.
            finish = xcodebuild_finish.FinishWatch() if tests and args[0] == 'xcodebuild' else None
            finish_offset = 0
            process = subprocess.Popen(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True, env=step_env())
            try:
                while True:
                    if device and (report := new_crash(reports, self.crash_baseline, device)):
                        if self.note_crash(entry, report):
                            raise InterruptedError('Repeated simulator process crashes')
                    now = time.monotonic()
                    if ceiling and (size := os.fstat(log.fileno()).st_size) != log_size:
                        log_size, last_output = size, now
                    elapsed = now - start
                    if elapsed >= timeout:
                        if not ceiling or elapsed >= ceiling or now - last_output >= stall_seconds:
                            entry['timeout_note'] = self.timeout_note(
                                name, elapsed, timeout, ceiling, stall_seconds, now - last_output)
                            raise subprocess.TimeoutExpired(args, timeout)
                        entry['ran_past_its_limit'] = True
                    try:
                        result = process.wait(timeout=0.25)
                        break
                    except subprocess.TimeoutExpired:
                        pass
                    if finish is not None:
                        finish_offset = feed_new_lines(self.output / f'{name}.log', finish_offset, finish)
                        if (quiet := finish.overdue()) is not None:
                            entry['forced_after_summary'] = {'quiet_seconds': round(quiet, 1),
                                                             'stopped_by': signal.Signals(
                                                                 xcodebuild_finish.stop_group(process)).name}
                            result = finish.result()
                            print(f'warning: {name}: {finish.note(quiet)}', flush=True)
                            break
                    if not watching:
                        continue
                    text = (self.output / f'{name}.log').read_text(errors='replace')[scan_from:]
                    if TESTS_STARTED.search(text):
                        watching = False
                        note_conditions('tests_started', seconds=round(time.monotonic() - attempt_start, 1))
                    elif time.monotonic() - attempt_start >= startup['seconds']:
                        lines = [line for line in text.splitlines() if line.strip()]
                        stall = {'attempt': attempt, 'after_seconds': round(time.monotonic() - attempt_start, 1),
                                 'last_log_line': lines[-1][:200] if lines else None}
                        if conditions:
                            stall['conditions'] = conditions()
                        stall.update(startup['diagnose'](self.output / f'{name}-stall-{attempt}'))
                        # The diagnosis takes seconds; a launch that began its tests meanwhile is slow, not stalled.
                        if TESTS_STARTED.search((self.output / f'{name}.log').read_text(errors='replace')[scan_from:]):
                            entry.setdefault('slow_starts', []).append(stall)
                            watching = False
                            note_conditions('tests_started', seconds=round(time.monotonic() - attempt_start, 1))
                            continue
                        entry.setdefault('startup_stalls', []).append(stall)
                        print(f'warning: {name} printed no test output {stall["after_seconds"]}s after launch '
                              f'(last log line: {stall["last_log_line"]}; {stall.get("diagnosis", "no diagnosis")}); '
                              f'attempt {attempt}', flush=True)
                        stop_process_group(process)
                        if attempt > startup['retries']:
                            raise StartupStall()
                        # The hook is the runner's own housekeeping, not the step: whatever it raises (a hung
                        # simctl is a TimeoutExpired) is recorded and the retry still goes ahead (#1807).
                        try:
                            relaunched = startup['reset'](attempt)
                        except (OSError, subprocess.SubprocessError) as error:
                            relaunched = {'error': repr(error)}
                        if relaunched:
                            stall['relaunch'] = relaunched
                        attempt += 1
                        log.write(f'\n--- {name}: no test output after {stall["after_seconds"]}s; launching attempt {attempt} ---\n')
                        log.flush()
                        scan_from = len((self.output / f'{name}.log').read_text(errors='replace'))
                        start += hold_launch()
                        attempt_start = time.monotonic()
                        note_conditions('start')
                        if finish is not None:
                            finish = xcodebuild_finish.FinishWatch()
                        process = subprocess.Popen(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                                   start_new_session=True, env=step_env())
            except (subprocess.TimeoutExpired, KeyboardInterrupt, InterruptedError, StartupStall) as stopped:
                # A startup stall is reported as its own reason below, not as the step running out of budget.
                entry['interrupted'] = not isinstance(stopped, StartupStall)
                entry['signalled'] = isinstance(stopped, KeyboardInterrupt)  # the lane stopped this run, not the step's own limit
                try:
                    if isinstance(stopped, subprocess.TimeoutExpired) and tests and not device and args[0] != 'xcodebuild':
                        entry['hang'] = hang_evidence(process.pid, self.output / f'{name}-hang')  # #1956, before the stop
                finally:
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
        entry.update(exit_code=result, seconds=round(time.monotonic() - start, 3), load_average_end=load_average())
        text = (self.output / f'{name}.log').read_text(errors='replace')
        errors = []
        if entry.get('startup_stalls'):
            entry['startup_attempts'] = attempt
            last = entry['startup_stalls'][-1]
            if result and last['attempt'] == attempt:  # the final launch itself stalled
                errors.append(f'Test runner printed no test output in {attempt} launch(es) of {startup["seconds"]}s '
                              f'(last log line: {last["last_log_line"]}; {last.get("diagnosis", "no diagnosis")}); '
                              f'host-app samples under {name}-stall-*/')
            elif not result and len(entry['startup_stalls']) == 1:
                # #705, owner's call 2026-10-11: one stall that the first retry recovered, with every requested
                # test then passing (the checks below still hold the step to that), counts as a PASS. The stall
                # stays on record: the lane runner logs each one on #705 as evidence of the cause.
                entry['startup_recovered'] = True
                print(f'warning: {name} recovered after 1 startup stall of {startup["seconds"]}s; '
                      f'samples under {name}-stall-*/', flush=True)
            elif not result:
                # More than one stall before a pass is not covered by that call: the step stays INCONCLUSIVE.
                errors.append(f'Recovered after {len(entry["startup_stalls"])} startup stall(s) of {startup["seconds"]}s; '
                              f'the tests passed on launch {attempt} but the stalls\' cause is unknown, so this is not a PASS '
                              f'(samples under {name}-stall-*/)')
        if tests:
            records = record_source() if record_source else test_records(text)
            payload = None
            entry['test_evidence'] = 'xunit' if record_source else 'log'
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
        if name == 'hot-file-ratchet':
            # The lane's own words (lane-runner.py run_auto), so a local FAIL reads as the queue's would.
            errors.extend(f'hot-file ratchet — {line[len("FAIL "):]}' for line in text.splitlines()
                          if line.startswith('FAIL '))
        if name in ('runner-tests', 'ops') or name.startswith('ops-'):
            match = re.search(r'Ran (\d+) tests? in ', text)
            entry['executed_count'] = int(match[1]) if match else 0
            if not entry['executed_count']:
                errors.append('Infrastructure runner executed zero tests' if name == 'runner-tests'
                              else f'{name} executed zero tests')
            if failures := unittest_failures(text):  # name them: CI shows only the manifest's errors (#2457)
                errors.extend(report_unittest_failures(name, failures))
                print('\n'.join(error for error in errors if error.startswith('Failed: ')), flush=True)
        if name in ('browser', 'share-link'):
            # `node --test` prints the TAP summary "# tests N" on Node 20 and 22 when piped, and the spec reporter's
            # "ℹ tests N" on 24 (#2480), where TAP is no longer the default.
            match = re.search(r'^(?:# |ℹ )tests (\d+)$', text, re.M)
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
            if not any(error.startswith(('Failed: ', 'hot-file ratchet — ')) for error in errors):  # they already say why
                errors[:0] = log_errors(text)
            errors.insert(0, f'Process exit {result}')
            if entry.get('timeout_note'):
                errors.insert(1, entry['timeout_note'])
            if entry.get('hang', {}).get('samples'):
                errors.insert(2, f'stuck: {entry["hang"]["diagnosis"]} (samples under {name}-hang/)')
        entry['errors'] = errors
        self.save()
        print(f'{name}: {entry["seconds"]}s — {"FAILED" if errors else "passed"}', flush=True)
        if errors:
            raise RuntimeError('; '.join(errors) + f' (see {self.output / (name + ".log")})')
        return text

    def timeout_note(self, name, elapsed, timeout, ceiling, stall_seconds, silent):
        """Why a step was stopped, for the lane's report: how long it ran, how far its tests got, how busy the Mac was,
        and how long the plan waited for its host-test slot (before any step's clock starts; #1767)."""
        log = (self.output / f'{name}.log').read_text(errors='replace')
        results = len(re.findall(r"^Test Case '.*' (?:passed|failed)", log, re.M))
        if ceiling and elapsed >= ceiling:
            why = f'still running at its {ceiling}s ceiling'
        elif ceiling and silent >= stall_seconds:
            why = f'ran past its {timeout}s budget, then printed nothing for {silent:.0f}s (a hang)'
        else:
            why = f'ran out of its {timeout}s limit'
        waited = self.manifest.get('host_test_slot', {}).get('waited_seconds')
        slot = '' if waited is None else f'; waited {waited:.0f}s for the host-test slot before the steps, not counted'
        load = load_average()
        unfinished = unfinished_test(log)
        running = f', {unfinished} started and did not finish' if unfinished else ''
        return (f'{name} {why}: {results} test results in the log{running}, '
                f'load average {load[0] if load else "unknown"}{slot}')

    def fast(self):
        if self.manifest['plan'] == 'fast-portable':
            return self.portable()
        if self.manifest['plan'] == 'fast-hosted-sessionkit':
            return self.hosted_sessionkit()
        # First and outside the slot: it takes seconds, and a failure here would otherwise cost a lane queue trip.
        self.hot_file_ratchet()
        # The host steps share two Mac-wide host-test slots with every session and the runner (#350);
        # the package step's swift test runs inside this run's slot.
        with host_test_slot(f'verify-tests {self.manifest["plan"]} in {ROOT}', out=sys.stdout,
                            max_wait=BUILD_SLOT_WAIT_SECONDS) as held:
            self.manifest['host_test_slot'] = held
            self.save()
            if self.manifest['plan'] == 'fast-mac-rest':
                self.mac_rest()
            else:
                self.host_steps()

    def hot_file_ratchet(self, base=None):
        """The lane's hot-file ratchet (scripts/hot_file_ratchet.py) in the author's own loop (#2175).

        On 2026-10-19 #2159, #2155 and #2067 each failed only this check, hours into the lane queue. It compares the
        committed branch with the local `base` (fetch first for an up-to-date verdict) and fails with the lane's words.
        A lane run (one given the PR's changed paths, or any CI job) leaves it to the runner, which judges next's copy with the PR's
        labels. With the hot-file-ok label granted, set SM_HOT_FILE_OK=1. `base` defaults to the trunk's ref."""
        if self.changed is not None or os.environ.get('GITHUB_ACTIONS') == 'true':
            # A CI job is a lane job even without --changed-files (the lane drops it for a path it can't pass), and
            # the lane's runner-tests step runs inside it too.
            return self.skip('hot-file-ratchet', 'the lane runner checks next\'s ratchet, with the PR\'s labels, before any build')
        if os.environ.get('SM_HOT_FILE_OK') == '1':
            return self.skip('hot-file-ratchet', 'SM_HOT_FILE_OK=1: the PR carries the hot-file-ok label')
        from trunk import trunk_branch  # #1492: the branch the author's run judges the ratchet against
        base = base or f'origin/{trunk_branch()}'
        known = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--verify', '--quiet', f'{base}^{{commit}}'],
                               capture_output=True, text=True)
        if known.returncode:
            # Name the fetch for the base actually judged, which a caller may give instead of the trunk (#2180 audit).
            branch = base[len('origin/'):] if base.startswith('origin/') else base
            return self.skip('hot-file-ratchet', f'{base} is not in this clone; run `git fetch origin {branch}` to check it')
        self.command('hot-file-ratchet', [sys.executable, 'scripts/hot_file_ratchet.py', '--base', base], timeout=60)

    def shipped_compat(self):
        """The shipped build's packet reader and database checks (#1899), when the diff reaches what they watch.
        After the SessionKit steps, so the writer's `swift test` finds that build already done."""
        needed, why = shipped_compat_needed(self.changed)
        if needed:
            self.manifest.setdefault('notes', []).append('shipped-build compatibility checks ran: ' + why)
            self.command('shipped-compat', ['sh', '-c', SHIPPED_COMPAT_COMMAND], timeout=SHIPPED_COMPAT_TIMEOUT)
        else:
            self.skip('shipped-compat', why)

    def hosted_sessionkit(self):
        """SessionKit's build and SessionKitCoreTests on a GitHub-hosted Mac (#1389), for hosted-portable.yml. No
        sound output there, so SessionKitTests and SessionKitTraceTests are left to the lane Mac (fast-mac-rest)."""
        core = {f'SessionKitCoreTests/{test}' for test in swift_tests(ROOT / 'Packages/SessionKit/Tests/SessionKitCoreTests')}
        if not core:
            raise RuntimeError('fast-hosted-sessionkit found no SessionKitCoreTests to run')
        self.command('package-build', [*PACKAGE_RUNNER, '--build-only'], timeout=PACKAGE_BUILD_TIMEOUT)
        self.package_core(core)
        self.skip('package', 'SessionKitTests and SessionKitTraceTests need a sound output; the lane Mac runs them '
                             '(--plan fast-mac-rest)')
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError(inputs_changed_message('Inputs changed during hosted SessionKit verification', self.input_files))

    def mac_rest(self):
        """What neither hosted plan runs (#1389): the runner tests that drive Apple tools, ops/disk, and SessionKit's
        two serial targets. Each runs only when the full fast plan would have run it for this diff."""
        scope, why = runner_test_scope(self.changed)
        if in_codex_sandbox():
            self.skip('runner-tests')
        elif scope != 'all':
            self.skip('runner-tests', why or 'the diff reaches none of the runner tests that drive Apple tools')
        else:
            self.command('runner-tests', [sys.executable, '-c', MAC_REST_RUNNER_LOADER, *PORTABLE_RUNNER_TESTS_LEFT_OUT],
                         **RUNNER_TESTS_LIMITS)
        needed, why = ops_tests_needed(self.changed)
        if needed:
            self.ops_steps(only=PORTABLE_OPS_LEFT_OUT)
        else:
            self.skip('ops', why)
        expected = set()
        for target in ('SessionKitTests', 'SessionKitTraceTests'):
            expected.update(f'{target}/{test}' for test in swift_tests(ROOT / f'Packages/SessionKit/Tests/{target}'))
        # A full SessionKit pass of this exact tree on this Mac (#1328) covers the rest too. A rest-only pass is
        # never recorded as one: it didn't run SessionKitCoreTests here.
        identity = None if in_codex_sandbox() else sessionkit_pass.toolchain()
        pass_key = sessionkit_pass.key(ROOT, identity)
        earlier = sessionkit_pass.find(state_dir(), pass_key) if self.changed else None
        if earlier:
            why = (f'the same SessionKit inputs, toolchain and test runner passed all {earlier.get("tests", "its")} tests '
                   f'at {earlier.get("passed_at")} (commit {str(earlier.get("head"))[:7]})')
            self.manifest['sessionkit_pass'] = {'reused': pass_key, **earlier}
            self.manifest.setdefault('notes', []).append('SessionKit build and tests skipped: ' + why)
            self.skip('package-build', why)
            self.skip('package', why)
        else:
            self.package_steps(expected, core_elsewhere=True)
        self.shipped_compat()
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError(inputs_changed_message('Inputs changed during Mac-only verification', self.input_files))

    def portable(self):
        """The fast plan's steps that run anywhere (#1847), then every step it leaves out, named as skipped.
        No host-test slot: that is the Mac's shared pool, and a hosted job is alone on its machine."""
        self.host_steps(portable=True)
        print('fast-portable runner-tests left out ' + ', '.join(PORTABLE_RUNNER_TESTS_LEFT_OUT), flush=True)
        for name, reason in PORTABLE_LEFT_OUT.items():
            self.skip(name, reason)
        print('fast-portable left out ' + ', '.join(PORTABLE_LEFT_OUT) + '; the fast plan on the Mac runs them.', flush=True)
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError(inputs_changed_message('Inputs changed during portable verification', self.input_files))

    def host_steps(self, portable=False):
        scope, why = runner_test_scope(self.changed)
        if portable:
            self.command('runner-tests', [sys.executable, '-c', PORTABLE_RUNNER_LOADER, *PORTABLE_RUNNER_TESTS_LEFT_OUT],
                         **RUNNER_TESTS_LIMITS)
        elif in_codex_sandbox():
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
                         **RUNNER_TESTS_LIMITS)
        else:
            self.command('runner-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests'],
                         **RUNNER_TESTS_LIMITS)
        needed, why = ops_tests_needed(self.changed)
        if portable:
            self.ops_steps(left_out=PORTABLE_OPS_LEFT_OUT)
        elif needed:
            self.ops_steps()
        else:
            self.skip('ops', why)
        # A hosted checkout has no Git LFS files; the voice model pointers still name each file's size and hash.
        self.command('contracts', [sys.executable, 'scripts/validate-contracts.py',
                                   *(['--allow-lfs-pointers'] if portable else [])])
        self.command('public-tree', [sys.executable, 'scripts/check-public-tree.py'])
        self.command('surfaces', [sys.executable, 'scripts/validate-surface-contracts.py'])
        self.command('inventory', [sys.executable, 'scripts/test_inventory.py'])
        # New main-thread store, file or audio work fails here, in seconds, instead of on the phone (#2257).
        self.command('main-thread-reads', [sys.executable, 'scripts/main_thread_reads.py'], timeout=120)
        if not (ROOT / 'node_modules').exists():
            raise RuntimeError('node_modules is missing in this worktree; run scripts/setup-worktree.sh')
        self.command('browser', ['npm', 'run', 'test:browser-extraction'])
        self.command('share-link', ['npm', 'run', 'test:share-link'])
        # The Go server, the research Python tests and the Caddy script (#1033); a suite that can't run
        # here is reported as skipped with its reason, not passed.
        self.command('research', [sys.executable, 'scripts/research_tests.py'], timeout=300)
        if portable:
            return
        expected = set()
        for target in ('SessionKitCoreTests', 'SessionKitTests', 'SessionKitTraceTests'):
            expected.update(f'{target}/{test}' for test in swift_tests(ROOT / f'Packages/SessionKit/Tests/{target}'))
        # Lane runs skip the SessionKit build and tests when this exact tree (the package, what its tests read,
        # the toolchain and the test runner) already passed them on this Mac (#1328). Only a run given the PR's
        # changed paths skips; one without them runs every step.
        identity = None if in_codex_sandbox() else sessionkit_pass.toolchain()
        pass_key = sessionkit_pass.key(ROOT, identity)
        earlier = sessionkit_pass.find(state_dir(), pass_key) if self.changed else None
        if earlier:
            why = (f'the same SessionKit inputs, toolchain and test runner passed all {earlier.get("tests", "its")} tests '
                   f'at {earlier.get("passed_at")} (commit {str(earlier.get("head"))[:7]})')
            self.manifest['sessionkit_pass'] = {'reused': pass_key, **earlier}
            self.manifest.setdefault('notes', []).append('SessionKit build and tests skipped: ' + why)
            self.skip('package-build', why)
            self.skip('package', why)
        else:
            self.package_steps(expected)
            if pass_key and sessionkit_pass.key(ROOT, identity) == pass_key:
                sessionkit_pass.record(state_dir(), pass_key, head=self.manifest['head'], tests=len(expected))
        self.shipped_compat()

        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError(inputs_changed_message('Inputs changed during fast verification', self.input_files))

    def package_steps(self, expected, core_elsewhere=False):
        """Build SessionKit and run its tests: SessionKitCoreTests in parallel (#1328), the rest serially.
        core_elsewhere: SessionKitCoreTests ran on a hosted Mac (fast-mac-rest, #1389); run only the rest."""
        # The build gets its own limit, so a cold build under load can't use up the tests' time (#844).
        # The tests' limit covers about 1,000 tests, including real-time AVPlayer tests that took
        # 150 s of a 230 s run with the Mac's load average at 40 to 180 (2026-10-05).
        self.command('package-build', [*PACKAGE_RUNNER, '--build-only'], timeout=PACKAGE_BUILD_TIMEOUT)
        audio = self.manifest['audio_output'] = host_audio.audio_output()
        # #1956: an output that never starts hangs the real-player tests until the step's limit. Say so now.
        if audio.get('stuck') and not in_codex_sandbox():
            self.manifest['lane_fault'] = f'no audio output: {audio["why"]}'
            self.save()
            raise RuntimeError(f'lane fault, not the PR: {self.manifest["lane_fault"]}')
        # Inside Codex's sandbox the audio tests are tolerated and the runner stays as it was: one serial step.
        core = {test for test in expected if test.startswith('SessionKitCoreTests/')}
        split = (bool(core) and not in_codex_sandbox()) or core_elsewhere
        try:
            if split and not core_elsewhere:
                self.package_core(core)
            self.command('package', [*PACKAGE_RUNNER, '--rest' if split else '--skip-build'],
                         timeout=PACKAGE_TEST_TIMEOUT, ceiling=PACKAGE_TEST_CEILING, stall_seconds=PACKAGE_STALL_SECONDS,
                         expected=expected - core if split else expected, tests=True,
                         allowed_skips={'SessionKitTests/SharingTests/testHeldOutPublicDomainPodcastAnchorCorpus',
                                        *POCKET_WEIGHT_TESTS, *SUPERTONIC_MODEL_TESTS, *SPEECH_MODEL_TESTS},
                         probation=CODEX_SANDBOX_AUDIO_TESTS & expected if in_codex_sandbox() else None)
        except RuntimeError as error:
            step = self.manifest['steps'][-1]
            # #1956: an output that stops starting during the run hangs a real-player test; its sample says so. A hang
            # the PR's own audio code caused ends with its xctest, so only an output that still won't start is the Mac.
            if step.get('hang', {}).get('audio_device') and not in_codex_sandbox():
                probe = step['hang']['output_after_stop'] = host_audio.output_starts()
                self.save()
                if not probe['starts']:
                    self.manifest['lane_fault'] = (f'no audio output: the sound output stopped starting during '
                                                   f'{step["name"]} ({probe["why"]}). Restart Core Audio '
                                                   '(sudo killall coreaudiod) or choose another output in Sound settings')
                    self.save()
                    raise RuntimeError(f'lane fault, not the PR: {self.manifest["lane_fault"]}; {error}') from error
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

    def package_core(self, expected):
        """SessionKitCoreTests with `swift test --parallel`. Anything wrong with that run (a failing test, a missing
        or unreadable result file, a timeout) is run again serially, and the serial run decides: parallel
        tests can fail on shared state that serial runs never meet, and the result file's format is SwiftPM's."""
        xunit = self.output / 'package-core.xunit.xml'
        try:
            self.command('package-core', [*PACKAGE_RUNNER, '--core-parallel', str(xunit)],
                         timeout=PARALLEL_CORE_TIMEOUT, ceiling=PARALLEL_CORE_CEILING,
                         stall_seconds=PARALLEL_CORE_STALL_SECONDS, expected=expected, tests=True,
                         allowed_skips=CORE_ALLOWED_SKIPS, record_source=lambda: xunit_records(xunit))
            return
        except RuntimeError as error:
            step = self.manifest['steps'][-1]
            if step.get('signalled'):
                raise  # the lane is stopping this run: a serial run would outlive it
            step['superseded'] = 'run again serially'
            self.manifest.setdefault('notes', []).append(
                f'SessionKitCoreTests: the parallel run failed, so they ran again serially ({str(error)[:300]})')
            self.save()
            print('package-core: parallel run failed; running SessionKitCoreTests serially', flush=True)
        self.command('package-core-serial', [*PACKAGE_RUNNER, '--core-serial'],
                     timeout=PACKAGE_TEST_TIMEOUT, ceiling=PACKAGE_TEST_CEILING, stall_seconds=PACKAGE_STALL_SECONDS,
                     expected=expected, tests=True, allowed_skips=CORE_ALLOWED_SKIPS)

    def skip(self, name, reason=None):
        reason = reason or CODEX_SANDBOX_SKIPS[name]
        self.manifest['steps'].append({'name': name, 'skipped': reason})
        self.save()
        print(f'{name}: skipped ({reason})', flush=True)

    def ops_steps(self, root=None, left_out=None, only=None):
        """The ops tools' own tests (ops/dial, ops/codex), one step per folder: each folder imports its
        module from beside its tests, so each is its own discovery top level. `left_out` maps a folder
        (relative to the root) to why it does not run here; it is named as skipped. `only`: run just these
        folders, and pass over the rest without a word (another plan runs them)."""
        base = Path(root or ROOT)
        for folder in ops_test_folders(base):
            if only is not None and folder.relative_to(base).as_posix() not in only:
                continue
            name = 'ops-' + '-'.join(folder.relative_to(base).parts[1:]) if folder != base / 'ops' else 'ops'
            if left_out and folder.relative_to(base).as_posix() in left_out:
                self.skip(name, left_out[folder.relative_to(base).as_posix()])
                continue
            self.command(name, [sys.executable, '-m', 'unittest', 'discover', '-s', str(folder), '-t', str(folder)])

    def simulator(self, device, ios=None):
        """The destination, and whether this run created it (its first boot gets the lane's tolerance).

        --device is used as given. Otherwise the dedicated Test Runner, created when missing, and
        replaced when the lane has marked it unsafe: it is this script's own device, and refusing it
        stopped every integration run on next for a day (#1325). A T3 gets a fresh device each run too.
        """
        def listed():
            return json.loads(capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']

        if device:
            return select_simulator(listed(), device, ios), False
        chosen, template = dedicated_simulator(listed(), ios)
        marked = lane_sim.unsafe_devices().get(chosen['udid']) if chosen else None
        if marked:
            print(f'{TEST_RUNNER_NAME} ({chosen["udid"]}) is on the lane\'s unsafe list ({marked["reason"]}); '
                  'replacing it with a fresh one', flush=True)
            subprocess.run(['xcrun', 'simctl', 'shutdown', chosen['udid']], cwd=ROOT, capture_output=True, timeout=60)
            self.command('simulator-retire', ['xcrun', 'simctl', 'delete', chosen['udid']], timeout=120)
            chosen, template = dedicated_simulator(listed(), ios)
        if chosen is not None:
            return chosen, False
        self.command('simulator-create', ['xcrun', 'simctl', 'create', TEST_RUNNER_NAME,
                     template['deviceTypeIdentifier'], template['runtime']], timeout=60)
        chosen, _ = dedicated_simulator(listed(), ios)
        if chosen is None:
            raise RuntimeError(f'Could not create the {TEST_RUNNER_NAME} simulator')
        return chosen, True

    def xcode_build(self, plan, runtime, rebuild=False, require_build=False):
        """Build every test plan of the scheme once, without a running simulator (#1330).

        The plan selects tests, not binaries. Omitting -testPlan from build-for-testing emits the
        scheme's test plans together; test-without-building still names the exact plan and selectors.
        """
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed before Xcode verification')
        scheme = PLANS[plan][0]
        if not require_build:
            self.command('generate', ['xcodegen', 'generate'])
        identity = input_identity()
        toolchain = capture(['xcodebuild', '-version']) + '\n' + platform.machine() + '\nSDK ' + capture(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'])
        cache_key = hashlib.sha256(('all-test-plans-v1' + identity + toolchain + runtime + scheme).encode()).hexdigest()
        derived = ROOT / '.build/verification' / scheme
        derived.mkdir(parents=True, exist_ok=True)
        stamp = derived / 'scheme.build.json'
        base = ['xcodebuild', '-configuration', 'Debug', '-project', 'SpokenMarginsNative.xcodeproj', '-scheme', scheme,
                '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(derived)]
        self.manifest.update(input_sha256=identity, toolchain=toolchain, build_key=cache_key)
        try:
            reused = not rebuild and json.loads(stamp.read_text()).get('key') == cache_key
        except (OSError, ValueError):
            reused = False
        self.manifest['reused_build'] = reused
        if not reused:
            if require_build:
                raise RuntimeError('Prepared Xcode build is missing or stale; refusing to build on a booted T3 device')
            stamp.unlink(missing_ok=True)
            self.command('build-for-testing', base + compilation_cache_settings() + ['build-for-testing'], timeout=900)
            log = self.output / 'build-for-testing.log'
            self.manifest['compilation_cache'] = compilation_cache_hits(log.read_text(errors='replace')) \
                if log.is_file() else None
            self.save()
        if input_identity() != identity:
            raise RuntimeError('Inputs changed during the build; evidence is not for one source state')
        if not reused:
            stamp.write_text(json.dumps({'key': cache_key}) + '\n')
        self.command('bundle-contracts', [sys.executable, 'scripts/verify-bundle.py',
                     str(derived / 'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app')])
        return derived, identity

    def provide_supertonic_model(self):
        """Fetch Supertonic's model before the simulator boots, and give its folder to the app's tests, which read
        SESSIONKIT_SUPERTONIC_DIR (xcodebuild passes TEST_RUNNER_-prefixed variables on without the prefix)."""
        folder = os.environ.get('SESSIONKIT_SUPERTONIC_DIR')
        if not folder:
            cache = supertonic_model_cache()
            self.command('supertonic-model', [sys.executable, str(ROOT / 'scripts/voice-catalog'), '--state-dir', str(cache),
                                              'fetch', SUPERTONIC_MODEL_VOICE], timeout=1200)
            folder = str(cache / 'files' / SUPERTONIC_MODEL_VOICE)
        os.environ['TEST_RUNNER_SESSIONKIT_SUPERTONIC_DIR'] = folder
        self.manifest['supertonic_model'] = folder
        self.save()

    def xcode(self, plan, device, rebuild, ios=None, only=(), probation=None, simulator_slot_fd=None,
              require_build=False):
        if input_identity() != self.manifest['input_sha256']:
            raise RuntimeError('Inputs changed before Xcode verification')
        scheme, name, timeout = PLANS[plan]
        # T3 runs a few test classes or methods of a plan. Each selector must name tests in the plan.
        selectors, planned, expected = t3_selection(only, name)
        if selectors:
            self.manifest['only_testing'] = selectors
        if any(test.endswith(SUPERTONIC_APP_MODEL_TEST)
               for test in planned if not selectors or any(selected(test, s) for s in selectors)):
            self.provide_supertonic_model()
        chosen, created = self.simulator(device, ios)
        refuse_unsafe(chosen, lane_sim.unsafe_devices())
        self.manifest['destination'] = chosen
        derived, identity = self.xcode_build(plan, chosen['runtime'], rebuild, require_build)
        base = ['xcodebuild', '-configuration', 'Debug', '-project', 'SpokenMarginsNative.xcodeproj', '-scheme', scheme,
                '-testPlan', name, '-destination', f'id={chosen["udid"]}', '-derivedDataPath', str(derived)]
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
                # At a boot stall, our own Test Runner is deleted and one fresh one booted instead (#705); a device
                # given with --device is the caller's, so it gets no retry.
                entry = {'name': 'simulator-boot', 'command': ['lane_sim.boot_with_retry', chosen['udid']]}
                self.manifest['steps'].append(entry)
                self.save()

                def replace(stalled):
                    nonlocal chosen
                    subprocess.run(['xcrun', 'simctl', 'shutdown', stalled], cwd=ROOT, capture_output=True, timeout=60)
                    self.command('simulator-retire', ['xcrun', 'simctl', 'delete', stalled], timeout=120)
                    chosen, _ = self.simulator(None, ios)
                    return chosen['udid']

                info = {}
                try:
                    head = capture(['git', 'rev-parse', '--short', 'HEAD'])
                except (OSError, subprocess.SubprocessError):
                    head = 'unknown commit'
                try:
                    _, seconds = lane_sim.boot_with_retry(
                        chosen['udid'], f'verify-tests --plan {plan} boot at {head} (evidence: {self.output})',
                        replace if not device and chosen.get('name') == TEST_RUNNER_NAME else None,
                        out=sys.stdout, info=info, first_boot=created)
                    entry.update(seconds=round(seconds, 3), exit_code=0, errors=[])
                except lane_sim.BootError as error:
                    entry.update(exit_code=1, errors=[str(error)])
                    raise RuntimeError(f'simulator-boot: {error}')
                finally:
                    if info.get('boot_stalls'):
                        entry['boot_stalls'] = info['boot_stalls']
                    self.manifest['destination'] = chosen
                    base[base.index('-destination') + 1] = f'id={chosen["udid"]}'
                    self.save()
            self.command('simulator-ready', ['xcrun', 'simctl', 'bootstatus', chosen['udid'], '-b'], timeout=180)
            if chosen.get('name') == TEST_RUNNER_NAME:
                # Start from an empty app container so earlier runs' data can't leak into this one.
                app = derived / 'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app'
                bundle_id = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
                subprocess.run(['xcrun', 'simctl', 'uninstall', chosen['udid'], bundle_id],
                               cwd=ROOT, capture_output=True, timeout=60)
            on_probation = None if probation is None else {
                test for test in expected if any(selected(test, s) for s in probation)}
            result_bundle = self.output / 'tests.xcresult'

            def relaunch(attempt):
                # The stalled attempt's app may still be up, and xcodebuild refuses an existing result bundle.
                app = derived / 'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app'
                bundle_id = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
                # A hung terminate must not use up the retry (#1807): note it and launch again regardless.
                note = {}
                try:
                    subprocess.run(['xcrun', 'simctl', 'terminate', chosen['udid'], bundle_id],
                                   cwd=ROOT, capture_output=True, timeout=TERMINATE_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    note['terminate'] = f'timed out after {TERMINATE_TIMEOUT_SECONDS}s'
                if result_bundle.exists():
                    result_bundle.rename(self.output / f'tests-stalled-{attempt}.xcresult')
                return note

            # Only the app-hosted unit tests (app, adapters): the UI plans launch a separate runner app.
            startup = {'seconds': STARTUP_STALL_SECONDS, 'retries': STARTUP_RETRIES,
                       'diagnose': lambda folder: stall_evidence(chosen['udid'], folder, result_bundle=result_bundle),
                       'reset': relaunch, 'conditions': lane_conditions.snapshot, 'hold': hold_for_launch} \
                if scheme == 'SpokenMarginsAppBehavior' else None
            if startup is not None:
                # What each launch installs (#2176): #2067 takes Supertonic's model out, about 144 MB.
                self.manifest['app_bundle_mb'] = lane_conditions.folder_mb(
                    derived / 'Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app')
                self.manifest['settle_before_tests'] = settle_before_tests(chosen['udid'])
                self.save()
            # An AudioLoopback test asks the Mac to record what it plays (#1790). A server starts only when the
            # request names one; in a whole-plan run (Release, a full AudioAdapters) it skips, and that's expected.
            asked = selectors if scheme == 'SpokenMarginsAppBehavior' else ()
            with lane_audio_window.serve(self.output, asked) as audio:
                try:
                    self.command('xcode-tests', base + [f'-only-testing:{s}' for s in selectors] + [
                                 'test-without-building', '-parallel-testing-enabled', 'NO',
                                 '-collect-test-diagnostics', 'never',
                                 '-test-timeouts-enabled', 'YES', '-resultBundlePath', str(result_bundle)],
                                 timeout=timeout, expected=expected, tests=True, probation=on_probation, startup=startup,
                                 allowed_skips=lane_audio_window.unasked(expected, asked))
                finally:  # a failed or skipped test raises here, and its verdict is what the report needs most
                    if audio:
                        step = self.manifest['steps'][-1]
                        step['audio_windows'] = lane_audio_window.attachments(audio)
                        step.setdefault('attachments', []).extend(step['audio_windows'])
                        self.save()
        finally:
            if scheme == 'SpokenMarginsAppBehavior':
                lane_sim.mark_quiet(chosen['udid'])
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
    parser.add_argument('--plan', choices=['fast', 'fast-portable', 'fast-hosted-sessionkit', 'fast-mac-rest', *PLANS],
                        default='fast')
    parser.add_argument('--device', help='Supported simulator UDID (including iPad); overrides phone preference')
    parser.add_argument('--ios', type=int, help='Required iOS major version, e.g. 26 or 27; never falls back to another OS')
    parser.add_argument('--simulator-slot-fd', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--rebuild', action='store_true', help='Ignore the compatible build stamp')
    parser.add_argument('--build-only', action='store_true', help='Build all plans of the Xcode scheme; do not boot or test')
    parser.add_argument('--runtime', help='Simulator runtime identifier for --build-only')
    parser.add_argument('--require-build', action='store_true', help='Refuse tests unless the prepared scheme build is current')
    parser.add_argument('--output', type=Path, help='New evidence directory')
    parser.add_argument('--changed-files', type=Path, metavar='FILE',
                        help='Lane runs: the PR\'s changed paths, one per line (renames name both sides). --plan fast then '
                             'skips the runner and ops tests nothing in the diff can affect; without it every step runs')
    parser.add_argument('--list', action='store_true', help='Inspect selection without running tests')
    parser.add_argument('--only-testing', action='append', default=[], metavar='CLASS[/METHOD]',
                        help='Xcode plans: run only these tests of the plan (repeatable); unknown ones fail the run')
    args = parser.parse_args()
    if args.build_only and (args.plan not in PLANS or not args.runtime):
        parser.error('--build-only needs an Xcode --plan and --runtime')
    if args.build_only and (args.device or args.require_build or args.only_testing):
        parser.error('--build-only takes no --device, --require-build or --only-testing')
    if errors := validate():
        parser.error('; '.join(errors))
    from test_inventory import scripted_journeys  # only the journeys plan reads the list
    journeys = scripted_journeys() if args.plan == 'journeys' else None
    if journeys and args.only_testing:
        parser.error('--plan journeys runs TestPlans/scripted-journeys.json; it takes no --only-testing')
    if args.list:
        print('\n'.join(f'{t} ({status})' for status, tests in journeys.items() for t in tests) if journeys
              else '\n'.join(sorted(plan_tests(ROOT, PLANS[args.plan][1]))) if args.plan in PLANS
              else ('fast-portable runs ' + ', '.join(PORTABLE_STEPS) + '; it leaves out ' + ', '.join(PORTABLE_LEFT_OUT)
                    if args.plan == 'fast-portable'
                    else 'hot-file ratchet, runner-tests, ops tests, contracts, surfaces, inventory, browser, all SessionKit tests'))
        return 0
    if journeys is not None and not any(journeys.values()):
        print('No scripted journeys are listed in TestPlans/scripted-journeys.json; nothing to run.')
        return 0
    # In a worktree under ~/Documents, .build and SessionKit's .build live in ~/Library/Caches, where the
    # disk-relief job (no Full Disk Access) can clear them (sm_build_cache.py).
    sm_build_cache.ensure_links(ROOT, log=lambda line: print(line, file=sys.stderr, flush=True))
    (ROOT / '.build').mkdir(exist_ok=True)
    with (ROOT / '.build/verification.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output = args.output or ROOT / 'artifacts/test-runs' / (
            datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '-' + args.plan)
        run = Run(output.resolve(), args.plan,
                  read_changed_files(args.changed_files) if args.plan in ('fast', 'fast-mac-rest') else None)
        try:
            if args.build_only:
                run.xcode_build(args.plan, args.runtime, args.rebuild)
            elif args.plan in ('fast', *FAST_SPLIT_PLANS, 'release'):
                run.fast()
            if args.plan not in ('fast', *FAST_SPLIT_PLANS) and not args.build_only:
                if journeys:
                    run.manifest['scripted_journeys'] = journeys
                    run.xcode(args.plan, args.device, args.rebuild, args.ios,
                              journeys['gating'] + journeys['probation'], probation=journeys['probation'],
                              simulator_slot_fd=args.simulator_slot_fd,
                              **({'require_build': True} if args.require_build else {}))
                else:
                    run.xcode(args.plan, args.device, args.rebuild, args.ios, args.only_testing,
                              simulator_slot_fd=args.simulator_slot_fd,
                              **({'require_build': True} if args.require_build else {}))
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
