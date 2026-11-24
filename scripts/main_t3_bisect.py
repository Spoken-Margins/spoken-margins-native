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
- A probe's verdict is `fail` only when a test that failed in the red run failed (the test, not just its class: a
  class fixed and broken again in another method must not blame the old break). A build failure or any other test
  failing is `undecided`: it is not evidence about the red run's tests.
- A culprit whose SHA already has a closed culprit issue is `undecided`: it was fixed forward, so this red run is
  another break and the same merge cannot be re-broken.
- `undecided` is retried once, then ends the bisection as undecided.

- An issue names only the tests the culprit's own probes saw fail. A red run with two separate breaks stops at the
  earlier one; the other failures are listed as "not by this merge" and are not bisected.
- The job token reaches `git lfs pull` by environment (GIT_CONFIG_*), never argv, so no error text can print it, and
  its base64 form is masked in the log first.

Revert (#4574, step 3 of docs/workstreams/retire-mac-ci.md): after it names a culprit, it reverts that merge on the
newest main the way the Mac's integration run does (ops/testdesk/integration_revert.py, whose safety rules it reuses):
- It opens `revert/pr<N>` as a PR with `automerge` and files a `ready` + `regression` "Re-land #N" issue, both with
  SM_REVERT_TOKEN. That must be a token whose PRs start workflows (the App's installation token): a PR opened with the
  job token starts none, so it would never be tested or merged. Without it nothing is pushed.
- It is two subcommands. `bisect` files the culprit issue and, when the revert is safe, writes
  main-t3-revert-request.json into the evidence folder; `revert` then checks every rule again on the newest main and
  opens it. The token is minted between the two (main-t3.yml): an App token lives one hour and a bisection can take
  four, and the probes of older commits never run with a write token in their environment.
- It refuses, and says why in the culprit issue, when the culprit is not a merged PR or is itself a revert; main
  already reverts it, or another revert PR is open; it changes persistence, a packet format, a migration or the lane
  (`.github/`, `scripts/lane*`); it changes only docs, ops or scripts outside the app build; the red run also has
  failures this merge did not cause (two breaks: reverting one leaves main red); or `git revert -m 1` does not apply
  cleanly on the newest main. Those go to a person through the culprit issue, which is `ready`.
- It reverts only when it has just opened the culprit issue, so a re-run on the same red commit never reverts twice.

The scripts/ folder is restored to the red commit's before each probe, so an old commit is tested by today's runner
(its flags, its crash handling) with its own app code and tests. Default taken: scripts/ only, not TestPlans/.

Run it only in a clean checkout (the workflow job): probes reset tracked files, so it refuses to start when any
are modified.

Subcommands:
- bisect --sha RED --run-url URL --evidence DIR: as above. Exits 0 whatever it finds; the red status is already set.
  Needs a checkout with full history (fetch-depth: 0) and the red run's evidence folder, so it runs in the red run's
  job, or a job that downloads that evidence and sets up the Mac as main-t3.yml's t3 job does.
- revert --evidence DIR: opens the revert `bisect` asked for in DIR, if any. Exits 0.

Environment: GH_TOKEN and GH_REPO (the workflow's), and SM_REVERT_TOKEN for `revert` only (without it the culprit
issue says the revert was not opened and why). Stdlib only, Python 3.9-compatible.
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


def _load_integration_revert():
    """ops/testdesk/integration_revert.py: the Mac integration run's revert rules and text, shared so the hosted revert
    refuses exactly what the Mac's does (#1180). Loaded by path: ops/testdesk is not a package."""
    import importlib.util
    path = Path(__file__).resolve().parents[1] / 'ops' / 'testdesk' / 'integration_revert.py'
    spec = importlib.util.spec_from_file_location('integration_revert', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


revert = _load_integration_revert()

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
REVERT_TOKEN_ENV = 'SM_REVERT_TOKEN'
# What `bisect` leaves for `revert` when the culprit is safe to revert (in the evidence folder).
REVERT_REQUEST = 'main-t3-revert-request.json'
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


def classify_probe(verdict: str, results: dict, wanted: set) -> str:
    """pass / fail / undecided for one probe run of the watched classes (lane-runner.py's verdict, main_t3's results).

    `wanted` is the set of test ids that failed in the red run. Only one of those failing counts as `fail`."""
    if verdict == 'PASS':
        return PASS
    if verdict != 'FAIL':
        return UNDECIDED  # INCONCLUSIVE: a runner fault, no simulator, a crash flood
    failed = [t for t, _ in results.get('failed', [])]
    if not failed:
        return UNDECIDED  # the build or a plan failed with no test result; says nothing about the red run's tests
    if any(t in wanted for t in failed):
        return FAIL
    return UNDECIDED  # another test failed here (even in a watched class): a different problem, not the one chased


def watched_failures(results: dict, wanted: set) -> list:
    """The red run's failing tests that failed in this probe: what that commit itself is shown to break."""
    return sorted(t for t, _ in results.get('failed', []) if t in wanted)


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


def find_culprit_issue(issues: list, sha: str) -> dict | None:
    """The culprit issue for this commit in `issues` (its marker, from the workflow's bot or a collaborator)."""
    for issue in sorted(issues, key=lambda i: i['number']):
        found = CULPRIT_MARKER_RE.search(issue.get('body') or '')
        if 'pull_request' not in issue and found and found.group(1) == sha and t3.trusted(issue):
            return issue
    return None


find_open_culprit_issue = find_culprit_issue  # the list passed in decides: open issues, or closed ones


def closed_issues() -> list:
    """Closed issues with the regression label, for the already-fixed check."""
    lines = t3.gh('api', '--paginate', '--jq', '.[] | @json',
                  f'repos/{t3.repo()}/issues?state=closed&labels={t3.ISSUE_LABEL}&per_page=100')
    return [json.loads(line) for line in lines.splitlines() if line.strip()]


# ---- Revert: decision and text (pure) ----------------------------------------------------------------

def revert_refusals(commit: dict, paths: list, scope, open_reverts: list, already_reverted: str | None,
                    unexplained: list, token: str | None, need_token: bool = True) -> list:
    """Reasons not to revert the culprit merge, empty when it is safe to try. `commit` has sha, parents, subject and
    body; `paths` are the files the merge changed against its first parent."""
    reasons = revert.revert_blockers(commit, paths, scope, ROOT, open_reverts, already_reverted)
    if unexplained:
        reasons.append(f'the red run also has {len(unexplained)} failing test{"s" if len(unexplained) != 1 else ""} '
                       'this merge did not cause, so reverting it would leave main red; a person should look at both')
    if need_token and not token:
        reasons.append(f'no {REVERT_TOKEN_ENV} is set, and a revert PR opened with the job token would start no checks, '
                       'so it could never merge')
    return reasons


def touched_since(culprit_paths: list, main_paths: list) -> list:
    """A refusal when main changed the culprit's files after the red commit: a fix forward may already have landed, and
    a revert on top of it would undo the fix too. The bisection can take two hours, so this is a real window."""
    both = sorted(set(culprit_paths) & set(main_paths))
    if not both:
        return []
    return ['main has changed files this merge touched since the red run (' + ', '.join(both[:3]) +
            (', ...' if len(both) > 3 else '') + '), so a fix forward may already be in; a person should check']


def revert_title(number: int, title: str, red: str) -> str:
    return f'Revert #{number}: {title} (main-t3 red on {red[:7]})'[:200]


def revert_message(number: int, title: str, red: str, merge_sha: str, run_url: str, tests: list) -> str:
    return '\n'.join([
        revert_title(number, title, red), '',
        f'The scheduled T3 on main failed on {red[:7]} ({run_url}): ' + ', '.join(t3.short_test(t) for t in tests[:10]) +
        '. Bisection found this merge to be the first where they fail.', '',
        f'This reverts commit {merge_sha}.'])


def revert_pr_body(number: int, title: str, red: str, run_url: str, tests: list, probes: list, culprit_issue: int,
                   reland: str, hot: str = '') -> str:
    found = ', '.join(f'`{s[:7]}` {o}' for s, o in probes) or 'none needed: one merge since the last green'
    lines = [f'Reverts #{number} ({title}) because the scheduled T3 on main (`main-t3`) failed on `{red[:7]}`: '
             + ', '.join(f'`{t3.short_test(t)}`' for t in tests[:20]) + f'. Run: {run_url}', '',
             f'Bisection probes: {found}. The merge of #{number} is the first commit where those tests fail.', '',
             f'Part of #{culprit_issue}. Re-land: {reland}', '']
    if hot:
        lines += [hot, '']
    lines += ['Opened by scripts/main_t3_bisect.py (#4574) under the owner\'s "revert first" rule, with the same safety '
              'rules as the Mac\'s integration run (ops/testdesk/integration_revert.py). It carries `automerge`.', '']
    return '\n'.join(lines)


def reland_title(number: int, title: str) -> str:
    return f'Re-land #{number} after a main-t3 revert: {title}'[:200]


def reland_body(number: int, title: str, red: str, run_url: str, tests: list, revert_pr: str, culprit_issue: int) -> str:
    return '\n'.join([
        '## Outcome', '',
        f'The change from #{number} ({title}) is back on `main`, with the tests that broke passing.', '',
        '## Evidence', '',
        f'- #{number} was reverted by {revert_pr} because the scheduled T3 on main failed on `{red[:7]}`: {run_url}',
        '- Failing tests: ' + ', '.join(f'`{t3.short_test(t)}`' for t in tests[:20]),
        f'- The bisection and its probes: #{culprit_issue}', '',
        '## Done when', '',
        f'1. The change from #{number} lands again in a new PR into main, with the failing tests above passing.',
        '2. A test that fails without the fix covers the cause (main-t3 found it; the PR\'s checks did not).', '',
        '## Must not break', '',
        'The journeys the original PR touched (docs/journeys.md), packets, the database, and the owner\'s Library.', '',
        '_Opened by scripts/main_t3_bisect.py (#4574)._'])


def not_reverted_section(reasons: list) -> str:
    return '\n'.join(['', '## Not reverted automatically', '',
                      'The bisection did not open a revert PR, so a person decides between a fix forward and a revert:',
                      *[f'- {reason}' for reason in reasons]])


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


def make_probe(grouped: dict, wanted: set, red: str, run_id: str, evidence: Path):
    """The probe function. `wanted` is the red run's failing test ids; `probe.failed` maps a commit to the ones its
    probes saw fail."""
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
        outcome = classify_probe(verdict, results, wanted)
        if outcome == FAIL:
            probe.failed.setdefault(sha, set()).update(watched_failures(results, wanted))
        print(f'Probe {sha[:7]}: {verdict} -> {outcome} ({len(results["failed"])} failed, {results["passed"]} passed; '
              f'{"; ".join(str(d) for d in details[:2])})', flush=True)
        return outcome

    probe.failed = {}
    return probe


def git_run(*args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    """git in the checkout, returning the result instead of raising (for commands whose failure is an answer)."""
    return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True,
                          env={**os.environ, **env} if env else None)


def gh_as(token: str, *args: str, stdin: str | None = None) -> str:
    """gh with another token than the job's (the revert token), never in argv."""
    done = subprocess.run(['gh', *args], input=stdin, capture_output=True, text=True,
                          env={**os.environ, 'GH_TOKEN': token})
    if done.returncode:
        raise RuntimeError(f'gh {" ".join(args[:3])}: {done.stderr.strip()[:300]}')
    return done.stdout


def culprit_commit(sha: str) -> dict:
    """{sha, parents, subject, body} of a commit, the shape integration_revert's rules read."""
    out = git('log', '-1', '--format=%P%x1f%s%x1f%b', sha)
    parents, subject, body = (out.rstrip('\n').split('\x1f') + ['', '', ''])[:3]
    return {'sha': sha, 'parents': parents.split(), 'subject': subject, 'body': body}


def changed_paths(sha: str) -> list:
    out = git('diff', '--name-only', '--no-renames', f'{sha}^1', sha)
    return [line for line in out.splitlines() if line.strip()]


def fetch_main() -> None:
    """The newest main as origin/main (the checkout keeps no credentials; the repository is public)."""
    git('fetch', '--quiet', 'origin', '+refs/heads/main:refs/remotes/origin/main')


def reverted_on_main(merge_sha: str) -> str | None:
    found = git_run('log', '--format=%H', '-n1', '--fixed-strings', f'--grep=This reverts commit {merge_sha}',
                    'origin/main')
    return (found.stdout.strip() or None) if found.returncode == 0 else None


def changed_on_main_since(red: str) -> list:
    out = git('diff', '--name-only', '--no-renames', red, 'origin/main')
    return [line for line in out.splitlines() if line.strip()]


def open_revert_prs() -> list:
    pulls = json.loads(t3.gh('api', f'repos/{t3.repo()}/pulls?state=open&base=main&per_page=100'))
    return [f"#{pr['number']}" for pr in pulls if re.match(r'\s*Revert\b', pr.get('title') or '', re.I)]


def open_revert(commit: dict, red: str, run_url: str, tests: list, probes: list, culprit_issue: int,
                token: str, area: str) -> tuple:
    """Revert the culprit merge on the newest main, push revert/pr<N>, open the PR with automerge and file the re-land
    issue, all as `token`. Returns (PR url, re-land url or '', '') or (None, '', why not); nothing is pushed on a
    failure before the push."""
    number = revert.pr_number(commit['subject'])
    title = revert.pr_title(commit['subject'], commit['body'])
    branch = revert.revert_branch(number)
    auth, env = lfs_credential(token)
    print(f'::add-mask::{auth}', flush=True)
    pushed, pr_url = False, None
    try:
        git('checkout', '--quiet', '--force', '-B', branch, 'origin/main')
        undone = git_run('revert', '--no-commit', '-m', '1', commit['sha'])
        if undone.returncode:
            conflicts = git_run('diff', '--name-only', '--diff-filter=U').stdout.split()
            git_run('revert', '--abort')
            return None, '', ('`git revert -m 1` does not apply cleanly on the newest main ('
                              + (', '.join(conflicts[:10]) or undone.stderr.strip()[:200]) + ')')
        if git_run('diff', '--cached', '--quiet').returncode == 0:
            git_run('revert', '--abort')
            return None, '', 'reverting it changes nothing: main already undoes it'
        grown = revert.grows_hot_file(git('diff', '--cached', '--numstat'))
        hot = revert.hot_note(grown) if grown else ''
        git('-c', 'user.name=main-t3 bisect', '-c', 'user.email=noreply@spokenmargins.invalid', 'commit', '--quiet',
            '-m', revert_message(number, title, red, commit['sha'], run_url, tests))
        git('push', '--quiet', '--force', 'origin', f'HEAD:refs/heads/{branch}', env=env)
        pushed = True
        pending = '(the re-land issue is filed right after this PR opens)'
        labels = ['automerge'] + (['hot-file-ok'] if grown else [])
        pr_url = gh_as(token, 'pr', 'create', '-R', t3.repo(), '--base', 'main', '--head', branch,
                       '--title', revert_title(number, title, red), '--label', ','.join(labels), '--body-file', '-',
                       stdin=revert_pr_body(number, title, red, run_url, tests, probes, culprit_issue, pending, hot)
                       ).strip().splitlines()[-1]
        reland = ''
        try:
            reland = gh_as(token, 'issue', 'create', '-R', t3.repo(), '--title', reland_title(number, title),
                           '--label', 'ready', '--label', t3.ISSUE_LABEL, '--label', area, '--body-file', '-',
                           stdin=reland_body(number, title, red, run_url, tests, pr_url, culprit_issue)
                           ).strip().splitlines()[-1]
            gh_as(token, 'pr', 'edit', pr_url, '-R', t3.repo(), '--body-file', '-',
                  stdin=revert_pr_body(number, title, red, run_url, tests, probes, culprit_issue, reland, hot))
        except (RuntimeError, IndexError) as error:
            # The revert PR exists and will merge; the culprit issue says the re-land is still to file.
            print(f'::warning::Revert PR {pr_url} is open, but the re-land issue or the PR text failed: {error}',
                  flush=True)
        return pr_url, reland, ''
    except (RuntimeError, IndexError) as error:
        if pushed and not pr_url:
            # Pushed but no PR: take the branch back down so nothing looks half-reverted.
            git_run('push', '--quiet', 'origin', f':refs/heads/{branch}', env=env)
        return None, '', str(error)[:300]
    finally:
        git_run('checkout', '--quiet', '--force', '--detach', red)
        git_run('branch', '-D', branch)


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
    # Probes run `git checkout --force` here, so edits to tracked files would be lost without a word.
    if git('status', '--porcelain', '--untracked-files=no').strip():
        print('Refusing to run: the checkout has uncommitted changes to tracked files, and the bisection resets them. '
              'Run it in a clean checkout (the workflow job).', flush=True)
        return 2
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    # A request left by an earlier run must never be acted on for this one.
    (evidence / REVERT_REQUEST).unlink(missing_ok=True)
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
            probe = make_probe(grouped, set(failed_tests), red, args.run_id, evidence)
            try:
                result = bisect([sha for sha, _ in commits], probe,
                                time_left=lambda: time.monotonic() - started < args.budget)
            finally:
                try:
                    git('checkout', '--force', '--detach', red)
                except RuntimeError as error:
                    print(f'Could not return to {red[:7]}: {error}', flush=True)
    if result.kind == 'culprit':
        # The same merge cannot break the suite twice: a closed culprit issue for it means it was fixed forward, and
        # this red run is a different break that the bisection mistook for it (a test fixed, then broken again).
        try:
            fixed = find_culprit_issue(closed_issues(), result.sha)
        except (RuntimeError, KeyError, ValueError) as error:
            print(f'::warning::Could not list the closed culprit issues: {error}', flush=True)
            fixed = None
        if fixed:
            result = Result('undecided', None, f'`{result.sha[:7]}` already has a closed culprit issue (#{fixed["number"]}) '
                            'and was fixed, so this red run is another break that the bisection could not tell apart',
                            result.probes)
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
                # The token is not read here: it would sit in the environment through hours of probes of older
                # commits, and an App token lives one hour (main-t3.yml mints it after this step; `revert` uses it).
                refusals = []
                try:
                    _, refusals = revert_safety(result.sha, red, unexplained, token=None, need_token=False)
                except Exception as error:  # noqa: BLE001 - test-scope.py runs from the red tree; the issue must still go up
                    refusals = [f'could not check whether the revert is safe: {error!r}'[:250]]
                if refusals:
                    body += '\n' + not_reverted_section(refusals)
                area = pr_area(pr)
                url = t3.gh('issue', 'create', '-R', t3.repo(), '--title', culprit_title(subject, pr, shown),
                            '--label', 'ready', '--label', t3.ISSUE_LABEL, '--label', area,
                            '--body-file', '-', stdin=body).strip()
                print(f'Culprit issue: {url}', flush=True)
                note = f'Bisected to `{result.sha[:7]}` ({subject}): {url}'
                if unexplained:
                    note += (f'. Not explained by this merge, and not bisected: {len(unexplained)} other failing test'
                             f'{"s" if len(unexplained) != 1 else ""} in the red run (another merge or a flake).')
                if not refusals:
                    request = {'sha': result.sha, 'red': red, 'run_url': args.run_url, 'tests': shown,
                               'probes': [list(p) for p in result.probes],
                               'culprit_issue': int(url.rstrip('/').rsplit('/', 1)[-1]), 'area': area,
                               'failure_issue': failure_issue['number'] if failure_issue else None}
                    (evidence / REVERT_REQUEST).write_text(json.dumps(request, indent=2) + '\n')
                    note += '. A revert is next: this run opens it and says so on both issues.'
            else:
                note = f'Bisected to `{result.sha[:7]}`; its issue is already open.'
        else:
            note = undecided_note(result, red, green, args.run_url)
        if failure_issue:
            t3.gh('issue', 'comment', str(failure_issue['number']), '-R', t3.repo(), '--body-file', '-', stdin=note)
    except (RuntimeError, KeyError, ValueError) as error:
        print(f'::warning::Could not post the bisection result: {error}', flush=True)
    return 0


def revert_safety(sha: str, red: str, unexplained: list, token: str | None, need_token: bool = True) -> tuple:
    """(commit, refusals) for reverting the culprit `sha` on the newest main: the Mac's rules, two breaks, the token,
    and main having changed the culprit's files since the red run. Raises on a git or gh fault."""
    fetch_main()
    commit = culprit_commit(sha)
    paths = changed_paths(sha)
    refusals = revert_refusals(commit, paths, revert.load_test_scope(ROOT), open_revert_prs(), reverted_on_main(sha),
                               unexplained, token, need_token=need_token)
    refusals += touched_since(paths, changed_on_main_since(red))
    return commit, refusals


def command_revert(args) -> int:
    """Open the revert that `bisect` asked for in its evidence folder, as SM_REVERT_TOKEN, and say so on the culprit
    issue and the failure issue. Every safety rule is checked again first: main may have moved since. Exits 0."""
    os.chdir(ROOT)
    path = Path(args.evidence) / REVERT_REQUEST
    if not path.exists():
        print('No revert to open: the bisection named no culprit, or refused to revert it (its issue says why).',
              flush=True)
        return 0
    try:
        request = json.loads(path.read_text())
        issue = int(request['culprit_issue'])
        sha, red = request['sha'], request['red']
    except (ValueError, KeyError, TypeError) as error:
        print(f'::warning::The revert request is unreadable, so nothing is reverted: {error!r}', flush=True)
        return 0
    token = os.environ.get(REVERT_TOKEN_ENV) or None
    pr_url, commit = None, None
    try:
        commit, refusals = revert_safety(sha, red, [], token)
    except Exception as error:  # noqa: BLE001 - whatever broke, the culprit issue says the revert did not happen
        refusals = [f'could not check whether the revert is safe: {error!r}'[:250]]
    if not token:
        refusals.append('the App token did not reach the revert step (its mint failed, or the App is not set up), '
                        'and re-running the job will not retry the revert, because this culprit issue is now open')
    if refusals:
        said = not_reverted_section(refusals).strip()
    else:
        pr_url, reland, why = open_revert(commit, request['red'], request['run_url'], request['tests'],
                                          [tuple(p) for p in request['probes']], issue, token, request['area'])
        if pr_url:
            said = f'Revert opened: {pr_url} (`automerge`). Re-land: {reland or "not filed, see the run log"}.'
        else:
            said = not_reverted_section([why]).strip()
    print(said, flush=True)
    try:
        t3.gh('issue', 'comment', str(issue), '-R', t3.repo(), '--body-file', '-', stdin=said)
        # The failure issue was told a revert comes next, so it hears how that ended either way.
        if request.get('failure_issue'):
            t3.gh('issue', 'comment', str(request['failure_issue']), '-R', t3.repo(), '--body-file', '-',
                  stdin=f'Bisected to `{sha[:7]}` (culprit issue #{issue}): {said}')
    except (RuntimeError, KeyError, ValueError) as error:
        print(f'::warning::Could not post the revert result: {error}', flush=True)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    run = sub.add_parser('bisect')
    run.add_argument('--sha', required=True, help='the red commit (full SHA)')
    run.add_argument('--run-url', required=True)
    run.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID', 'local'))
    run.add_argument('--evidence', required=True,
                     help="the red run's evidence folder (its verify-* manifests, `main-<sha7>` under "
                          "$SM_LANE_EVIDENCE_DIR in main-t3.yml); probes write beside them")
    run.add_argument('--budget', type=int, default=BUDGET_SECONDS, help='seconds before it stops starting probes')
    undo = sub.add_parser('revert', help="open the revert `bisect` asked for, as $SM_REVERT_TOKEN")
    undo.add_argument('--evidence', required=True, help='the folder `bisect` wrote its revert request into')
    args = parser.parse_args(argv)
    if args.command == 'revert':
        return command_revert(args)
    if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        parser.error('--sha must be a full 40-character commit SHA')
    return command_bisect(args)


if __name__ == '__main__':
    sys.exit(main())
