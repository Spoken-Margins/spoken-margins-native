#!/usr/bin/env python3
"""App tests on a branch, by dispatch (#4839, step 2 of docs/workstreams/retire-mac-ci.md).

.github/workflows/branch-t3.yml runs this on a hosted Mac when a session or the owner asks for app tests on a branch
(the job `/lane T3` used to be). It is a request, never a gate: it sets no commit status, so no merge waits on it.

Subcommands:
- run --sha SHA --tests "A B" --out FILE: the named test classes (or, with none, both whole plans) through
  main_t3.py's T3 machinery on a fresh simulator clone. It makes no GitHub call and needs no token: the job that runs
  it, on the branch's own code, holds `contents: read` only. It writes FILE (the result) and exits 0 only on a pass.
- report --result FILE --run-url URL [--pr N]: the trusted job, running main's copy of this file with
  `pull-requests: write`, posts the result on pull request N and in the job summary. The result is data here.

Test classes are named as in `tests:` lines (`LibraryTests` or `LibraryTests/testOne`), at most MAX_SELECTORS. A name no
plan holds fails the run (verify-tests.py's rule: a named test that doesn't exist is a failure). Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_t3 as T  # noqa: E402

ROOT = T.ROOT
MARKER = '<!-- branch-t3 -->'
MAX_SELECTORS = 40
SELECTOR = re.compile(r'[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?')
APP_TEST_TARGET = 'SpokenMarginsAppTests'
COMMENT_LIMIT = 60000  # GitHub's comment limit is 65536
STATES = ('success', 'failure', 'error')


# ---- Pure logic (scripts/tests/test_branch_t3.py) -------------------------------------------------

def parse_tests(text: str) -> list:
    """Selectors from a dispatch input: commas or whitespace between names, nothing else allowed in a name."""
    names = [n for n in re.split(r'[,\s]+', text or '') if n]
    bad = [n for n in names if not SELECTOR.fullmatch(n)]
    if bad:
        raise ValueError(f'not a test class or Class/method name: {", ".join(bad[:5])}')
    if len(names) > MAX_SELECTORS:
        raise ValueError(f'{len(names)} tests named; the most is {MAX_SELECTORS}. Name classes, or none for the whole suite.')
    names = [n[:-2] if n.endswith('()') else n for n in names]  # test ids carry no parentheses
    if APP_TEST_TARGET in names:
        raise ValueError(f'{APP_TEST_TARGET} is the test target, not a test class; name classes, or none for the whole suite')
    return list(dict.fromkeys(names))


def full_selector(selector: str) -> str:
    return selector if selector.startswith(APP_TEST_TARGET + '/') else f'{APP_TEST_TARGET}/{selector}'


def plan_for_tests(selectors: list, plans: dict) -> tuple:
    """Group selectors by the plans holding them; selectors no plan holds are returned separately. A class split
    across plans goes to each plan that runs part of it, or the rest of it would silently not run."""
    grouped, unknown = {}, []
    for selector in selectors:
        full = full_selector(selector)
        holding = [p for p, tests in plans.items() if any(t == full or t.startswith(full + '/') for t in tests)]
        for plan in holding:
            grouped.setdefault(plan, []).append(full)
        if not holding:
            unknown.append(selector)
    return grouped, unknown


def group(names: list, plans: dict) -> tuple:
    """({plan: selectors}, unknown names). No names means both whole plans (an empty selector list). `plans` is
    {plan: set of test ids}."""
    if not names:
        return {plan: [] for plan in plans}, []
    return plan_for_tests(names, plans)


def comment_body(result: dict, run_url: str) -> str:
    """The pull request comment for a result read from the test job's file (untrusted text is cut and quoted)."""
    state = result.get('state') if result.get('state') in STATES else 'error'
    sha = re.sub(r'[^0-9a-f]', '', str(result.get('sha') or ''))[:40]
    words = {'success': 'passed', 'failure': 'FAILED', 'error': 'did not finish (a runner fault, nothing proven)'}[state]
    tests = result.get('tests') or []
    scope = ', '.join(f'`{t}`' for t in tests[:MAX_SELECTORS]) if tests else 'the whole app suite (both plans)'
    res = result.get('results') or {}
    failed = res.get('failed') or []
    failed_count = max(len(failed), int(res.get('failed_count') or 0))  # the list is cut; the count is not
    lines = [MARKER, f'**branch-t3 {words}** on `{sha[:7]}`: {scope}.', '',
             f'- {T.truncate(str(result.get("description") or ""), 300)}',
             f'- Passed: {int(res.get("passed") or 0)}. Failed: {failed_count}.']
    if res.get('retried'):
        lines.append('- Passed on retry (counts as a pass): ' +
                     ', '.join(T.short_test(str(t)) for t in res['retried'][:20]))
    if failed:
        lines += ['', f'Failing tests ({failed_count}):']
        for entry in failed[:T.FAILURES_SHOWN]:
            test, messages = (list(entry) + [[]])[:2] if isinstance(entry, (list, tuple)) else (str(entry), [])
            said = ' | '.join(str(m) for m in messages)
            lines.append(f'- `{T.short_test(str(test))}`' + (f': {T.truncate(said, 300)}' if said else ''))
        if failed_count > min(len(failed), T.FAILURES_SHOWN):
            lines.append(f'- and {failed_count - min(len(failed), T.FAILURES_SHOWN)} more; the run\'s evidence has them all')
    elif state != 'success':
        lines += ['', 'What the run said:']
        lines += [f'- {T.truncate(str(d), 300)}' for d in (result.get('details') or [])[:10]]
    lines += ['', f'Run and evidence: {run_url}. A request, not a gate: it sets no status and holds no merge.']
    body = '\n'.join(lines)
    return body if len(body) <= COMMENT_LIMIT else body[:COMMENT_LIMIT - 40] + '\n\n(cut to fit GitHub\'s limit)'


# ---- Commands -------------------------------------------------------------------------------------

def command_run(args) -> int:
    os.chdir(ROOT)
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    out = Path(args.out)
    names, verdict, ran, crashes = [], 'INCONCLUSIVE', 'nothing', 'unknown'
    details, results = [], {'passed': 0, 'failed': [], 'retried': []}
    try:
        names = parse_tests(args.tests)
        lane = T.load_lane_t3()
        from test_inventory import plan_tests
        plans = {plan: plan_tests(ROOT, name) for plan, name in lane.PLANS.items()}
        grouped, unknown = group(names, plans)
        if unknown:
            verdict, details = 'FAIL', [f'No app test plan holds: {", ".join(unknown)}. A named test that does not '
                                        'exist is a failure.']
        else:
            verdict, ran, details, crashes, results = T.run_suite(args.sha, args.run_id, evidence, grouped=grouped,
                                                                  label='branch', log_retries=False)
    except ValueError as error:
        verdict, details = 'FAIL', [str(error)]
    except Exception as error:  # noqa: BLE001 - a stop in the machinery is a runner fault, not the branch's
        verdict, details = 'INCONCLUSIVE', [f'branch_t3.py stopped: {error!r}']
    state = T.VERDICT_STATE.get(verdict, 'error')
    state = T.state_after_build_fault(state, results, T.fetch_fault_in_builds(evidence))
    text = T.description(state, results, details)
    results = {'passed': results.get('passed', 0), 'failed_count': len(results.get('failed', [])), 'retried': results.get('retried', [])[:20],  # small: it travels as a job output
               'failed': [[t, [T.truncate(m, 300) for m in msgs[:3]]] for t, msgs in results.get('failed', [])[:T.FAILURES_SHOWN]]}
    out.write_text(json.dumps({'sha': args.sha, 'state': state, 'verdict': verdict, 'description': text, 'ran': ran,
                               'crashes': crashes, 'tests': names, 'results': results,
                               'details': [T.truncate(d, 500) for d in details[:15]]}, indent=2) + '\n')
    T.write_outputs(state=state)
    T.write_summary('\n'.join([f'## branch-t3 on `{args.sha[:7]}`: {state}', '', text, '', f'Ran: {ran}',
                               f'Crashes: {crashes}', '', *[f'- {T.truncate(d, 500)}' for d in details[:40]]]))
    print(f'branch-t3 on {args.sha[:7]}: {state} ({text})', flush=True)
    return 0 if state == 'success' else 1


def command_report(args) -> int:
    path = Path(args.result)
    try:
        result = json.loads(path.read_text())
        if not isinstance(result, dict):
            raise ValueError('not an object')
    except (OSError, ValueError):
        result = {'state': 'error', 'sha': args.sha, 'description': 'the test job left no result (it stopped early)'}
    body = comment_body(result, args.run_url)
    T.write_summary(body)
    print(body)
    if args.pr:
        T.gh('api', '-X', 'POST', f'repos/{T.repo()}/issues/{args.pr}/comments', '--input', '-',
             stdin=json.dumps({'body': body + '\n'}))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    run = sub.add_parser('run')
    run.add_argument('--sha', required=True)
    run.add_argument('--tests', default='')
    run.add_argument('--out', required=True)
    run.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID', 'local'))
    run.add_argument('--evidence', default=os.environ.get('SM_LANE_EVIDENCE_DIR', str(ROOT / 'artifacts/branch-t3')))
    report = sub.add_parser('report')
    report.add_argument('--result', required=True)
    report.add_argument('--run-url', required=True)
    report.add_argument('--sha', default='')
    report.add_argument('--pr', type=int, default=0)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', getattr(args, 'sha', '') or '0' * 40):
        parser.error('--sha must be a full 40-character commit SHA')
    return {'run': command_run, 'report': command_report}[args.command](args)


if __name__ == '__main__':
    sys.exit(main())
