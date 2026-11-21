#!/usr/bin/env python3
"""Bisect a red scheduled main T3 to the merge that broke it (#4574, plan on #2048).

scripts/main_t3.py runs the whole app suite on main every few hours and, when it fails, opens one "Main T3 failed on
<sha7>" issue that lists the merges since the last green `main-t3` commit. This script narrows that list to one merge.

What it does, after a `failure` (never after `error`, which proves nothing about main):
1. Takes the failing test classes from the red run's own manifests (the red run's evidence folder), grouped by plan.
2. Takes the first-parent commits in `last green..red`, oldest first. The red head is known to fail; the last green is
   known to pass.
3. Bisects them. Each probe checks out one commit and runs only the failing classes through lane-runner.py's T3
   machinery (the same build, simulator clone, crash-flood stop and retries as the whole run). Cost: about log2(merges)
   probes, plus one repeat of the culprit when its failure was seen only in a probe.
4. Says what it found. A culprit gets one `ready` + `regression` issue naming the merge, its PR and the failing tests.
   Anything it cannot decide (a runner fault twice on one commit, a commit that does not build, a different test
   failing, the culprit passing on a repeat, no green in history, out of time or probes) is posted as a note on the
   open failure issue and names no PR.

Rules the pure part (`bisect`, `classify_probe`) keeps, tested in scripts/tests/test_main_t3_bisect.py:
- A name is given only when the commit before it passed and the commit itself failed in a way that repeats: the red
  run itself, or a probe that failed twice.
- A probe's verdict is `fail` only when a test of a watched class failed. A build failure or another test failing is
  `undecided`: it is not evidence about the watched tests.
- `undecided` is retried once, then ends the bisection as undecided.

The scripts/ folder is restored to the red commit's before each probe, so an old commit is tested by today's runner
(its flags, its crash handling) with its own app code and tests. Default taken: scripts/ only, not TestPlans/.

Subcommand:
- bisect --sha RED --run-url URL --evidence DIR: as above. Exits 0 whatever it finds; the red status is already set.

Environment: GH_TOKEN and GH_REPO (the workflow's). Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import main_t3 as t3

ROOT = t3.ROOT
CULPRIT_MARKER = '<!-- main-t3-culprit: %s -->'
CULPRIT_MARKER_RE = re.compile(r'<!-- main-t3-culprit: ([0-9a-f]{40}) -->')
MAX_PROBES = 8  # 2**8 = 256 merges; log2(30) is 5, and a runner-fault retry or the confirming repeat needs a few more
UNDECIDED_RETRIES = 1
BUDGET_SECONDS = 200 * 60  # the workflow job's limit minus what it spends before the first probe
DEFAULT_AREA = 'area: groundwork'
PR_NUMBER = re.compile(r'Merge pull request #(\d+)|\(#(\d+)\)\s*$')

PASS, FAIL, UNDECIDED = 'pass', 'fail', 'undecided'


# ---- Pure logic (scripts/tests/test_main_t3_bisect.py) ---------------------------------------------

@dataclasses.dataclass
class Result:
    kind: str  # 'culprit' or 'undecided'
    sha: str | None  # the culprit
    reason: str
    probes: list  # [(sha, outcome)] in the order they ran; a retry or the confirming repeat is its own entry

    @property
    def runs(self) -> int:
        return len(self.probes)


def class_of(test: str) -> str:
    """'SpokenMarginsAppTests/FooTests/testBar' -> 'SpokenMarginsAppTests/FooTests'."""
    return '/'.join(test.split('/')[:2])


def failing_classes(chosen: dict) -> dict:
    """{plan: sorted classes} of the tests that failed in the red run, from main_t3.pick_manifests' output.

    A class goes under each plan that saw one of its tests fail, so a class split across plans runs where it broke."""
    grouped = {}
    for plan, (manifest, fresh) in chosen.items():
        for source in (manifest, fresh):
            for step in (source or {}).get('steps', []):
                for test, record in (step.get('tests') or {}).items():
                    if record.get('status') == 'failed':
                        grouped.setdefault(plan, set()).add(class_of(test))
    return {plan: sorted(classes) for plan, classes in grouped.items()}


def watched_tests(grouped: dict) -> set:
    return {c for classes in grouped.values() for c in classes}


def classify_probe(verdict: str, results: dict, watched: set) -> str:
    """pass / fail / undecided for one probe run of the watched classes (lane-runner.py's verdict, main_t3's results)."""
    if verdict == 'PASS':
        return PASS
    if verdict != 'FAIL':
        return UNDECIDED  # INCONCLUSIVE: a runner fault, no simulator, a crash flood
    failed = [t for t, _ in results.get('failed', [])]
    if not failed:
        return UNDECIDED  # the build or a plan failed with no test result; says nothing about the watched tests
    if any(class_of(t) in watched for t in failed):
        return FAIL
    return UNDECIDED  # another test failed here: a different problem, not the one being chased


def bisect(commits: list, probe, max_probes: int = MAX_PROBES, time_left=lambda: True) -> Result:
    """Find the first failing commit in `commits` (oldest first). The last one is known to fail and the commit before
    the first is known to pass. `probe(sha)` returns PASS, FAIL or UNDECIDED; `time_left()` is False when out of time."""
    if not commits:
        return Result('undecided', None, 'there are no commits between the last green and the red one', [])
    probes = []

    def run(sha):
        """One probe, retried once when undecided. Returns the outcome, or None when out of probes or time."""
        outcome = UNDECIDED
        for _ in range(1 + UNDECIDED_RETRIES):
            if len(probes) >= max_probes:
                return None
            if not time_left():
                return None
            outcome = probe(sha)
            probes.append((sha, outcome))
            if outcome != UNDECIDED:
                break
        return outcome

    def undecided(reason):
        return Result('undecided', None, reason, probes)

    good, bad = -1, len(commits) - 1
    while bad - good > 1:
        mid = (good + bad) // 2
        outcome = run(commits[mid])
        if outcome is None:
            return undecided(f'out of probes or time with {bad - good} commits still possible')
        if outcome == UNDECIDED:
            return undecided(f'{commits[mid][:7]} could not be tested (the run was undecided twice)')
        if outcome == PASS:
            good = mid
        else:
            bad = mid
    culprit = commits[bad]
    if bad != len(commits) - 1:
        # Its failure was seen once, in a probe. The red head's was seen by the whole run, with its own retries.
        again = run(culprit)
        if again is None:
            return undecided(f'out of probes or time before {culprit[:7]} could be repeated')
        if again != FAIL:
            return undecided(f'{culprit[:7]} failed once and then {"passed" if again == PASS else "could not be tested"}'
                             ': a flaky test, not a culprit')
    return Result('culprit', culprit, f'{culprit[:7]} is the first failing commit', probes)


def pr_number(subject: str) -> int | None:
    """The PR a first-parent commit subject names: 'Merge pull request #12 from x/y' or a squash 'Title (#12)'."""
    match = PR_NUMBER.search(subject)
    return int(match.group(1) or match.group(2)) if match else None


def area_label(labels: list) -> str:
    """The one area label to carry over from the culprit PR, else Groundwork (an issue carries exactly one)."""
    areas = sorted({name for name in labels if name.startswith('area: ')})
    return areas[0] if len(areas) == 1 else DEFAULT_AREA


def culprit_title(subject: str, pr: int | None, tests: list) -> str:
    first = t3.short_test(tests[0]) if tests else 'a test'
    more = f' and {len(tests) - 1} more' if len(tests) > 1 else ''
    return t3.truncate(f'Main T3 red: {"#" + str(pr) if pr else subject} broke {first}{more}', 120)


def culprit_body(sha: str, subject: str, pr: int | None, red: str, green: str, run_url: str, tests: list, result: Result,
                 failure_issue: str | None) -> str:
    named = f'PR #{pr}' if pr else f'the merge `{subject}`'
    probes = ', '.join(f'`{s[:7]}` {o}' for s, o in result.probes) or 'none needed: one merge since the last green'
    lines = [CULPRIT_MARKER % sha, '',
             '## Outcome', '',
             f'`main` passes the whole app suite again, with {named} fixed forward or reverted.', '',
             '## Evidence', '',
             f'- The scheduled T3 on main (`main-t3`) failed on `{red[:7]}`: {run_url}',
             f'- Bisected by scripts/main_t3_bisect.py over the first-parent commits in `{green[:7]}..{red[:7]}`. First '
             f'failing commit: `{sha}` ({subject}).',
             f'- Probes: {probes}.',
             f'- Failing tests ({len(tests)}): ' + ', '.join(f'`{t3.short_test(t)}`' for t in tests[:20]) +
             (f' and {len(tests) - 20} more' if len(tests) > 20 else ''),
             ]
    if failure_issue:
        lines.append(f'- The failure issue for the run: {failure_issue}')
    lines += ['', '## Done when', '',
              '1. The failing tests pass on `main`, by a fix forward or by reverting the merge (a revert goes first '
              'when the fix is not quick).',
              '2. The test that caught it is kept, or the PR names the layer that should have and adds a test there.',
              '3. `main-t3` is green on the commit that closes this issue.', '',
              '## Must not break', '',
              'The journeys the merge touched (docs/journeys.md), packets, the database, and the owner\'s Library and '
              'recordings.', '',
              '_Opened by scripts/main_t3_bisect.py from .github/workflows/main-t3.yml (#4574)._']
    return '\n'.join(lines)


def undecided_note(result: Result, red: str, green: str | None, run_url: str) -> str:
    probes = ', '.join(f'`{s[:7]}` {o}' for s, o in result.probes) or 'none'
    return (f'Bisection of the red run on `{red[:7]}` ({run_url}) could not decide, so it names no PR: {result.reason}. '
            f'Probes: {probes}. The merges since the last green'
            f'{" (`" + green[:7] + "`)" if green else ""} are listed above.')


def find_open_culprit_issue(issues: list, sha: str) -> dict | None:
    """The open culprit issue for this commit (its marker, from the workflow's bot or a collaborator)."""
    for issue in sorted(issues, key=lambda i: i['number']):
        found = CULPRIT_MARKER_RE.search(issue.get('body') or '')
        if 'pull_request' not in issue and found and found.group(1) == sha and t3.trusted(issue):
            return issue
    return None


# ---- Git and the runs -------------------------------------------------------------------------------

def git(*args: str) -> str:
    done = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(f'git {" ".join(args[:3])}: {done.stderr.strip()[:300]}')
    return done.stdout


def merges_in_range(green: str, red: str) -> list:
    """(sha, subject) of the first-parent commits in green..red, oldest first."""
    out = git('log', '--first-parent', '--reverse', '--format=%H %s', f'{green}..{red}')
    return [tuple(line.split(' ', 1)) if ' ' in line else (line, '') for line in out.splitlines() if line.strip()]


def check_out(sha: str, red: str) -> None:
    """The commit's tree, with scripts/ from the red commit (see the module docstring), and its LFS files."""
    git('checkout', '--force', '--detach', sha)
    git('checkout', red, '--', 'scripts')
    token = os.environ.get('GH_TOKEN')
    if token:
        import base64
        auth = base64.b64encode(f'x-access-token:{token}'.encode()).decode()
        # The checkout keeps no credentials; the job token is handed to this one command (main-t3.yml does the same).
        git('-c', f'http.https://github.com/.extraheader=AUTHORIZATION: basic {auth}', 'lfs', 'pull')


def make_probe(grouped: dict, watched: set, red: str, run_id: str, evidence: Path):
    lane = t3.load_lane_runner()
    lane.T3_TIMEOUT = t3.RUN_TIMEOUT
    count = [0]

    def probe(sha: str) -> str:
        count[0] += 1
        out = evidence / f'bisect-{count[0]:02d}-{sha[:7]}'
        out.mkdir(parents=True, exist_ok=True)
        try:
            check_out(sha, red)
            verdict, _where, _ran, details, _crashes, _ = lane._run_t3_grouped(
                {plan: list(classes) for plan, classes in grouped.items()}, f'bisect-{sha[:7]}-{run_id}', out)
        except Exception as error:  # noqa: BLE001 - a fault in the machinery decides nothing about the commit
            print(f'Probe {sha[:7]} stopped: {error!r}', flush=True)
            return UNDECIDED
        results = t3.collect_results(t3.pick_manifests(t3.read_manifests(out)))
        outcome = classify_probe(verdict, results, watched)
        print(f'Probe {sha[:7]}: {verdict} -> {outcome} ({len(results["failed"])} failed, {results["passed"]} passed; '
              f'{"; ".join(str(d) for d in details[:2])})', flush=True)
        return outcome

    return probe


def pr_area(pr: int | None) -> str:
    if pr is None:
        return DEFAULT_AREA
    try:
        labels = json.loads(t3.gh('api', f'repos/{t3.repo()}/issues/{pr}'))['labels']
        return area_label([label['name'] for label in labels])
    except (RuntimeError, KeyError, TypeError, ValueError):
        return DEFAULT_AREA


# ---- The command ------------------------------------------------------------------------------------

def command_bisect(args) -> int:
    os.chdir(ROOT)
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    red = args.sha
    chosen = t3.pick_manifests(t3.read_manifests(evidence))
    # The red run's own manifests are the evidence; the probes write beside them in bisect-NN folders.
    grouped = failing_classes(chosen)
    results = t3.collect_results(chosen)
    failed_tests = [t for t, _ in results['failed']]
    failure_issue = t3.find_open_issue(t3.open_issues())
    green = None
    try:
        green = t3.find_last_green(red)
    except (RuntimeError, KeyError, TypeError, ValueError) as error:
        print(f'Could not find the last green {t3.CONTEXT}: {error}', flush=True)
    if not grouped:
        result = Result('undecided', None, 'the red run named no failing test (a build or plan failure), so there is '
                        'nothing to bisect on', [])
    elif not green:
        result = Result('undecided', None, f'no green {t3.CONTEXT} in the last {t3.HISTORY_PAGES * 100} commits', [])
    else:
        commits = merges_in_range(green, red)
        subjects = dict(commits)
        started = time.monotonic()
        probe = make_probe(grouped, watched_tests(grouped), red, args.run_id, evidence)
        try:
            result = bisect([sha for sha, _ in commits], probe, time_left=lambda: time.monotonic() - started < args.budget)
        finally:
            try:
                git('checkout', '--force', '--detach', red)
            except RuntimeError as error:
                print(f'Could not return to {red[:7]}: {error}', flush=True)
    (evidence / 'main-t3-bisect.json').write_text(json.dumps(
        {'red': red, 'green': green, 'classes': grouped, 'kind': result.kind, 'culprit': result.sha,
         'reason': result.reason, 'probes': result.probes}, indent=2) + '\n')
    print(f'Bisection: {result.kind}: {result.reason} ({result.runs} runs)', flush=True)
    try:
        if result.kind == 'culprit':
            issues = t3.open_issues()
            if find_open_culprit_issue(issues, result.sha) is None:
                subject = subjects.get(result.sha, '')
                pr = pr_number(subject)
                body = culprit_body(result.sha, subject, pr, red, green, args.run_url, failed_tests, result,
                                    failure_issue['html_url'] if failure_issue else None)
                url = t3.gh('issue', 'create', '-R', t3.repo(), '--title', culprit_title(subject, pr, failed_tests),
                            '--label', 'ready', '--label', t3.ISSUE_LABEL, '--label', pr_area(pr),
                            '--body-file', '-', stdin=body).strip()
                print(f'Culprit issue: {url}', flush=True)
                note = f'Bisected to `{result.sha[:7]}` ({subject}): {url}'
            else:
                note = f'Bisected to `{result.sha[:7]}`; its issue is already open.'
        else:
            note = undecided_note(result, red, green, args.run_url)
        if failure_issue:
            t3.gh('issue', 'comment', str(failure_issue['number']), '-R', t3.repo(), '--body-file', '-', stdin=note)
    except (RuntimeError, KeyError, ValueError) as error:
        print(f'::warning::Could not post the bisection result: {error}', flush=True)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    run = sub.add_parser('bisect')
    run.add_argument('--sha', required=True, help='the red commit (full SHA)')
    run.add_argument('--run-url', required=True)
    run.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID', 'local'))
    run.add_argument('--evidence', default=os.environ.get('SM_LANE_EVIDENCE_DIR', str(ROOT / 'artifacts/main-t3')),
                     help="the red run's evidence folder (its verify-* manifests); probes write beside them")
    run.add_argument('--budget', type=int, default=BUDGET_SECONDS, help='seconds before it stops starting probes')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full 40-character commit SHA')
    return command_bisect(args)


if __name__ == '__main__':
    sys.exit(main())
