#!/usr/bin/env python3
"""The lane's deterministic tiers: run a T2 or T3 request from a PR and post the report.

Run by .github/workflows/lane.yml on the Mac's self-hosted runner. The workflow checks out the PR's
head in --tree and runs this script as taken from the base branch (next); the script merges the
newest next into the tree itself, so a report tests the PR against the current next even when
GitHub's merge ref for the PR is stale. Agent sessions can't run it (the lane guard blocks it); they ask
by commenting a request and adding the lane:queued label. Formats: docs/workstreams/test-lane.md.

- The runner takes the newest T2/T3 request it hasn't answered yet. T4 and T5 requests belong to the
  Test Desk: while one is waiting, the runner leaves lane:queued in place so the Test Desk sees it.
- The newest commit wins: if the PR moved on since this run was queued, a newer run tests it.
- A request identical to one that already has a PASS or FAIL report (same head merged into the
  same next, tier and tests) runs once. After an INCONCLUSIVE report, asking again runs again.
- T2 builds for simulator and device (unsigned) through scripts/xcodebuild-lane.
- T3 runs the named app-hosted tests through verify-tests.py on a fresh iOS 26 simulator, created
  for the job and deleted afterwards. It is booted under the lane's boot rules (scripts/lane_sim.py):
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
  MERGE_ATTEMPTS). It won't merge a PR that changes .github/ or scripts/lane* (a PR can change the
  workflow that tests it), or an audio, persistence or packet change without a Codex audit comment:
  those pass or fail as usual, and a person merges them. A PR someone asked T3 for merges only on a
  T3 PASS (#410): while its newest T3 report is FAIL or INCONCLUSIVE, or its newest T3 request has
  no report yet, the automerge run reports that verdict (INCONCLUSIVE while waiting) and doesn't merge.
- PR code (builds and tests) runs without the GitHub token in its environment, and the checkout
  keeps no credentials, so only this script's own fetch and push can use the token.
- Build folders stay warm between jobs. The checkout wipes the workspace, so the tree's .build (the
  app's DerivedData and verify-tests' output) and Packages/SessionKit/.build (SwiftPM) link to a cache
  outside it, keyed by the SessionKit source tree under test: a DerivedData reused after SessionKit
  changes gives false "does not conform" errors (AGENTS.md), so any SessionKit change starts a new
  cache. At most WARM_KEEP caches, never below WARM_FREE_FLOOR of free disk; otherwise the job runs
  cold. A warm rebuild measured 6 to 10 s against 90 s cold, per build.
- Two runners (item 5). lane.yml's `lane` job answers /lane requests on the main runner (the only
  one that runs simulators); its `automerge` job runs on any runner labelled sm-lane-build. --mode
  keeps each job to its own work. On the build-only runner (SM_LANE_RUNNER_ROLE=build), an
  automerge job first waits for room: no simulator job, normal memory pressure, and enough free disk.

Environment: GH_TOKEN and GH_REPO (the workflow's), SM_LANE_EVIDENCE_DIR (where evidence goes,
default ~/Library/Caches/SpokenMarginsLane/evidence), SM_LANE_TOOLS (a checkout whose .venv and
node_modules to link in, default the owner's main checkout).
Stdlib only, Python 3.9-compatible: it runs under /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

QUEUED, RUNNING, DONE = 'lane:queued', 'lane:running', 'lane:done'
AUTOMERGE = 'automerge'
FAST_TIMEOUT = 2400
MERGE_ATTEMPTS = 3
WARM_KEEP = 2
BUILD_RUNNER_WAIT = 90 * 60
BUILD_RUNNER_FREE_DISK = 20 * 10**9
WARM_FREE_FLOOR = 15 * 10**9
MERGE_CHECK = '**Merge check (triage desk)'  # the prefix scripts/merge_audit.py requires
AUDITS = ('**Codex audit (Astra)', '## Codex audit')  # how an audit comment starts: the hourly task's, or an older manual one
DESK_ONLY = ('.github/', 'scripts/lane')
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

def pr_code_env() -> dict:
    """The environment for the PR's own code (builds, tests): without the GitHub token, so nothing the
    PR changes can use the lane's write access."""
    return {name: value for name, value in os.environ.items() if name not in ('GH_TOKEN', 'GITHUB_TOKEN')}


def git_with_token(tree: Path) -> list[str]:
    """git for this script's own fetch and push: the token goes in a header for that one command, since
    the checkout keeps no credentials."""
    token = os.environ.get('GH_TOKEN')
    if not token:
        return ['git', '-C', str(tree)]
    basic = base64.b64encode(f'x-access-token:{token}'.encode()).decode()
    return ['git', '-C', str(tree), '-c', f'http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}']


def run_bounded(command: list[str], log, timeout: float, grace: float = INTERRUPT_GRACE) -> int | None:
    """Run in a new process group and return its exit code, or None if it timed out.

    On timeout the whole group gets SIGINT first, so verify-tests.py and xcodebuild-lane stop their
    own xcodebuild and record the interruption, then SIGKILL if it's still there after the grace.
    """
    # The child gets default SIGINT handling even if this process was started with it ignored (as
    # background jobs are), or the interrupt below would be silently ignored all the way down.
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                               env=pr_code_env(), preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
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
    found = [line.strip() for line in lines if ' error: ' in line or line.startswith('error:') or 'errSec' in line]
    if 'The following build commands failed:' in lines:
        for line in lines[lines.index('The following build commands failed:') + 1:]:
            if not line.strip():
                break
            found.append('failed: ' + line.strip())
    return list(dict.fromkeys(found))[:limit]


def run_t2(evidence: Path, runner=run_bounded) -> tuple[str, str, list[str]]:
    results, details = [], []
    for name, args in T2_BUILDS:
        log = evidence / f't2-{name}.log'
        command = [str(ROOT / 'scripts/xcodebuild-lane'), '-project', 'SpokenMarginsNative.xcodeproj',
                   '-scheme', 'SpokenMarginsApp', *args]
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


def diff_scope(tree: Path, base: str) -> dict:
    """test-scope.py's answer for the PR, from the base branch's copy of the policy, so a PR can't
    reclassify itself to skip its builds."""
    policy = base_policy(tree, base, 'scripts/test-scope.py')
    paths, diffs = committed_changes(tree, base)
    return policy.classify(paths, diffs, root=tree)


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


def merge_blockers(scope: dict, comments: list[dict]) -> list[str]:
    """Why the runner won't merge this PR itself even on PASS; the desk merges those."""
    reasons = []
    desk = [f['path'] for f in scope['files'] if f['path'].startswith(DESK_ONLY)]
    if desk:
        reasons.append(f'it changes the lane or its workflows ({", ".join(desk[:5])}), and a PR can change '
                       'what tests it')
    risky = sorted({AUDITED[f['category']] for f in scope['files'] if f['category'] in AUDITED})
    if risky and not any((c.get('body') or '').lstrip().startswith(AUDITS) for c in comments):
        reasons.append(f'it touches {" and ".join(risky)} and has no "Codex audit (Astra)" comment yet')
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
    again = 'after a T3 PASS, push or remove and re-add automerge to merge'
    if latest is None or latest[0] < asked:
        return 'INCONCLUSIVE', f'this PR\'s newest /lane T3 request has no lane report yet; {again}'
    _, verdict, commit, url = latest
    if verdict != 'PASS':
        return verdict, (f'the newest T3 lane report on this PR is {verdict} (on {commit[:7]}: {url}), and a PR '
                         f'asked for T3 merges only on a T3 PASS. Fix it or ask for T3 again; {again}')
    return None


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
    runner's merges, and its hourly schedule runs only once merge-audit.yml is on the default branch.
    After each merge, run next's audit over the last two hours instead. Best effort: never fails a job."""
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


def merge_check(head: str, merge_sha: str, base: str, base_sha: str, ran: str) -> str:
    return (f'{MERGE_CHECK} on `{head[:7]}`: PASS.**\n'
            f'- Tested the merge commit `{merge_sha[:7]}`: {base} at `{base_sha[:7]}` first, then this PR.\n'
            f'- Ran: {ran}.\n'
            f'- Pushing `{merge_sha[:7]}` to {base} now. If {base} moved meanwhile, the push is refused and the '
            'runner tests again on the newest one.\n'
            '_Posted by the lane runner (scripts/lane-runner.py)._')


def run_auto(github, pull: dict, pr: int, base: str, head: str, base_sha: str, evidence: Path,
             comments: list[dict], labels=(), attempts: int = MERGE_ATTEMPTS) -> tuple[str, str, str, list[str]]:
    """The automerge run: test the merge commit, and push it to <base> on PASS unless something blocks it."""
    notes: list[str] = []
    for attempt in range(1, attempts + 1):
        merge_sha, conflicts = build_merge_commit(ROOT, base, head, pr, pull.get('title', ''))
        if conflicts:
            return 'INCONCLUSIVE', 'no simulator', 'nothing', notes + [
                f'The PR does not merge cleanly into {base} ({base_sha[:7]}): {", ".join(conflicts[:10])}. '
                f'Merge {base} into your branch and push; the automerge label runs it again.']
        warm = warm_build_folders(ROOT)
        scope = diff_scope(ROOT, base)
        (evidence / 'scope.json').write_text(json.dumps(scope, indent=2))
        verdict, where, ran, details = run_automerge(
            scope, evidence, ratchet=lambda: hot_file_violations(ROOT, base, set(labels)))
        details = [f'tested the merge commit {merge_sha[:7]} ({base} at {base_sha[:7]} first, then this PR); {warm}'] \
            + notes + details
        if verdict != 'PASS':
            return verdict, where, ran, details
        held = t3_gate(github.comments())  # read now: a T3 report may have landed while this ran
        if held:
            return held[0], where, ran, details + [f'not merged: {held[1]}.']
        blockers = merge_blockers(scope, comments)
        if blockers:
            return verdict, where, ran, details + [f'not merged by the runner: {b}. The desk merges it.'
                                                   for b in blockers]
        now = github.pull()
        if now['head']['sha'] != head or AUTOMERGE not in {label['name'] for label in now.get('labels', [])}:
            return verdict, where, ran, details + ['not merged: the PR moved on or lost the automerge label while '
                                                   'it was tested']
        github.comment(merge_check(head, merge_sha, base, base_sha, ran))
        pushed, message = push_merge(ROOT, merge_sha, base)
        if pushed:
            sweep_merge_audit(ROOT, base)
            return verdict, where, ran, details + [f'merged into {base} as {merge_sha[:7]}']
        if not next_moved(message):  # no permission, network: testing again wouldn't help
            return verdict, where, ran, details + [f'not merged: the push to {base} failed ({message}). A job '
                                                   'whose lane.yml predates push rights (#382) can\'t push.']
        notes.append(f'attempt {attempt}: the push to {base} was refused ({message}), so {base} moved; '
                     'tested again on the newest one')
        base_sha = fetch_base(ROOT, base)
    return 'PASS', where, ran, details + notes[-1:] + [
        f'not merged: {base} kept moving ({attempts} attempts). Remove and re-add automerge to try again.']


# ---- Warm build folders -------------------------------------------------------------------------

def warm_root() -> Path:
    return Path(os.environ.get('SM_LANE_WARM_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane/warm-build')


def sessionkit_key(tree: Path) -> str | None:
    """The SessionKit source tree in the tree under test (its git tree hash), or None."""
    found = subprocess.run(['git', '-C', str(tree), 'rev-parse', 'HEAD:Packages/SessionKit'],
                           capture_output=True, text=True)
    return found.stdout.strip()[:12] if found.returncode == 0 and found.stdout.strip() else None


_WARM_LOCKS: dict = {}


def warm_build_folders(tree: Path, root: Path | None = None, free=lambda path: shutil.disk_usage(path).free) -> str:
    """Link the tree's build folders to the cache for its SessionKit tree; returns a line for the report."""
    import fcntl
    root = root or warm_root()
    key = sessionkit_key(tree)
    if not key:
        return 'build folders: cold (no SessionKit tree to key a cache on)'
    root.mkdir(parents=True, exist_ok=True)
    wanted = root / f'sk-{key}'
    others = sorted((d for d in root.iterdir() if d.is_dir() and d.name.startswith('sk-') and d != wanted),
                    key=lambda d: d.stat().st_mtime, reverse=True)
    for old in others[WARM_KEEP - 1:]:
        if not _cache_busy(old):
            shutil.rmtree(old, ignore_errors=True)
    if free(root) < WARM_FREE_FLOOR:
        for old in others:
            if not _cache_busy(old):
                shutil.rmtree(old, ignore_errors=True)
        if free(root) < WARM_FREE_FLOOR:
            return f'build folders: cold (less than {WARM_FREE_FLOOR // 10**9} GB free)'
    was_warm = (wanted / 'root').is_dir()
    for name in ('root', 'sessionkit'):
        (wanted / name).mkdir(parents=True, exist_ok=True)
    lock = open(wanted / '.lock', 'a+')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        return f'build folders: cold (the SessionKit {key} cache is in use by another runner job)'
    for held in _WARM_LOCKS.values():  # a new key in a later attempt: this job moves to the new cache
        held.close()
    _WARM_LOCKS.clear()
    _WARM_LOCKS[key] = lock  # held until this job's process exits
    os.utime(wanted)
    for link, target in ((tree / '.build', wanted / 'root'), (tree / 'Packages/SessionKit/.build', wanted / 'sessionkit')):
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            shutil.rmtree(link)
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target, target_is_directory=True)
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
                           free=lambda: shutil.disk_usage(Path.home()).free) -> str | None:
    """The second runner builds only while the Mac has room: no simulator job, normal memory pressure,
    and BUILD_RUNNER_FREE_DISK free. Returns None when there's room, or why it gave up waiting."""
    if simulator_jobs is None or pressure is None:
        from lane_slots import memory_pressure_level, simulator_jobs_running
        simulator_jobs = simulator_jobs or simulator_jobs_running
        pressure = pressure or memory_pressure_level
    started, last_note = clock(), None
    while True:
        busy = []
        if simulator_jobs():
            busy.append('a simulator job is running')
        if pressure() not in (1, None):
            busy.append('memory pressure is above normal')
        if free() < BUILD_RUNNER_FREE_DISK:
            busy.append(f'less than {BUILD_RUNNER_FREE_DISK // 10**9} GB of disk is free')
        if not busy:
            return None
        waited = clock() - started
        if waited >= max_wait:
            return f'the build runner waited {duration(waited)} for room: {"; ".join(busy)}'
        if last_note is None or clock() - last_note >= 300:
            print(f'[lane] build runner waiting ({duration(waited)} so far): {"; ".join(busy)}', file=out, flush=True)
            last_note = clock()
        sleep(poll)


# ---- T3 -----------------------------------------------------------------------------------------

def plan_for_tests(selectors: list[str], plans: dict[str, set]) -> tuple[dict[str, list[str]], list[str]]:
    """Group selectors by the plan holding them; selectors no plan holds are returned separately."""
    grouped, unknown = {}, []
    for selector in selectors:
        full = selector if selector.startswith(APP_TEST_TARGET + '/') else f'{APP_TEST_TARGET}/{selector}'
        plan = next((p for p, tests in plans.items()
                     if any(t == full or t.startswith(full + '/') for t in tests)), None)
        if plan:
            grouped.setdefault(plan, []).append(full)
        else:
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
    if any(s['failed'] or s['build_failed'] for s in summaries):
        return 'FAIL'
    return 'INCONCLUSIVE'


def run_plans(grouped: dict[str, list[str]], run_plan, evidence: Path) -> tuple[list, list, list, list]:
    """Run each plan's selectors; stop at the first crash flood (AGENTS.md: don't reboot in a loop)."""
    summaries, statuses, ran, details = [], [], [], []
    plans = list(grouped.items())
    for position, (plan, selectors) in enumerate(plans):
        output = evidence / f'verify-{plan}'
        manifest = run_plan(plan, selectors, output)
        summary = summarize_manifest(manifest)
        summaries.append(summary)
        statuses.append(manifest.get('status', 'missing'))
        ran.append(f'{", ".join(s.split("/", 1)[1] for s in selectors)} ({summary["passed"]} passed'
                   f'{", " + str(len(summary["failed"])) + " failed" if summary["failed"] else ""})')
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


def run_t3(tests: list[str], request_id: str, evidence: Path) -> tuple[str, str, str, list[str], str, str]:
    """Returns verdict, where, ran, details, crashes, cc."""
    from test_inventory import plan_tests
    if not tests:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The T3 request names no tests. Add `tests: Class/method, …` '
                '(scripts/test-scope.py suggests them).'], 'none', '')
    plans = {plan: plan_tests(ROOT, name) for plan, name in PLANS.items()}
    grouped, unknown = plan_for_tests(tests, plans)
    if unknown:
        return ('FAIL', 'no simulator', 'nothing', [f'Not in any app test plan: {", ".join(unknown)}. A named test '
                'that does not exist is a failure (verify-tests.py rule).'], 'none', '')
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
        summaries, statuses, ran, details = run_plans(grouped, run_plan, evidence)
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


# ---- Main ---------------------------------------------------------------------------------------

def sweep_runner_simulators() -> None:
    """Delete simulators a previous runner job left behind (only this one runner makes them)."""
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    for group in devices.get('devices', {}).values():
        for device in group:
            if device.get('name', '').startswith(RUNNER_SIMULATOR_PREFIX):
                subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], capture_output=True, timeout=120)
                subprocess.run(['xcrun', 'simctl', 'delete', device['udid']], capture_output=True, timeout=120)
                print(f'Deleted leftover simulator {device["name"]}')


def cleanup(github: GitHub, run_url: str, mode: str = 'any') -> int:
    """After a failed or cancelled job: remove leftovers, say so on the PR, and free the labels."""
    sweep_runner_simulators()
    if mode == 'auto':  # the lane:* labels belong to /lane requests
        github.comment(f'Lane: the automerge run stopped before reporting ({run_url}). Push again, or remove and '
                       f're-add automerge, to run it again.\n{NOTE}')
        return 0
    _, desk_waiting = pending_requests(github.comments())
    github.comment(f'Lane: the runner stopped before reporting ({run_url}). If it is still needed, comment '
                   f'the request again and add lane:queued.\n{NOTE}')
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
    """Hand the verdict to the workflow, whose last step makes the check red unless it is PASS (#184).

    The script itself exits 0 once it has reported, so a lane.yml from before this change (on a PR that
    hasn't merged next) stays green on FAIL, as before, instead of posting "stopped before reporting".
    """
    outputs = os.environ.get('GITHUB_OUTPUT')
    if outputs:
        with open(outputs, 'a') as handle:
            handle.write(f'reported=true\nverdict={verdict}\n')


def link_tools(source: Path) -> None:
    for name in ('.venv', 'node_modules'):
        if not (ROOT / name).exists() and (source / name).exists():
            (ROOT / name).symlink_to(source / name)


def main(argv=None) -> int:
    global ROOT
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
    repo = os.environ['GH_REPO']
    github = GitHub(repo, args.pr)
    run_url = f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{repo}/actions/runs/{args.run_id}'
    if args.cleanup:
        return cleanup(github, run_url, args.mode)
    sweep_runner_simulators()
    pull = github.pull()
    head = pull['head']['sha']
    labels = {label['name'] for label in pull.get('labels', [])}
    automerge = AUTOMERGE in labels
    if head != args.event_head:
        print(f'The PR moved on to {head[:7]} since this run was queued; the newer run tests it.')
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
    explicit = request is not None and request['tier'] != 'auto'  # automerge runs leave lane:* labels alone
    if request is None:
        if not desk_waiting and QUEUED in labels and args.mode != 'auto':
            github.comment('Lane: lane:queued is set, but there is no `/lane T2` or `/lane T3` request comment newer '
                           'than the last lane report, so nothing ran. Comment the request (format in '
                           f'docs/workstreams/test-lane.md), then add lane:queued.\n{NOTE}')
            github.relabel(QUEUED, None)
        print('No unanswered T2/T3 request; nothing to do.')
        return 0
    base_sha = fetch_base(ROOT, args.base)
    wanted = identity(request['tier'], head, base_sha, request['tests'])
    # An automerge run always runs: after an earlier PASS that didn't merge (no audit yet, next moved),
    # re-adding the label is how to try again.
    done_before = earlier_report(comments, wanted) if explicit else None
    if done_before:
        url, earlier_verdict = done_before
        github.comment(f'Lane: identical {request["tier"]} request for {head[:7]} already reported '
                       f'({earlier_verdict}): {url}\n{NOTE}')
        if explicit and not desk_waiting:
            github.relabel(QUEUED, DONE)
        record_outcome(earlier_verdict)  # a repeated FAIL stays red
        return 0
    request_id = f'pr{args.pr}-r{args.run_id}'
    evidence = Path(os.environ.get('SM_LANE_EVIDENCE_DIR') or
                    Path.home() / 'Library/Caches/SpokenMarginsLane/evidence') / request_id
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'request.json').write_text(json.dumps(dict(request, head=head, base=args.base, base_sha=base_sha),
                                                      indent=2))
    if explicit and not desk_waiting:  # a waiting T4/T5 keeps lane:queued so the Test Desk still sees it
        github.relabel(QUEUED, RUNNING)
    link_tools(Path(os.environ.get('SM_LANE_TOOLS') or Path.home() / 'Documents/GitHub/spoken-margins-native'))
    no_room = wait_for_room_to_build() \
        if request['tier'] == 'auto' and os.environ.get('SM_LANE_RUNNER_ROLE') == 'build' else None
    started = time.monotonic()
    requested = request.get('commit', '')
    moved = [f'requested {requested[:7]}, tested the newest commit {head[:7]}'] \
        if requested and not head.startswith(requested) else []
    cc = ''
    try:
        conflicts = [] if request['tier'] == 'auto' else merge_base_branch(ROOT, args.base)
        if no_room:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no build', 'nothing', 'none'
            details = [f'{no_room}. Push again, or remove and re-add automerge, to try again.']
        elif request['tier'] == 'auto':
            verdict, where, ran, details = run_auto(github, pull, args.pr, args.base, head, base_sha, evidence,
                                                    comments, labels)
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
            verdict, where, ran, details, crashes, cc = run_t3(request['tests'], request_id, evidence)
            details = [warm] + details
    except Exception as error:  # noqa: BLE001 - any lane fault is reported, never silent
        verdict, where, ran, crashes = 'INCONCLUSIVE', 'lane error', 'nothing', 'unknown'
        details = [f'The lane itself failed: {error!r}. evidence: {evidence}']
    body = report(request_id, verdict, head, base_sha, request['tier'], where, time.monotonic() - started,
                  ran, moved + details, crashes, str(evidence),
                  'journeys and anything a listener notices (T4), audible content (owner)', wanted, cc, args.base)
    (evidence / 'report.md').write_text(body)
    print(body)
    github.comment(body)  # if this fails, the job fails and the tidy step says so on the PR
    record_outcome(verdict)
    _, desk_waiting = pending_requests(github.comments())
    if explicit:
        github.relabel(RUNNING, QUEUED if desk_waiting else DONE)
    if not (ROOT / '.build').is_symlink():  # a cold job (disk floor, busy cache) built in the workspace
        shutil.rmtree(ROOT / '.build/dd', ignore_errors=True)
        shutil.rmtree(ROOT / '.build/verification', ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
