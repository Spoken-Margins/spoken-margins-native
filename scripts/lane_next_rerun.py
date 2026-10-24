"""Before a lane run blames a PR for a failing host test, re-run that test on the plain trunk (#1204).

"next" in this docstring and the function names below means the trunk, which is main since 2026-10-20 (#1492);
the report line and issue titles name the real branch (#2535).

From 2026-10-02 to 10-09, 6 host-test FAILs were the same real-player tests failing on 4 unrelated PRs,
because the Mac had no sound output (#909). A test that is broken on next, or on the Mac, fails every PR
until someone notices, and each FAIL wakes a thread to look for a bug its PR didn't write.

When `--plan fast` fails, the lane runner calls recheck(). It reads which tests failed from the failed
step (the SessionKit XCTests, scripts/tests or an ops/ folder), checks out the next commit the PR was
merged with in the same tree, runs only those tests there with a time limit, and checks the merge commit
out again. If every one of them fails on next too, the verdict is INCONCLUSIVE ("fails on next <sha7>
too: not this PR") and each gets an issue of its own, or a comment on the open one already named after
it. If any passes on next or doesn't exist there, the FAIL stands. A failure no test name explains (a
crash, a timeout, a contracts check) stays FAIL, as before.

Stdlib only, Python 3.9-compatible: the lane runner imports it under /usr/bin/python3.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys

import comment_trust
import trunk

# unittest's failure headings: "FAIL: test_x (module.Class.test_x)" on Python 3.11+, "(module.Class)" before;
# a subTest adds " (name='a')", and a class fixture reads "ERROR: setUpClass (module.Class)".
PY_FAILURE = re.compile(r'^(?:FAIL|ERROR): (\w+) \(([\w.]+)\)', re.M)
XCTEST_CASE = re.compile(r"Test Case '-\[(\w+)\.(\w+) (test\w+)\]' (passed|failed|skipped)")
# The SessionKit tests that need a running audio output, as verify-tests.py names them (#909).
REAL_PLAYER_TEST = re.compile(r'/(?:RealPlayer[A-Z]\w*Tests|StreamSeekLifecycleTests)/')
RERUN_TIMEOUT = 600  # one limit for the whole re-run: an incremental SessionKit build of next plus the tests
MARK = 'LANE-NEXT-RERUN '
ISSUE_LABELS = ['ready', 'priority', 'bug', 'regression']
MILESTONE = 'Open Source: after the flip'  # Solid Ground is closed; a pipeline fault goes here (owner, 2026-10-19)
BULK_LIMIT = 5  # more failing tests than this at once is the Mac or the tree, not that many broken tests
# The branch the re-run uses is the trunk (main since 2026-10-20, #1492), so the report line and issue titles name
# it. lane-runner.py's auto-revert does not read that wording: it matches NOT_THIS_PR, which names no branch.
# Open issues filed before the change still carry "next" in their title; LEGACY_BRANCH keeps them found (#2535).
NOT_THIS_PR = 'too: not this PR'
LEGACY_BRANCH = 'next'


def branch() -> str:
    try:
        return trunk.trunk_branch()
    except ValueError:
        return 'the trunk'


def fails_on(name: str | None = None) -> str:
    """How the report line starts: "fails on main"."""
    return f'fails on {name or branch()}'


def issue_title(test: str, name: str | None = None) -> str:
    return f'Host test fails on {name or branch()}: {test}'


def bulk_titles() -> tuple[str, ...]:
    """The title of the one issue for many failing tests, now and as it was filed before #2535."""
    return tuple(f'Host tests fail on {name}: many at once' for name in dict.fromkeys((branch(), LEGACY_BRANCH)))

# Run inside the PR's venv Python, in the tree, on next's code: one result per requested name.
PY_LOADER = r'''
import json, sys, unittest
sys.path.insert(0, sys.argv[1])
def flat(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from flat(test)
        else:
            yield test
results = {}
for name in sys.argv[2:]:
    try:
        suite = unittest.defaultTestLoader.loadTestsFromName(name)
    except Exception:
        results[name] = 'missing'
        continue
    tests = list(flat(suite))
    if not tests or any(type(test).__name__ == '_FailedTest' for test in tests):
        results[name] = 'missing'
        continue
    result = unittest.TestResult()
    suite.run(result)
    results[name] = 'failed' if result.failures or result.errors else 'passed'
    for case, trace in result.failures + result.errors:  # the log must show what failed, not only that it did (#2535)
        print('LANE-NEXT-RERUN-FAILURE ' + name + '\n' + trace, flush=True)
print('LANE-NEXT-RERUN ' + json.dumps(results), flush=True)
'''


def _manifest(output: Path) -> dict:
    try:
        return json.loads((output / 'manifest.json').read_text())
    except (OSError, ValueError):
        return {}


def python_failures(log: str) -> list[str]:
    """The unittest identifiers in a log's FAIL and ERROR headings, each once, in order."""
    found = []
    for method, where in PY_FAILURE.findall(log):
        name = where if where.rsplit('.', 1)[-1] == method or method in ('setUpClass', 'tearDownClass',
                                                                           'setUpModule', 'tearDownModule') \
            else f'{where}.{method}'
        if name not in found:
            found.append(name)
    return found


def failing_tests(output: Path, tree: Path) -> tuple[str, str, list[str]] | None:
    """(kind, folder, test identifiers) for the step that stopped `--plan fast`, or None when its failure
    can't be pinned on named tests: a timeout, a crash, missing tests, or a step that isn't a test suite.

    kind is 'swift' (identifiers like SessionKitTests/Class/testMethod) or 'python' (module.Class.method,
    importable with `folder`, relative to the tree, on sys.path)."""
    # A step marked superseded was run again (the parallel SessionKitCoreTests run, #1328): the rerun decides.
    steps = [step for step in _manifest(output).get('steps', []) if step.get('errors') and not step.get('superseded')]
    if not steps:
        return None
    step = steps[-1]
    if step.get('interrupted'):
        return None
    name = step.get('name', '')
    if name in ('package', 'package-core', 'package-core-serial'):
        # Only test failures: "Missing:" tests, a crash or an unexpected skip aren't a test to re-run.
        if not all(error.startswith(('Failed: ', 'Process exit ')) for error in step['errors']):
            return None
        failed = sorted(test for test, record in (step.get('tests') or {}).items() if record.get('status') == 'failed')
        return ('swift', 'Packages/SessionKit', failed) if failed else None
    if name == 'runner-tests':
        folder = 'scripts/tests'
    elif name.startswith('ops'):
        command = step.get('command') or []
        if '-s' not in command:
            return None
        try:
            folder = Path(command[command.index('-s') + 1]).resolve().relative_to(tree.resolve()).as_posix()
        except (IndexError, ValueError):
            return None
    else:
        return None
    try:
        log = (output / f'{name}.log').read_text(errors='replace')
    except OSError:
        return None
    failed = python_failures(log)
    return ('python', folder, failed) if failed else None


def _git(tree: Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(tree), *args], text=True, stderr=subprocess.STDOUT).strip()


def swift_filter(tests: list[str]) -> str:
    """One `swift test --filter` expression matching exactly these Target/Class/method identifiers."""
    return '^(?:' + '|'.join(re.escape(test.replace('/', '.', 1)) for test in tests) + ')$'


def _default_runner(tree: Path):
    def run(command, log, timeout):
        process = subprocess.Popen(command, cwd=tree, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            return None
    return run


def rerun_on(tree: Path, sha: str, kind: str, folder: str, tests: list[str], log_path: Path,
             runner=None, python: str | None = None, timeout: float = RERUN_TIMEOUT) -> tuple[dict, str]:
    """Check out <sha> in the tree, run just these tests, and check the tree's commit out again.

    Returns ({test: 'failed' | 'passed' | 'missing'}, a note). A test the run didn't report counts as
    missing, so a build that fails on next or a timeout never reads as "fails on next too"."""
    runner = runner or _default_runner(tree)
    python = python or sys.executable
    try:
        back = _git(tree, 'rev-parse', 'HEAD')
        _git(tree, 'checkout', '--quiet', '--detach', sha)
    except (OSError, subprocess.CalledProcessError) as error:
        output = getattr(error, 'output', '') or str(error)
        return {}, f'could not check out {branch()} {sha[:7]} to re-run them ({output.strip()[:200]})'
    try:
        if kind == 'swift':
            command = ['swift', 'test', '--package-path', folder, '--filter', swift_filter(tests)]
        else:
            command = [python, '-c', PY_LOADER, folder, *tests]
        with log_path.open('w') as log:
            code = runner(command, log, timeout)
        text = log_path.read_text(errors='replace')
    finally:
        _git(tree, 'checkout', '--quiet', '--detach', back)
    if kind == 'swift':
        seen = {}
        for module, cls, method, status in XCTEST_CASE.findall(text):
            identifier = f'{module}/{cls}/{method}'
            if seen.get(identifier) != 'failed':  # a passing retry never hides a failure
                seen[identifier] = status
        results = {test: seen[test] if seen.get(test) in ('failed', 'passed') else 'missing' for test in tests}
    else:
        marked = [line[len(MARK):] for line in text.splitlines() if line.startswith(MARK)]
        try:
            reported = json.loads(marked[-1]) if marked else {}
        except ValueError:
            reported = {}
        results = {test: reported.get(test, 'missing') for test in tests}
    note = '' if code is not None else f'the re-run on {branch()} stopped after {int(timeout)} s'
    return results, note


def _issue_key(test: str) -> tuple[str, str]:
    """The class and method a title may name the test by: Class/testX (XCTest) or Class.test_x (unittest)."""
    parts = re.split(r'[/.]', test)
    tail = parts[-2:] if len(parts) >= 2 else parts
    return '/'.join(tail), '.'.join(tail)


def report_broken_on_next(api, repo: str, tests: list[str], sha: str, pr: int, request_id: str,
                          log_path: Path) -> list[str]:
    """File one issue per test, or comment on the open issue whose title already names it. Returns a line
    per test for the report. `api(*args)` is `gh api`; a failure is reported, never raised."""
    try:
        listed = api('--paginate', '--jq', '.[] | @json', f'repos/{repo}/issues?state=open&per_page=100')
        open_issues = [json.loads(line) for line in listed.splitlines() if line.strip()]
        # Only issues from the team can already name a failing test: a stranger titling an issue after one must not
        # stop the real regression issue being filed, or collect the runner's comment (#1822).
        open_issues = [issue for issue in comment_trust.trusted_only(open_issues) if 'pull_request' not in issue]
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return [f'could not read the open issues to report them ({error!r})']
    milestone = None
    try:
        milestones = json.loads(api(f'repos/{repo}/milestones?state=open&per_page=100'))
        milestone = next((m['number'] for m in milestones if m.get('title') == MILESTONE), None)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        pass
    if len(tests) > BULK_LIMIT:
        return _report_bulk(api, repo, tests, sha, pr, request_id, log_path, open_issues, milestone)
    lines = []
    for test in tests:
        slash, dot = _issue_key(test)
        existing = next((issue for issue in open_issues
                         if test in issue.get('title', '') or slash in issue.get('title', '')
                         or dot in issue.get('title', '')), None)
        try:
            if existing:
                api(f'repos/{repo}/issues/{existing["number"]}/comments', '-f',
                    f'body=Failed on plain next `{sha[:7]}` too, when the lane re-ran it for #{pr} ({request_id}). '
                    f'Log on the Mac: `{log_path}`.\n\n_Posted by the lane runner (scripts/lane_next_rerun.py, #1204)._')
                lines.append(f'{test}: already open as #{existing["number"]}; commented')
                continue
            body = (f'**Outcome.** `{test}` passes on `{branch()}` again, so it stops failing unrelated PRs.\n\n'
                    f'**Evidence.** It failed in the lane run {request_id} on #{pr}. The lane re-ran it on plain '
                    f'`{branch()}` at `{sha[:7]}` on the same Mac, and it failed there too, so it isn\'t that PR\'s '
                    f'doing. Re-run log on the Mac: `{log_path}`.\n\n'
                    '**Done when**\n1. The cause is named: the test, the code on the trunk, or the Mac\'s state.\n'
                    '2. It passes on the trunk in a lane run.\n\n'
                    '**Must not break.** Don\'t skip or quarantine the test to make it pass.\n\n'
                    '**Tier.** T1.\n\n---\n_Filed by the lane runner (scripts/lane_next_rerun.py, #1204)._')
            args = [f'repos/{repo}/issues', '-f', f'title={issue_title(test)}', '-f', f'body={body}']
            for label in ISSUE_LABELS:
                args += ['-f', f'labels[]={label}']
            if milestone is not None:
                args += ['-F', f'milestone={milestone}']
            filed = json.loads(api(*args))
            open_issues.append(filed)
            lines.append(f'{test}: filed #{filed["number"]}')
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
            lines.append(f'{test}: not reported ({error!r})')
    return lines


def _report_bulk(api, repo, tests, sha, pr, request_id, log_path, open_issues, milestone) -> list[str]:
    """One issue for a run where more than BULK_LIMIT tests fail on plain next: 66 per-test issues on 2026-10-21
    were one fault. A later bulk run comments on the open one."""
    title = bulk_titles()[0]
    listing = '\n'.join(f'- `{test}`' for test in tests)
    existing = next((issue for issue in open_issues if issue.get('title', '') in bulk_titles()), None)
    try:
        if existing:
            api(f'repos/{repo}/issues/{existing["number"]}/comments', '-f',
                f'body={len(tests)} tests failed on plain next `{sha[:7]}` again, in the lane re-run for #{pr} '
                f'({request_id}). Log on the Mac: `{log_path}`.\n\n_Posted by the lane runner (scripts/lane_next_rerun.py)._')
            return [f'{len(tests)} tests fail on {branch()}: already open as #{existing["number"]}; commented']
        body = (f'**Outcome.** The {len(tests)} tests below pass on the trunk again, so they stop failing unrelated PRs.\n\n'
                f'**Evidence.** They failed in the lane run {request_id} on #{pr}, and on plain `{branch()}` at `{sha[:7]}` on the '
                f'same Mac. That many at once points at the Mac or the checkout, not at that many broken tests. '
                f'Log on the Mac: `{log_path}`.\n\n{listing}\n\n'
                '**Done when**\n1. The cause is named.\n2. They pass on the trunk in a lane run.\n\n'
                '**Must not break.** Don\'t skip or quarantine the tests to make them pass.\n\n'
                '**Tier.** T1.\n\n---\n_Filed by the lane runner (scripts/lane_next_rerun.py, #1204)._')
        args = [f'repos/{repo}/issues', '-f', f'title={title}', '-f', f'body={body}']
        for label in ISSUE_LABELS:
            args += ['-f', f'labels[]={label}']
        if milestone is not None:
            args += ['-F', f'milestone={milestone}']
        filed = json.loads(api(*args))
        return [f'{len(tests)} tests fail on {branch()}: filed #{filed["number"]} as one issue']
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        return [f'{len(tests)} tests fail on {branch()}: not reported ({error!r})']


def recheck(tree: Path, base_sha: str, evidence: Path, details: list[str], api, repo: str, pr: int,
            runner=None, python: str | None = None) -> tuple[str, list[str]]:
    """The verdict for a failed `--plan fast` run in <evidence>/fast, after re-running its failing tests on
    next at <base_sha>. Returns ('FAIL' or 'INCONCLUSIVE', details)."""
    output = evidence / 'fast'
    found = failing_tests(output, tree)
    if not found:
        return 'FAIL', details
    kind, folder, tests = found
    log_path = evidence / 'next-rerun.log'
    results, note = rerun_on(tree, base_sha, kind, folder, tests, log_path, runner=runner, python=python)
    if not results:
        return 'FAIL', details + [f'not re-run on {branch()}: {note}']
    on_next = [test for test in tests if results.get(test) == 'failed']
    others = [f'{test} ({results.get(test, "missing")} on {branch()})' for test in tests if test not in on_next]
    sha7 = base_sha[:7]
    # #909: with no sound output the real-player tests fail everywhere. That's the Mac, not next: don't file.
    audio = _manifest(output).get('audio_output') or {}
    mac = [test for test in on_next if audio.get('usable') is False and kind == 'swift' and REAL_PLAYER_TEST.search(test)]
    to_file = [test for test in on_next if test not in mac]
    filed = report_broken_on_next(api, repo, to_file, base_sha, pr, evidence.name, log_path) if to_file else []
    lines = ([f'  {line}' for line in filed]
             + ([f'  not filed, the Mac has no sound output (#909): {", ".join(mac)}'] if mac else [])
             + ([f'  {note}'] if note else []))
    if not others:
        return 'INCONCLUSIVE', details + [
            f'{fails_on()} {sha7} {NOT_THIS_PR}. The failing tests ({len(tests)}) were re-run on plain '
            f'{branch()} {sha7} and failed there as well. evidence: {log_path}', *lines]
    passed = f'{", ".join(others[:5])}{" …" if len(others) > 5 else ""}'
    return 'FAIL', details + [
        f're-run on plain {branch()} {sha7}: {passed}, so the FAIL stands'
        + (f'; {len(on_next)} of them also fail on {branch()}' if on_next else '') + f'. evidence: {log_path}', *lines]
