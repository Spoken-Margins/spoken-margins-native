#!/usr/bin/env python3
"""The slow tier (#5145): tests that are slow on CI and have not failed in 30 days run nightly and before builds.

Owner, 2026-11-23 (docs/decisions.md): "Suites that are slow and never fail move to a nightly and pre-build run. Each
PR keeps the fast suites and the packet, database and owner-data guards." Every test here was measured on the hosted
runners from 2026-10-24 to 2026-11-23 (the `metrics` branch, every failed hosted-portable job log, 908 `mac-core-tests`
result files and 138 `hosted-mac-rest-test-runs` step logs). Each one was slow and had no failure in any of them.

Where each list is read:
- PR, merge-group and lane-dispatch runs of hosted-portable.yml pass `verify-tests.py --leave-out-slow`, which leaves
  these out of package-core, package and runner-tests and names them in the run.
- `verify-tests.py --plan slow` runs exactly these. .github/workflows/main-slow.yml runs it on `main` once a night and
  before the 8:00 and 17:00 phone builds, records a `main-slow` commit status, and on a failure opens one issue naming
  the merges since the last green run (scripts/main_slow.py). scripts/phone-build runs it itself when its commit has
  no green `main-slow` status.
- An author's own `--plan fast`, with no flag, still runs everything.

A test moves back to every PR when the slow run catches it failing (the waste signal in #5145): delete its line here.
Never list a packet, database or owner-data guard; scripts/tests/test_slow_tier.py fails if a name looks like one, or
if a listed test no longer exists. Stdlib only.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Target/Class/test -> what was measured (seconds are the hosted Mac's p50 for that one test).
SLOW_SWIFT_TESTS = {
    'SessionKitCoreTests/KittenFrontEndTests/testSeededWordsAndNormalizerInputsMatchTheReference':
        '181 s p50, 229 s p90; 0 failures in 908 runs. Its 6 siblings stay; Linux still runs it on every merge (8 s there)',
    'SessionKitTests/KittenRendererTests/testALongArticleThroughTheFallbackVoiceNeverPausesOverOneSecond':
        '78 s p50 in the serial package step; 0 failures in 120 runs',
    'SessionKitCoreTests/PrivacyPassTokenTests/testFreshBlindingFinishes':
        '37 s p50, 51 s p90; 0 failures in 908 runs; Linux still runs it on every merge',
    'SessionKitCoreTests/PrivacyPassTokenTests/testRFC9474Vectors':
        '22 s p50, 30 s p90; 0 failures in 908 runs; Linux still runs it on every merge',
}

# scripts/tests modules, as parallel_unittest.py --leave-out takes them.
SLOW_RUNNER_MODULES = {
    'test_sm_status': 'the longest runner module in nearly every hosted run (115 to 350 s, the tail of runner-tests); '
                      '0 failures in 30 days of hosted logs',
}

# Words in a test's name that mark a packet, database or owner-data guard. Deliberately broad: a false hit only
# means a test can't move.
GUARD_WORDS = re.compile(
    r'packet|sharing|share|import|export|database|sqlite|store|persist|migrat|schema|build\d|shipped|compat|'
    r'owner|library|recording|backup|delete|reset|manifest', re.IGNORECASE)

SWIFT_TARGETS = ('SessionKitCoreTests', 'SessionKitTests', 'SessionKitTraceTests')


def swift_regex(tests) -> str:
    """A SwiftPM --filter/--skip regex (matched against "Module.Class/test") naming exactly these tests."""
    names = sorted(tests)
    if not names:
        raise ValueError('no tests to name')
    parts = []
    for name in names:
        target, cls, test = name.split('/')
        parts.append(re.escape(f'{target}.{cls}/{test}'))
    return '^(' + '|'.join(parts) + ')$'


def swift_tests_in(targets) -> set:
    return {t for t in SLOW_SWIFT_TESTS if t.split('/')[0] in targets}


def problems(root: Path = ROOT) -> list:
    """Why the lists can't stand: a guard-looking name, a malformed id, or a test or module that no longer exists."""
    found = []
    for name in SLOW_SWIFT_TESTS:
        parts = name.split('/')
        if len(parts) != 3 or parts[0] not in SWIFT_TARGETS or not parts[2].startswith('test'):
            found.append(f'{name}: not Target/Class/testName in a SessionKit test target')
            continue
        if GUARD_WORDS.search(parts[1] + parts[2]):
            found.append(f'{name}: looks like a packet, database or owner-data guard; those stay on every PR')
        folder = root / 'Packages/SessionKit/Tests' / parts[0]
        pattern = re.compile(r'\bfunc ' + re.escape(parts[2]) + r'\s*\(')
        declared = [p for p in folder.rglob('*.swift')
                    if f'class {parts[1]}' in (text := p.read_text(errors='replace')) and pattern.search(text)]
        if not declared:
            found.append(f'{name}: no such test in {folder.relative_to(root)}')
    for module in SLOW_RUNNER_MODULES:
        if GUARD_WORDS.search(module):
            found.append(f'{module}: looks like a packet, database or owner-data guard; those stay on every PR')
        if not (root / 'scripts/tests' / f'{module}.py').is_file():
            found.append(f'{module}: no scripts/tests/{module}.py')
    return found


if __name__ == '__main__':
    import sys
    issues = problems()
    print('\n'.join(issues) or f'{len(SLOW_SWIFT_TESTS)} Swift tests and {len(SLOW_RUNNER_MODULES)} runner modules, all fine')
    sys.exit(1 if issues else 0)
