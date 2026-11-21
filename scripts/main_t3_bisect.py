#!/usr/bin/env python3
"""Bisect a red scheduled main T3 to the merge that broke it (#4574, plan on #2048).

scripts/main_t3.py runs the whole app suite on main every few hours and, when it fails, opens one "Main T3 failed on
<sha7>" issue that lists the merges since the last green `main-t3` commit. This script narrows that list to one merge.

What it does, after a `failure` (never after `error`, which proves nothing about main):
1. Takes the failing test classes from the red run's own manifests (the red run's evidence folder), grouped by plan.
2. Takes the first-parent commits in `last green..red`, oldest first. The red head is known to fail; the last green is
   known to pass.
3. Bisects them. Each probe checks out one commit and runs only the failing classes through lane-runner.py's T3
   machinery (the same build, simulator clone, crash-flood stop and retries as the whole run). A commit that predates a
   class does not run it and counts as a pass. Cost: about log2(merges) probes, plus one more on the culprit: the
   culprit's failing classes must fail on their own, twice if its first failure was in a probe, or it is not named.
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

- An issue names only the tests the culprit's own probes saw fail. A red run with two separate breaks stops at the
  earlier one; the other failures are listed as "not by this merge" and are not bisected.
- The job token reaches `git lfs pull` by environment (GIT_CONFIG_*), never argv, so no error text can print it, and
  its base64 form is masked in the log first.

The scripts/ folder is restored to the red commit's before each probe, so an old commit is tested by today's runner
(its flags, its crash handling) with its own app code and tests. Default taken: scripts/ only, not TestPlans/.

Subcommand:
- bisect --sha RED --run-url URL --evidence DIR: as above. Exits 0 whatever it finds; the red status is already set.
  Needs a checkout with full history (fetch-depth: 0) and the red run's evidence folder, so it runs in the red run's
  job, or a job that downloads that evidence and sets up the Mac as main-t3.yml's t3 job does.

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
MAX_PROBES = 10  # log2(30) is 5 and log2(256) is 8; the culprit's own probe and a runner-fault retry need a few more
UNDECIDED_RETRIES = 1
# One probe is a build and one run of a few classes, never the whole plans. Each verify-tests.py run in it gets
# PROBE_TIMEOUT (a probe is at most three: the build and two plans). No probe starts after BUDGET_SECONDS, which leaves
# the last one room to end and the result to be posted inside the bisect job's 240 minutes (the job sets
# timeout-minutes: 240): 240 min - 20 min of setup - 3 * 30 min = 130 min.
PROBE_TIMEOUT = 30 * 60
BUDGET_SECONDS = 130 * 60
TEST_SOURCES = 'App/SpokenMarginsAppTests'
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


def watched_failures(results: dict, watched: set) -> list:
    """The failed tests of a probe that belong to a watched class: what that commit itself is shown to break."""
    return sorted(t for t, _ in results.get('failed', []) if class_of(t) in watched)


def bisect(commits: list, probe, max_probes: int = MAX_PROBES, time_left=lambda: True) -> Result:
    """Find the first failing commit in `commits` (oldest first). The last one is known to fail and the commit before
    the first is known to pass. `probe(sha)` returns PASS, FAIL or UNDECIDED; `time_left()` is False when out of time.

    The red head is known to fail only in the whole suite. A culprit is named only after the watched classes have
    failed in a probe of the culprit itself: for the head too, since a failure that comes from another test's pollution
    or a flake does not reproduce when its classes run alone, and blaming the newest merge for it would be a guess."""
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
    seen = sum(1 for sha, outcome in probes if sha == culprit and outcome == FAIL)
    if seen < 2 if bad != len(commits) - 1 else seen < 1:
        # A probe that found it failing is one sighting; the head's whole run is not a sighting of its classes alone.
        again = run(culprit)
        if again is None:
            return undecided(f'out of probes or time before {culprit[:7]} could be checked on its own')
        if again != FAIL:
            how = 'passed' if again == PASS else 'could not be tested'
            return undecided(f'{culprit[:7]} failed in the whole suite or a first probe, then {how} with only its failing '
                             'classes: a flaky test or one that depends on others, not a culprit')
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
                 failure_issue: str | None, unexplained: list | None = None) -> str:
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
    if unexplained:
        lines.append(f'- Also failing in the red run, but not by this merge (its probes did not fail them; another merge '
                     f'or a flake): ' + ', '.join(f'`{t3.short_test(t)}`' for t in unexplained[:20]) +
                     (f' and {len(unexplained) - 20} more' if len(unexplained) > 20 else ''))
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

def describe(args: tuple) -> str:
    """The first words of a git command for an error message, without the value after any `-c` (a credential)."""
    shown, skip = [], False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg == '-c':
            skip = True
            continue
        shown.append(arg)
    return ' '.join(shown[:3])


def git(*args: str, env: dict | None = None) -> str:
    """Run git in the checkout. `env` adds to the environment, so a credential never goes in argv or in an error."""
    done = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True,
                          env={**os.environ, **env} if env else None)
    if done.returncode:
        raise RuntimeError(f'git {describe(args)}: {done.stderr.strip()[:300]}')
    return done.stdout


def lfs_credential(token: str) -> tuple:
    """(the basic-auth value, the environment that hands it to git for one command). GIT_CONFIG_* keeps it out of
    argv, so no error text or process listing carries it; the caller masks the value in the workflow log."""
    import base64
    auth = base64.b64encode(f'x-access-token:{token}'.encode()).decode()
    return auth, {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'http.https://github.com/.extraheader',
                  'GIT_CONFIG_VALUE_0': f'AUTHORIZATION: basic {auth}'}


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
        auth, env = lfs_credential(token)
        # Actions masks the raw token, not the base64 of it, so mask that too before anything can print it.
        print(f'::add-mask::{auth}', flush=True)
        # The checkout keeps no credentials; the job token is handed to this one command (main-t3.yml does the same).
        git('lfs', 'pull', env=env)


def present_classes(grouped: dict, root: Path) -> dict:
    """The watched classes whose Swift class is declared in the checked-out tree, by plan. A class a PR added is not in
    the commits before it, and verify-tests.py refuses a selector its plan does not hold."""
    sources = [path.read_text(errors='replace') for path in sorted((root / TEST_SOURCES).rglob('*.swift'))]
    present = {}
    for plan, classes in grouped.items():
        here = [c for c in classes if any(re.search(r'\bclass\s+' + re.escape(c.split('/')[-1]) + r'\b', text)
                                          for text in sources)]
        if here:
            present[plan] = here
    return present


def make_probe(grouped: dict, watched: set, red: str, run_id: str, evidence: Path):
    """The probe function. `probe.failed` maps a commit to the watched tests its probes saw fail."""
    lane = t3.load_lane_runner()
    lane.T3_TIMEOUT = PROBE_TIMEOUT
    count = [0]

    def probe(sha: str) -> str:
        count[0] += 1
        out = evidence / f'bisect-{count[0]:02d}-{sha[:7]}'
        out.mkdir(parents=True, exist_ok=True)
        try:
            check_out(sha, red)
            here = present_classes(grouped, ROOT)
            if not here:
                print(f'Probe {sha[:7]}: none of the watched classes exist yet, so they cannot fail here -> pass',
                      flush=True)
                return PASS
            verdict, _where, _ran, details, _crashes, _ = lane._run_t3_grouped(
                {plan: list(classes) for plan, classes in here.items()}, f'bisect-{sha[:7]}-{run_id}', out)
        except Exception as error:  # noqa: BLE001 - a fault in the machinery decides nothing about the commit
            print(f'Probe {sha[:7]} stopped: {error!r}', flush=True)
            return UNDECIDED
        results = t3.collect_results(t3.pick_manifests(t3.read_manifests(out)))
        outcome = classify_probe(verdict, results, watched)
        if outcome == FAIL:
            probe.failed.setdefault(sha, set()).update(watched_failures(results, watched))
        print(f'Probe {sha[:7]}: {verdict} -> {outcome} ({len(results["failed"])} failed, {results["passed"]} passed; '
              f'{"; ".join(str(d) for d in details[:2])})', flush=True)
        return outcome

    probe.failed = {}
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
    try:
        failure_issue = t3.find_open_issue(t3.open_issues())
    except (RuntimeError, ValueError) as error:
        print(f'Could not list the open issues: {error}', flush=True)
        failure_issue = None
    green = None
    probe = None
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
        result = None
        try:
            commits = merges_in_range(green, red)
        except RuntimeError as error:
            commits = []
            result = Result('undecided', None, f'the commits since the last green could not be listed: {error}', [])
        subjects = dict(commits)
        if not commits and result is None:
            result = bisect([], None)
        if commits:
            started = time.monotonic()
            probe = make_probe(grouped, watched_tests(grouped), red, args.run_id, evidence)
            try:
                result = bisect([sha for sha, _ in commits], probe,
                                time_left=lambda: time.monotonic() - started < args.budget)
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
                # Name only what the culprit's own probes saw fail; the rest of the red run's failures are not its.
                shown = sorted(getattr(probe, 'failed', {}).get(result.sha) or failed_tests)
                unexplained = [t for t in failed_tests if t not in shown]
                body = culprit_body(result.sha, subject, pr, red, green, args.run_url, shown, result,
                                    failure_issue['html_url'] if failure_issue else None, unexplained)
                url = t3.gh('issue', 'create', '-R', t3.repo(), '--title', culprit_title(subject, pr, shown),
                            '--label', 'ready', '--label', t3.ISSUE_LABEL, '--label', pr_area(pr),
                            '--body-file', '-', stdin=body).strip()
                print(f'Culprit issue: {url}', flush=True)
                note = f'Bisected to `{result.sha[:7]}` ({subject}): {url}'
                if unexplained:
                    note += (f'. Not explained by this merge, and not bisected: {len(unexplained)} other failing test'
                             f'{"s" if len(unexplained) != 1 else ""} in the red run (another merge or a flake).')
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
