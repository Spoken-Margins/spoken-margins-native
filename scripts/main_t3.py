#!/usr/bin/env python3
"""The scheduled T3 on main (#4573, plan on #2048): the whole app test suite on main's head, recorded as a commit status.

Owner decision 2026-11-18: no per-PR simulator runs. Instead .github/workflows/main-t3.yml runs this every 3 hours
and at two fixed ticks before the owner's phone builds, only when main's head has no `main-t3` status yet, and
releases refuse a commit without a green one (#4575). It is the trunk's one simulator run: hosted-integration.yml no
longer runs on a push.

The contract other tools read (#4575's release gate):
- After each run, a commit status on the tested SHA with context `main-t3`: `success` (every test passed), `failure`
  (a real test or build failure) or `error` (a runner fault, nothing proven: no simulator, XCTest never connected, a
  crash flood). `target_url` is the Actions run; the description is "1870 passed" or "3 failed: Class/testA, ...",
  cut to GitHub's 140 characters. A run in progress leaves `pending`.
- "Main has changed" means main's head SHA has no `main-t3` status yet. Two additions, which only decide when this
  workflow runs: a `pending` older than STALE_PENDING (a job killed too hard to clean up) counts as none, and one
  `error` gets one automatic retry on the next tick (a runner fault proves nothing about main). A `failure` is never
  run again on the same commit (owner, 2026-11-18): verify-tests.py's in-run retries already tell a flake from a real
  failure. A manual dispatch with `force` always runs.

Subcommands:
- decide --sha SHA: print and write `run=true|false` to $GITHUB_OUTPUT.
- run --sha SHA --run-url URL: set `pending`, run both app plans (AppBehavior and AudioAdapters, every test in them)
  through lane-runner.py's T3 machinery on a fresh simulator clone, set the final status, and on `failure` open or
  update the one open "Main T3 failed on <sha7>" issue (label `regression`, marker MARKER). On `success` it closes
  that issue with a note. Tests that failed and passed on a retry are logged on the flake tally (#2176) as the lane
  does. Exits 0 only on `success`.
- lost --sha SHA --run-url URL: the job died after `pending`; set `error` so the next tick retries.

Bisecting a red main is #4574's: the issue names the failing tests, the previous green SHA and the merges between.
Environment: GH_TOKEN and GH_REPO (the workflow's). Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTEXT = 'main-t3'
DESCRIPTION_LIMIT = 140  # GitHub's limit on a commit status description
STALE_PENDING = datetime.timedelta(hours=5)  # main-t3.yml's job limit is 3 h; a pending older than this was lost
ERROR_RETRIES = 1
MARKER = '<!-- main-t3-failure -->'
STATE_MARKER = re.compile(r'<!-- main-t3-state: (\{.*?\}) -->')
ISSUE_LABEL = 'regression'
BOT = 'github-actions[bot]'
TRUSTED_ASSOCIATIONS = ('OWNER', 'MEMBER', 'COLLABORATOR')
TARGET_PREFIX = 'SpokenMarginsAppTests/'
PLANS = ('app', 'adapters')  # lane-runner.py's PLANS keys: AppBehavior and AudioAdapters, in that order
BODY_LIMIT = 60000  # GitHub's issue body limit is 65536
FAILURES_SHOWN = 60
MERGES_SHOWN = 40
HISTORY_PAGES = 3  # 300 commits back for the last green
# The whole plans on a 3-core hosted Mac: hosted-integration.yml needed an hour for --plan app alone (#2596). This is
# lane-runner.py's budget for each verify-tests.py run (build, then each plan), replacing its per-PR T3_TIMEOUT.
RUN_TIMEOUT = 100 * 60
VERDICT_STATE = {'PASS': 'success', 'FAIL': 'failure', 'INCONCLUSIVE': 'error'}


# ---- Pure logic (scripts/tests/test_main_t3.py) ---------------------------------------------------

def parse_time(stamp: str) -> datetime.datetime:
    return datetime.datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)


def should_run(statuses: list, now: datetime.datetime, force: bool = False) -> tuple:
    """(run?, why) from the commit's statuses as GitHub lists them (newest first, any context)."""
    if force:
        return True, 'forced by a manual dispatch'
    ours = sorted((s for s in statuses if s.get('context') == CONTEXT),
                  key=lambda s: s.get('created_at') or '', reverse=True)
    if not ours:
        return True, f'no {CONTEXT} status on this commit yet'
    newest = ours[0]
    state = newest.get('state')
    if state == 'pending':
        age = now - parse_time(newest['created_at'])
        if age > STALE_PENDING:
            return True, f'its {CONTEXT} run has been pending for {int(age.total_seconds() // 3600)} h (lost)'
        return False, f'a {CONTEXT} run is in progress on this commit'
    if state == 'error':
        errors = sum(1 for s in ours if s.get('state') == 'error')
        if errors <= ERROR_RETRIES:
            return True, f'its {CONTEXT} run hit a runner fault; one retry'
        return False, f'{errors} {CONTEXT} runner faults on this commit already; waiting for main to move'
    return False, f'already tested: {CONTEXT} {state}'


def short_test(name: str) -> str:
    return name[len(TARGET_PREFIX):] if name.startswith(TARGET_PREFIX) else name


def pick_manifests(found: dict) -> dict:
    """One manifest per plan from {output folder name: manifest}: an overload rerun (`-retry`) replaces the first run,
    and a fresh-clone rerun (`-fresh`) counts only for its failures (lane-runner.py: it is evidence otherwise)."""
    chosen = {}
    for plan in PLANS:
        base = f'verify-{plan}'
        manifest = found.get(base + '-retry') or found.get(base)
        if manifest is None:
            continue
        fresh = found.get(base + '-fresh')
        chosen[plan] = (manifest, fresh)
    return chosen


def collect_results(chosen: dict) -> dict:
    """Passed count, failing tests with their messages, and tests that passed on a retry."""
    passed, failed, retried = 0, {}, set()
    for manifest, fresh in chosen.values():
        for source in (manifest, fresh):
            if not source:
                continue
            for step in source.get('steps', []):
                retried.update(step.get('passed_on_retry') or [])
                for test, record in (step.get('tests') or {}).items():
                    if source is manifest and record.get('status') == 'passed':
                        passed += 1
                    if record.get('status') == 'failed':
                        failed.setdefault(test, [])
                        for message in record.get('retry_failures') or []:
                            if message and message not in failed[test]:
                                failed[test].append(message)
                    if record.get('passed_on_retry'):
                        retried.add(test)
    return {'passed': passed, 'failed': [(t, failed[t]) for t in sorted(failed)], 'retried': sorted(retried)}


def truncate(text: str, limit: int) -> str:
    text = ' '.join(text.split())
    return text if len(text) <= limit else text[:limit - 3].rstrip() + '...'


def description(state: str, results: dict, details: list) -> str:
    """The status line: '1870 passed', '3 failed: A/testB, ...', or the runner fault, within 140 characters."""
    passed, failed = results.get('passed', 0), results.get('failed', [])
    if state == 'success':
        retried = len(results.get('retried', []))
        return truncate(f'{passed} passed' + (f', {retried} on retry' if retried else ''), DESCRIPTION_LIMIT)
    if state == 'pending':
        return 'running the whole app suite'
    if state == 'failure':
        if failed:
            return truncate(f'{len(failed)} failed: ' + ', '.join(short_test(t) for t, _ in failed), DESCRIPTION_LIMIT)
        first = next((d for d in details if d), 'the build or a plan failed')
        return truncate(f'failed, no test result: {first}', DESCRIPTION_LIMIT)
    first = next((d for d in details if d), 'no test result')
    return truncate(f'runner fault: {first}', DESCRIPTION_LIMIT)


def status_payload(state: str, run_url: str, text: str) -> dict:
    if state not in ('success', 'failure', 'error', 'pending'):
        raise ValueError(f'not a commit status state: {state}')
    return {'state': state, 'context': CONTEXT, 'target_url': run_url, 'description': truncate(text, DESCRIPTION_LIMIT)}


def last_green(nodes: list, exclude: str = '') -> str | None:
    """The newest commit in a history listing whose main-t3 status is a success (GraphQL: oid, status.context.state)."""
    for node in nodes:
        context = ((node.get('status') or {}).get('context') or {})
        if node.get('oid') != exclude and context.get('state') == 'SUCCESS':
            return node['oid']
    return None


def trusted(item: dict) -> bool:
    return (item.get('user') or {}).get('login') == BOT or item.get('author_association') in TRUSTED_ASSOCIATIONS


def find_open_issue(issues: list) -> dict | None:
    """The open failure issue this script keeps (its marker, from the workflow's bot or a collaborator), oldest first."""
    found = [i for i in issues if 'pull_request' not in i and MARKER in (i.get('body') or '') and trusted(i)]
    return min(found, key=lambda i: i['number']) if found else None


def issue_state(issue: dict | None) -> dict:
    match = STATE_MARKER.search((issue or {}).get('body') or '')
    if not match:
        return {}
    try:
        return json.loads(match.group(1))
    except ValueError:
        return {}


def issue_title(sha: str) -> str:
    return f'Main T3 failed on {sha[:7]}'


def issue_body(sha: str, run_url: str, results: dict, details: list, green: str | None, merges: list,
               first_failed: str | None = None) -> str:
    first_failed = first_failed or sha
    failed = results.get('failed', [])
    state = {'first_failed': first_failed, 'latest': sha, 'last_green': green,
             'failed': [t for t, _ in failed][:200]}
    lines = [MARKER, f'<!-- main-t3-state: {json.dumps(state, sort_keys=True).replace("-->", "")} -->', '',
             f'The scheduled T3 on main (`main-t3`, #4573) failed on `{sha}`: {run_url}', '']
    if first_failed != sha:
        lines += [f'It first failed on `{first_failed}` and is still failing.', '']
    lines.append(f'- Last green `main-t3`: `{green}`' if green else
                 f'- Last green `main-t3`: none in the last {HISTORY_PAGES * 100} commits')
    lines.append(f'- Passed: {results.get("passed", 0)}. Failed: {len(failed)}.')
    if results.get('retried'):
        lines.append(f'- Passed on retry (counted as passes, logged on the flake tally): '
                     f'{", ".join(short_test(t) for t in results["retried"])}')
    lines += ['', f'## Failing tests ({len(failed)})', '']
    if failed:
        for test, messages in failed[:FAILURES_SHOWN]:
            said = ' | '.join(messages)
            lines.append(f'- `{short_test(test)}`' + (f': {truncate(said, 400)}' if said else ': no assertion message kept'))
        if len(failed) > FAILURES_SHOWN:
            lines.append(f'- and {len(failed) - FAILURES_SHOWN} more; the run\'s evidence artifact has them all')
    else:
        lines.append('No single test failed; the build or a plan did. What the run said:')
        lines += [f'- {truncate(d, 400)}' for d in details[:15]]
    if green:
        lines += ['', f'## Merges since the last green ({len(merges)})', '',
                  f'First-parent commits in `{green[:7]}..{sha[:7]}`:', '']
        lines += [f'- {m}' for m in merges[:MERGES_SHOWN]]
        if len(merges) > MERGES_SHOWN:
            lines.append(f'- and {len(merges) - MERGES_SHOWN} more')
    lines += ['', 'Evidence: the run\'s `main-t3-evidence` artifact (logs and manifests). Finding the culprit is '
              '#4574. This issue is updated by each failing run and closed by the first green one.', '',
              '_Posted by scripts/main_t3.py from .github/workflows/main-t3.yml._']
    body = '\n'.join(lines)
    return body if len(body) <= BODY_LIMIT else body[:BODY_LIMIT - 40] + '\n\n(cut to fit GitHub\'s limit)'


def still_failing_note(sha: str, run_url: str, results: dict, previous: list) -> str:
    now = [t for t, _ in results.get('failed', [])]
    new = [short_test(t) for t in now if t not in previous]
    fixed = [short_test(t) for t in previous if t not in now]
    parts = [f'Still failing on `{sha[:7]}` ({run_url}): {len(now)} failed, {results.get("passed", 0)} passed.']
    if new:
        parts.append(f'Newly failing: {", ".join(new[:20])}.')
    if fixed:
        parts.append(f'Now passing: {", ".join(fixed[:20])}.')
    return ' '.join(parts)


# ---- GitHub ---------------------------------------------------------------------------------------

def gh(*args: str, stdin: str | None = None) -> str:
    done = subprocess.run(['gh', *args], input=stdin, capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(f'gh {" ".join(args[:3])}: {done.stderr.strip()[:300]}')
    return done.stdout


def repo() -> str:
    return os.environ['GH_REPO']


def statuses(sha: str) -> list:
    return json.loads(gh('api', f'repos/{repo()}/commits/{sha}/statuses?per_page=100'))


def set_status(sha: str, payload: dict) -> None:
    gh('api', '-X', 'POST', f'repos/{repo()}/statuses/{sha}', '--input', '-', stdin=json.dumps(payload))
    print(f'{CONTEXT} on {sha[:7]}: {payload["state"]} ({payload["description"]})', flush=True)


HISTORY_QUERY = '''query($owner: String!, $name: String!, $expr: String!, $after: String) {
  repository(owner: $owner, name: $name) { object(expression: $expr) { ... on Commit {
    history(first: 100, after: $after) { pageInfo { hasNextPage endCursor }
      nodes { oid status { context(name: "%s") { state } } } } } } } }''' % CONTEXT


def find_last_green(sha: str) -> str | None:
    owner, name = repo().split('/', 1)
    after = None
    for _ in range(HISTORY_PAGES):
        args = ['api', 'graphql', '-f', f'query={HISTORY_QUERY}', '-f', f'owner={owner}', '-f', f'name={name}',
                '-f', f'expr={sha}']
        if after:
            args += ['-f', f'after={after}']
        history = json.loads(gh(*args))['data']['repository']['object']['history']
        found = last_green(history['nodes'], exclude=sha)
        if found or not history['pageInfo']['hasNextPage']:
            return found
        after = history['pageInfo']['endCursor']
    return None


def merges_between(green: str, sha: str) -> list:
    done = subprocess.run(['git', 'log', '--first-parent', '--format=%h %s', f'{green}..{sha}'], cwd=ROOT,
                          capture_output=True, text=True)
    return done.stdout.splitlines() if done.returncode == 0 else [f'(git log failed: {done.stderr.strip()[:200]})']


def open_issues() -> list:
    lines = gh('api', '--paginate', '--jq', '.[] | @json',
               f'repos/{repo()}/issues?state=open&labels={ISSUE_LABEL}&per_page=100')
    return [json.loads(line) for line in lines.splitlines() if line.strip()]


def report_failure(sha: str, run_url: str, results: dict, details: list) -> str:
    try:
        green = find_last_green(sha)
    except (RuntimeError, KeyError, TypeError, ValueError) as error:
        print(f'Could not find the last green {CONTEXT}: {error}', flush=True)
        green = None
    merges = merges_between(green, sha) if green else []
    issue = find_open_issue(open_issues())
    if issue is None:
        body = issue_body(sha, run_url, results, details, green, merges)
        return gh('issue', 'create', '-R', repo(), '--title', issue_title(sha), '--label', ISSUE_LABEL,
                  '--body-file', '-', stdin=body).strip()
    previous = issue_state(issue)
    body = issue_body(sha, run_url, results, details, green, merges, previous.get('first_failed'))
    number = str(issue['number'])
    gh('issue', 'edit', number, '-R', repo(), '--body-file', '-', stdin=body)
    gh('issue', 'comment', number, '-R', repo(), '--body-file', '-',
       stdin=still_failing_note(sha, run_url, results, previous.get('failed') or []))
    return issue['html_url']


def close_on_green(sha: str, run_url: str, results: dict) -> None:
    issue = find_open_issue(open_issues())
    if issue is None:
        return
    gh('issue', 'close', str(issue['number']), '-R', repo(), '--reason', 'completed', '--comment',
       f'`{CONTEXT}` passed on `{sha[:7]}` ({run_url}): {results["passed"]} passed. Closing; the next failing run '
       'opens a new issue.')


# ---- The run --------------------------------------------------------------------------------------

def load_lane_runner():
    spec = importlib.util.spec_from_file_location('lane_runner', ROOT / 'scripts/lane-runner.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_manifests(evidence: Path) -> dict:
    found = {}
    for output in evidence.glob('verify-*'):
        try:
            found[output.name] = json.loads((output / 'manifest.json').read_text())
        except (OSError, ValueError):
            continue
    return found


def run_suite(sha: str, run_id: str, evidence: Path):
    """lane-runner.py's T3 on a fresh clone with every test of both plans (no --only-testing). Returns
    (verdict, ran, details, crashes, results)."""
    lane = load_lane_runner()
    lane.T3_TIMEOUT = RUN_TIMEOUT
    grouped = {plan: [] for plan in PLANS}  # an empty selector list runs the whole plan
    verdict, where, ran, details, crashes, _ = lane._run_t3_grouped(grouped, f'main-{sha[:7]}-{run_id}', evidence)
    results = collect_results(pick_manifests(read_manifests(evidence)))
    try:
        lane.log_retry_passes(evidence, repo(), sha, run_id, lane.RepoTally(repo()))
    except Exception as error:  # noqa: BLE001 - the verdict is already decided
        print(f'Could not log the retry-passes: {error!r}', flush=True)
    return verdict, f'{where}; {ran}', details, crashes, results


def write_outputs(**values) -> None:
    path = os.environ.get('GITHUB_OUTPUT')
    if path:
        with open(path, 'a') as out:
            for key, value in values.items():
                out.write(f'{key}={value}\n')


def write_summary(text: str) -> None:
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a') as out:
            out.write(text + '\n')


def command_decide(args) -> int:
    now = datetime.datetime.now(datetime.timezone.utc)
    run, why = should_run(statuses(args.sha), now, args.force)
    print(f'{CONTEXT} on {args.sha[:7]}: {"run" if run else "skip"} ({why})')
    write_outputs(run=str(run).lower())
    write_summary(f'{CONTEXT} on `{args.sha[:7]}`: {"run" if run else "skip"}, {why}.')
    return 0


def command_run(args) -> int:
    os.chdir(ROOT)
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    set_status(args.sha, status_payload('pending', args.run_url, description('pending', {}, [])))
    try:
        verdict, ran, details, crashes, results = run_suite(args.sha, args.run_id, evidence)
    except Exception as error:  # noqa: BLE001 - a crash in the lane's machinery is a runner fault, not main's
        verdict, ran, details, crashes, results = ('INCONCLUSIVE', 'nothing', [f'main_t3.py stopped: {error!r}'],
                                                   'unknown', {'passed': 0, 'failed': [], 'retried': []})
    state = VERDICT_STATE.get(verdict, 'error')  # a crash flood with no failed test is INCONCLUSIVE there: `error`
    text = description(state, results, details)
    set_status(args.sha, status_payload(state, args.run_url, text))
    write_outputs(state=state)
    (evidence / 'main-t3.json').write_text(json.dumps({'sha': args.sha, 'state': state, 'verdict': verdict,
                                                        'description': text, 'ran': ran, 'crashes': crashes,
                                                        'results': results, 'details': details}, indent=2) + '\n')
    write_summary('\n'.join([f'## {CONTEXT} on `{args.sha[:7]}`: {state}', '', text, '', f'Ran: {ran}',
                             f'Crashes: {crashes}', '', *[f'- {truncate(d, 500)}' for d in details[:40]]]))
    try:
        if state == 'failure':
            print(f'Failure issue: {report_failure(args.sha, args.run_url, results, details)}', flush=True)
        elif state == 'success':
            close_on_green(args.sha, args.run_url, results)
    except (RuntimeError, KeyError, ValueError) as error:
        print(f'::warning::Could not update the {CONTEXT} failure issue: {error}', flush=True)
    return 0 if state == 'success' else 1


def command_lost(args) -> int:
    ours = [s for s in statuses(args.sha) if s.get('context') == CONTEXT]
    newest = max(ours, key=lambda s: s.get('created_at') or '', default=None)
    if newest and newest.get('state') == 'pending':
        set_status(args.sha, status_payload('error', args.run_url, 'runner fault: the job stopped before it reported'))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    decide = sub.add_parser('decide')
    decide.add_argument('--sha', required=True)
    decide.add_argument('--force', action='store_true')
    run = sub.add_parser('run')
    run.add_argument('--sha', required=True)
    run.add_argument('--run-url', required=True)
    run.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID', 'local'))
    run.add_argument('--evidence', default=os.environ.get('SM_LANE_EVIDENCE_DIR', str(ROOT / 'artifacts/main-t3')))
    lost = sub.add_parser('lost')
    lost.add_argument('--sha', required=True)
    lost.add_argument('--run-url', required=True)
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full 40-character commit SHA')
    return {'decide': command_decide, 'run': command_run, 'lost': command_lost}[args.command](args)


if __name__ == '__main__':
    sys.exit(main())
