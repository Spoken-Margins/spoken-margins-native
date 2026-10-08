#!/usr/bin/env python3
"""Runs the tests under research/ that need nothing heavier than Go or Python's standard library (#1033).

  scripts/research_tests.py          run every suite; skipped suites are named with the reason

Before this, `go test` for the share-link and map-upload server (tokens, App Attest, rate limits, request
logging), the research Python tests and the Caddy privacy-filter script ran only when someone typed them.
`verify-tests.py --plan fast` now runs this file as its `research` step, and test-scope.py treats the code
paths in TESTED_PREFIXES as T1 so a PR that touches only the server still gets that step.

A suite that cannot run here (no `go` on the Mac, say) is printed as `skipped: <suite> - <reason>` and
counted, never passed silently. The last line is `research-tests: <N> tests in <S> suites; <K> skipped`, which
verify-tests.py reads. Exit status is 1 when a suite fails or runs no tests.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

# The code these suites test. test-scope.py keeps its own copy (it loads without importing siblings);
# test_research_tests.py fails when the two differ.
TESTED_PREFIXES = ('research/B4/', 'research/B2/', 'research/D3/', 'research/C1/tools/')

# Where `go` lives when the lane's PATH is short: the official installer and Homebrew on Apple silicon.
GO_DIRECTORIES = ('/usr/local/go/bin', '/opt/homebrew/bin', '/usr/local/bin')

C1_HEAVY = ('test_i14', 'test_score', 'test_precheck', 'test_chapters')
C1_NEEDS = 'the packages in research/C1/requirements.txt (pymupdf, lxml, regex, ...)'

# (label, directory, unittest arguments). Each runs from its own folder, as its README does.
PYTHON_SUITES = (
    ('python research/B2', 'research/B2', ('test_b2',)),
    ('python research/D3', 'research/D3', ('discover', '-s', 'tests')),
    ('python research/C1/tools (test_net, test_groundtruth)', 'research/C1/tools',
     ('test_net', 'test_groundtruth')),
)
# Suites in the research folders that need packages or models this runner does not install.
HEAVY = (
    ('python research/C1/tools (' + ', '.join(C1_HEAVY) + ')', C1_NEEDS),
    ('python research/C2/frontend', 'research/C2/.venv with the speech engines installed'),
)

TAIL_LINES = 40


class Result:
    def __init__(self, label, tests=0, error=None, skipped=None, output=''):
        self.label, self.tests, self.error, self.skipped, self.output = label, tests, error, skipped, output

    @property
    def ran(self):
        return self.skipped is None


def tail(text, limit=TAIL_LINES):
    lines = text.rstrip().splitlines()
    return '\n'.join((['...'] if len(lines) > limit else []) + lines[-limit:])


def find_go(path=None):
    search = os.pathsep.join(filter(None, [path if path is not None else os.environ.get('PATH', ''),
                                           *GO_DIRECTORIES]))
    return shutil.which('go', path=search)


def run(args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, errors='replace',
                          env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', **(env or {})})


def go_suite(root, go=None):
    label = 'go research/B4/server'
    go = go or find_go()
    if not go:
        return Result(label, skipped='`go` is not on PATH or in ' + ', '.join(GO_DIRECTORIES)
                      + '; the server tests did not run')
    # -count=1: a cached pass would say nothing about this checkout. -json: the test count, and the
    # failing test's own output.
    done = run([go, 'test', '-json', '-count=1', './...'], root / 'research/B4/server')
    passed, failed, output = 0, [], {}
    stray = []
    for line in done.stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            stray.append(line)
            continue
        test, package, action = event.get('Test'), event.get('Package', ''), event.get('Action')
        if action == 'output':
            output.setdefault((package, test), []).append(event.get('Output', ''))
        elif test and action == 'pass' and '/' not in test:
            passed += 1
        elif action == 'fail' and (test is None or '/' not in test):
            failed.append((package, test))
        elif action == 'build-fail':
            failed.append((package, None))
    if done.returncode == 0 and passed:
        return Result(label, tests=passed)
    detail = [f'go test exited {done.returncode} with {passed} tests passed']
    for package, test in failed[:10]:
        name = f'{package} {test}' if test else package
        detail.append(f'FAIL {name}\n' + tail(''.join(output.get((package, test), [])), 25))
    if not failed:
        detail.append(tail('\n'.join(stray) + '\n' + done.stderr + ''.join(
            text for lines in output.values() for text in lines)))
    return Result(label, error='\n'.join(detail))


def python_suite(root, label, folder, arguments):
    done = run([sys.executable, '-m', 'unittest', *arguments], root / folder)
    text = done.stdout + done.stderr
    match = re.search(r'Ran (\d+) tests? in ', text)
    tests = int(match[1]) if match else 0
    if done.returncode or not tests:
        return Result(label, tests=tests, error=f'unittest exited {done.returncode} after {tests} tests\n' + tail(text))
    return Result(label, tests=tests)


def caddy_suite(root):
    label = 'shell research/B4/deploy/test-edit-caddyfile.sh'
    done = run(['bash', str(root / 'research/B4/deploy/test-edit-caddyfile.sh')], root)
    text = done.stdout + done.stderr
    match = re.search(r'^(\d+) checks passed$', text, re.M)
    checks = int(match[1]) if match else 0
    if done.returncode or not checks:
        return Result(label, tests=checks, error=f'script exited {done.returncode} after {checks} checks\n' + tail(text))
    return Result(label, tests=checks)


def suites(root):
    yield lambda: go_suite(root)
    for label, folder, arguments in PYTHON_SUITES:
        yield lambda label=label, folder=folder, arguments=arguments: python_suite(root, label, folder, arguments)
    yield lambda: caddy_suite(root)


def main(root=ROOT, out=sys.stdout):
    results = [suite() for suite in suites(Path(root))]
    results += [Result(label, skipped=f'needs {needs}; not run here') for label, needs in HEAVY]
    for result in results:
        if result.skipped is not None:
            print(f'skipped: {result.label} - {result.skipped}', file=out)
        elif result.error:
            print(f'FAILED: {result.label}\n{result.error}', file=out)
        else:
            print(f'passed: {result.label} ({result.tests} tests)', file=out)
    ran = [r for r in results if r.ran]
    tests = sum(r.tests for r in ran if not r.error)
    skipped = sum(not r.ran for r in results)
    print(f'research-tests: {tests} tests in {len(ran)} suites; {skipped} skipped', file=out)
    return 1 if any(r.error for r in ran) or not tests else 0


if __name__ == '__main__':
    sys.exit(main())
