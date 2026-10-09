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

Stdlib only, Python 3.9-compatible: lane-runner.py runs under /usr/bin/python3.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
from pathlib import Path
import tempfile

LEDGER = 'step-ledger.json'
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


def record(ledger: dict, name: str, result: str, seconds: float, pr: int, head: str, base: str,
           failed=()) -> list[str]:
    """Add one run of step <name> to <ledger> and return the alarms it raises, newly, as comment bodies.

    result: pass, fail or fault (outcome()). failed: the tests or parts that failed, for the shared-failure rule.
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
        step['open_fails'][pr_key] = head
    else:
        step['since_fail_runs'] += 1
        step['since_fail_seconds'] += seconds
    if result == 'pass' and pr_key in step['open_fails']:
        if step['open_fails'].pop(pr_key) != head:  # a later commit fixed what the step caught
            step['catches'] += 1
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


def record_runs(state: Path, runs: list[dict], pr: int, head: str) -> list[str]:
    """Add a job's step runs ({'step', 'result', 'seconds', 'base', 'failed'}) to the ledger in <state> and
    return the new alarms."""
    raised = []
    with opened(state) as ledger:
        for run in runs:
            raised += record(ledger, run['step'], run['result'], run['seconds'], pr, head, run.get('base') or '',
                             run.get('failed') or ())
    return raised
