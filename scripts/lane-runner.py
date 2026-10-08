#!/usr/bin/env python3
"""The lane's deterministic tiers: run a T2 or T3 request from a PR and post the report.

Run by .github/workflows/lane.yml on the Mac's self-hosted runner. The workflow checks out the PR's
head in --tree and runs this script as taken from the base branch (next); the script merges the
newest next into the tree itself, so a report tests the PR against the current next even when
GitHub's merge ref for the PR is stale. Agent sessions can't run it (the lane guard blocks it); they ask
by commenting a request and adding the lane:queued label. Formats: docs/workstreams/test-lane.md.

- The runner takes the newest T2/T3 request it hasn't answered yet. T4 and T5 requests belong to the
  Test Desk: while one is waiting, the runner leaves lane:queued in place so the Test Desk sees it.
- Every job that posts a report and doesn't merge the PR, for a /lane request or the automerge label,
  ends by removing and re-adding lane:done, after its last report (the automerge run a T3 PASS
  releases, #421), so each job makes a new `labeled` event: the Hourly dispatch wakes on it. An
  automerge run leaves lane:queued and lane:running alone.
- The newest commit wins: if the PR moved on since this run was queued, a newer run tests it.
- A request identical to one that already has a PASS or FAIL report (same head merged into the
  same next, tier and tests) runs once. After an INCONCLUSIVE report, asking again runs again.
- T2 builds for simulator and device (unsigned) through scripts/xcodebuild-lane.
- T3 runs the named app-hosted tests, plus every app test class the base branch's test-scope.py
  suggests for the PR's diff (#351), through verify-tests.py on a fresh iOS 26 simulator, created
  for the job and deleted afterwards. The report lists the classes it added and how long each plan took. It is booted under the lane's boot rules (scripts/lane_sim.py):
  one boot at a time, no builds meanwhile, no retry after a failed boot, a stop at the first crash
  during boot, and a long wait for the first boot's data migration. The job holds the Mac's one
  simulator slot throughout, so it never runs alongside a Test Desk job. A crash flood stops the run.
- A timeout interrupts the whole process group, so no xcodebuild keeps running outside the slots.
- The automerge label asks for the checks a finished PR needs, with no request comment (the
  ready-queue plan, decision 3). The base branch's scripts/test-scope.py classifies the PR's
  committed diff: T0 (docs, research, the server) runs nothing, T1 runs --plan fast, and T2 or
  higher runs --plan fast and both builds. An explicit request on the PR goes first. Before any of
  that, next's scripts/hot_file_ratchet.py fails a PR that grows Gate1AppModel.swift or
  Gate1RootView.swift above its ceiling, unless the PR has the hot-file-ok label.
- The runner merges what it passes (decision 3, owner-approved). An automerge run tests the exact
  merge commit, with next as its first parent. On PASS it posts a "Merge check (triage desk)"
  comment (the prefix scripts/merge_audit.py looks for) and pushes that commit to next with a plain
  push; if next moved meanwhile, the push is refused and it tests again on the newest next (up to
  MERGE_ATTEMPTS), unless next's new commits touch none of the PR's files and no build inputs: then
  it re-merges onto the newest next and pushes without testing again (untested_moves). It won't merge an audio, persistence, packet or lane change
  (test-scope.py's lane_paths) until a Codex audit of its head says "No blocking findings": those pass
  or fail as usual, and the audit script re-arms automerge after a clean audit. Lane changes no longer
  wait for a person (owner rule 2026-10-01); the audit checks them, because a lane PR's own run uses
  its own workflow and helpers. A PR someone asked T3 for merges only on a
  T3 PASS (#410): while its newest T3 report is FAIL or INCONCLUSIVE, or its newest T3 request has
  no report yet, the automerge run reports that verdict (INCONCLUSIVE while waiting) and doesn't merge.
  When a T3 then passes, the lane job that reported it runs the held automerge run itself, in the
  same job (#421): a label the runner re-added with the workflow's token would start no new run.
  While the PR's T3 request for its head is still waiting, the automerge run on the build runner runs its
  checks anyway and its held report records what passed with which next (#834); the T3 PASS's lane job
  then merges without repeating them unless next has since moved in ways that matter (untested_moves).
  Anywhere else, or with no room to build, the automerge run skips its checks and reports itself held
  straight away, and the T3 PASS's lane job runs them before it merges.
- PR code (builds and tests) runs without the GitHub token in its environment, and the checkout
  keeps no credentials, so only this script's own fetch and push can use the token.
- Build folders stay warm between jobs. The checkout wipes the workspace, so the tree's .build (the
  app's DerivedData and verify-tests' output) and Packages/SessionKit/.build (SwiftPM) link to a cache
  outside it, keyed by the SessionKit source tree under test: a DerivedData reused after SessionKit
  changes gives false "does not conform" errors (AGENTS.md), so any SessionKit change starts a new
  cache. So does an Xcode project change. Each checkout (each runner) has its own caches, because
  DerivedData and SwiftPM's state record absolute paths, and a cache whose SwiftPM state lists a
  binary artifact that isn't on disk starts again cold (#405). At most WARM_KEEP caches per checkout,
  never below WARM_FREE_FLOOR of free disk; otherwise the job runs cold. A warm rebuild measured 6 to
  10 s against 90 s cold, per build.
- Two runners (item 5). lane.yml's `lane` job answers /lane requests on the main runner (the only
  one that runs simulators); its `automerge` job runs on any runner labelled sm-lane-build. --mode
  keeps each job to its own work. On the build-only runner (SM_LANE_RUNNER_ROLE=build), an
  automerge job first waits for room: no simulator job, normal memory pressure, and enough free disk.
  Trial (2026-10-01): a host-only job (T0/T1) there may start beside a simulator job while memory
  pressure reads normal and BESIDE_SIMULATOR_FREE_DISK is free; each one is logged for the owner.
- Auto-revert of a lane change that broke the lane (owner rule 2026-10-01, auto_revert). Each job on
  next starts by finding the newest merge into next that touched the lane (test-scope.py's lane
  paths). If the first two lane reports on PRs after it, from jobs that tested a next with it, were
  both runner faults (INCONCLUSIVE for a lane reason, or a job that stopped before reporting; not a
  merge conflict, a T3 hold or a FAIL), it reverts that merge with `git revert -m 1`, pushes like a
  merge, files a `ready` + `regression` issue to re-land it, and posts "Lane auto-revert:" on #337.
  Once per lane change; a revert that doesn't apply cleanly is reported on #337 and left for a person.

Environment: GH_TOKEN and GH_REPO (the workflow's), SM_LANE_EVIDENCE_DIR (where evidence goes,
default ~/Library/Caches/SpokenMarginsLane/evidence), SM_LANE_TOOLS (a checkout whose .venv and
node_modules to link in, default the owner's main checkout).
Stdlib only, Python 3.9-compatible: it runs under /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import base64
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

QUEUED, RUNNING, DONE = 'lane:queued', 'lane:running', 'lane:done'
AUTOMERGE = 'automerge'
FAST_TIMEOUT = 2400
MERGE_ATTEMPTS = 3
# #863: keep more exact-key hits across interleaved PRs. Cloning across SessionKit keys also copies
# Xcode metadata pointing at the donor cache; retain strict keys to avoid stale modules instead.
# WARM_FREE_FLOOR still takes precedence over this per-checkout retention limit.
WARM_KEEP = 4
BUILD_RUNNER_WAIT = 90 * 60
BUILD_RUNNER_FREE_DISK = 20 * 10**9
# Trial (2026-10-01): host-only jobs on the build runner may run beside a simulator job, with this much disk.
BESIDE_SIMULATOR_FREE_DISK = 30 * 2**30
BESIDE_SIMULATOR_LOG = 'beside-simulator.log'  # in the lane state folder: one line per job, to count crashes against
# Read by the tree's lane_slots.py (spelled here so this runner never needs a name from that copy, lane_slots_helper).
BUILD_NEEDS_ROOM_ENV = 'SM_LANE_BUILD_NEEDS_ROOM'
WARM_FREE_FLOOR = 15 * 10**9
PROJECT_FILE = 'SpokenMarginsNative.xcodeproj/project.pbxproj'  # its layout names Xcode's VFS folders (#405)
# How the T3 gate's hold reads in an automerge report, now and before #421 (PRs held by an older runner).
HELD_FOR_T3 = ('not merged: held for T3', 'after a T3 PASS, push or remove and re-add automerge to merge')
NOT_VERIFIED = 'journeys and anything a listener notices (T4), audible content (owner)'
MERGE_CHECK = '**Merge check (triage desk)'  # the prefix scripts/merge_audit.py requires
AUDITS = ('**Codex audit (Astra)', '## Codex audit')  # how an audit comment starts: the hourly task's, or an older manual one
AUDITED = {'audio': 'the audio session', 'persistence': 'persistence', 'packet': 'packets'}
BOT = ('github-actions[bot]', '41898282+github-actions[bot]@users.noreply.github.com')
RUNNER_TIERS = ('T2', 'T3')
APP_TEST_TARGET = 'SpokenMarginsAppTests'
PLANS = {'app': 'AppBehavior', 'adapters': 'AudioAdapters'}
# The device build compiles without signing: the runner is a background service with no access to
# the login keychain's signing key (errSecInternalComponent), and signing is a release-archive check.
T2_BUILDS = (('simulator', ["-destination", "generic/platform=iOS Simulator", "build-for-testing"]),
             ('device', ["-destination", "generic/platform=iOS", "CODE_SIGNING_ALLOWED=NO", "build"]))
BUILD_TIMEOUT = 1800
T3_TIMEOUT = 3600
INTERRUPT_GRACE = 120
RUNNER_SIMULATOR_PREFIX = 'SM Lane Runner '
# How long a T3 waits for the Mac's one simulator slot (a Test Desk job may hold it); keeps the job
# inside lane.yml's 150-minute limit together with the boot and the test run.
RUNNER_SLOT_WAIT = 3600
MARKER = re.compile(r'<!-- lane-request: (\{.*?\}) -->')
NOTE = '<!-- lane-note -->'
REQUEST = re.compile(r'^\s*/lane\s+(T\d)\b', re.M)
REPORT = re.compile(r'^Lane report \S+ — (PASS|FAIL|INCONCLUSIVE)', re.M)
IDENTICAL = re.compile(r'^Lane: identical (T\d) request for (\w+) already reported \((PASS|FAIL)\)', re.M)
CHECKS = re.compile(r'^<!-- lane-checks: (\{.*\}) -->$', re.M)  # a held automerge report's passed checks (#834)


# ---- Requests -----------------------------------------------------------------------------------

def parse_request(body: str) -> dict | None:
    """The /lane line and the `key: value` lines after it, or None if the comment isn't a request."""
    lines = body.replace('\r\n', '\n').split('\n')
    for index, line in enumerate(lines):
        match = REQUEST.match(line)
        if not match:
            continue
        request = {'tier': match.group(1)}
        for extra in lines[index + 1:]:
            field = re.match(r'^\s*([a-z][a-z ]*?)\s*:\s*(.*)$', extra)
            if field:
                request[field.group(1)] = re.sub(r'\s+#.*$', '', field.group(2)).strip()
        # test-lane.md's example once read `run: J1, J7   # or: tests: …`, so `run: tests: A, B` is
        # accepted too; a separate `tests:` line wins.
        inline = re.match(r'^tests\s*:\s*(.*)$', request.get('run', ''))
        if inline and not request.get('tests'):
            request['tests'] = inline.group(1)
        request['tests'] = [t for t in re.split(r'[,\s]+', request.get('tests', '')) if t]
        return request
    return None


def is_runner_comment(body: str) -> bool:
    return bool(MARKER.search(body)) or NOTE in body


def report_identity(body: str) -> dict | None:
    match = MARKER.search(body)
    try:
        return json.loads(match.group(1)) if match else None
    except ValueError:
        return None


def is_automerge_comment(body: str) -> bool:
    """An automerge run's report or note: the lane job never ran the /lane request before it."""
    return (report_identity(body) or {}).get('tier') == 'auto' or \
        (NOTE in body and body.startswith('Lane: the automerge run'))


def pending_requests(comments: list[dict]) -> tuple[dict | None, bool]:
    """The newest T2/T3 request the runner hasn't answered, and whether a T4/T5 request is waiting.

    A runner request is answered once a runner report or note comes after it. A Test Desk request
    is waiting until a report that isn't the runner's (the Test Desk's) comes after it.
    """
    runner_request, runner_answered, desk_request, desk_answered = None, -1, -1, -1
    for index, comment in enumerate(comments):
        body = comment.get('body') or ''
        if is_runner_comment(body):
            if not is_automerge_comment(body):  # the automerge job answers no /lane request (#410)
                runner_answered = index
            continue
        if REPORT.search(body):
            desk_answered = index
            continue
        request = parse_request(body)
        if not request:
            continue
        if request['tier'] in RUNNER_TIERS:
            runner_request = (index, dict(request, url=comment.get('html_url'),
                                          author=(comment.get('user') or {}).get('login')))
        else:
            desk_request = index
    newest = runner_request[1] if runner_request and runner_request[0] > runner_answered else None
    return newest, desk_request > desk_answered


def identity(tier: str, commit: str, base: str, tests: list[str]) -> dict:
    """What a report covers: the PR head merged into this next commit (a moved next runs again)."""
    return {'tier': tier, 'commit': commit, 'next': base, 'tests': sorted(tests)}


def earlier_report(comments: list[dict], wanted: dict) -> tuple[str, str] | None:
    """(URL, verdict) of a PASS or FAIL lane report already posted for this exact request.

    INCONCLUSIVE doesn't count: that request runs again.
    """
    for comment in comments:
        body = comment.get('body') or ''
        match, verdict = MARKER.search(body), REPORT.search(body)
        if not match or not verdict or verdict.group(1) == 'INCONCLUSIVE':
            continue
        try:
            if json.loads(match.group(1)) == wanted:
                return comment.get('html_url') or 'an earlier comment', verdict.group(1)
        except ValueError:
            continue
    return None


# ---- Reports ------------------------------------------------------------------------------------

def duration(seconds: float) -> str:
    minutes, seconds = divmod(int(seconds), 60)
    return f'{minutes}m{seconds:02d}s' if minutes else f'{seconds}s'


def report(request_id: str, verdict: str, head: str, base: str, tier: str, where: str, seconds: float,
           ran: str, details: list[str], crashes: str, evidence: str, not_verified: str, wanted: dict,
           cc: str = '', base_name: str = 'next') -> str:
    lines = [f'Lane report {request_id} — {verdict}',
             f'commit {head[:7]} (tested merged with {base_name} at {base[:7]}) · tier {tier} · {where} · {duration(seconds)}',
             f'ran: {ran}', *details, f'crashes: {crashes}', f'evidence: {evidence} (on the Mac)',
             f'not verified: {not_verified}']
    if cc:
        lines.append(cc)
    return '\n'.join(lines) + f'\n<!-- lane-request: {json.dumps(wanted, sort_keys=True)} -->\n'


# ---- Processes ----------------------------------------------------------------------------------

# The workflow's command files. A step's processes append to them to set its outputs (the verdict the
# Verdict step reads), environment and summary, so the PR's code must not see them: the lane's own tests
# call main(), and inherited, they wrote their fake verdicts into the job's output after the real one.
WORKFLOW_FILES = ('GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY')


def pr_code_env() -> dict:
    """The environment for the PR's own code (builds, tests): without the GitHub token, so nothing the
    PR changes can use the lane's write access, and without the workflow's command files, so it can't set
    the job's verdict. Nor BUILD_NEEDS_ROOM_ENV: that is for the T2 builds alone (pr_build_env), and host
    tests that take build slots or test lane_slots mustn't inherit it."""
    return {name: value for name, value in os.environ.items()
            if name not in ('GH_TOKEN', 'GITHUB_TOKEN', BUILD_NEEDS_ROOM_ENV, *WORKFLOW_FILES)}


def pr_build_env() -> dict:
    """pr_code_env for the T2 builds. On the build runner it sets BUILD_NEEDS_ROOM_ENV, so each xcodebuild-lane
    checks the build runner's rules again as it takes its build slot (lane_slots.py)."""
    env = pr_code_env()
    if os.environ.get('SM_LANE_RUNNER_ROLE') == 'build':
        env[BUILD_NEEDS_ROOM_ENV] = '1'
    return env


def git_with_token(tree: Path) -> list[str]:
    """git for this script's own fetch and push: the token goes in a header for that one command, since
    the checkout keeps no credentials."""
    token = os.environ.get('GH_TOKEN')
    if not token:
        return ['git', '-C', str(tree)]
    basic = base64.b64encode(f'x-access-token:{token}'.encode()).decode()
    return ['git', '-C', str(tree), '-c', f'http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}']


def run_bounded(command: list[str], log, timeout: float, grace: float = INTERRUPT_GRACE, env=None) -> int | None:
    """Run in a new process group and return its exit code, or None if it timed out.

    On timeout the whole group gets SIGINT first, so verify-tests.py and xcodebuild-lane stop their
    own xcodebuild and record the interruption, then SIGKILL if it's still there after the grace.
    """
    # The child gets default SIGINT handling even if this process was started with it ignored (as
    # background jobs are), or the interrupt below would be silently ignored all the way down.
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                               env=env or pr_code_env(), preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGINT)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return None


# ---- T2 -----------------------------------------------------------------------------------------

def first_errors(log: Path, limit: int = 5) -> list[str]:
    try:
        text = log.read_text(errors='replace')
    except OSError:
        return []
    lines = text.splitlines()
    found = [line.strip() for line in lines if ' error: ' in line or line.startswith('error:') or 'errSec' in line
             or re.match(r'\w+(Error|Exception): ', line)]  # a Python traceback's last line
    if 'The following build commands failed:' in lines:
        for line in lines[lines.index('The following build commands failed:') + 1:]:
            if not line.strip():
                break
            found.append('failed: ' + line.strip())
    if not found:
        # simctl says why in plain lines ("An error was encountered processing the command (domain=…,
        # code=…):" then the reason), which match none of the above: #440's report said only "Process exit 148".
        found = [line.strip()[:300] for line in lines if line.strip()][-2:]
    return list(dict.fromkeys(found))[:limit]


def run_t2(evidence: Path, runner=None) -> tuple[str, str, list[str]]:
    runner = runner or (lambda command, log, timeout: run_bounded(command, log, timeout, env=pr_build_env()))
    results, details = [], []
    for name, args in T2_BUILDS:
        log = evidence / f't2-{name}.log'
        # Its own DerivedData per destination (#405): after a device build in the same folder, the next warm
        # simulator build reused its cached build plan and never rewrote the missing all-product-headers.yaml.
        command = [str(ROOT / 'scripts/xcodebuild-lane'), '-project', 'SpokenMarginsNative.xcodeproj',
                   '-scheme', 'SpokenMarginsApp', '-derivedDataPath', str(ROOT / f'.build/dd-{name}'), *args]
        with log.open('w') as handle:
            code = runner(command, handle, BUILD_TIMEOUT)
        if code == 0:
            results.append(f'{name} build (pass)')
        else:
            results.append(f'{name} build ({"timed out" if code is None else "fail"})')
            details.append(f'{name} build — expected: succeeds. observed: '
                           f'{"no result after " + duration(BUILD_TIMEOUT) if code is None else f"exit {code}"}. '
                           f'evidence: {log}')
            details += [f'  {line}' for line in first_errors(log)]
    failed = [r for r in results if not r.endswith('(pass)')]
    verdict = 'PASS' if not failed else ('INCONCLUSIVE' if all('timed out' in r for r in failed) else 'FAIL')
    return verdict, ', '.join(results), details


# ---- Automerge ----------------------------------------------------------------------------------

def committed_changes(tree: Path, base: str) -> tuple[list[str], dict[str, str]]:
    """The PR's committed changes against origin/<base>: paths, and SessionKit source diffs (for the
    public-API check). Nothing untracked in the runner's workspace counts."""
    git = ['git', '-C', str(tree)]
    merge_base = subprocess.check_output(git + ['merge-base', 'HEAD', f'origin/{base}'], text=True).strip()
    paths = subprocess.check_output(git + ['diff', '--name-only', merge_base, 'HEAD'], text=True).splitlines()
    diffs, current = {}, None
    for line in subprocess.check_output(git + ['diff', '-U0', merge_base, 'HEAD', '--', 'Packages/SessionKit/Sources'],
                                        text=True).splitlines():
        if line.startswith('diff --git '):
            current = line.split(' b/', 1)[1]
            diffs[current] = ''
        elif current:
            diffs[current] += line + '\n'
    return sorted(set(paths)), diffs


def base_policy(tree: Path, base: str, path: str):
    """A script from the base branch, loaded as a module, so a PR can't change the rules that judge it.
    None if the base doesn't have it yet."""
    import types
    shown = subprocess.run(['git', '-C', str(tree), 'show', f'origin/{base}:{path}'], capture_output=True, text=True)
    if shown.returncode != 0:
        return None
    module = types.ModuleType('lane_policy_' + Path(path).stem.replace('-', '_'))
    module.__file__ = str(tree / path)
    exec(compile(shown.stdout, f'origin/{base}:{path}', 'exec'), module.__dict__)
    return module


def base_scripts_fallback(tree: Path, base: str, into: Path | None = None) -> Path | None:
    """Put the base branch's copy of each scripts/*.py module the tree lacks at the end of sys.path, and
    return the folder (None when the tree lacks none).

    The workflow runs next's lane-runner.py, but its helpers (lane_slots and friends) are imported from the
    tree's scripts/. A PR branched before a helper existed has no copy, so `from lane_slots import ...`
    raised ModuleNotFoundError before the job could report (#904: #886, about 1,400 commits behind next, on
    sm-lane-mac-2's wait for room). The tree's own copies still come first; lane_slots_helper covers a copy
    that is there but older.
    """
    listed = subprocess.run(['git', '-C', str(tree), 'ls-tree', '--name-only', f'origin/{base}', 'scripts/'],
                            capture_output=True, text=True)
    if listed.returncode != 0:
        raise RuntimeError(f'git ls-tree origin/{base} failed: {listed.stderr.strip()[:200]}')
    missing = [name for name in (Path(line).name for line in listed.stdout.splitlines())
               if name.endswith('.py') and name[:-3].isidentifier() and not (tree / 'scripts' / name).exists()]
    if not missing:
        return None
    into = into or Path(tempfile.mkdtemp(prefix='sm-lane-base-scripts-', dir=os.environ.get('RUNNER_TEMP') or None))
    into.mkdir(parents=True, exist_ok=True)
    for name in missing:
        shown = subprocess.run(['git', '-C', str(tree), 'show', f'origin/{base}:scripts/{name}'],
                               capture_output=True, text=True)
        if shown.returncode == 0:
            (into / name).write_text(shown.stdout)
    if str(into) not in sys.path:
        sys.path.append(str(into))
    return into


def diff_scope(tree: Path, base: str) -> dict:
    """test-scope.py's answer for the PR, from the base branch's copy of the policy, so a PR can't
    reclassify itself to skip its builds."""
    policy = base_policy(tree, base, 'scripts/test-scope.py')
    paths, diffs = committed_changes(tree, base)
    return policy.classify(paths, diffs, root=tree)


def t3_scope(tree: Path, base: str, evidence: Path) -> tuple[list[str], list[str]]:
    """test-scope.py's app test classes for the PR's diff, and a note if it couldn't say.

    A broken policy doesn't stop the run: the requested tests still run, and the report says so.
    """
    try:
        scope = diff_scope(tree, base)
    except Exception as error:  # noqa: BLE001 - the report names it
        return [], [f'test-scope.py could not classify the diff ({error!r}), so only the requested tests ran']
    (evidence / 'scope.json').write_text(json.dumps(scope, indent=2))
    return scope_classes(scope), []


def hot_file_violations(tree: Path, base: str, labels) -> list[str]:
    """next's hot-file ratchet on the tree's HEAD (none until the ratchet is on next)."""
    ratchet = base_policy(tree, base, 'scripts/hot_file_ratchet.py')
    return ratchet.violations(tree, f'origin/{base}', 'HEAD', labels) if ratchet else []


def run_fast(evidence: Path, runner=run_bounded) -> tuple[str, list[str]]:
    """--plan fast (host tests): returns (PASS, FAIL or INCONCLUSIVE, details)."""
    python = ROOT / '.venv/bin/python'
    output, log_path = evidence / 'fast', evidence / 'verify-fast.log'
    command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', 'fast',
               '--output', str(output)]
    with log_path.open('w') as log:
        code = runner(command, log, FAST_TIMEOUT)
    if code is None:
        return 'INCONCLUSIVE', [f'host tests (--plan fast) — no result after {duration(FAST_TIMEOUT)}; interrupted. '
                                f'evidence: {log_path}']
    if code == 0 and _read_manifest(output).get('status') == 'verified':
        return 'PASS', []
    return 'FAIL', [f'host tests (--plan fast) — expected: verified. observed: exit {code}. evidence: {log_path}',
                    *[f'  {line}' for line in first_errors(log_path)]]


def run_automerge(scope: dict, evidence: Path, fast=run_fast, t2=run_t2,
                  ratchet=lambda: []) -> tuple[str, str, str, list[str]]:
    """Returns verdict, where, ran, details for the checks the PR's diff needs."""
    tier = int(scope['tier'][1:])
    details = [f'test-scope: {scope["tier"]} ({"; ".join(scope["why"]) or "no changes"})']
    too_big = ratchet()
    if too_big:
        return 'FAIL', 'no build', 'hot-file ratchet: failed', details + [f'hot-file ratchet — {line}'
                                                                          for line in too_big]
    if tier == 0:
        return 'PASS', 'no build', 'nothing to build or test', details + [
            'nothing here reaches the host tests or the app (docs, research or server only)']
    verdict, more = fast(evidence)
    details += more
    if verdict != 'PASS':
        return verdict, 'host only', 'host tests (--plan fast): ' + verdict.lower(), details
    if tier == 1:
        return 'PASS', 'host only', 'host tests (--plan fast): passed', details + [
            'no app build: nothing in the diff reaches the app (T1)']
    verdict, builds, more = t2(evidence)
    return verdict, 'no simulator (compile only)', f'host tests (--plan fast): passed; {builds}', details + more


AUDIT_SHA = re.compile(r'`([0-9a-f]{7,40})`')
CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)  # how the audit task's verdict line opens


def audit_blocker(comments: list[dict], head: str) -> str | None:
    """Why the Codex audits on the PR don't clear its head, or None when the newest audit of the head is clean.

    #441: any audit comment used to clear the PR, whatever commit it covered or what it found. An audit
    counts only if its heading names the head commit (the hourly task's says "on `<sha7>`"), and it clears
    only if its verdict, the first line after the heading, opens "No blocking findings". Anything else
    holds, so a new audit format fails closed.
    """
    audits = []
    for comment in comments:
        body = (comment.get('body') or '').lstrip()
        if body.startswith(AUDITS):
            heading, _, rest = body.partition('\n')
            verdict = next((line.strip() for line in rest.splitlines() if line.strip()), '')
            audits.append((AUDIT_SHA.findall(heading), verdict))
    if not audits:
        return 'has no "Codex audit (Astra)" comment yet'
    on_head = [verdict for shas, verdict in audits if any(head.startswith(sha) for sha in shas)]
    if not on_head:
        audited = next((shas[0] for shas, _ in reversed(audits) if shas), None)
        return (f'has no Codex audit of its head: the audit is on `{audited}`, the head is `{head[:7]}`' if audited
                else f'has no Codex audit naming its head `{head[:7]}`')
    if not CLEAN_AUDIT.match(on_head[-1]):
        return f'the Codex audit on the head `{head[:7]}` has blocking findings (it doesn\'t say "No blocking findings")'
    return None


def merge_blockers(scope: dict, comments: list[dict], head: str) -> list[str]:
    """Why the runner won't merge this PR yet even on PASS: an audited kind of change without a clean Codex
    audit of its head. Lane changes are one of those kinds; they no longer wait for a person (owner rule
    2026-10-01). The audit script re-arms automerge after a clean audit, and that run merges."""
    reasons = []
    risky = sorted({AUDITED[f['category']] for f in scope['files'] if f['category'] in AUDITED})
    if scope.get('lane_paths'):  # owner rule 2026-10-01: lane changes need the audit too (test-scope.py)
        risky.append('the lane')
    audit = audit_blocker(comments, head) if risky else None
    if audit:
        reasons.append(f'it touches {" and ".join(risky)}, and {audit}' if audit.startswith('the ')
                       else f'it touches {" and ".join(risky)} and {audit}')
    return reasons


def t3_gate(comments: list[dict]) -> tuple[str, str] | None:
    """(verdict, why) when the PR's T3 request stands in the way of the runner's merge, else None.

    #408 merged on host tests and builds while its T3 report, minutes older, said FAIL (build-for-testing
    broke before any test ran), and its changed tests had run nowhere. A PR with no T3 request is not
    held. With one, the newest T3 request must have a report, and the newest T3 report must be PASS.
    A FAIL or INCONCLUSIVE on an earlier head still holds a later head until a newer T3 passes.
    """
    asked, latest = -1, None
    for index, comment in enumerate(comments):
        body = comment.get('body') or ''
        url = comment.get('html_url') or 'an earlier comment'
        wanted, verdict, identical = report_identity(body), REPORT.search(body), IDENTICAL.search(body)
        if wanted and verdict:
            if wanted.get('tier') == 'T3':
                latest = index, verdict.group(1), wanted.get('commit', ''), url
        elif identical and NOTE in body:
            if identical.group(1) == 'T3':  # "already reported": the request is answered by that report
                latest = index, identical.group(3), identical.group(2), url
        elif not is_runner_comment(body) and not verdict:  # a Test Desk report is no request (pending_requests)
            request = parse_request(body)
            if request and request['tier'] == 'T3':
                asked = index
    if asked < 0:
        return None
    again = ('the lane job that reports a T3 PASS on this head merges it, testing again only if next has since '
             'moved in ways that matter (#834)')
    if latest is None or latest[0] < asked:
        return 'INCONCLUSIVE', f'held for T3: this PR\'s newest /lane T3 request has no lane report yet; {again}'
    _, verdict, commit, url = latest
    if verdict != 'PASS':
        return verdict, (f'held for T3: the newest T3 lane report on this PR is {verdict} (on {commit[:7]}: {url}), '
                         f'and a PR asked for T3 merges only on a T3 PASS. Fix it or ask for T3 again; {again}')
    return None


def held_for_t3(comments: list[dict], head: str) -> bool:
    """Whether the newest automerge report is on this head and was held by the T3 gate.

    An automerge report on an older head doesn't count: the push since started a new automerge run,
    which reads the T3 reports itself before it merges.
    """
    for comment in reversed(comments):
        body = comment.get('body') or ''
        wanted = report_identity(body)
        if wanted and wanted.get('tier') == 'auto' and REPORT.search(body):
            return wanted.get('commit') == head and any(held in body for held in HELD_FOR_T3)
    return False


def checks_note(head: str, tested_base: str, ran: str, where: str) -> str:
    """The line a held automerge report carries when its host tests and builds passed: what held_checks reads."""
    return '<!-- lane-checks: ' + json.dumps({'commit': head, 'next': tested_base, 'ran': ran, 'where': where},
                                             sort_keys=True) + ' -->'


def held_checks(comments: list[dict], head: str) -> dict | None:
    """The checks the automerge run held for T3 on <head> passed: {'next', 'ran', 'where'}, or None.

    #834: the lane job that reported a T3 PASS ran --plan fast and both builds on sm-lane-mac, the one runner
    that runs T3s, 7 to 39 minutes a PR (2026-10-04), while the build runner could have run them as the T3
    waited. Now the build runner's automerge run does, and its held report says what passed with which next
    (checks_note). Only the newest automerge report counts, and only when it is the runner's own (posted
    with the workflow's token), on <head>, held for T3, and names the head and a full next commit.
    The checks line and the hold must each be a whole line of their own: the PR's own test output appears in
    a report only indented (first_errors), so it can't pass for either. The last checks line counts.
    """
    for comment in reversed(comments):
        body = comment.get('body') or ''
        wanted = report_identity(body)
        if not (wanted and wanted.get('tier') == 'auto' and REPORT.search(body)):
            continue
        found = CHECKS.findall(body)
        if wanted.get('commit') != head or (comment.get('user') or {}).get('login') != BOT[0] \
                or not PENDING_T3_HOLD.search(body) or not found:
            return None
        try:
            checked = json.loads(found[-1])
        except ValueError:
            return None
        if not isinstance(checked, dict) or checked.get('commit') != head \
                or not re.fullmatch(r'[0-9a-f]{40}', str(checked.get('next') or '')):
            return None
        return {'next': checked['next'], 'ran': str(checked.get('ran') or 'host tests and builds'),
                'where': str(checked.get('where') or 'no simulator (compile only)')}
    return None


def t3_request_for_head(comments: list[dict], labels, head: str) -> str | None:
    """The link to a /lane T3 request for <head> that the lane job has still to answer, or None.

    An automerge run on such a PR can't merge: the T3 gate holds it until the T3 reports, and the lane
    job that reports a T3 PASS merges it (#421). On the build runner the automerge run still runs its host
    tests and builds, and that lane job merges without them when next hasn't moved in ways that matter
    (#834, held_checks). Anywhere else it skips them: running them first only to be held cost 20 runs in
    two days, and on the simulator runner they'd take a T3's time. It counts only when lane:queued or
    lane:running says a lane job will answer it, when it is the newest unanswered T2/T3 request, and when
    its `commit:` names <head>: a request for an older head may be running on that head, and then nothing
    else would test this one.
    """
    if not {QUEUED, RUNNING} & set(labels):
        return None
    request, _ = pending_requests(comments)
    if not request or request['tier'] != 'T3' or not t3_gate(comments):
        return None
    named = (request.get('commit') or '').split()
    commit = named[0].lower() if named else ''
    if len(commit) < 7 or not re.fullmatch(r'[0-9a-f]+', commit) or not head.startswith(commit):
        return None
    return request.get('url') or 'the /lane T3 comment'


def build_merge_commit(tree: Path, base: str, head: str, pr: int, title: str) -> tuple[str | None, list[str]]:
    """The exact commit that would land: origin/<base> as first parent, the PR head as second.

    Returns (its SHA, []) or (None, the conflicting files); a conflict leaves the tree clean.
    """
    git = ['git', '-C', str(tree)]
    subprocess.run(git + ['checkout', '--quiet', '--detach', f'origin/{base}'], check=True, capture_output=True)
    name, email = BOT
    merged = subprocess.run(git + ['-c', f'user.name={name}', '-c', f'user.email={email}', 'merge', '--no-ff',
                                   '--quiet', '-m', f'Merge pull request #{pr}: {title}',
                                   '-m', 'Tested as this exact commit and merged by the lane runner.', head],
                            capture_output=True, text=True)
    if merged.returncode == 0:
        return subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip(), []
    conflicts = subprocess.run(git + ['diff', '--name-only', '--diff-filter=U'], capture_output=True,
                               text=True).stdout.split()
    subprocess.run(git + ['merge', '--abort'], capture_output=True)
    return None, conflicts or ['the merge failed']


def push_merge(tree: Path, sha: str, base: str) -> tuple[bool, str]:
    """A plain push of the tested merge commit to <base>: refused unless <base> is still its first parent."""
    pushed = subprocess.run(git_with_token(tree) + ['push', '--quiet', 'origin', f'{sha}:refs/heads/{base}'],
                            capture_output=True, text=True)
    lines = [line.strip() for line in (pushed.stderr + pushed.stdout).splitlines()
             if line.strip() and not line.startswith('hint:')]
    telling = [line for line in lines if 'rejected' in line or line.startswith(('error:', 'fatal:'))]
    return pushed.returncode == 0, (telling or lines or [f'exit {pushed.returncode}'])[0]


def sweep_merge_audit(tree: Path, base: str) -> None:
    """Pushes made with the workflow token start no workflow, so merge-audit's push run never sees the
    runner's merges. After each merge, run next's audit over the last two hours instead. Best effort: never fails a job."""
    try:
        audit = base_policy(tree, base, 'scripts/merge_audit.py')
        if audit:
            audit.main(['--sweep-hours', '2'])
    except Exception as error:  # noqa: BLE001 - the audit is a safety net, not part of the verdict
        print(f'merge-audit sweep skipped: {error!r}')


def next_moved(push_message: str) -> bool:
    """Whether a refused push means the branch moved (so testing again on its newest commit can help)."""
    return 'rejected' in push_message and any(
        reason in push_message for reason in ('fetch first', 'non-fast-forward', 'stale info'))


# What a change on next can't touch for the runner to land a tested PR on it without testing again: the
# build and the project (any .xcodeproj, xcconfig, package manifest or lock), the workflows, every script
# (the build's phases and the lane's own test drivers), the contract schemas the validators read, and the
# browser tests' packages.
BUILD_INPUT_PREFIXES = ('project.yml', 'Config/', '.github/', 'scripts/', 'Contracts/schemas/')
BUILD_INPUT_NAMES = {'Package.swift', 'Package.resolved', 'package.json', 'package-lock.json'}
SKIPPED_SHOWN = 10


def is_build_input(path: str) -> bool:
    return path.startswith(BUILD_INPUT_PREFIXES) or Path(path).name in BUILD_INPUT_NAMES \
        or '.xcodeproj/' in path or '.xcworkspace/' in path or path.endswith('.xcconfig')


def untested_moves(tree: Path, tested_base: str, new_base: str, head: str) -> tuple[list[str] | None, str]:
    """(next's commits since <tested_base>, '') when they can't change what the PR's test showed, else (None, why).

    They can't when they touch none of the PR's files and no build input. Each first-parent commit counts
    with everything it brought in, so a merge of another PR counts with that PR's files.
    """
    git = ['git', '-C', str(tree)]
    if subprocess.run(git + ['merge-base', '--is-ancestor', tested_base, new_base], capture_output=True).returncode:
        return None, f'it no longer contains the tested commit {tested_base[:7]}'
    merge_base = subprocess.check_output(git + ['merge-base', tested_base, head], text=True).strip()
    mine = set(subprocess.check_output(git + ['diff', '--name-only', merge_base, head], text=True).split())
    log = subprocess.check_output(git + ['log', '--first-parent', '-m', '--name-only', '--format=%x00%h %s',
                                         f'{tested_base}..{new_base}'], text=True)
    commits, touched = [], set()
    for line in log.splitlines():
        if line.startswith('\0'):
            commits.append(line[1:])
        elif line.strip():
            touched.add(line.strip())
    shared = sorted(touched & mine)
    if shared:
        return None, f'its commits touch this PR\'s files ({", ".join(shared[:5])})'
    inputs = sorted(p for p in touched if is_build_input(p))
    if inputs:
        return None, f'its commits touch build inputs ({", ".join(inputs[:5])})'
    return commits, ''


def merge_check_untested(head: str, merge_sha: str, base: str, base_sha: str, tested_base: str, ran: str,
                         commits: list[str]) -> str:
    """The merge check for a re-merge pushed without testing again. It never says "Pushing `<sha7>`":
    scripts/phone-build reads that as "the runner tested this exact commit"."""
    shown = ', '.join(f'`{c}`' for c in commits[:SKIPPED_SHOWN]) + \
        (f' and {len(commits) - SKIPPED_SHOWN} more' if len(commits) > SKIPPED_SHOWN else '')
    moved = (f'- {base} has since moved to `{base_sha[:7]}`, and its commits touch none of this PR\'s files and no '
             f'build inputs: {shown}.\n' if commits else
             f'- {base} hasn\'t moved since (the test ran in the automerge run held for T3).\n')
    return (f'{MERGE_CHECK} on `{head[:7]}`: PASS, re-merged onto the newest {base} without re-testing.**\n'
            f'- Tested this PR merged with {base} at `{tested_base[:7]}`. Ran: {ran}.\n'
            + moved +
            f'- So the re-merge `{merge_sha[:7]}` goes to {base} not re-tested. The Test Desk tests {base}\'s merged '
            'tip end to end.\n'
            '_Posted by the lane runner (scripts/lane-runner.py)._')


def merge_check(head: str, merge_sha: str, base: str, base_sha: str, ran: str) -> str:
    return (f'{MERGE_CHECK} on `{head[:7]}`: PASS.**\n'
            f'- Tested the merge commit `{merge_sha[:7]}`: {base} at `{base_sha[:7]}` first, then this PR.\n'
            f'- Ran: {ran}.\n'
            f'- Pushing `{merge_sha[:7]}` to {base} now. If {base} moved meanwhile, the push is refused and the '
            'runner tests again on the newest one, unless the new commits touch none of this PR\'s files and no '
            'build inputs.\n'
            '_Posted by the lane runner (scripts/lane-runner.py)._')


class AutoRunContext:
    """The base of the latest merge/check attempt, available even if that attempt raises."""
    def __init__(self, tested_base: str):
        self.tested_base = tested_base


def run_auto(github, pull: dict, pr: int, base: str, head: str, base_sha: str, evidence: Path,
             comments: list[dict], labels=(), attempts: int = MERGE_ATTEMPTS,
             room_for_builds=None, context: AutoRunContext | None = None,
             checked: dict | None = None) -> tuple[str, str, str, list[str]]:
    """The automerge run: test the merge commit, and push it to <base> on PASS unless something blocks it.

    room_for_builds: for a job that started as host-only beside a simulator job. If the merge commit needs
    the app builds after all, they wait for it first.
    checked: the checks the automerge run held for T3 on this head passed (held_checks). They stand, as after
    a refused push, when next's commits since touch none of the PR's files and no build inputs (#834);
    otherwise this run tests again.
    """
    notes: list[str] = []
    tested_base, skipped = None, None  # the next the last test ran on; next's commits since, when they can't matter
    scope, tested, checks = None, '', []
    if checked:
        try:
            skipped, why = untested_moves(ROOT, checked['next'], base_sha, head)
        except (OSError, subprocess.SubprocessError) as error:  # can't tell: test again
            skipped, why = None, f'the runner could not compare the commits ({error!r})'
        held_run = f'the automerge run held for T3 passed its checks with {base} at {checked["next"][:7]}'
        if skipped is None:
            notes.append(f'{held_run}; tested again on {base_sha[:7]}, because {why}')
        else:
            tested_base, ran, where, verdict = checked['next'], checked['ran'], checked['where'], 'PASS'
            tested = (f'not re-tested: {held_run}, and ' + (
                f'{base}\'s {len(skipped)} commit{"s" if len(skipped) != 1 else ""} since touch none of this PR\'s '
                'files and no build inputs' if skipped else f'{base} hasn\'t moved since'))
    for attempt in range(1, attempts + 1):
        if context is not None:
            context.tested_base = base_sha
        remember_tested(base, base_sha)
        # Each retry gets its own folder: verify-tests.py refuses an --output folder that exists (#404).
        tried = evidence if attempt == 1 else evidence / f'attempt-{attempt}'
        merge_sha, conflicts = build_merge_commit(ROOT, base, head, pr, pull.get('title', ''))
        if conflicts:
            return 'INCONCLUSIVE', 'no simulator', 'nothing', notes + [
                f'The PR does not merge cleanly into {base} ({base_sha[:7]}): {", ".join(conflicts[:10])}. '
                f'Merge {base} into your branch and push; the automerge label runs it again.']
        if skipped is None:
            tried.mkdir(parents=True, exist_ok=True)
            warm = warm_build_folders(ROOT)
            scope = diff_scope(ROOT, base)
            (tried / 'scope.json').write_text(json.dumps(scope, indent=2))
            no_room = room_for_builds() if room_for_builds and int(scope['tier'][1:]) >= 2 else None
            if no_room:
                return 'INCONCLUSIVE', 'no build', 'nothing', notes + [
                    f'{no_room}. Push again, or remove and re-add automerge, to try again.']
            verdict, where, ran, checks = run_automerge(
                scope, tried, ratchet=lambda: hot_file_violations(ROOT, base, set(labels)))
            tested = f'tested the merge commit {merge_sha[:7]} ({base} at {base_sha[:7]} first, then this PR); {warm}'
            if verdict != 'PASS':
                return verdict, where, ran, [tested] + notes + checks
            tested_base = base_sha
        elif scope is None:  # the held run's checks stand; the audit hold still reads the diff's scope
            scope = diff_scope(ROOT, base)
            # The ratchet reads the labels, which may have changed since: hot-file-ok taken off (#926 audit).
            too_big = hot_file_violations(ROOT, base, set(labels))
            if too_big:
                return 'FAIL', 'no build', 'hot-file ratchet: failed', [tested] + notes + [
                    f'hot-file ratchet — {line}' for line in too_big]
        details = [tested] + notes + checks
        latest = github.comments()  # read now: a T3 report or an audit may have landed while this ran
        held = t3_gate(latest)
        if held:  # what passed, for the lane job that reports the T3 PASS (#834)
            return held[0], where, ran, details + [checks_note(head, tested_base, ran, where),
                                                   f'not merged: {held[1]}.']
        blockers = merge_blockers(scope, latest, head)
        if blockers:
            return verdict, where, ran, details + [f'not merged by the runner: {b}. It merges once a Codex audit '
                                                   'of its head says "No blocking findings".' for b in blockers]
        now = github.pull()
        if now['head']['sha'] != head or AUTOMERGE not in {label['name'] for label in now.get('labels', [])} \
                or now.get('state', 'open') != 'open':  # another run merged it meanwhile, or someone closed it
            return verdict, where, ran, details + ['not merged: the PR moved on, lost the automerge label or was '
                                                   'closed while it was tested']
        github.comment(merge_check(head, merge_sha, base, base_sha, ran) if skipped is None else
                       merge_check_untested(head, merge_sha, base, base_sha, tested_base, ran, skipped))
        pushed, message = push_merge(ROOT, merge_sha, base)
        if pushed:
            sweep_merge_audit(ROOT, base)
            return verdict, where, ran, details + [f'merged into {base} as {merge_sha[:7]}']
        if not next_moved(message):  # no permission, network: testing again wouldn't help
            return verdict, where, ran, details + [f'not merged: the push to {base} failed ({message}). A job '
                                                   'whose lane.yml predates push rights (#382) can\'t push.']
        base_sha = fetch_base(ROOT, base)
        try:
            skipped, why = untested_moves(ROOT, tested_base, base_sha, head)
        except (OSError, subprocess.SubprocessError) as error:  # can't tell: test again
            skipped, why = None, f'the runner could not compare the commits ({error!r})'
        refused = f'attempt {attempt}: the push to {base} was refused ({message}), so {base} moved to {base_sha[:7]}'
        if skipped is None:
            notes.append(f'{refused}; tested again on the newest one, because {why}')
        else:
            shown = ', '.join(skipped[:SKIPPED_SHOWN]) + \
                (f' and {len(skipped) - SKIPPED_SHOWN} more' if len(skipped) > SKIPPED_SHOWN else '')
            notes.append(f'{refused}; not re-tested: {base}\'s {len(skipped)} commit{"s" if len(skipped) != 1 else ""} '
                         f'since the tested {tested_base[:7]} touch none of this PR\'s files and no build inputs, so '
                         f'the re-merge onto {base_sha[:7]} goes without testing again (skipped: {shown})')
    return 'PASS', where, ran, details + notes[-1:] + [
        f'not merged: {base} kept moving ({attempts} attempts). Remove and re-add automerge to try again.']


def clean_tree(tree: Path) -> None:
    """Drop changes to tracked files a test run left, so checking out another commit can't refuse."""
    subprocess.run(['git', '-C', str(tree), 'reset', '--hard', '--quiet'], check=True, capture_output=True)


def merge_after_t3(github, pr: int, base: str, head: str, request_id: str, evidence: Path, base_sha: str,
                   why: str) -> str | None:
    """After a T3 PASS on <head>: the automerge run the T3 gate held, run here in the lane job (#421).

    When that held run passed its host tests and builds (held_checks), they aren't run again here unless next
    has since moved in ways that matter (#834): the merge takes seconds instead of minutes on sm-lane-mac.

    Only for a PR that is still open on <head> with the automerge label, whose newest automerge report
    was held by the T3 gate, and that the gate no longer holds. It runs here rather than by re-adding the
    label: a label change made with the workflow's GITHUB_TOKEN starts no workflow run. Returns the report
    it posted, or None when nothing was held. The lane job's own check stays the T3 verdict.
    The automerge job calls it too, after posting a held report: a T3 PASS that landed between its T3 read
    and that post found no held report to release (#421).
    """
    pull = github.pull()
    labels = {label['name'] for label in pull.get('labels', [])}
    comments = github.comments()
    if pull.get('state', 'open') != 'open' or pull['head']['sha'] != head or AUTOMERGE not in labels \
            or not held_for_t3(comments, head) or t3_gate(comments):
        return None
    checked = held_checks(comments, head)  # the build runner's held run passed its checks: no need to repeat
    evidence.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    started_by = [f'{why}; the automerge run on {head[:7]} was held for T3']
    context = AutoRunContext(base_sha)
    try:
        clean_tree(ROOT)  # the T3 ran in this tree; the merge commit checks out next over it
        base_sha = fetch_base(ROOT, base)
        remember_tested(base, base_sha)
        verdict, where, ran, details = run_auto(github, pull, pr, base, head, base_sha, evidence, comments, labels,
                                               context=context, checked=checked)
    except Exception as error:  # noqa: BLE001 - any lane fault is reported, never silent
        verdict, where, ran = 'INCONCLUSIVE', 'lane error', 'nothing'
        details = [f'The lane itself failed: {error!r}. evidence: {evidence}. Remove and re-add automerge to '
                   'run it again.']
    base_sha = context.tested_base
    body = report(request_id, verdict, head, base_sha, 'auto', where, time.monotonic() - started, ran,
                  started_by + details, 'none', str(evidence), NOT_VERIFIED, identity('auto', head, base_sha, []),
                  base_name=base)
    (evidence / 'report.md').write_text(body)
    print(body)
    github.comment(body)
    return body


# ---- Warm build folders -------------------------------------------------------------------------

def warm_root() -> Path:
    return Path(os.environ.get('SM_LANE_WARM_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane/warm-build')


def sessionkit_key(tree: Path) -> str | None:
    """The SessionKit source tree in the tree under test (its git tree hash), or None."""
    found = subprocess.run(['git', '-C', str(tree), 'rev-parse', 'HEAD:Packages/SessionKit'],
                           capture_output=True, text=True)
    return found.stdout.strip()[:12] if found.returncode == 0 and found.stdout.strip() else None


def project_key(tree: Path) -> str:
    """The Xcode project file in the tree under test (its git blob hash), or 'none'."""
    found = subprocess.run(['git', '-C', str(tree), 'rev-parse', f'HEAD:{PROJECT_FILE}'], capture_output=True, text=True)
    return found.stdout.strip()[:8] if found.returncode == 0 and found.stdout.strip() else 'none'


def checkout_folder(tree: Path) -> str:
    """One folder of caches per checkout path: DerivedData and SwiftPM state record absolute paths (#405)."""
    return 'checkout-' + hashlib.sha1(str(tree.resolve()).encode()).hexdigest()[:8]


def missing_binary_artifacts(cache: Path) -> list[str]:
    """Binary artifacts (onnxruntime.xcframework) that a cache's SwiftPM state lists but that aren't on disk."""
    missing = []
    for state in [cache / 'sessionkit/workspace-state.json', *cache.glob('root/dd*/SourcePackages/workspace-state.json')]:
        try:
            artifacts = json.loads(state.read_text()).get('object', {}).get('artifacts', [])
        except (OSError, ValueError, AttributeError):
            continue
        for artifact in artifacts if isinstance(artifacts, list) else []:
            path = artifact.get('path') if isinstance(artifact, dict) else None
            if path and not (state.parent / path).exists():  # absolute paths ignore state.parent
                missing.append(Path(path).name)
    return missing


_WARM_LOCKS: dict = {}


def warm_build_folders(tree: Path, root: Path | None = None, free=lambda path: shutil.disk_usage(path).free) -> str:
    """Link the tree's build folders to the cache for its SessionKit tree; returns a line for the report."""
    import fcntl
    shared = root or warm_root()
    sk = sessionkit_key(tree)
    if not sk:
        return 'build folders: cold (no SessionKit tree to key a cache on)'
    key = f'{sk}-{project_key(tree)}'
    root = shared / checkout_folder(tree)
    root.mkdir(parents=True, exist_ok=True)
    wanted = root / f'sk-{key}'
    for old in shared.glob('sk-*'):  # caches from before #405, shared by both runners
        if old.is_dir() and not _cache_busy(old):
            shutil.rmtree(old, ignore_errors=True)
    others = sorted((d for d in root.iterdir() if d.is_dir() and d.name.startswith('sk-') and d != wanted),
                    key=lambda d: d.stat().st_mtime, reverse=True)
    for old in others[WARM_KEEP - 1:]:
        if not _cache_busy(old):
            shutil.rmtree(old, ignore_errors=True)
    if free(root) < WARM_FREE_FLOOR:
        for old in [d for d in shared.glob('checkout-*/sk-*') if d.is_dir() and d != wanted]:
            if not _cache_busy(old):
                shutil.rmtree(old, ignore_errors=True)
        if free(root) < WARM_FREE_FLOOR:
            return f'build folders: cold (less than {WARM_FREE_FLOOR // 10**9} GB free)'
    was_warm = (wanted / 'root').is_dir()
    for name in ('root', 'sessionkit'):
        (wanted / name).mkdir(parents=True, exist_ok=True)
    lock = _WARM_LOCKS.get(key)  # a later attempt, or the automerge run after a T3, holds it already
    if lock is None:
        lock = open(wanted / '.lock', 'a+')
        try:  # flock belongs to the open file, so a second open in this process would see it as busy
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.close()
            return f'build folders: cold (the SessionKit {key} cache is in use by another runner job)'
    for held in _WARM_LOCKS.values():  # a new key in a later attempt: this job moves to the new cache
        if held is not lock:
            held.close()
    _WARM_LOCKS.clear()
    _WARM_LOCKS[key] = lock  # held until this job's process exits
    os.utime(wanted)
    shutil.rmtree(wanted / 'root/dd', ignore_errors=True)  # both T2 builds' shared DerivedData before #405's split
    for link, target in ((tree / '.build', wanted / 'root'), (tree / 'Packages/SessionKit/.build', wanted / 'sessionkit')):
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            shutil.rmtree(link)
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target, target_is_directory=True)
    missing = missing_binary_artifacts(wanted)  # read through the links: the state records the tree's paths
    if missing:  # SwiftPM won't fetch an artifact its state says it has, so the build fails on it (#405)
        for name in ('root', 'sessionkit'):
            shutil.rmtree(wanted / name, ignore_errors=True)
            (wanted / name).mkdir(exist_ok=True)
        return f'build folders: cold, cache reset ({", ".join(sorted(set(missing)))} was missing) (SessionKit {key})'
    return f'build folders: {"warm" if was_warm else "cold, new cache"} (SessionKit {key})'


def _cache_busy(cache: Path) -> bool:
    import fcntl
    try:
        with open(cache / '.lock', 'a+') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    except OSError:
        return False


# ---- The build-only runner ----------------------------------------------------------------------

def wait_for_room_to_build(out=sys.stdout, max_wait: float = BUILD_RUNNER_WAIT, poll: float = 30,
                           clock=time.monotonic, sleep=time.sleep, simulator_jobs=None, pressure=None,
                           free=lambda: shutil.disk_usage(Path.home()).free, builds=None, note=None) -> str | None:
    """The second runner builds only while the Mac has room: normal memory pressure and BUILD_RUNNER_FREE_DISK
    free. Returns None when there's room, or why it gave up waiting.

    Trial, extended 2026-10-01: sm-lane-mac-2 spent 6.9 of its 12.7 busy hours in a day waiting here for a
    simulator job (mostly the Test Desk's) while the Mac was ~60% idle, and the host-only trial covered few
    jobs because most automerge jobs build. A build may now start beside one simulator job on the host-only
    terms (pressure read as normal now, BESIDE_SIMULATOR_FREE_DISK free) while the one build slot lane_slots
    leaves during a simulator job is free; note(text) is called when it does. Never beside two. This is the
    check when the job starts; each build checks again as it takes its slot (BUILD_NEEDS_ROOM_ENV).
    """
    from lane_slots import memory_pressure_level, simulator_jobs_running
    builds = builds or lane_slots_helper('build_jobs_running', lambda: None)
    problem, beside = wait_for_room(out, max_wait, poll, clock, sleep, simulator_jobs or simulator_jobs_running,
                                    pressure or memory_pressure_level, free, builds)
    if beside and note:
        note(beside)
    return problem


def lane_slots_helper(name: str, fallback):
    """lane_slots.<name>, or fallback when the tree's copy of lane_slots.py predates it.

    The workflow runs next's lane-runner.py, but lane_slots comes from the PR's checkout (main() puts the
    tree's scripts/ first on sys.path, and the module stays loaded after the merge commit is checked out).
    A branch that hasn't merged next since a helper landed lacks it, and a plain import raised ImportError
    before the job could report (#656 audit). Every lane_slots name newer than #656 is looked up here, with
    a fallback that keeps the older, more careful behaviour.
    """
    import lane_slots
    return getattr(lane_slots, name, fallback)


def pressure_is_normal(level) -> bool:
    """Only a level read as normal (1) counts: running beside a simulator needs to know, not guess."""
    return level == 1


def wait_for_room_to_test_on_host(out=sys.stdout, max_wait: float = BUILD_RUNNER_WAIT, poll: float = 30,
                                  clock=time.monotonic, sleep=time.sleep, simulator_jobs=None, pressure=None,
                                  free=lambda: shutil.disk_usage(Path.home()).free) -> tuple:
    """Room for a host-only job (T0/T1: no xcodebuild, no simulator) on the build runner: (None or why it gave
    up, a note when it runs beside a simulator job).

    Trial (2026-10-01): the build runner sat idle whenever any simulator job ran, the Test Desk's included
    (394 minutes in a day). A host-only job may now start beside one while the kernel reads memory pressure
    as normal and more than BESIDE_SIMULATOR_FREE_DISK is free. With no simulator job, the build runner's
    usual rules hold. Builds wait in wait_for_room_to_build.
    """
    from lane_slots import memory_pressure_level, simulator_jobs_running
    return wait_for_room(out, max_wait, poll, clock, sleep, simulator_jobs or simulator_jobs_running,
                         pressure or memory_pressure_level, free)


def wait_for_room(out, max_wait, poll, clock, sleep, simulator_jobs, pressure, free, builds=None) -> tuple:
    """(None or why it gave up, a note when there's room beside a simulator job). builds, for a job that builds:
    how many build slots are held (None: can't tell, so it doesn't build beside a simulator job); beside a
    simulator job, it needs the one slot left then, and one simulator."""
    started, last_note = clock(), None
    while True:
        jobs, level, room = simulator_jobs(), pressure(), free()
        busy = []
        if jobs:
            if not pressure_is_normal(level):
                busy.append('a simulator job is running and memory pressure is '
                            + ('unreadable' if level is None else 'above normal'))
            if room < BESIDE_SIMULATOR_FREE_DISK:
                busy.append(f'a simulator job is running and less than {BESIDE_SIMULATOR_FREE_DISK // 2**30} GiB '
                            'of disk is free')
            held = builds() if builds and jobs == 1 else 0
            if builds and jobs > 1:
                busy.append('two simulator jobs are running')
            elif held is None:
                busy.append('a simulator job is running, and this checkout\'s lane_slots.py can\'t count build '
                            'slots (merge next into the branch to build beside one)')
            elif held:
                busy.append('a simulator job is running and the one build slot it leaves is taken')
        else:
            if level not in (1, None):
                busy.append('memory pressure is above normal')
            if room < BUILD_RUNNER_FREE_DISK:
                busy.append(f'less than {BUILD_RUNNER_FREE_DISK // 10**9} GB of disk is free')
        if not busy:
            return None, (f'{"built" if builds else "ran"} beside a simulator job (trial): memory pressure normal, '
                          f'{room // 2**30} GiB free' if jobs else None)
        waited = clock() - started
        if waited >= max_wait:
            return f'the build runner waited {duration(waited)} for room: {"; ".join(busy)}', None
        if last_note is None or clock() - last_note >= 300:
            print(f'[lane] build runner waiting ({duration(waited)} so far): {"; ".join(busy)}', file=out, flush=True)
            last_note = clock()
        sleep(poll)


def host_only_scope(tree: Path, base: str) -> bool:
    """Whether the PR's diff needs no app build (T0 or T1), by the base branch's policy. Unsure means no."""
    try:
        return int(diff_scope(tree, base)['tier'][1:]) <= 1
    except Exception:  # noqa: BLE001 - a job that can't tell waits like a build
        return False


def note_beside_simulator(request_id: str, pr: int, note: str) -> None:
    """One line per job that ran beside a simulator job, so the trial can be judged against crash reports."""
    import datetime
    from lane_slots import state_dir
    try:
        state_dir().mkdir(parents=True, exist_ok=True)
        with (state_dir() / BESIDE_SIMULATOR_LOG).open('a') as log:
            log.write(f'{datetime.datetime.now().astimezone().isoformat(timespec="seconds")}\t{request_id}\t'
                      f'PR #{pr}\t{note}\n')
    except OSError as error:
        print(f'[lane] could not note the trial in {BESIDE_SIMULATOR_LOG}: {error!r}')


# ---- T3 -----------------------------------------------------------------------------------------

def full_selector(selector: str) -> str:
    return selector if selector.startswith(APP_TEST_TARGET + '/') else f'{APP_TEST_TARGET}/{selector}'


def scope_classes(scope: dict) -> list[str]:
    """The app test classes test-scope.py suggests for the diff."""
    if 'app_tests' in scope:
        return list(scope['app_tests'])
    # A test-scope.py from before #351 names them only in its suggested lane request.
    return re.findall(rf'{APP_TEST_TARGET}/(\w+)', scope.get('lane_request') or '')


def with_scope_classes(requested: list[str], classes: list[str]) -> tuple[list[str], list[str]]:
    """The requested selectors plus the diff's test classes, and which classes that added.

    #220 merged while a test in the class its diff touched failed on every head: each request named a
    few methods, and the runner ran only those. A requested method inside an added class is dropped,
    since the class runs it anyway.
    """
    named = {full_selector(s) for s in requested}
    added = [c for c in dict.fromkeys(classes) if full_selector(c) not in named]
    covered = tuple(full_selector(c) + '/' for c in added)
    return [s for s in requested if not full_selector(s).startswith(covered)] + added, added


def count_tests(selector: str, plans: dict[str, set]) -> int:
    full = full_selector(selector)
    return len({t for tests in plans.values() for t in tests if t == full or t.startswith(full + '/')})


def plan_for_tests(selectors: list[str], plans: dict[str, set]) -> tuple[dict[str, list[str]], list[str]]:
    """Group selectors by the plans holding them; selectors no plan holds are returned separately.

    A class split across plans (SupertonicSpeechTests: one method runs only in AudioAdapters) goes to
    each plan that runs part of it, or the rest of it would silently not run.
    """
    grouped, unknown = {}, []
    for selector in selectors:
        full = full_selector(selector)
        holding = [p for p, tests in plans.items() if any(t == full or t.startswith(full + '/') for t in tests)]
        for plan in holding:
            grouped.setdefault(plan, []).append(full)
        if not holding:
            unknown.append(selector)
    return grouped, unknown


def summarize_manifest(manifest: dict) -> dict:
    """Test counts, failed tests, crash reports and whether a flood or timeout stopped the run.

    A build that was interrupted (timeout or flood) is not a build failure: that's INCONCLUSIVE.
    """
    summary = {'passed': 0, 'failed': [], 'crashes': [], 'flood': False, 'interrupted': False, 'build_failed': False,
               'out_of_time': None}
    for step in manifest.get('steps', []):
        if step.get('interrupted') and not step.get('simulator_crash_report') and step.get('timeout_seconds'):
            summary['out_of_time'] = (step.get('name'), step.get('timeout_seconds'))
        for test, record in (step.get('tests') or {}).items():
            if record.get('status') == 'passed':
                summary['passed'] += 1
            elif record.get('status') == 'failed':
                summary['failed'].append(test)
        summary['crashes'] += [Path(p).name for p in step.get('simulator_crash_reports', [])]
        summary['flood'] |= bool(step.get('simulator_crash_report'))
        summary['interrupted'] |= bool(step.get('interrupted'))
        summary['build_failed'] |= (step.get('name') == 'build-for-testing' and bool(step.get('errors'))
                                    and not step.get('interrupted'))
    return summary


def failed_step_errors(manifest: dict, output: Path, limit: int = 3) -> list[str]:
    """The first error lines from the log of the step that stopped verify-tests.py.

    Its log stays on the Mac, so without these a report says only "Process exit 70" (#410).
    """
    for step in manifest.get('steps', []):
        if step.get('exit_code') and not step.get('interrupted'):
            return first_errors(output / f'{step.get("name")}.log', limit)
    return []


def t3_verdict(summaries: list[dict], statuses: list[str]) -> str:
    if statuses and all(status == 'verified' for status in statuses):
        return 'PASS'
    # A plan that lost its simulator failed for the lane's reasons (#411: exit 70 when the device vanished).
    if any((s['failed'] or s['build_failed']) and not s.get('device_lost') for s in summaries):
        return 'FAIL'
    return 'INCONCLUSIVE'


READINESS_STEPS = ('simulator-boot', 'simulator-ready')


def run_plans(grouped: dict[str, list[str]], run_plan, evidence: Path,
              device_available=lambda: True) -> tuple[list, list, list, list]:
    """Run each plan's selectors; stop at the first crash flood (AGENTS.md: don't reboot in a loop).

    Also stop when a plan ends with the simulator not ready or gone: the next plan would only fail to find
    it (#440: exit 148 at the readiness step, then "No matching supported simulator" for the adapters plan).
    """
    summaries, statuses, ran, details = [], [], [], []
    plans = list(grouped.items())
    for position, (plan, selectors) in enumerate(plans):
        output = evidence / f'verify-{plan}'
        started = time.monotonic()
        manifest = run_plan(plan, selectors, output)
        took = time.monotonic() - started
        summary = summarize_manifest(manifest)
        summaries.append(summary)
        statuses.append(manifest.get('status', 'missing'))
        ran.append(f'{", ".join(s.split("/", 1)[1] for s in selectors)} ({summary["passed"]} passed'
                   f'{", " + str(len(summary["failed"])) + " failed" if summary["failed"] else ""}'
                   f'; {plan} plan, build and tests, {duration(took)})')
        attachments = [a for step in manifest.get('steps', []) for a in step.get('attachments', [])]
        if attachments:  # older PR checkouts have no exporter/helper; load only when evidence exists
            from lane_xcresult_attachments import report_lines
            details.extend(report_lines(attachments))
        for test in summary['failed'][:10]:
            details.append(f'{test} — expected: passes. observed: failed. evidence: {output}/tests.xcresult')
        if summary['out_of_time']:
            step, limit = summary['out_of_time']
            what = {'xcode-tests': 'test run', 'build-for-testing': 'build'}.get(step, step)
            details.append(f'{plan}: the {what} ran out of its own {duration(limit)} budget (verify-tests.py `{step}`) '
                           f'after {summary["passed"]} passing test{"s" if summary["passed"] != 1 else ""}. '
                           'The simulator\'s boot has a separate budget and had finished before it started.')
        if manifest.get('status') != 'verified' and not summary['failed']:
            details.append(f'{plan}: {manifest.get("error") or manifest.get("status")}. evidence: {output}/manifest.json')
            details += [f'{plan}: {line}' for line in failed_step_errors(manifest, output)]
        if summary['flood']:
            skipped = [p for p, _ in plans[position + 1:]]
            if skipped:
                details.append(f'Stopped after the crash flood; not run: {", ".join(skipped)}.')
                statuses.append('not run')
            break
        if manifest.get('status') != 'verified':
            stopped_at = next((step.get('name') for step in manifest.get('steps', []) if step.get('exit_code')),
                              None)  # a readiness step that ran out of time counts too
            gone = not device_available()
            if gone or stopped_at in READINESS_STEPS:
                summary['device_lost'] = True
                skipped = [p for p, _ in plans[position + 1:]]
                why = ('the fresh simulator is gone (no longer listed by `simctl list devices available`)' if gone
                       else f'the fresh simulator was not ready (verify-tests.py `{stopped_at}`)')
                details.append(f'{plan}: {why}, so this is the lane\'s fault, not the PR\'s'
                               + (f'; not run: {", ".join(skipped)}.' if skipped else '.'))
                if skipped:
                    statuses.append('not run')
                break
    return summaries, statuses, ran, details


def first_boot(udid: str, log) -> tuple:
    """Boot the fresh simulator under the lane's boot rules (scripts/lane_sim.py).

    Returns (None when ready or the reason it isn't, details such as the memory pressure at boot).
    """
    import lane_sim
    info = {}
    try:
        lane_sim.boot(udid, f'runner boot {udid}', out=log, info=info, first_boot=True)
    except lane_sim.BootError as error:
        return str(error), info
    return None, info


def run_t3(tests: list[str], request_id: str, evidence: Path,
           classes: list[str] = ()) -> tuple[str, str, str, list[str], str, str]:
    """Returns verdict, where, ran, details, crashes, cc.

    Runs the requested selectors plus `classes`, test-scope.py's app test classes for the diff.
    """
    from test_inventory import plan_tests
    if not tests and not classes:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The T3 request names no tests, and test-scope.py suggests '
                'no app test classes for this diff. Add `tests: Class/method, …`.'], 'none', '')
    plans = {plan: plan_tests(ROOT, name) for plan, name in PLANS.items()}
    _, missing = plan_for_tests(tests, plans)  # checked before an added class can absorb a misspelled method
    if missing:
        return ('FAIL', 'no simulator', 'nothing', [f'Not in any app test plan: {", ".join(missing)}. A named test '
                'that does not exist is a failure (verify-tests.py rule).'], 'none', '')
    selectors, added = with_scope_classes(tests, list(classes))
    grouped, unknown = plan_for_tests(selectors, plans)
    scope = []
    running = [c for c in added if c not in unknown]
    if running:
        count = sum(count_tests(c, plans) for c in running)
        scope.append(f'test-scope added for this diff: {", ".join(f"{c} ({count_tests(c, plans)})" for c in running)}; '
                     f'{count} test{"s" if count != 1 else ""} beyond the request')
    if len(running) < len(added):
        scope.append(f'test-scope suggested, but no app test plan runs: {", ".join(c for c in added if c in unknown)}')
    if not grouped:
        return 'INCONCLUSIVE', 'no simulator', 'nothing', scope + ['Nothing to run.'], 'none', ''
    verdict, where, ran, details, crashes, cc = _run_t3_grouped(grouped, request_id, evidence)
    return verdict, where, ran, scope + details, crashes, cc


def _run_t3_grouped(grouped, request_id, evidence):
    """Take the simulator slot and run the grouped selectors on a fresh device."""
    import lane_sim
    runtime = lane_sim.newest_runtime()
    if not runtime:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', [f'No iOS {lane_sim.IOS_MAJOR} simulator runtime is installed.'],
                'none', '')
    from lane_slots import acquire_simulator_slot, release_handle
    try:
        slot = acquire_simulator_slot(f'runner T3 {request_id}', out=sys.stdout, max_wait=RUNNER_SLOT_WAIT)
    except TimeoutError as error:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The Mac\'s simulator slots stayed busy (a Test Desk job or '
                f'another run, and no room for a second simulator), so this run did not start one: {error}'], 'none', '')
    try:
        return _t3_on_fresh_device(grouped, request_id, evidence, runtime)
    finally:
        release_handle(slot)


def _t3_on_fresh_device(grouped, request_id, evidence, runtime):
    """The T3 job proper; the caller holds the simulator slot throughout."""
    claim = claim_runner_device(RUNNER_SIMULATOR_PREFIX + request_id)
    try:
        return _t3_on_claimed_device(grouped, request_id, evidence, runtime)
    finally:
        release_runner_device(claim)


def _t3_on_claimed_device(grouped, request_id, evidence, runtime):
    import lane_sim
    udid = lane_sim.create_temporary(RUNNER_SIMULATOR_PREFIX + request_id)
    where = f'fresh iPhone 17, {runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")}'
    python = ROOT / '.venv/bin/python'

    def run_plan(plan, selectors, output):
        command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', plan,
                   '--device', udid, '--output', str(output)]
        for selector in selectors:
            command += ['--only-testing', selector]
        with (evidence / f'verify-{plan}.log').open('w') as log:
            if run_bounded(command, log, T3_TIMEOUT) is None:
                return {**_read_manifest(output), 'status': 'timed out',
                        'error': f'the runner\'s {duration(T3_TIMEOUT)} budget for the whole verify-tests.py run '
                                 '(build and tests) ran out; interrupted'}
        return _read_manifest(output) or {'status': 'missing', 'error': 'verify-tests.py wrote no manifest'}

    try:
        boot_started = time.monotonic()
        with (evidence / 'first-boot.log').open('w') as log:
            problem, boot_info = first_boot(udid, log)
        boot_seconds = time.monotonic() - boot_started  # the boot alone, before any build or test
        if problem:
            details = [f'The fresh simulator did not boot: {problem} evidence: {evidence}/first-boot.log']
            if boot_info.get('period') == 'two-simulator' and 'not ready after' in problem \
                    and lane_sim.back_to_one_simulator(f'a two-simulator T3 boot ({request_id}) timed out: {problem}'):
                details.append('This boot ran while two simulators were up, so the lane is back to one simulator '
                               '(noted on #184).')
            return 'INCONCLUSIVE', where, 'nothing', details, 'watched during boot', ''
        lane_sim.start_watcher(udid, ROOT / 'scripts/lane-sim-boot',  # stops the device at a SpringBoard crash
                               crash_window=boot_info.get('boot_window'))
        summaries, statuses, ran, details = run_plans(grouped, run_plan, evidence,
                                                      lambda: lane_sim.is_available(udid))
        details.insert(0, f'first boot of the fresh simulator took {duration(boot_seconds)} (memory pressure at boot: '
                          f'{boot_info.get("pressure", "unknown")}, after waiting {boot_info.get("pressure_waited", 0)}s; '
                          f'{boot_info.get("period", "one-simulator")} period)')
        if boot_info.get('tolerated'):
            details.insert(1, f'tolerated one SpringBoard change in the first 30 s of the first boot (owner\'s rule, '
                              f'#184): {boot_info["tolerated"]}')
    finally:
        lane_sim.release(udid)
    watched = lane_sim.unsafe_devices().get(udid)
    if watched and watched['reason'].startswith('late crash report'):
        # A crash during the boot, reported after it: the device is marked unsafe, but the run itself went on.
        details.append(f'after the run started, a crash report arrived for a crash during the boot ({watched["reason"]}); '
                       'the device was marked unsafe and deleted')
        watched = None
    crash_names = [c for s in summaries for c in s['crashes']]
    flood = any(s['flood'] for s in summaries) or bool(watched)
    crashes = ('crash flood: ' if flood else '') + (', '.join(crash_names) if crash_names else 'none')
    if watched:
        crashes += f' (the SpringBoard watcher stopped the device: {watched["reason"]})'
        statuses.append('stopped by the SpringBoard watcher')
    elif flood:
        crashes += ' (simulator shut down, run stopped)'
    cc = '@uncomposed: SpringBoard crashed on the lane runner\'s simulator.' if flood else ''
    verdict = 'INCONCLUSIVE' if watched else t3_verdict(summaries, statuses)  # a simulator crash, not the app
    timed_out = any(s['out_of_time'] for s in summaries) or 'timed out' in statuses
    if verdict == 'INCONCLUSIVE' and timed_out and boot_info.get('period') == 'two-simulator' \
            and lane_sim.back_to_one_simulator(f'a two-simulator T3 run ({request_id}) ended INCONCLUSIVE on a timeout.'):
        details.append('This ran while two simulators were up and timed out, so the lane is back to one simulator '
                       '(noted on #184).')
    return verdict, where, '; '.join(ran), details, crashes, cc


def _read_manifest(output: Path) -> dict:
    try:
        return json.loads((output / 'manifest.json').read_text())
    except (OSError, ValueError):
        return {}


# ---- GitHub -------------------------------------------------------------------------------------

class GitHub:
    def __init__(self, repo: str, pr: int):
        self.repo, self.pr = repo, pr

    def api(self, *args: str) -> str:
        return subprocess.check_output(['gh', 'api', *args], text=True)

    def pull(self) -> dict:
        return json.loads(self.api(f'repos/{self.repo}/pulls/{self.pr}'))

    def comments(self) -> list[dict]:
        lines = self.api('--paginate', '--jq', '.[] | @json', f'repos/{self.repo}/issues/{self.pr}/comments')
        return [json.loads(line) for line in lines.splitlines() if line.strip()]

    def comment(self, body: str) -> str:
        return json.loads(self.api(f'repos/{self.repo}/issues/{self.pr}/comments', '-f', f'body={body}'))['html_url']

    def relabel(self, remove: str | None, add: str | None) -> None:
        if remove:
            subprocess.run(['gh', 'api', '-X', 'DELETE',
                            f'repos/{self.repo}/issues/{self.pr}/labels/{remove.replace(":", "%3A")}'],
                           capture_output=True)
        if add:
            self.api('-X', 'POST', f'repos/{self.repo}/issues/{self.pr}/labels', '-f', f'labels[]={add}')


# ---- Auto-revert of a lane change that broke the lane (owner rule 2026-10-01) ---------------------

OPS_ISSUE = 337
AUTO_REVERT = 'Lane auto-revert'  # how both the revert comment and the could-not-revert comment on #337 start
STOPPED = 'stopped before reporting'  # cleanup()'s note when a job died before its report
MERGE_SUBJECT = re.compile(r'^Merge pull request #(\d+)(?::\s*(.*)| from \S+)')
TESTED_ON = re.compile(r'\(tested merged with (\S+) at ([0-9a-f]{7,40})\)')
REVERTS = re.compile(r'^This reverts commit ([0-9a-f]{40})', re.M)  # git revert's own line
# INCONCLUSIVE reports that are the PR's or the request's own doing, not the lane's.
NOT_LANE_FAULTS = (('does not merge cleanly', 'a merge conflict'),
                   ('names no tests', 'a T3 request with no tests'), ('Nothing to run.', 'nothing to run'))
PENDING_T3_HOLD = re.compile(r'^not merged: held for T3:', re.M)
LANE_MERGE_LOOKBACK = 300


def utc(stamp: str):
    """A git or GitHub ISO 8601 time as an aware datetime (Python 3.9 can't read a trailing Z)."""
    import datetime
    return datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).astimezone(datetime.timezone.utc)


def lane_merge(tree: Path, base: str, is_lane, lookback: int = LANE_MERGE_LOOKBACK) -> dict | None:
    """The newest merge into <base> (first-parent history) whose changes touch the lane, or None.

    Returns {'sha', 'parent', 'time', 'pr', 'title', 'subject', 'paths'}: paths are the lane paths it
    changed against next before it, title is None when the subject doesn't carry it (a GitHub merge).
    """
    log = subprocess.check_output(['git', '-C', str(tree), 'log', '--first-parent', '--merges',
                                   '--diff-merges=first-parent', '--name-only', f'-n{lookback}',
                                   '--format=@@%H %P|%cI|%s', f'origin/{base}'], text=True)
    merge = None
    for line in log.splitlines() + ['@@']:
        if line.startswith('@@'):
            if merge and merge['paths']:
                return merge
            if line == '@@':
                return None
            shas, stamp, subject = line[2:].split('|', 2)
            sha, parent = shas.split()[:2]
            pr = MERGE_SUBJECT.match(subject)
            merge = {'sha': sha, 'parent': parent, 'time': stamp, 'subject': subject,
                     'pr': int(pr.group(1)) if pr else None, 'title': pr.group(2) if pr else None, 'paths': []}
        elif line.strip() and merge is not None and is_lane(line.strip()):
            merge['paths'].append(line.strip())
    return None


def lane_report_verdict(body: str) -> tuple[bool, str] | None:
    """For a runner comment: (whether it is a runner fault, why), or None if it isn't a lane report.

    A runner fault is an INCONCLUSIVE report for a lane reason (a boot failure, the build runner's room
    wait, a crash in the runner, a missing tool or runtime, a timeout), or a job that stopped before it
    could report. A merge conflict, a T3 hold or a malformed request is not, and neither is FAIL.
    """
    if NOTE in body and STOPPED in body:
        return True, 'the job stopped before it could report'
    verdict = REPORT.search(body)
    if not verdict or not MARKER.search(body):
        return None
    if verdict.group(1) != 'INCONCLUSIVE':
        return False, verdict.group(1)
    if PENDING_T3_HOLD.search(body):
        return False, 'INCONCLUSIVE (held for T3)'
    for text, why in NOT_LANE_FAULTS:
        if text in body:
            return False, f'INCONCLUSIVE ({why})'
    lines = [line.strip() for line in body.splitlines()[3:] if line.strip() and not line.startswith('<!--')]
    return True, 'INCONCLUSIVE: ' + (lines[0][:200] if lines else 'no reason given')


def lane_reports_after(tree: Path, merge: dict, comments, base: str = 'next') -> list[dict]:
    """The runner's lane reports on PRs from after the lane merge, oldest first, at most two.

    `comments` is the repository's issue comments, oldest first. A report counts only if it says it
    tested <base> (not a lane-check/** branch, which tests some other lane change) at a commit that
    already had the merge in it, so a job that started before the merge landed doesn't count. A
    stopped-job note counts on the same terms, from the base cleanup() found recorded; one that names
    no tested commit (the job stopped before it fetched one, or a runner from before 2026-10-01's
    audit fix) doesn't count.
    """
    since, found = utc(merge['time']), []
    for comment in comments:
        body = comment.get('body') or ''
        if (comment.get('user') or {}).get('login') not in BOT or '/pull/' not in (comment.get('html_url') or ''):
            continue
        if utc(comment.get('created_at') or '1970-01-01T00:00:00Z') <= since:
            continue
        judged = lane_report_verdict(body)
        if judged is None:
            continue
        tested = TESTED_ON.search(body)
        if not tested or tested.group(1) != base:
            continue
        if subprocess.run(['git', '-C', str(tree), 'merge-base', '--is-ancestor', merge['sha'], tested.group(2)],
                          capture_output=True).returncode != 0:
            continue
        found.append({'url': comment.get('html_url'), 'fault': judged[0], 'why': judged[1]})
        if len(found) == 2:
            break
    return found


def reverts_on_base(tree: Path, merge: dict, is_lane) -> list[str]:
    """The lane changes on <base> before the merge that the merge's own commits revert, by git revert's
    "This reverts commit <sha>" line, not by any title. A commit the PR branch reverted that was never
    on <base> (a branch undoing its own first try), or a reverted commit that touched no lane path,
    doesn't make the merge a revert of a lane change."""
    git = ['git', '-C', str(tree)]
    log = subprocess.check_output(git + ['log', '--format=%B%x00', f'{merge["parent"]}..{merge["sha"]}'], text=True)
    undone = []
    for sha in dict.fromkeys(REVERTS.findall(log)):
        if subprocess.run(git + ['merge-base', '--is-ancestor', sha, merge['parent']],
                          capture_output=True).returncode != 0:
            continue
        changed = subprocess.run(git + ['diff', '--name-only', f'{sha}^1', sha], capture_output=True, text=True)
        if changed.returncode == 0 and any(is_lane(path) for path in changed.stdout.splitlines()):
            undone.append(sha)
    return undone


def reverted_by(tree: Path, base: str, sha: str) -> str | None:
    """The commit on <base> whose message says it reverts <sha> (git revert's own line), if any."""
    found = subprocess.run(['git', '-C', str(tree), 'log', '--format=%H', '-n1', '--fixed-strings',
                            f'--grep=This reverts commit {sha}', f'origin/{base}'], capture_output=True, text=True)
    return found.stdout.strip() or None


def revert_merge(tree: Path, base: str, merge: dict, message: str,
                 attempts: int = MERGE_ATTEMPTS) -> tuple[str | None, str]:
    """git revert -m 1 the merge on the newest <base> and push it the way the runner pushes merges.

    Returns (the revert commit, '') or (None, why not). Leaves the tree checked out where it was.
    """
    git = ['git', '-C', str(tree)]
    name, email = BOT
    start = subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()
    try:
        for _ in range(attempts):
            done = reverted_by(tree, base, merge['sha'])
            if done:
                return None, f'{base} already reverts it ({done[:7]})'
            subprocess.run(git + ['checkout', '--quiet', '--force', '--detach', f'origin/{base}'], check=True,
                           capture_output=True)
            undone = subprocess.run(git + ['revert', '--no-commit', '-m', '1', merge['sha']], capture_output=True,
                                    text=True)
            if undone.returncode != 0:
                conflicts = subprocess.run(git + ['diff', '--name-only', '--diff-filter=U'], capture_output=True,
                                           text=True).stdout.split()
                subprocess.run(git + ['revert', '--abort'], capture_output=True)
                return None, ('git revert -m 1 does not apply cleanly on the newest '
                              f'{base} ({", ".join(conflicts[:10]) or undone.stderr.strip()[:200]})')
            if subprocess.run(git + ['diff', '--cached', '--quiet'], capture_output=True).returncode == 0:
                subprocess.run(git + ['revert', '--abort'], capture_output=True)
                return None, f'reverting it changes nothing: {base} already undoes it'
            subprocess.run(git + ['-c', f'user.name={name}', '-c', f'user.email={email}', 'commit', '--quiet',
                                  '-m', message], check=True, capture_output=True)
            sha = subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()
            pushed, why = push_merge(tree, sha, base)
            if pushed:
                return sha, ''
            if not next_moved(why):
                return None, f'the push to {base} failed ({why})'
            fetch_base(tree, base)
        return None, f'{base} kept moving ({attempts} attempts)'
    finally:
        subprocess.run(git + ['checkout', '--quiet', '--force', '--detach', start], capture_output=True)


class Repo:
    """The repository-wide GitHub calls the auto-revert needs (GitHub above is one PR's)."""

    def __init__(self, repo: str):
        self.repo = repo

    def api(self, *args: str) -> str:
        return subprocess.check_output(['gh', 'api', *args], text=True)

    def comments_since(self, since: str):
        """Every issue and PR comment created since <since>, oldest first, a page at a time."""
        page = 1
        while True:
            batch = json.loads(self.api(f'repos/{self.repo}/issues/comments?since={since}&sort=created'
                                        f'&direction=asc&per_page=100&page={page}'))
            yield from batch
            if len(batch) < 100:
                return
            page += 1

    def issue_comments(self, number: int) -> list[dict]:
        lines = self.api('--paginate', '--jq', '.[] | @json', f'repos/{self.repo}/issues/{number}/comments')
        return [json.loads(line) for line in lines.splitlines() if line.strip()]

    def comment(self, number: int, body: str) -> str:
        return json.loads(self.api(f'repos/{self.repo}/issues/{number}/comments', '-f', f'body={body}'))['html_url']

    def title(self, number: int) -> str:
        return json.loads(self.api(f'repos/{self.repo}/pulls/{number}')).get('title', '')

    def open_issue(self, title: str, body: str, labels: list[str]) -> str:
        args = [f'repos/{self.repo}/issues', '-f', f'title={title}', '-f', f'body={body}']
        for label in labels:
            args += ['-f', f'labels[]={label}']
        return json.loads(self.api(*args))['html_url']


def auto_revert(tree: Path, base: str, repo, policy=None) -> str:
    """At the start of a lane job: revert the newest lane change on <base> if the two lane reports after
    it were both runner faults (owner rule 2026-10-01). Returns what it did, for the job log.

    Only a merge that touched the lane (test-scope.py's lane paths) is ever reverted, and each only once:
    a revert already on <base>, or an earlier "Lane auto-revert" comment on #337 naming it, stops it.
    A revert that doesn't apply cleanly is reported on #337 and left for a person.
    """
    fetch_base(tree, base)
    policy = policy or base_policy(tree, base, 'scripts/test-scope.py')
    if policy is None or not hasattr(policy, 'is_lane_path'):
        return 'no lane path list on the base yet'
    merge = lane_merge(tree, base, policy.is_lane_path)
    if merge is None:
        return 'no lane change in recent merges'
    label = f'#{merge["pr"]}' if merge['pr'] else merge['sha'][:7]
    undone = reverts_on_base(tree, merge, policy.is_lane_path)
    if undone:  # reverting a revert would bring the broken change back
        return (f'the newest lane change ({label}) is itself a revert (of '
                f'{", ".join(sha[:7] for sha in undone)}); left alone')
    reports = lane_reports_after(tree, merge, repo.comments_since(utc(merge['time']).strftime('%Y-%m-%dT%H:%M:%SZ')),
                                 base)
    if len(reports) < 2 or not all(report['fault'] for report in reports):
        return f'the newest lane change ({label}) is fine so far: ' + (
            '; '.join(f'{r["url"]} {r["why"]}' for r in reports) or 'no lane report since')
    done = reverted_by(tree, base, merge['sha'])
    if done:
        return f'{label} was already reverted ({done[:7]})'
    if any((c.get('body') or '').startswith(AUTO_REVERT) and merge['sha'][:7] in (c.get('body') or '')
           for c in repo.issue_comments(OPS_ISSUE)):
        return f'{label} was already handled (#{OPS_ISSUE})'
    title = merge['title'] or (repo.title(merge['pr']) if merge['pr'] else merge['subject'])
    evidence = '\n'.join(f'{n}. {r["url"]}: {r["why"]}' for n, r in enumerate(reports, 1))
    message = (f'Revert {label}: {title} (lane auto-revert)\n\n'
               f'The two lane reports after this lane change were both runner faults:\n{evidence}\n\n'
               'Reverted by the lane runner (owner rule 2026-10-01).\n\n'
               f'This reverts commit {merge["sha"]}, reversing\nchanges made to {merge["parent"]}.')
    sha, problem = revert_merge(tree, base, merge, message)
    if not sha:
        repo.comment(OPS_ISSUE, f'{AUTO_REVERT} failed: {label} (`{merge["sha"][:7]}`, a lane change) was not '
                                f'reverted on {base}: {problem}. The two lane reports after it were both runner '
                                f'faults:\n{evidence}\nNothing was pushed. A person needs to look; the runner won\'t '
                                f'try this change again.\n_Posted by the lane runner (scripts/lane-runner.py)._')
        return f'could not revert {label}: {problem}'
    issue = ''
    try:
        issue = repo.open_issue(
            f'Re-land {label} after a lane auto-revert: {title}',
            f'The lane runner reverted {label} on {base} as `{sha[:7]}` (owner rule 2026-10-01), because the two '
            f'lane reports after it were both runner faults:\n{evidence}\n\n'
            f'**Done when:** the change lands again in a new PR into {base}, with the cause of those faults '
            'fixed, and the two lane reports after it are not both runner faults.\n\n'
            '**Must not break:** the lane jobs of other PRs while the re-land is tested.\n\n'
            '_Filed by the lane runner (scripts/lane-runner.py)._', ['ready', 'regression'])
    except Exception as error:  # noqa: BLE001 - the #337 comment still says what happened
        issue = f'not filed ({error!r})'
    repo.comment(OPS_ISSUE, f'{AUTO_REVERT}: reverted {label} (`{merge["sha"][:7]}`, a lane change) on {base} as '
                            f'`{sha[:7]}`. The two lane reports after it were both runner faults:\n{evidence}\n'
                            f'Re-land issue: {issue}\n_Posted by the lane runner (scripts/lane-runner.py)._')
    return f'reverted {label} as {sha[:7]}'


# ---- Main ---------------------------------------------------------------------------------------

def runner_device_claim(name: str) -> Path:
    from lane_slots import state_dir
    return state_dir() / ('runner-device-' + re.sub(r'[^A-Za-z0-9._-]+', '-', name) + '.lock')


def claim_runner_device(name: str):
    """Lock the name of the device a T3 job is about to create, until the job has deleted it (#440).

    Both runners live on this Mac, and every lane job starts by sweeping leftover runner simulators. Without
    the claim, a job starting on the other runner deleted a T3's device mid-run: exit 148 at the readiness
    step (#440), or xcodebuild's "Unable to find a device" (exit 70, #411). The kernel drops the lock when
    this process exits, however it exits, so a crashed job's device is still swept.
    """
    import fcntl
    path = runner_device_claim(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open('a+')
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def release_runner_device(handle) -> None:
    Path(handle.name).unlink(missing_ok=True)
    handle.close()


def runner_device_claimed(name: str) -> bool:
    import fcntl
    try:
        handle = runner_device_claim(name).open()
    except OSError:
        return False
    with handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
    return False


def sweep_runner_simulators() -> None:
    """Delete simulators earlier runner jobs left behind; a running job's claimed device stays (#440)."""
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    for group in devices.get('devices', {}).values():
        for device in group:
            if device.get('name', '').startswith(RUNNER_SIMULATOR_PREFIX):
                if runner_device_claimed(device['name']):
                    print(f'Left {device["name"]} alone: a running T3 job holds it')
                    continue
                subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], capture_output=True, timeout=120)
                subprocess.run(['xcrun', 'simctl', 'delete', device['udid']], capture_output=True, timeout=120)
                print(f'Deleted leftover simulator {device["name"]}')


TESTED_RECORD: Path | None = None  # main() sets it to a file in this job's RUNNER_TEMP


def remember_tested(base: str, sha: str) -> None:
    """Note which base this job is testing, so cleanup() can name it if the job stops before its report:
    the auto-revert counts a stopped job only against a lane change that the tested base contained."""
    if TESTED_RECORD is None:
        return
    try:
        TESTED_RECORD.write_text(json.dumps({'base': base, 'sha': sha}))
    except OSError as error:
        print(f'Could not note the tested base: {error!r}')


def tested_note() -> str:
    """' (tested merged with <base> at <sha>)' from remember_tested(), in a report's words, or ''."""
    try:
        tested = json.loads(TESTED_RECORD.read_text()) if TESTED_RECORD else None
    except (OSError, ValueError):
        tested = None
    if not isinstance(tested, dict) or not tested.get('base') or not re.fullmatch(r'[0-9a-f]{40}', tested.get('sha') or ''):
        return ''
    return f' (tested merged with {tested["base"]} at {tested["sha"][:7]})'


def cleanup(github: GitHub, run_url: str, mode: str = 'any') -> int:
    """After a failed or cancelled job: remove leftovers, say so on the PR, and free the labels."""
    sweep_runner_simulators()
    tested = tested_note()
    if mode == 'auto':  # lane:queued and lane:running belong to /lane requests
        github.comment(f'Lane: the automerge run stopped before reporting ({run_url}){tested}. Push again, or '
                       f'remove and re-add automerge, to run it again.\n{NOTE}')
        return 0
    _, desk_waiting = pending_requests(github.comments())
    github.comment(f'Lane: the runner stopped before reporting ({run_url}){tested}. If it is still needed, '
                   f'comment the request again and add lane:queued.\n{NOTE}')
    github.relabel(RUNNING, None)
    if not desk_waiting:
        github.relabel(QUEUED, None)
    return 0


def fetch_base(tree: Path, base: str) -> str:
    """Fetch the newest base branch into the tree and return its commit."""
    subprocess.run(git_with_token(tree) + ['fetch', '--no-tags', '--quiet', 'origin', base], check=True)
    return subprocess.check_output(['git', '-C', str(tree), 'rev-parse', f'origin/{base}'], text=True).strip()


def merge_base_branch(tree: Path, base: str) -> list[str]:
    """Merge origin/<base> into the checked-out PR head. Returns the conflicting files, if any."""
    git = ['git', '-C', str(tree)]
    merged = subprocess.run(git + ['-c', 'user.name=Spoken Margins lane', '-c', 'user.email=lane@localhost',
                                   'merge', '--no-edit', '--quiet', f'origin/{base}'], capture_output=True, text=True)
    if merged.returncode == 0:
        return []
    conflicts = subprocess.run(git + ['diff', '--name-only', '--diff-filter=U'], capture_output=True,
                               text=True).stdout.split()
    subprocess.run(git + ['merge', '--abort'], capture_output=True)
    return conflicts or [merged.stderr.strip().splitlines()[-1] if merged.stderr.strip() else 'the merge failed']


def record_outcome(verdict: str) -> None:
    """Hand the verdict to the workflow, whose Verdict step makes the check red on FAIL (#184).

    The script itself exits 0 once it has reported, so a lane.yml from before this change (on a PR that
    hasn't merged next) stays green on FAIL, as before, instead of posting "stopped before reporting".
    """
    outputs = os.environ.get('GITHUB_OUTPUT')
    if outputs:
        with open(outputs, 'a') as handle:
            handle.write(f'reported=true\nverdict={verdict}\n')


def request_name(pr: int, run_id: str, attempt: str | None) -> str:
    """The report's name and evidence folder. A re-run of a job keeps its run id, and verify-tests.py
    refuses an --output folder that exists (#404), so each attempt after the first gets its own."""
    return f'pr{pr}-r{run_id}' + (f'-a{attempt}' if attempt and attempt != '1' else '')


def tools_source() -> Path:
    return Path(os.environ.get('SM_LANE_TOOLS') or Path.home() / 'Documents/GitHub/spoken-margins-native')


def link_tools(source: Path) -> None:
    for name in ('.venv', 'node_modules'):
        if not (ROOT / name).exists() and (source / name).exists():
            (ROOT / name).symlink_to(source / name)


def main(argv=None) -> int:
    global ROOT, TESTED_RECORD
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--event-head', required=True, help='head SHA the triggering event saw')
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--tree', type=Path, default=ROOT, help='checkout of the PR head to test')
    parser.add_argument('--base', default='next', help='branch the PR merges into')
    parser.add_argument('--cleanup', action='store_true', help='tidy up after a cancelled or failed job')
    parser.add_argument('--mode', choices=['explicit', 'auto', 'any'], default='any',
                        help='explicit: answer /lane requests only; auto: the automerge label only')
    args = parser.parse_args(argv)
    ROOT = args.tree.resolve()
    sys.path.insert(0, str(ROOT / 'scripts'))
    try:
        fallback = base_scripts_fallback(ROOT, args.base)
        if fallback:
            print(f'Lane helpers this branch predates come from origin/{args.base}: '
                  + ', '.join(sorted(p.stem for p in fallback.glob('*.py'))))
    except Exception as error:  # noqa: BLE001 - without it a stale branch fails as before; a fresh one is fine
        print(f'Lane helper fallback skipped: {error!r}')
    repo = os.environ['GH_REPO']
    github = GitHub(repo, args.pr)
    run_url = f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{repo}/actions/runs/{args.run_id}'
    if os.environ.get('RUNNER_TEMP'):  # one job's own folder, shared by its run and its cleanup step
        TESTED_RECORD = Path(os.environ['RUNNER_TEMP']) / \
            f'sm-lane-tested-{args.run_id}-{os.environ.get("GITHUB_RUN_ATTEMPT") or "1"}.json'
    if args.cleanup:
        return cleanup(github, run_url, args.mode)
    if args.base == 'next':  # lane-check/** bases test lane changes; only next gets reverted
        try:
            print(f'Lane auto-revert check: {auto_revert(ROOT, args.base, Repo(repo))}')
        except Exception as error:  # noqa: BLE001 - the check must never stop the job it runs in
            print(f'Lane auto-revert check skipped: {error!r}')
    sweep_runner_simulators()
    pull = github.pull()
    head = pull['head']['sha']
    labels = {label['name'] for label in pull.get('labels', [])}
    automerge = AUTOMERGE in labels
    if head != args.event_head:
        print(f'The PR moved on to {head[:7]} since this run was queued; the newer run tests it.')
        return 0
    if pull.get('state', 'open') != 'open':  # merged or closed while queued: don't spend a test cycle on it (#860)
        print(f'PR #{args.pr} is {pull["state"]}; nothing to test.')
        return 0
    comments = github.comments()
    request, desk_waiting = pending_requests(comments)
    if args.mode == 'auto':  # the automerge job never answers /lane requests: the lane job does
        if not automerge:
            print('The automerge label is gone; nothing to do.')
            return 0
        request = None
    if request is None and automerge and args.mode != 'explicit':
        request = {'tier': 'auto', 'tests': [], 'commit': ''}  # the automerge label is the request
    explicit = request is not None and request['tier'] != 'auto'  # automerge runs leave lane:queued/running alone
    if request is None:
        if not desk_waiting and QUEUED in labels and args.mode != 'auto':
            github.comment('Lane: lane:queued is set, but there is no `/lane T2` or `/lane T3` request comment newer '
                           'than the last lane report, so nothing ran. Comment the request (format in '
                           f'docs/workstreams/test-lane.md), then add lane:queued.\n{NOTE}')
            github.relabel(QUEUED, None)
        print('No unanswered T2/T3 request; nothing to do.')
        return 0
    base_sha = fetch_base(ROOT, args.base)
    remember_tested(args.base, base_sha)
    wanted = identity(request['tier'], head, base_sha, request['tests'])
    # An automerge run always runs: after an earlier PASS that didn't merge (no audit yet, next moved),
    # re-adding the label is how to try again.
    done_before = earlier_report(comments, wanted) if explicit else None
    request_id = request_name(args.pr, args.run_id, os.environ.get('GITHUB_RUN_ATTEMPT'))
    evidence = Path(os.environ.get('SM_LANE_EVIDENCE_DIR') or
                    Path.home() / 'Library/Caches/SpokenMarginsLane/evidence') / request_id

    def after_t3_pass(why: str) -> str | None:
        """Release a held automerge run (#421), and return its report if it posted one. Never changes this
        job's result, which is already reported."""
        try:
            link_tools(tools_source())  # the identical-request path returns before the job links them
            return merge_after_t3(github, args.pr, args.base, head, f'{request_id}-auto',
                                  evidence.parent / f'{request_id}-auto', base_sha, why)
        except Exception as error:  # noqa: BLE001 - reported on the PR when GitHub can be reached
            print(f'The automerge run after the T3 PASS stopped: {error!r}')
            try:
                github.comment(f'Lane: the automerge run after the T3 PASS stopped before reporting ({run_url}: '
                               f'{error!r}). Remove and re-add automerge to run it again.\n{NOTE}')
            except Exception:  # noqa: BLE001
                pass

    if done_before:
        url, earlier_verdict = done_before
        github.comment(f'Lane: identical {request["tier"]} request for {head[:7]} already reported '
                       f'({earlier_verdict}): {url}\n{NOTE}')
        if explicit and not desk_waiting:
            github.relabel(QUEUED, DONE)
        record_outcome(earlier_verdict)  # a repeated FAIL stays red
        if request['tier'] == 'T3' and earlier_verdict == 'PASS':
            after_t3_pass(f'started by the T3 PASS ({url}) in the same lane job')
        return 0
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'request.json').write_text(json.dumps(dict(request, head=head, base=args.base, base_sha=base_sha),
                                                      indent=2))
    if explicit and not desk_waiting:  # a waiting T4/T5 keeps lane:queued so the Test Desk still sees it
        if DONE in labels:  # a running PR doesn't also say done
            github.relabel(DONE, None)
        github.relabel(QUEUED, RUNNING)
    link_tools(tools_source())
    # A pending T3 for this head: the lane job that reports its PASS merges. The build runner runs the checks
    # meanwhile, so that job needn't (#834); any other runner leaves them to it, as a simulator runner's time
    # is the T3s'.
    t3_first = t3_request_for_head(comments, labels, head) if request['tier'] == 'auto' else None
    on_build_runner = os.environ.get('SM_LANE_RUNNER_ROLE') == 'build'
    no_room, beside, room_for_builds = None, None, None
    if request['tier'] == 'auto' and on_build_runner:
        if host_only_scope(ROOT, args.base):  # the trial: work may run beside a simulator job, builds too
            no_room, beside = wait_for_room_to_test_on_host()
            room_for_builds = functools.partial(wait_for_room_to_build, note=lambda text: (
                print(f'[lane] {text}', flush=True), note_beside_simulator(request_id, args.pr, text)))
        else:
            noted = []
            no_room = wait_for_room_to_build(note=noted.append)
            beside = noted[0] if noted else None
        if beside:
            print(f'[lane] {beside}', flush=True)
            note_beside_simulator(request_id, args.pr, beside)
    started = time.monotonic()
    requested = request.get('commit', '')
    moved = [f'requested {requested[:7]}, tested the newest commit {head[:7]}'] \
        if requested and not head.startswith(requested) else []
    cc = ''
    context = AutoRunContext(base_sha)
    try:
        conflicts = [] if request['tier'] == 'auto' else merge_base_branch(ROOT, args.base)
        if t3_first and not on_build_runner:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no build', 'nothing', 'none'
            details = [f'{HELD_FOR_T3[0]}: the /lane T3 request for this head ({t3_first}) has no lane report yet, '
                       'and this is not the build runner, so this run skipped its own host tests and builds. The lane '
                       'job that reports a T3 PASS on this head runs them on the merge commit itself and merges on '
                       'PASS; nobody needs to push or re-label.']
        elif no_room:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no build', 'nothing', 'none'
            details = [f'{no_room}. Push again, or remove and re-add automerge, to try again.']
        elif request['tier'] == 'auto':
            verdict, where, ran, details = run_auto(github, pull, args.pr, args.base, head, base_sha, evidence,
                                                    comments, labels, room_for_builds=room_for_builds,
                                                    context=context)
            details = ([beside] if beside else []) + details
            crashes = 'none'
        elif conflicts:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no simulator', 'nothing', 'none'
            details = [f'The PR does not merge cleanly into {args.base} ({base_sha[:7]}): {", ".join(conflicts[:10])}. '
                       f'Merge {args.base} into your branch, push, and ask again.']
        elif request['tier'] == 'T2':
            warm = warm_build_folders(ROOT)
            verdict, ran, details = run_t2(evidence)
            where, crashes, details = 'no simulator (compile only)', 'none', [warm] + details
        else:
            warm = warm_build_folders(ROOT)
            classes, problem = t3_scope(ROOT, args.base, evidence)
            verdict, where, ran, details, crashes, cc = run_t3(request['tests'], request_id, evidence, classes)
            details = [warm] + problem + details
    except Exception as error:  # noqa: BLE001 - any lane fault is reported, never silent
        verdict, where, ran, crashes = 'INCONCLUSIVE', 'lane error', 'nothing', 'unknown'
        details = [f'The lane itself failed: {error!r}. evidence: {evidence}']
    if t3_first and verdict == 'INCONCLUSIVE' and not any(line.startswith(HELD_FOR_T3[0]) for line in details):
        # The build runner's checks didn't finish (no room, a timeout, a lane error) while the T3 waits: the T3
        # PASS still releases the run, and tests it. Not at a line's start, so the auto-revert still counts the
        # report as a runner fault (PENDING_T3_HOLD), while held_for_t3 finds it.
        details.append(f'The checks did not finish, so: {HELD_FOR_T3[0]} until the /lane T3 request for this head '
                       f'({t3_first}) reports. The lane job that reports a T3 PASS on this head runs the host tests and '
                       'builds on the merge commit itself and merges on PASS.')
    if request['tier'] == 'auto':
        base_sha = context.tested_base
        wanted = identity('auto', head, base_sha, request['tests'])
    body = report(request_id, verdict, head, base_sha, request['tier'], where, time.monotonic() - started,
                  ran, moved + details, crashes, str(evidence),
                  NOT_VERIFIED, wanted, cc, args.base)
    (evidence / 'report.md').write_text(body)
    print(body)
    t3_url = github.comment(body)  # if this fails, the job fails and the tidy step says so on the PR
    record_outcome(verdict)
    _, desk_waiting = pending_requests(github.comments())
    if explicit:
        github.relabel(RUNNING, QUEUED if desk_waiting else None)
    released = None
    if explicit and request['tier'] == 'T3' and verdict == 'PASS':
        released = after_t3_pass(f'started by the T3 PASS ({t3_url}) in the same lane job')
    elif request['tier'] == 'auto' and verdict != 'PASS':  # a T3 PASS may have landed before this held report
        released = after_t3_pass('started again in the same automerge job, because a T3 PASS landed while it '
                                 'was held')
    last = details + (released or '').splitlines()  # the job's last report: a released automerge run's, if any
    if not any(line.startswith(f'merged into {args.base} as ') for line in last) \
            and not (explicit and desk_waiting):  # a merged PR closes: nothing to pick up
        # Remove, then add: adding a label the PR already has is no `labeled` event, and the Hourly dispatch
        # wakes on lane:done's. The lane and automerge jobs run side by side, so the other may have added it.
        github.relabel(DONE, DONE)
    if not (ROOT / '.build').is_symlink():  # a cold job (disk floor, busy cache) built in the workspace
        for derived in (ROOT / '.build').glob('dd*'):
            shutil.rmtree(derived, ignore_errors=True)
        shutil.rmtree(ROOT / '.build/verification', ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
