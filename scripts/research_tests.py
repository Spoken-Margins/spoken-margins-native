#!/usr/bin/env python3
"""Runs the tests under research/ that need nothing heavier than Go, bash and a few light Python packages (#1033).

  scripts/research_tests.py          run every suite; skipped suites are named with the reason

Before this, `go test` for the share-link and map-upload server (tokens, App Attest, rate limits, request
logging), the research Python tests and the Caddy privacy-filter script ran only when someone typed them.
`verify-tests.py --plan fast` now runs this file as its `research` step, and test-scope.py treats the code
paths in TESTED_PREFIXES as T1 so a PR that touches only the server still gets that step.

A suite that cannot run here (no `go` on the Mac, a bash too old for the Caddy script, a Python package
missing) is printed as `skipped: <suite> - <reason>` and counted, never passed silently; verify-tests.py
puts each skip in its manifest and the lane's PASS report. Suites that are never run here, by design, are
printed as `not covered: <suite> - <reason>`. The last line is
`research-tests: <N> tests in <S> suites; <K> skipped; <M> not covered`. Exit status is 1 when a suite fails
or when no test ran at all.
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

# (label, directory, unittest arguments). Each runs from its own folder, as its README does.
PYTHON_SUITES = (
    ('python research/B2', 'research/B2', ('test_b2',)),
    ('python research/D3', 'research/D3', ('discover', '-s', 'tests')),
    ('python research/C1/tools test_net', 'research/C1/tools', ('test_net',)),
    ('python research/C1/tools test_groundtruth', 'research/C1/tools', ('test_groundtruth',)),
)
# Packages from research/C1/requirements.txt and requirements-dev.txt. A suite that can't import one is
# skipped by name; any other missing module is a real failure.
THIRD_PARTY = ('lxml', 'regex', 'fitz', 'pdfminer', 'jsonschema')
# Suites in the research folders that need packages or models this runner does not install.
NOT_COVERED = (
    ('python research/C1/tools (test_i14, test_score, test_precheck, test_chapters)',
     'they need the packages in research/C1/requirements.txt (pymupdf, regex, ...)'),
    ('python research/C2/frontend', 'it needs research/C2/.venv with the speech engines installed'),
)

TAIL_LINES = 40


class Result:
    def __init__(self, label, tests=0, error=None, skipped=None, not_covered=None, partial=None):
        self.label, self.tests, self.error, self.skipped, self.not_covered = label, tests, error, skipped, not_covered
        self.partial = partial  # a suite that ran, but not all of its checks: counted as run, and named as skipped

    @property
    def ran(self):
        return self.skipped is None and self.not_covered is None


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
    # -count=1: a cached pass says nothing about this checkout. -json: the test count, and the
    # failing test's own output.
    done = run([go, 'test', '-json', '-count=1', './...'], root / 'research/B4/server')
    passed, failed_tests, failed_packages, output, compiler, stray = 0, [], [], {}, {}, []
    for line in done.stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            stray.append(line)
            continue
        test, package, action = event.get('Test'), event.get('Package', ''), event.get('Action')
        if action == 'output':
            output.setdefault((package, test), []).append(event.get('Output', ''))
        elif action == 'build-output':  # the compiler's text, keyed by import path
            compiler.setdefault(event.get('ImportPath', ''), []).append(event.get('Output', ''))
        elif action == 'build-fail':
            failed_packages.append(event.get('ImportPath', ''))
        elif test and action == 'pass' and '/' not in test:
            passed += 1
        elif action == 'fail' and test and '/' not in test:
            failed_tests.append((package, test))
        elif action == 'fail' and not test:
            failed_packages.append(package)
    if done.returncode == 0 and passed:
        return Result(label, tests=passed)
    detail = [f'go test exited {done.returncode} with {passed} tests passed']
    for package, test in failed_tests[:10]:
        detail.append(f'failed test: {package} {test}\n' + tail(''.join(output.get((package, test), [])), 25))
    # A package that failed on its own (does not build, panics at start-up, times out) rather than
    # through a named test.
    for package in dict.fromkeys(p for p in failed_packages if p and p not in {t[0] for t in failed_tests}):
        text = ''.join(compiler.get(package, []) + output.get((package, None), []))
        text = text or ''.join(t for key, lines in compiler.items() if key.startswith(package) for t in lines)
        detail.append(f'failed package: {package}\n' + tail(text, 25))
    if len(detail) == 1:
        detail.append(tail('\n'.join(stray) + '\n' + done.stderr + ''.join(
            text for lines in [*output.values(), *compiler.values()] for text in lines)))
    return Result(label, error='\n'.join(detail))


def python_suite(root, label, folder, arguments):
    done = run([sys.executable, '-m', 'unittest', *arguments], root / folder)
    text = done.stdout + done.stderr
    missing = re.search(r"ModuleNotFoundError: No module named '(\w+)", text)
    if done.returncode and missing and missing[1] in THIRD_PARTY:
        return Result(label, skipped=f'the Python package `{missing[1]}` is not installed for {sys.executable}')
    match = re.search(r'Ran (\d+) tests? in ', text)
    tests = int(match[1]) if match else 0
    if done.returncode or not tests:
        return Result(label, tests=tests, error=f'unittest exited {done.returncode} after {tests} tests\n' + tail(text))
    return Result(label, tests=tests)


def bash_has_mapfile(root):
    return run(['bash', '-c', 'type mapfile'], root).returncode == 0


def caddy_suite(root):
    label = 'shell research/B4/deploy/test-edit-caddyfile.sh'
    # edit-caddyfile.sh reads the Caddyfile with `mapfile`, which bash 3.2 (macOS /bin/bash) lacks.
    if not bash_has_mapfile(root):
        return Result(label, skipped='the `bash` on PATH has no `mapfile` (macOS /bin/bash is 3.2); '
                                     'the Caddy filter script did not run')
    done = run(['bash', str(root / 'research/B4/deploy/test-edit-caddyfile.sh')], root)
    text = done.stdout + done.stderr
    # The script's last line is "N checks passed", or "N checks passed, but not the Caddy ones above" where
    # Caddy isn't installed (a hosted Linux job, #1847); both count.
    match = re.search(r'^(\d+) checks passed(, but not the Caddy ones above)?$', text, re.M)
    checks = int(match[1]) if match else 0
    if done.returncode or not checks:
        return Result(label, tests=checks, error=f'script exited {done.returncode} after {checks} checks\n' + tail(text))
    if match[2]:  # #2605: the Caddy checks (validate every candidate, serve it, read the log) ran nothing
        return Result(label, tests=checks, partial='Caddy or smserver is missing (set CADDY and SMSERVER); '
                                                    'the Caddy validate and local-serving checks did not run')
    return Result(label, tests=checks)


def rollback_suite(root):
    label = 'shell research/B4/deploy/test-server-rollback.sh'
    done = run(['bash', str(root / 'research/B4/deploy/test-server-rollback.sh')], root)
    text = done.stdout + done.stderr
    match = re.search(r'^(\d+) passed$', text, re.M)
    checks = int(match[1]) if match else 0
    if done.returncode or not checks:
        return Result(label, tests=checks, error=f'script exited {done.returncode} after {checks} checks\n' + tail(text))
    return Result(label, tests=checks)


def suites(root):
    yield lambda: go_suite(root)
    for label, folder, arguments in PYTHON_SUITES:
        yield lambda label=label, folder=folder, arguments=arguments: python_suite(root, label, folder, arguments)
    yield lambda: caddy_suite(root)
    yield lambda: rollback_suite(root)


def main(root=ROOT, out=sys.stdout):
    results = [suite() for suite in suites(Path(root))]
    results += [Result(label, not_covered=why) for label, why in NOT_COVERED]
    for result in results:
        if result.not_covered is not None:
            print(f'not covered: {result.label} - {result.not_covered}', file=out)
        elif result.skipped is not None:
            print(f'skipped: {result.label} - {result.skipped}', file=out)
        elif result.error:
            print(f'FAILED: {result.label}\n{result.error}', file=out)
        else:
            print(f'passed: {result.label} ({result.tests} tests)', file=out)
            if result.partial:
                print(f'skipped: {result.label} - {result.partial}', file=out)
    ran = [r for r in results if r.ran]
    tests = sum(r.tests for r in ran if not r.error)
    skipped = sum(r.skipped is not None or bool(r.partial) for r in results)
    not_covered = sum(r.not_covered is not None for r in results)
    print(f'research-tests: {tests} tests in {len(ran)} suites; {skipped} skipped; {not_covered} not covered',
          file=out)
    return 1 if any(r.error for r in ran) or not tests else 0


if __name__ == '__main__':
    sys.exit(main())
