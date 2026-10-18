"""The lane's step ledger: what each lane step costs and catches, and an alarm the moment one looks like waste.

#1200: the per-PR app builds ran 140 times in a week, about 8 runner-hours, and caught no compile failure.
Nobody saw it until someone read a week of reports by hand (#1196). Now each step a lane job runs (the
hot-file ratchet, host tests, app builds, app tests) is noted when the job reports, in one JSON file in the
lane state folder on the Mac (not in git):

- runs and wall time;
- PASS, real FAIL and runner-fault counts. A fault is the lane's, not the PR's: INCONCLUSIVE, a lane
  error, or app tests that passed with zero tests run;
- catches: a FAIL on a PR's head, then a later commit on the same PR that passes that step. A FAIL
  followed by a PASS on the same head is a flake, not a catch.

Alarms are signals, not timers. Each one is posted once and not again until its condition clears and
comes back:

- waste: WASTE_RUNS runs of a step in a row without a FAIL, averaging more than WASTE_SECONDS a run;
- faults: FAULT_RUNS runner faults of a step in a row;
- shared failure: the same test fails one step on two different PRs tested against the same next commit,
  which points at next, not at either PR.

Per test (#1789): a failure also opens a per-test record, and the later PASS closes it with a class, written as one
line to test-catches.jsonl beside the ledger. The class comes from the PR's own commits between the failing
head and the passing one (first-parent only, so next merged into the PR does not count):

- catch: product code changed (App/, Packages/ or Contracts/, outside test folders);
- wrong-test: only test files changed, so the test was wrong, not the code;
- flake: same head, or nothing changed, and the passing run tested against the same next;
- next-moved: the PR's own code didn't change but next did between the two runs (the same head re-run on a
  newer next, or next merged into the PR). Either next broke the test and a later next fixed it, or it was a
  flake; the ledger can't tell which, so it doesn't count it as either;
- other: only files outside those (docs, scripts), or the diff could not be read.

A test closes only on a run that ran it. The lane reports list failing tests only, and T3 runs a different set
of tests on each request, so a test missing from a run's failures may simply not have run. Each step run can carry
'ran', the tests it executed; a named test closes only when it is in that list and not among the failures, and
otherwise stays open (step['open_tests']) with the head it last failed at. The lane runner passes 'ran' for the host tests
and the T3 run (the tests in their verify-tests.py manifests, #1830); a step that cannot say, such as the app builds, passes
none, so its named failures stay open and only a step failure that named no test (step:<name>) closes on the step's
PASS. The integration run (record_tip) always runs the full app plan, so a
PASS there closes every open test.

`python3 scripts/lane_ledger.py report` prints the totals per test. "Episodes" counts failures that were later
closed, not every run of the test.

Stdlib only, Python 3.9-compatible: lane-runner.py runs under /usr/bin/python3.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

LEDGER = 'step-ledger.json'
CATCHES = 'test-catches.jsonl'
PRODUCT_ROOTS = ('App', 'Packages', 'Contracts')
WASTE_RUNS = 20
WASTE_SECONDS = 60
FAULT_RUNS = 3
KEEP_BASES = 50  # next commits whose failing tests are remembered, for the shared-failure rule
VERDICTS = ('pass', 'fail', 'fault')


def outcome(verdict: str, zero_tests: bool = False) -> str:
    """pass, fail or fault for a step's lane verdict. INCONCLUSIVE and a lane error are faults; so is a PASS
    that ran no test. A FAIL that ran no test stays a FAIL: a test target that doesn't compile fails that way."""
    verdict = (verdict or '').upper()
    if verdict == 'PASS':
        return 'fault' if zero_tests else 'pass'
    return 'fail' if verdict == 'FAIL' else 'fault'


def empty() -> dict:
    return {'version': 1, 'steps': {}, 'failures': {}, 'alarms': {}}


def _step(ledger: dict, name: str) -> dict:
    return ledger['steps'].setdefault(name, {
        'runs': 0, 'seconds': 0.0, 'pass': 0, 'fail': 0, 'fault': 0, 'catches': 0,
        'since_fail_runs': 0, 'since_fail_seconds': 0.0, 'faults_in_a_row': 0, 'open_fails': {}})


def duration(seconds: float) -> str:
    minutes, seconds = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    return f'{hours}h{minutes:02d}m' if hours else (f'{minutes}m{seconds:02d}s' if minutes else f'{seconds}s')


def _is_test_path(file: str) -> bool:
    parts = file.split('/')
    name = parts[-1]
    return (any(p in ('tests', 'Tests', 'TestPlans') or p.endswith('Tests') for p in parts[:-1])
            or name.startswith('test_') or name.endswith(('Tests.swift', 'Test.swift', '_test.py')))


def changed_files(repo, old: str, new: str, merges: bool = False):
    """Files the commits from <old> to <new> changed, following first parents only, or None if git can't say.
    With merges=False a merge commit adds nothing, so next merged into a PR doesn't count as the PR's change;
    with merges=True (the tips of next, each a PR merge) a merge counts as its diff from its first parent."""
    if old == new:
        return []
    def git(*args):
        return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, timeout=60)
    try:
        if git('merge-base', '--is-ancestor', old, new).returncode == 0:
            walk = git('log', '--first-parent', '--diff-merges=first-parent' if merges else '--no-diff-merges',
                       '--name-only', '--format=',
                       f'{old}..{new}')
        else:  # rebased or force-pushed: only the two trees can be compared
            walk = git('diff', '--name-only', old, new)
    except (OSError, subprocess.SubprocessError):
        return None
    if walk.returncode:
        return None
    return sorted({line for line in walk.stdout.splitlines() if line})


def classify(repo, old: str, new: str, merges: bool = False) -> str:
    files = changed_files(repo, old, new, merges) if repo else None
    if files is None:
        return 'other'
    if not files:
        return 'flake'
    if any(f.split('/')[0] in PRODUCT_ROOTS and not _is_test_path(f) for f in files):
        return 'catch'
    if all(_is_test_path(f) for f in files):
        return 'wrong-test'
    return 'other'


def _close(sink: list, step: str, key: str, test: str, origin: dict, new: str, repo, merges: bool, base: str,
           kinds: dict) -> None:
    """Add one line to <sink>: <test>, failing since <origin> ({'head', 'base', 'seconds'}), fixed at <new>.
    base: the next commit the closing run tested against. When the PR's own code is unchanged but next moved since
    the failing run, the class is next-moved, not flake. An unknown base (an older ledger) keeps flake."""
    old = origin['head']
    if old not in kinds:
        kinds[old] = classify(repo, old, new, merges)
    kind = kinds[old]
    if kind == 'flake' and base and origin.get('base') and origin['base'] != base:
        kind = 'next-moved'
    sink.append({'step': step, 'test': test, 'key': key, 'from': old, 'to': new, 'class': kind,
                 'seconds': round(origin.get('seconds', 0.0), 1)})


def close_tests(sink: list, open_fail: dict, step: str, key: str, new: str, repo, merges: bool,
                tests=None, base: str = '') -> None:
    """Classify the tests in <open_fail> (all, or just <tests>) as fixed at <new>, adding a line each to <sink>."""
    kinds: dict = {}
    for test in open_fail.get('tests') or [f'step:{step}']:
        if tests is None or test in tests:
            _close(sink, step, key, test, open_fail, new, repo, merges, base, kinds)


def _open(value) -> dict:
    """An open failure; the first ledgers kept only the failing head."""
    return value if isinstance(value, dict) else {'head': value, 'tests': [], 'seconds': 0.0}


def _settle_tests(step: dict, pr_key: str, before, failing: list, ran, passed: bool, name: str, head: str,
                  base: str, repo, sink) -> None:
    """Close the PR's open test failures that this run shows fixed, and keep the rest open.

    The lane reports list failing tests only, so a test missing from <failing> may not have run: T3 runs the
    request's tests: line plus the classes test-scope picks, a different set each time (audit on 4dc582d). A named
    test closes only when <ran> (the tests this run executed) includes it; with ran None nobody knows, so it stays
    open in step['open_tests'] with the head it last failed at, until a run that ran it passes it. A test still in
    <failing> is reopened at this head by the caller. A failure that named no test (step:<name>) closes when the
    step passes, since the whole step ran; a later FAIL that names tests replaces it."""
    pending = dict(step.get('open_tests', {}).get(pr_key, {}))
    kinds, kept, key = {}, {}, f'pr:{pr_key}'
    ran = None if ran is None else set(ran)
    if before is not None:
        origin = {'head': before['head'], 'base': before.get('base', ''), 'seconds': before.get('seconds', 0.0)}
        for test in before.get('tests') or []:
            pending[test] = origin
        if passed and not before.get('tests') and sink is not None:
            _close(sink, name, key, f'step:{name}', origin, head, repo, False, base, kinds)
    for test, origin in pending.items():
        if test in failing:
            continue
        if ran is not None and test in ran:
            if sink is not None:
                _close(sink, name, key, test, origin, head, repo, False, base, kinds)
        else:
            kept[test] = origin
    if kept:
        step.setdefault('open_tests', {})[pr_key] = kept
    else:
        step.get('open_tests', {}).pop(pr_key, None)


def record(ledger: dict, name: str, result: str, seconds: float, pr: int, head: str, base: str,
           failed=(), repo=None, sink=None, ran=None) -> list[str]:
    """Add one run of step <name> to <ledger> and return the alarms it raises, newly, as comment bodies.

    result: pass, fail or fault (outcome()). failed: the tests or parts that failed, for the shared-failure rule
    and the per-test catch lines. repo: the git checkout holding the PR's heads; sink: a list that gets one dict
    per closed test failure (record_runs writes them to test-catches.jsonl). ran: the tests this run executed, or
    None when the caller can't say; only a test that ran and didn't fail is closed (_settle_tests).
    """
    if result not in VERDICTS:
        raise ValueError(f'unknown step result {result!r}')
    step, alarms, raised = _step(ledger, name), ledger['alarms'], []
    pr_key = str(pr)
    step['runs'] += 1
    step['seconds'] += seconds
    step[result] += 1
    if result == 'fail':
        step['since_fail_runs'], step['since_fail_seconds'] = 0, 0.0
        tests = list(dict.fromkeys(failed))
        before = step['open_fails'].get(pr_key)
        _settle_tests(step, pr_key, before and _open(before), tests, ran, False, name, head, base, repo, sink)
        step['open_fails'][pr_key] = {'head': head, 'tests': tests, 'seconds': seconds, 'base': base}
    else:
        step['since_fail_runs'] += 1
        step['since_fail_seconds'] += seconds
    if result == 'pass' and (pr_key in step['open_fails'] or pr_key in step.get('open_tests', {})):
        before = step['open_fails'].pop(pr_key, None)
        if before is not None:
            before = _open(before)
            if before['head'] != head:  # a later commit fixed what the step caught
                step['catches'] += 1
        _settle_tests(step, pr_key, before, (), ran, True, name, head, base, repo, sink)
    step['faults_in_a_row'] = step['faults_in_a_row'] + 1 if result == 'fault' else 0

    waste = f'waste:{name}'
    runs, spent = step['since_fail_runs'], step['since_fail_seconds']
    if runs >= WASTE_RUNS and spent / runs > WASTE_SECONDS:
        if waste not in alarms:
            alarms[waste] = True
            raised.append(
                f'**Lane step alarm: {name} may be waste.** {runs} runs in a row without a FAIL, '
                f'{duration(spent / runs)} a run on average ({duration(spent)} in all). Over its whole record: '
                f'{step["runs"]} runs, {duration(step["seconds"])}, {step["fail"]} FAIL, {step["catches"]} '
                f'caught (a FAIL that a later commit on the same PR fixed), {step["fault"]} runner faults. '
                f'If nothing it would catch is caught elsewhere first, keep it; otherwise cut it or run it less.')
    elif waste in alarms and runs < WASTE_RUNS:  # a FAIL cleared it
        del alarms[waste]

    faults = f'faults:{name}'
    if step['faults_in_a_row'] >= FAULT_RUNS:
        if faults not in alarms:
            alarms[faults] = True
            raised.append(
                f'**Lane step alarm: {name} failed for the lane\'s own reasons {step["faults_in_a_row"]} times in a '
                f'row** (INCONCLUSIVE, a lane error or zero tests), most recently on PR #{pr} at `{head[:7]}`. '
                f'Every run it spends now is wasted until the runner is fixed.')
    elif faults in alarms:
        del alarms[faults]

    if result == 'fail' and base:
        seen = ledger['failures'].setdefault(f'{name}|{base}', {})
        for test in dict.fromkeys(failed):
            prs = seen.setdefault(test, [])
            if pr not in prs:
                prs.append(pr)
            shared = f'shared:{name}|{base}|{test}'
            if len(prs) >= 2 and shared not in alarms:
                alarms[shared] = True
                raised.append(
                    f'**Lane step alarm: `{test}` failed {name} on {len(prs)} different PRs** '
                    f'({", ".join(f"#{n}" for n in prs)}), each tested with next at `{base[:7]}`. It may be '
                    f'broken on next, not in those PRs: fix or revert it on next before blaming them.')
        _prune(ledger)
    return raised


def _prune(ledger: dict) -> None:
    """Keep the shared-failure memory to the newest KEEP_BASES (step, next) pairs, and their alarm keys."""
    failures = ledger['failures']
    for key in list(failures)[:-KEEP_BASES]:
        del failures[key]
        for alarm in [a for a in ledger['alarms'] if a.startswith(f'shared:{key}|')]:
            del ledger['alarms'][alarm]


def path(state: Path) -> Path:
    return Path(state) / LEDGER


@contextlib.contextmanager
def opened(state: Path):
    """The ledger in <state>, locked against the other runners for the whole update, written back atomically."""
    state = Path(state)
    state.mkdir(parents=True, exist_ok=True)
    with (state / (LEDGER + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            ledger = json.loads(path(state).read_text())
            if not isinstance(ledger, dict) or ledger.get('version') != 1:
                raise ValueError('not a version 1 ledger')
        except FileNotFoundError:
            ledger = empty()
        except ValueError:  # a damaged ledger starts again, keeping the old one beside it
            os.replace(path(state), state / (LEDGER + '.damaged'))
            ledger = empty()
        yield ledger
        handle, temporary = tempfile.mkstemp(dir=state, prefix=LEDGER + '.')
        with os.fdopen(handle, 'w') as out:
            json.dump(ledger, out, indent=1, sort_keys=True)
        os.replace(temporary, path(state))


def _append_catches(state: Path, lines: list) -> None:
    if lines:
        stamp = int(time.time())
        with (Path(state) / CATCHES).open('a') as out:
            for line in lines:
                out.write(json.dumps(dict(line, at=stamp), sort_keys=True) + '\n')


def record_runs(state: Path, runs: list[dict], pr: int, head: str, repo=None) -> list[str]:
    """Add a job's step runs ({'step', 'result', 'seconds', 'base', 'failed'}) to the ledger in <state> and
    return the new alarms. repo: the git checkout with the PR's heads, to classify closed failures; without it
    the current directory's repository is tried."""
    raised, lines = [], []
    repo = repo or Path.cwd()
    with opened(state) as ledger:
        for run in runs:
            raised += record(ledger, run['step'], run['result'], run['seconds'], pr, head, run.get('base') or '',
                             run.get('failed') or (), repo, lines, run.get('ran'))
        _append_catches(state, lines)
    return raised


def record_tip(state: Path, repo, sha: str, verdict: str, failed=(), flaky=(), seconds: float = 0.0) -> list[dict]:
    """The integration run's version, keyed on next tips instead of a PR. FAIL opens the failing tests at <sha>
    (a test that failed and then passed on a re-run of the same build is a flake at once); a later PASS closes
    them against the commits between the two tips. INCONCLUSIVE changes nothing."""
    lines = []
    with opened(state) as ledger:
        tips = ledger.setdefault('tips', {})
        for test in flaky:
            lines.append({'step': 'integration', 'test': test, 'key': 'next', 'from': sha, 'to': sha,
                          'class': 'flake', 'seconds': round(seconds, 1)})
        if verdict == 'FAIL':
            before = tips.get('next')
            tests = list(dict.fromkeys(failed))
            if before:  # a re-run of the same tip that fails fewer tests closes the rest as flakes
                gone = [t for t in before['tests'] if t not in tests]
                close_tests(lines, before, 'integration', 'next', sha, repo, True, gone)
            tips['next'] = {'head': sha, 'tests': tests, 'seconds': seconds}
        elif verdict == 'PASS' and 'next' in tips:
            close_tests(lines, tips.pop('next'), 'integration', 'next', sha, repo, True)
        _append_catches(state, lines)
    return lines


def report(state: Path) -> str:
    """Per test: episodes closed, catches, wrong-test, flakes, next-moved, other, and seconds spent in failing runs."""
    totals: dict = {}
    try:
        rows = [json.loads(line) for line in (Path(state) / CATCHES).read_text().splitlines() if line.strip()]
    except FileNotFoundError:
        rows = []
    for row in rows:
        total = totals.setdefault(row['test'], dict.fromkeys(('episodes', 'catch', 'wrong-test', 'flake', 'next-moved', 'other', 'seconds'), 0))
        total['episodes'] += 1
        total[row['class'] if row['class'] in total else 'other'] += 1
        total['seconds'] += row.get('seconds', 0)
    if not totals:
        return 'No closed test failures recorded yet.'
    order = sorted(totals.items(), key=lambda kv: (-kv[1]['catch'], -kv[1]['episodes'], kv[0]))
    out = [f'{"test":<60} {"eps":>4} {"catch":>5} {"wrong":>5} {"flake":>5} {"next":>5} {"other":>5} {"time":>7}']
    for test, t in order:
        name = test if len(test) <= 60 else '...' + test[-57:]
        out.append(f'{name:<60} {t["episodes"]:>4} {t["catch"]:>5} {t["wrong-test"]:>5} {t["flake"]:>5} '
                   f'{t["next-moved"]:>5} {t["other"]:>5} {duration(t["seconds"]):>7}')
    return '\n'.join(out)


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] != ['report']:
        print('usage: lane_ledger.py report [state-dir]', file=sys.stderr)
        return 2
    if argv[1:2]:
        state = Path(argv[1])
    else:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from lane_slots import state_dir
        state = state_dir()
    print(report(state))
    return 0


if __name__ == '__main__':
    sys.exit(main())
