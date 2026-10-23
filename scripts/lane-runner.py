#!/usr/bin/env python3
"""The lane's deterministic tiers: run a T2 or T3 request from a PR and post the report.

Run by .github/workflows/lane.yml on the Mac, or, for T0/ops-only automerge, on a GitHub-hosted Linux runner (--hosted, #861, #2442).
The workflow checks out the PR's
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
- T2 builds for simulator and device (unsigned) through scripts/xcodebuild-lane, on an explicit request.
- T3 runs the named app-hosted tests, plus every app test class the base branch's test-scope.py
  suggests for the PR's diff (#351), through verify-tests.py on an iOS 26 simulator cloned from a
  clean template that completed its first boot (#1330), then deleted afterwards. One build prepares
  both plans before the job takes a simulator slot. Tests hold no build slot. The report lists the
  classes it added and how long each plan took. It is booted under the lane's boot rules (scripts/lane_sim.py):
  one boot at a time, no builds meanwhile, no retry after a failed boot, a stop at the first crash
  during boot, and a long wait for the template's first boot's data migration. The job holds a Mac-wide
  simulator slot from cloning through deletion. A crash flood stops the run.
- A timeout interrupts the whole process group, so no xcodebuild keeps running outside the slots.
- The automerge label asks for the checks a finished PR needs, with no request comment (the
  ready-queue plan, decision 3). The base branch's scripts/test-scope.py classifies the PR's
  committed diff: T0 (docs, research notes) runs nothing, and anything else runs --plan fast only. It
  builds no app (owner, 2026-10-09: 140 runs in a week built both targets and caught no compile failure):
  the author builds both targets before pushing, and the integration run on next's tip builds and tests
  the merged app. An explicit request on the PR goes first. Before any of that, next's scripts/hot_file_ratchet.py fails a PR that grows Gate1AppModel.swift or
  Gate1RootView.swift above its ceiling, unless the PR has the hot-file-ok label.
- The runner merges what it passes (decision 3, owner-approved). An automerge run tests the exact
  merge commit, with next as its first parent. On PASS it posts a "Merge check (triage desk)"
  comment (the prefix scripts/merge_audit.py looks for) and pushes that commit to next with a plain
  push; if next moved meanwhile, the push is refused and it tests again on the newest next (up to
  MERGE_ATTEMPTS), unless next's new commits touch none of the PR's files and no build inputs its checks
  read (#1208: a lane tool such as phone-build doesn't count for a PR that isn't a lane change): then
  it re-merges onto the newest next and pushes without testing again (untested_moves). It won't merge an audio, persistence, packet or lane change
  (test-scope.py's lane_paths) until a Codex or Claude audit of its head says "No blocking findings": those pass
  or fail as usual, and the audit script re-arms automerge after a clean audit. The held report records what
  passed with which next, and the re-armed run merges on that PASS without the checks again unless next has since
  moved in ways that matter (untested_moves, #1461). Other lane changes don't
  wait for a person (owner rule 2026-10-01); the audit checks them, because a lane PR's own run uses
  its own workflow and helpers. The exception: it never merges a PR touching scripts/lane-runner.py or
  anything under .github/, whatever the audit says, and its report says it needs the owner's tap
  (owner rule 2026-10-09, #1203, owner_tap_paths): the runner can't test itself. A PR someone asked T3 for merges only on a
  T3 PASS (#410): while its newest T3 report is FAIL or INCONCLUSIVE, or its newest T3 request has
  no report yet, the automerge run reports that verdict (INCONCLUSIVE while waiting) and doesn't merge.
  When a T3 then passes, the lane job that reported it runs the held automerge run itself, in the
  same job (#421): a label the runner re-added with the workflow's token would start no new run.
  While the PR's T3 request for its head is still waiting, the automerge run on the build runner runs its
  checks anyway and its held report records what passed with which next (#834); the T3 PASS's lane job
  then merges without repeating them unless next has since moved in ways that matter (untested_moves).
  Anywhere else, or with no room to build, the automerge run skips its checks and reports itself held
  straight away, and the T3 PASS's lane job runs them before it merges.
- Hosted fast checks (#1389), only with the LANE_HOSTED_FAST repository variable `on` (a rollout guard for going
  public): when both hosted-portable.yml jobs passed on the PR's head and recorded a merge tree that matches this
  head merged onto the next they tested, and next's commits since can't matter (untested_moves), the automerge
  run takes them for the portable steps and SessionKitCoreTests and runs only --plan fast-mac-rest on the Mac.
  Anything short of that, and with the variable unset, it runs the whole --plan fast as before. (The VPS's
  linux-t1.yml pair, read from #2160 until the flip, was retired in #2442.)
- Merging off the Mac (#2459), with LANE_HOSTED_FAST and LANE_HOSTED_MAC_REST both `on` (a rollout guard, off until
  the hosted Mac-rest check passes on the hosted image): hosted-portable.yml also runs --plan fast-mac-rest on a GitHub-hosted Mac, and test-scope.py routes every automerge job to hosted
  Linux (--hosted). There a PR held for T3 is reported held in seconds, testing nothing. Otherwise the job waits,
  on Linux, for all three hosted checks to pass on this head merged onto next, dispatches them once more when next
  has since moved in ways that matter, and merges on them, running no test itself. A hosted check that failed is
  the PR's FAIL. When they can't be had (missing, cancelled, never recorded), the job posts nothing and lane.yml's
  `automerge-mac` job runs it on the build Mac the old way. The T3 PASS's lane job merges on them too, in seconds,
  when they stand then.
  With LANE_HOSTED_FAST `on` and LANE_HOSTED_MAC_REST not, every automerge job still starts on hosted Linux: a PR
  held for T3 is reported held there in seconds, and otherwise the job waits there for the hosted pair on this head.
  A failed one is the PR's FAIL; once both passed (or can't be had) it hands the run to `automerge-mac`, which runs
  --plan fast-mac-rest (or the whole --plan fast) and merges, so the build Mac never idles waiting for the pair.
- Hosted T2 and T3 (#1389 phase 2), only with the LANE_HOSTED_APP repository variable `on` (the same kind of rollout
  guard): test-scope.py routes the lane job to a GitHub-hosted Mac, and lane.yml sets SM_LANE_GITHUB_HOSTED=1 there,
  with the lane state and evidence folders in the job's own temporary folder. This script runs as on the Mac: the
  slots, the template and the claims are the job's alone, so they never wait. Only these differ: the report says the
  evidence is the run's `lane-evidence` artifact, the lane auto-revert check stays with the Mac jobs, and a T3 PASS
  that must re-run host tests hands them to the Mac's release job as the simulator runner does (#1209).
  When those checks have to run (none passed, or next has since moved in ways that matter), the lane job on the
  simulator runner doesn't run them itself (#1209): it dispatches lane.yml's release job (workflow_dispatch, which
  unlike a label starts a run from the workflow's token), posts a note, and moves on to the next T3. The release
  job (--mode release, run_release) runs them on a build runner under its room rules and merges on PASS. If the
  dispatch fails, the lane job runs them as before.
- PR code (builds and tests) runs without the GitHub token in its environment, and the checkout
  keeps no credentials, so only this script's own fetch and push can use the token.
- Build folders stay warm between T2 and T3 jobs. The checkout wipes the workspace, so the tree's .build (the
  app's DerivedData and verify-tests' output) and Packages/SessionKit/.build (SwiftPM) link to a cache
  outside it, keyed by the SessionKit source tree under test: a DerivedData reused after SessionKit
  changes gives false "does not conform" errors (AGENTS.md), so any SessionKit change starts a new
  cache. So does an Xcode project change. Each checkout (each runner) has its own caches, because
  DerivedData and SwiftPM's state record absolute paths, and a cache whose SwiftPM state lists a
  binary artifact that isn't on disk starts again cold (#405). At most WARM_KEEP caches per checkout,
  never below WARM_FREE_FLOOR of free disk; otherwise the job runs cold. A warm rebuild measured 6 to
  10 s against 90 s cold, per build. Automerge runs build no app, so they keep no cache (#1207): their host
  tests build SessionKit in the workspace, which the job empties when it ends, and each automerge job removes
  the idle caches with no app build in them that its runner's earlier automerge runs left (host_build_folders).
- Two runners (item 5). lane.yml's `lane` job answers /lane requests on the main runner (the only
  one that runs simulators); its `automerge` job runs on any runner labelled sm-lane-build. --mode
  keeps each job to its own work. On the build-only runner (SM_LANE_RUNNER_ROLE=build), an
  automerge job first waits for room: no simulator job, normal memory pressure, and enough free disk.
  Trial (2026-10-01): an automerge job, which runs no xcodebuild, may start there beside a simulator job
  while memory pressure reads normal and BESIDE_SIMULATOR_FREE_DISK is free; each one is logged for the owner.
  The builds-beside-a-simulator trial ended with the per-PR app builds (#1207): T2 builds take lane_slots'
  usual build slots wherever they run.
- SessionKit tests are skipped when the tree under test already passed them on this Mac (#1328,
  scripts/sessionkit_pass.py): the key is a digest of the package, the repository files its tests read, the
  toolchain and the test runner. The PASS report says so. Never skipped without the changed-paths list,
  and a pass older than 24 hours isn't used.
- The step ledger (#1200, scripts/lane_ledger.py). Each step a job runs (the hot-file ratchet, host tests, app
  builds, app tests) is noted with its verdict and wall time, and when the job has reported, they go into
  step-ledger.json in the lane state folder: runs, time, PASS / FAIL / runner faults, and catches. A rule that
  trips (a step 20 runs without a FAIL at over a minute a run, 3 runner faults in a row, one test failing on
  two PRs against the same next) posts one "Lane step alarm" comment on #337 at once. Never fails a job.
- Auto-revert of a lane change that broke the lane (owner rule 2026-10-01, auto_revert). Each job on
  next starts by finding the newest merge into next that touched the lane (test-scope.py's lane
  paths). If the first two lane reports on PRs after it, from jobs that tested a next with it, were
  both runner faults (INCONCLUSIVE for a lane reason, or a job that stopped before reporting; not a
  merge conflict, a T3 hold or a FAIL), it reverts that merge with `git revert -m 1`, pushes like a
  merge, files a `ready` + `regression` issue to re-land it, and posts "Lane auto-revert:" on #337.
  Once per lane change; a revert that doesn't apply cleanly is reported on #337 and left for a person.
- Inherited audit findings (#712, scripts/lane_inherited_holds.py, loaded from next). A PR that brings in another
  PR's commits is held by that PR's blocking audit of them, even with a clean audit of its own head: the finding
  clears only with a machine-readable resolution on the PR (the source audit comment, the full head, evidence) and a
  clean audit of the head posted after it. A lookup that can't finish holds the merge too. The hold line reads
  "not merged by the runner: it inherits a blocking audit finding ..." and says what clears it.

Environment: GH_TOKEN and GH_REPO (the workflow's), SM_LANE_EVIDENCE_DIR (where evidence goes,
default ~/Library/Caches/SpokenMarginsLane/evidence), SM_LANE_TOOLS (a checkout whose .venv and
node_modules to link in, default ~/Library/Caches/SpokenMarginsLane/tools, a lane-only clone kept out of
~/Documents, which macOS privacy denies the runners' service process (#2493)).
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
import urllib.parse

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
# Above the 20 GiB at which the Mac finisher pauses and BUILD_RUNNER_FREE_DISK, so idle caches go before other
# work stops for lack of disk (#1775). The lane folder's overall cap is ops/disk/sm_lane_prune.py's.
WARM_FREE_FLOOR = 25 * 10**9
PRUNE_TIMEOUT = 300
PROJECT_FILE = 'SpokenMarginsNative.xcodeproj/project.pbxproj'  # its layout names Xcode's VFS folders (#405)
# How the T3 gate's hold reads in an automerge report, now and before #421 (PRs held by an older runner).
HELD_FOR_T3 = ('not merged: held for T3', 'after a T3 PASS, push or remove and re-add automerge to merge')
NOT_VERIFIED = 'journeys and anything a listener notices (T4), audible content (owner)'
MERGE_CHECK = '**Merge check (triage desk)'  # the prefix scripts/merge_audit.py requires
AUDITS = ('**Codex audit (Astra)', '## Codex audit', '**Claude audit on `')
AUDITED = {'audio': 'the audio session', 'persistence': 'persistence', 'packet': 'packets'}
BOT = ('github-actions[bot]', '41898282+github-actions[bot]@users.noreply.github.com')
RUNNER_TIERS = ('T2', 'T3')
# Whose PR comments the runner reads (#1719). Once the repository is public, anyone can comment, and a /lane
# request runs the PR's code on the Mac; a fake report or note could also answer a request or lift the T3 hold.
# So the runner sees only comments from the owner, the organisation's members and the repository's
# collaborators (GitHub's author_association), and from the project's own bot, the workflows' github-actions.
TRUSTED_ASSOCIATIONS = ('OWNER', 'MEMBER', 'COLLABORATOR')
TRUSTED_BOTS = (BOT[0],)
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
AUDIT_HOLD = re.compile(r'^not merged by the runner: ', re.M)  # the line merge_blockers' hold puts in a report (#1461)
# How the lane job's note starts when it hands a released automerge run to the build runner (#1209). It starts like
# the automerge run's own notes ('Lane: the automerge run'), so it answers no /lane request.
HANDED_OFF = 'Lane: the automerge run held for T3'
LANE_WORKFLOW = 'lane.yml'


# ---- Requests -----------------------------------------------------------------------------------

def trusted_comment(comment: dict) -> bool:
    """Whether the runner may act on this comment: the owner's, a member's or collaborator's, or the project's bot.

    A comment without author_association (GitHub always sends it) is not trusted.
    """
    login = (comment.get('user') or {}).get('login')
    return comment.get('author_association') in TRUSTED_ASSOCIATIONS or login in TRUSTED_BOTS


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


def trunk() -> str:
    """The trunk branch, from scripts/trunk.py (#1492). Imported late, like the other helpers, so a tree that
    predates it takes origin/<base>'s copy through base_scripts_fallback."""
    from trunk import trunk_branch
    return trunk_branch()


def github_hosted() -> bool:
    """This job runs on a GitHub-hosted Mac (lane.yml sets it there, #1389 phase 2)."""
    return os.environ.get('SM_LANE_GITHUB_HOSTED') == '1'


def report(request_id: str, verdict: str, head: str, base: str, tier: str, where: str, seconds: float,
           ran: str, details: list[str], crashes: str, evidence: str, not_verified: str, wanted: dict,
           cc: str = '', base_name: str | None = None, hosted: bool = False) -> str:
    base_name = base_name or trunk()
    location = ('on a GitHub-hosted Linux runner' if hosted else
                'on a GitHub-hosted Mac; the run\'s `lane-evidence` artifact keeps it for 7 days' if github_hosted()
                else 'on the Mac')
    lines = [f'Lane report {request_id} — {verdict}',
             f'commit {head[:7]} (tested merged with {base_name} at {base[:7]}) · tier {tier} · {where} · {duration(seconds)}',
             f'ran: {ran}', *details, f'crashes: {crashes}', f'evidence: {evidence} ({location})',
             f'not verified: {not_verified}']
    if cc:
        lines.append(cc)
    return '\n'.join(lines) + f'\n<!-- lane-request: {json.dumps(wanted, sort_keys=True)} -->\n'


# ---- Step ledger --------------------------------------------------------------------------------

STEP_RUNS: list[dict] = []  # this job's step runs, for the step ledger once the job has reported (flush_ledger)
TESTED_BASE = ''  # the next commit the job is testing now (remember_tested)


def note_step(name: str, verdict: str, seconds: float, failed=(), zero_tests: bool = False, ran=None) -> None:
    """ran: the tests this run executed (#1830), or None when the step can't say; the ledger closes a named test
    failure only on a run that ran it."""
    STEP_RUNS.append({'step': name, 'verdict': verdict, 'seconds': seconds, 'base': TESTED_BASE,
                      'failed': list(failed), 'zero_tests': zero_tests, 'ran': None if ran is None else list(ran)})


def ledger_step(name: str, read=None):
    """Note each run of the decorated step for the step ledger: its verdict (the result's first item) and wall
    time, and through read(args, result) what failed, whether it ran zero tests and, when it can say, which tests it
    ran: (failed, zero) or (failed, zero, ran). A step that raises is a runner fault."""
    def wrap(function):
        @functools.wraps(function)
        def run(*args, **kwargs):
            started = time.monotonic()
            try:
                result = function(*args, **kwargs)
            except BaseException:
                note_step(name, 'ERROR', time.monotonic() - started)
                raise
            failed, zero, ran = [], False, None
            try:
                failed, zero, *rest = read(args, result) if read else ([], False)
                ran = rest[0] if rest else None
            except Exception:  # noqa: BLE001 - the ledger never changes a step's result
                pass
            note_step(name, result[0], time.monotonic() - started, failed, zero, ran)
            return result
        return run
    return wrap


def manifest_failures(*outputs: Path) -> tuple[list[str], bool, list[str]]:
    """(The failed tests, or failed steps when a step names no tests, whether no test ran, and the names of the
    tests that did run) in the verify-tests.py manifests under <outputs>. A SessionKit step skipped as already
    passed (#1328) ran no test and adds no names."""
    failed, counted, ran = [], 0, []
    for output in outputs:
        manifest = _read_manifest(output)
        if manifest.get('sessionkit_pass'):  # SessionKit's tests were skipped as already passed (#1328): not a run of none
            counted += 1
        for step in manifest.get('steps', []):
            if step.get('superseded'):  # the parallel SessionKitCoreTests run that a serial run replaced (#1328)
                continue
            tests = step.get('tests') or {}
            counted += len(tests)
            ran += [test for test, record in tests.items() if record.get('status') != 'skipped']  # a skip is not a run
            failed += [test for test, record in tests.items() if record.get('status') == 'failed']
            if step.get('exit_code') and not step.get('interrupted') and not tests:
                failed.append(str(step.get('name')))
    return failed, counted == 0, list(dict.fromkeys(ran))


STALL_ISSUE = 1802  # the evidence log for app startup stalls and simulator boot stalls (#705 is closed)
BOOT_STALLS = 'boot-stalls.json'  # a T3 boot's stalls (boot_t3_device), for log_recovered_stalls


def recovered_startup_stalls(manifest: dict) -> list[dict]:
    """The steps of a verify-tests.py manifest that stalled once at startup, recovered on the first retry and passed.

    Owner's call 2026-10-11: such a step counts as a PASS, and each stall is logged on the evidence log (STALL_ISSUE). Two or more stalls
    before a pass stay a step error, so they never show up here.
    """
    return [{'step': step.get('name'), 'stall': step['startup_stalls'][0],
             'passed': sum(r.get('status') == 'passed' for r in (step.get('tests') or {}).values())}
            for step in manifest.get('steps', [])
            if step.get('startup_recovered') and len(step.get('startup_stalls') or []) == 1 and not step.get('errors')]


def boot_stall_note(evidence: Path, pr: int, head: str, report_url: str, verdict: str) -> str | None:
    """The evidence-log comment for the T3 boot's stalls (<evidence>/boot-stalls.json), in the startup stalls' format."""
    try:
        found = json.loads((evidence / BOOT_STALLS).read_text())
        stalls, outcome = found['stalls'], found['outcome']
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not stalls:
        return None
    if outcome.startswith('recovered'):
        title = f'Boot stall recovered on a fresh device; the run then ended {verdict}'
    else:
        title = f'Boot stall, {outcome}'
    lines = [f'{title}: the T3 run for PR #{pr} at `{head[:7]}` ({report_url}).']
    lines += [f'- Boot {number}, clone `{stall.get("udid")}` (memory pressure {stall.get("pressure", "unknown")}): '
              f'{stall.get("error")}' for number, stall in enumerate(stalls, 1)]
    lines.append(f'- Outcome: {outcome}.')
    lines.append(f'- Evidence on the Mac: `{evidence}/first-boot.log` and the boot log '
                 '`~/Library/Caches/SpokenMarginsLane/boot-events.log`.')
    lines.append('_Posted by the lane runner (scripts/lane-runner.py)._')
    return '\n'.join(lines)


def log_recovered_stalls(evidence: Path, pr: int, head: str, report_url: str, post, verdict: str = '') -> int:
    """Post the T3 boot's stalls, and each recovered startup stall in the verify-* manifests under <evidence>,
    on the evidence log (STALL_ISSUE) with post(body).

    Best effort: the report is already posted, and nothing here can fail the job. Returns how many were posted.
    """
    posted = 0
    booted = boot_stall_note(evidence, pr, head, report_url, verdict)
    if booted:
        try:
            post(booted)
            posted += 1
        except Exception as error:  # noqa: BLE001 - the report already says the stall happened
            print(f'Could not log the boot stall on #{STALL_ISSUE}: {error!r}', flush=True)
    for output in sorted(evidence.glob('verify-*')):
        plan = output.name.removeprefix('verify-')
        for found in recovered_startup_stalls(_read_manifest(output)):
            stall = found['stall']
            body = (f'Startup stall recovered on the first retry, counted as a PASS (owner\'s call 2026-10-11): '
                    f'the `{plan}` plan of the T3 run for PR #{pr} at `{head[:7]}` ({report_url}).\n'
                    f'- No test output {stall.get("after_seconds")}s after launch (launch {stall.get("attempt")}); '
                    f'last log line: `{stall.get("last_log_line")}`.\n'
                    f'- The retry then passed {found["passed"]} test(s) in `{found["step"]}`.\n'
                    f'- Evidence on the Mac: `{output}/{found["step"]}-stall-{stall.get("attempt")}/` '
                    '(simulator processes and a `sample` of the host app) and the partial result bundle '
                    f'`{output}/tests-stalled-{stall.get("attempt")}.xcresult`.\n'
                    '_Posted by the lane runner (scripts/lane-runner.py)._')
            try:
                post(body)
                posted += 1
            except Exception as error:  # noqa: BLE001 - the report already says the stall happened
                print(f'Could not log the recovered stall on #{STALL_ISSUE}: {error!r}', flush=True)
    return posted


def flush_ledger(pr: int, head: str, post) -> list[str]:
    """Put this job's step runs in the step ledger and post each new alarm with post(body). Returns the alarms.
    Best effort: the job has already reported, and nothing here can fail it."""
    runs = list(STEP_RUNS)
    STEP_RUNS.clear()
    if not runs:
        return []
    try:
        import lane_ledger
        from lane_slots import state_dir
        alarms = lane_ledger.record_runs(state_dir(), [
            dict(run, result=lane_ledger.outcome(run['verdict'], run['zero_tests'])) for run in runs], pr, head)
    except Exception as error:  # noqa: BLE001
        print(f'[lane] step ledger not updated: {error!r}')
        return []
    for body in alarms:
        try:
            post(f'{body}\n_Posted by the lane runner\'s step ledger (scripts/lane_ledger.py, #1200), after PR #{pr}. '
                 'The numbers are in step-ledger.json in the lane state folder on the Mac._')
        except Exception as error:  # noqa: BLE001
            print(f'[lane] could not post the step alarm: {error!r}\n{body}')
    return alarms


# ---- Processes ----------------------------------------------------------------------------------

# The workflow's command files. A step's processes append to them to set its outputs (the verdict the
# Verdict step reads), environment and summary, so the PR's code must not see them: the lane's own tests
# call main(), and inherited, they wrote their fake verdicts into the job's output after the real one.
WORKFLOW_FILES = ('GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY')


def pr_code_env() -> dict:
    """The environment for the PR's own code (builds, tests): without the GitHub token, so nothing the
    PR changes can use the lane's write access, and without the workflow's command files, so it can't set
    the job's verdict."""
    return {name: value for name, value in os.environ.items()
            if name not in ('GH_TOKEN', 'GITHUB_TOKEN', *WORKFLOW_FILES)}


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


@ledger_step('app builds', lambda args, result: (
    [part.rsplit(' (', 1)[0] for part in result[1].split(', ') if not part.endswith('(pass)')], False))
def run_t2(evidence: Path, runner=None) -> tuple[str, str, list[str]]:
    runner = runner or run_bounded
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
    # Both sides of a rename (a file moved out of .github/ is a change to .github/), and NUL-separated: git's default
    # output lists only the new name of a rename and quotes a name like .github/wörkflows/x.yml (#1402 audit).
    paths = subprocess.check_output(git + ['diff', '--name-only', '--no-renames', '-z', merge_base, 'HEAD'],
                                    text=True).split('\0')
    paths = [path for path in paths if path]
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
    sm-lane-mac-2's wait for room). The tree's own copies still come first.
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
    """The base branch's hot-file ratchet on the tree's HEAD (none until the ratchet is on that branch)."""
    ratchet = base_policy(tree, base, 'scripts/hot_file_ratchet.py')
    return ratchet.violations(tree, f'origin/{base}', 'HEAD', labels) if ratchet else []


def changed_paths_for_tests(tree: Path, base: str) -> list[str] | None:
    """Every path the tree changes against origin/<base>, both sides of a rename, for verify-tests.py's
    --changed-files (#862). None when git can't say, which runs every step."""
    try:
        git = ['git', '-C', str(tree)]
        merge_base = subprocess.check_output(git + ['merge-base', 'HEAD', f'origin/{base}'], text=True).strip()
        # NUL-delimited: git's default output quotes and escapes a name like scripts/tests/test_café.py, which
        # then no longer starts with scripts/ and would leave the lane's own tests out.
        raw = subprocess.check_output(git + ['diff', '--name-only', '--no-renames', '-z', merge_base, 'HEAD'])
        paths = [path.decode() for path in raw.split(b'\0') if path]
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        return None
    # The hand-off is one path per line, so a name that line splitting or trimming would change can't be sent.
    if any(path.splitlines() != [path] or path != path.strip() for path in paths):
        return None
    return sorted(set(paths)) or None


def fast_manifest(args, result):
    """What the host tests failed and ran, for the step ledger; their zero-test case is not a runner fault."""
    failed, _, ran = manifest_failures(args[0] / 'fast')
    return failed, False, ran


@ledger_step('host tests', fast_manifest)
def run_fast(evidence: Path, runner=run_bounded, changed: list[str] | None = None) -> tuple[str, list[str]]:
    """--plan fast (host tests): returns (PASS, FAIL or INCONCLUSIVE, details).

    changed: the PR's changed paths, so the plan can leave out the lane's own Python tests when nothing they
    read changed (#862). Without it every step runs."""
    return run_host_plan('fast', evidence, runner, changed)


@ledger_step('host tests (Mac rest)', fast_manifest)
def run_mac_rest(evidence: Path, runner=run_bounded, changed: list[str] | None = None) -> tuple[str, list[str]]:
    """--plan fast-mac-rest (#1389): the host tests the hosted fast checks don't run, when they stand
    (hosted_fast_checks). Its own ledger step, so the ledger shows what the Mac still spends per PR."""
    return run_host_plan('fast-mac-rest', evidence, runner, changed)


def run_host_plan(plan: str, evidence: Path, runner, changed: list[str] | None) -> tuple[str, list[str]]:
    if runner is run_bounded:  # a real run; tests hand in their own runner, and test the guard on its own
        pointers = ensure_lfs_files(ROOT)
        if pointers:
            return 'INCONCLUSIVE', [pointers]
    python = ROOT / '.venv/bin/python'
    output, log_path = evidence / 'fast', evidence / 'verify-fast.log'
    command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', plan,
               '--output', str(output)]
    if changed:
        changed_file = evidence / 'changed-files.txt'
        changed_file.write_text('\n'.join(changed) + '\n')
        command += ['--changed-files', str(changed_file)]
    with log_path.open('w') as log:
        code = runner(command, log, FAST_TIMEOUT)
    if code is None:
        return 'INCONCLUSIVE', [f'host tests (--plan {plan}) — no result after {duration(FAST_TIMEOUT)}; interrupted. '
                                f'evidence: {log_path}']
    manifest = _read_manifest(output)
    if manifest.get('lane_fault'):  # #909: the Mac, not the PR (its lid is closed, so there is no sound output)
        return 'INCONCLUSIVE', [f'host tests (--plan {plan}) — lane fault: {manifest["lane_fault"]}. Ask the owner to open '
                                f'the lid or connect an audio output, then re-run. evidence: {log_path}']
    if code == 0 and manifest.get('status') == 'verified':
        # A suite the Mac could not run (no `go`, say) passed nothing: the report says so (#1033).
        return 'PASS', [f'{step["name"]} skipped: {reason}' for step in manifest.get('steps', [])
                        if isinstance(step.get('skipped'), list) for reason in step['skipped']] + [
                        str(note) for note in manifest.get('notes', [])]
    return 'FAIL', [f'host tests (--plan {plan}) — expected: verified. observed: exit {code}. evidence: {log_path}',
                    *[f'  {line}' for line in first_errors(log_path)]]


# ---- Git LFS files in the checkout (#2139) ------------------------------------------------------
# A checkout made without LFS (shipped-build-compat.yml's, on 2026-10-19) writes each model as a 132-byte pointer, and
# the lane's own `lfs: true` checkout never rewrites a file whose blob is unchanged, so the pointer stays. The tests
# then failed deep inside a voice test (`Protobuf parsing failed`) as if the PR had broken it. Before any host test,
# build or simulator run, every LFS file must be its content: a pointer is restored from the checkout's LFS cache
# (`git lfs checkout`, no download), and one that stays a pointer is a runner fault, not a FAIL.

LFS_POINTER_HEADER = b'version https://git-lfs.github.com/spec/v1\n'
LFS_POINTER_NOTE = 'LFS pointer, not the model'
LFS_STEP = 'LFS files'


def lfs_pointer_files(tree: Path) -> list[str]:
    """The tree's Git LFS files (filter=lfs in .gitattributes) that are pointer files, not their content."""
    listed = subprocess.run(['git', '-C', str(tree), 'ls-files', '-z', '--', ':(attr:filter=lfs)'],
                            capture_output=True)
    if listed.returncode != 0:  # not a checkout: nothing here to check
        return []
    pointers = []
    for name in sorted(filter(None, listed.stdout.decode('utf-8', 'surrogateescape').split('\0'))):
        try:
            with (tree / name).open('rb') as handle:  # LFS pointers are under 1024 bytes
                head = handle.read(1025)
        except OSError:
            continue
        if len(head) <= 1024 and head.startswith(LFS_POINTER_HEADER):
            pointers.append(name)
    return pointers


def ensure_lfs_files(tree: Path, run=subprocess.run) -> str | None:
    """Make every LFS file in the tree its content. Returns None when they are (after a repair, if one was needed),
    else the report line naming each file still a pointer. A job that skips LFS on purpose (GIT_LFS_SKIP_SMUDGE=1,
    the hosted T0/ops automerge job's) is not checked."""
    if os.environ.get('GIT_LFS_SKIP_SMUDGE', '').strip().lower() in ('1', 't', 'true', 'y', 'yes', 'on'):  # as git-lfs reads it
        return None
    started = time.monotonic()
    pointers = lfs_pointer_files(tree)
    if not pointers:
        note_step(LFS_STEP, 'PASS', time.monotonic() - started)
        return None
    print(f'[lane] {len(pointers)} LFS pointer file(s) in the checkout; restoring them from its LFS cache: '
          + ', '.join(pointers), flush=True)
    restored = run(['git', '-C', str(tree), 'lfs', 'checkout', *pointers], capture_output=True, text=True)
    left = [name for name in lfs_pointer_files(tree) if name in pointers]
    if not left:
        print(f'[lane] git lfs checkout restored {len(pointers)} file(s).', flush=True)
        # A runner fault in the ledger's terms: the checkout was wrong, not the PR. Repairs in a row raise its fault
        # alarm, as something keeps writing pointers. No repair or stop in 60 days says the guard is waste.
        note_step(LFS_STEP, 'REPAIRED', time.monotonic() - started)
        return None
    note_step(LFS_STEP, 'INCONCLUSIVE', time.monotonic() - started)
    said = (restored.stderr or restored.stdout or '').strip().splitlines()
    return (f'runner fault, not the PR (#2139): {"; ".join(f"{name}: {LFS_POINTER_NOTE}" for name in left)}. '
            f'`git lfs checkout` could not restore {"it" if len(left) == 1 else "them"} from this checkout\'s LFS '
            f'cache (exit {restored.returncode}{": " + said[-1] if said else ""}). Run `git lfs pull` in the runner\'s '
            'checkout, then run the lane again; nothing was built or tested.')


NO_APP_BUILD_PER_PR = ('no app build per PR (owner, 2026-10-09): the author builds both targets before pushing, '
                       'and the integration run on next\'s tip builds and tests the merged app')


def recheck_on_base(github, base_sha: str):
    """#1204: a failed --plan fast run's failing tests, re-run on plain <base> at base_sha before the PR is
    blamed (scripts/lane_next_rerun.py). If they fail there too the verdict is INCONCLUSIVE, not FAIL."""
    def recheck(evidence: Path, details: list[str]) -> tuple[str, list[str]]:
        try:
            import lane_next_rerun
        except ImportError:  # a tree without the helper, before base_scripts_fallback could supply it
            return 'FAIL', details
        python = ROOT / '.venv/bin/python'
        return lane_next_rerun.recheck(ROOT, base_sha, evidence, details, github.api, github.repo, github.pr,
                                       runner=run_bounded, python=str(python if python.exists() else sys.executable))
    return recheck


@ledger_step('ops tests', lambda args, result: ([], any('zero tests' in line for line in result[1])))
def run_ops(evidence: Path, runner=run_bounded) -> tuple[str, list[str]]:
    """The same per-folder Python discovery as verify-tests.py's ops_steps, without any Mac slots."""
    folders = sorted({p.parent for p in (ROOT / 'ops').rglob('test_*.py')})
    if not folders:
        return 'INCONCLUSIVE', ['ops tests: zero tests (no test folders found)']
    details = []
    for index, folder in enumerate(folders):
        log_path = evidence / f'ops-{index}.log'
        with log_path.open('w') as log:
            code = runner([sys.executable, '-m', 'unittest', 'discover', '-s', str(folder), '-t', str(folder)],
                          log, FAST_TIMEOUT)
        details.append(f'{folder.relative_to(ROOT)}: exit {code}; evidence: {log_path}')
        if code is None:
            return 'INCONCLUSIVE', details
        count = re.search(r'^Ran (\d+) tests? in ', log_path.read_text(errors='replace'), re.M)
        # Newer unittest exits 5 for an empty suite; older Python exits 0.
        empty = count is not None and int(count[1]) == 0
        if code != 0 and not (code == 5 and empty):
            return 'FAIL', details + first_errors(log_path)
        if not count or empty:
            return 'INCONCLUSIVE', details + [f'{folder.relative_to(ROOT)}: zero tests or no unittest summary']
    return 'PASS', details


def run_automerge(scope: dict, evidence: Path, fast=run_fast,
                  ratchet=lambda: [], changed=lambda: None, recheck=None,
                  hosted: bool = False, hosted_fast: dict | None = None,
                  mac_rest=run_mac_rest) -> tuple[str, str, str, list[str]]:
    """Returns verdict, where, ran, details for the checks the PR's diff needs: the hot-file ratchet, then
    --plan fast unless the diff is T0, or only ops folder tests in hosted mode.
    Never an app build (NO_APP_BUILD_PER_PR).

    hosted_fast: the hosted fast checks that stand for this merge (hosted_fast_checks, #1389); then the Mac runs
    only --plan fast-mac-rest instead of --plan fast.

    recheck(evidence, details): what a FAIL of the host tests becomes once their failing tests have been
    re-run on plain next (#1204); None leaves the FAIL as it is."""
    tier = int(scope['tier'][1:])
    details = [f'test-scope: {scope["tier"]} ({"; ".join(scope["why"]) or "no changes"})']
    started = time.monotonic()
    too_big = ratchet()
    note_step('hot-file ratchet', 'FAIL' if too_big else 'PASS', time.monotonic() - started)
    if too_big:
        return 'FAIL', 'no build', 'hot-file ratchet: failed', details + [f'hot-file ratchet — {line}'
                                                                          for line in too_big]
    if tier == 0:
        return 'PASS', 'no build', 'nothing to build or test', details + [
            'nothing here reaches the host tests or the app (docs or research notes only)']
    if hosted:
        verdict, more = run_ops(evidence)
        return verdict, 'hosted Linux runner', 'ops folder tests: ' + verdict.lower(), details + more
    if hosted_fast:
        label = hosted_fast_ran(hosted_fast)
        details += hosted_fast_lines(hosted_fast)
        verdict, more = mac_rest(evidence, changed=changed())
    else:
        label = 'host tests (--plan fast)'
        verdict, more = fast(evidence, changed=changed())
    if verdict == 'FAIL' and recheck:
        verdict, more = recheck(evidence, more)
    details += more
    if verdict != 'PASS':
        return verdict, 'host only', f'{label}: ' + verdict.lower(), details
    if tier == 1:
        return 'PASS', 'host only', f'{label}: passed', details + [
            'no app build: nothing in the diff reaches the app (T1)']
    return 'PASS', 'host only', f'{label}: passed', details + [NO_APP_BUILD_PER_PR]


# #1389: once the repo is public, the fast plan's portable steps and SessionKitCoreTests run on GitHub-hosted
# runners (hosted-portable.yml), on GitHub's merge commit of the PR, and the Mac runs only --plan fast-mac-rest.
# Rollout guard, not a feature switch: unset (today, a private repo whose hosted minutes cost money) the Mac runs
# the whole --plan fast as before. The lead sets the repository variable to `on` once the repo is public; lane.yml
# hands it to this runner, and the same variable starts the hosted jobs. Retire the variable and the old path
# together once hosted runs have carried the lane for a while.
HOSTED_FAST_SWITCH = 'LANE_HOSTED_FAST'
# check run name (the job's `name:` in hosted-portable.yml) -> the verify-tests.py plan it ran
HOSTED_FAST_CHECKS = {'hosted fast: portable': 'fast-portable',
                      'hosted fast: SessionKit core': 'fast-hosted-sessionkit'}
# #2459: the third hosted check, --plan fast-mac-rest on a GitHub-hosted Mac (hosted-portable.yml `mac-rest`). With
# it, the automerge job runs on hosted Linux and runs no test itself. Anything but `on` keeps merging on the build Mac.
HOSTED_REST_SWITCH = 'LANE_HOSTED_MAC_REST'
HOSTED_REST_CHECK = {'hosted fast: Mac rest': 'fast-mac-rest'}
HOSTED_TESTED_TITLE = 'lane-hosted-tested'
HOSTED_TESTED = re.compile(r'^plan=(\S+) tree=([0-9a-f]{40}) parents=([0-9a-f]{40}) ([0-9a-f]{40})\s*$')


def hosted_fast_on(env=None) -> bool:
    return (os.environ if env is None else env).get(HOSTED_FAST_SWITCH, '').strip().lower() == 'on'


def hosted_rest_on(env=None) -> bool:
    """Whether merging runs off the Mac on all three hosted checks (#2459): the hosted fast pair is on, and
    LANE_HOSTED_MAC_REST is `on`. test-scope.py's hosted_merge_routing reads the same two variables."""
    env = os.environ if env is None else env
    return hosted_fast_on(env) and env.get(HOSTED_REST_SWITCH, '').strip().lower() == 'on'


def hosted_tested(annotations: list[dict]) -> dict | None:
    """What a hosted fast job tested, from its `lane-hosted-tested` notice: the plan, the merge commit's tree, next
    (parent 1) and the PR's head (parent 2). None without exactly one such notice."""
    found = [HOSTED_TESTED.match(str(a.get('message', '')).strip()) for a in annotations
             if a.get('title') == HOSTED_TESTED_TITLE and a.get('annotation_level') == 'notice']
    if len(found) != 1 or not found[0]:
        return None
    plan, tree, base, head = found[0].groups()
    return {'plan': plan, 'tree': tree, 'base': base, 'head': head}


def hosted_fast_records(github, head: str, checks: dict = HOSTED_FAST_CHECKS) -> tuple[dict | None, str]:
    """({check name: what it tested}, '') when every check in <checks> (name -> plan) has a successful newest run on
    the PR's <head> that says what it tested; else (None, why not)."""
    found = {}
    for name, plan in checks.items():
        runs = json.loads(github.api(f'repos/{github.repo}/commits/{head}/check-runs?check_name='
                                     f'{urllib.parse.quote(name, safe="")}&filter=latest&per_page=50'))
        # Only GitHub Actions' own runs: another app could post a check run with the same name.
        runs = [run for run in runs.get('check_runs', []) if (run.get('app') or {}).get('slug') == 'github-actions']
        if not runs:
            return None, f'no "{name}" check ran on {head[:7]}'
        run = max(runs, key=lambda run: (run.get('started_at') or '', run.get('id') or 0))
        if run.get('status') != 'completed':
            return None, f'"{name}" {NOT_FINISHED} on {head[:7]}'
        if run.get('conclusion') != 'success':
            return None, f'"{name}" ended {run.get("conclusion")} on {head[:7]}'
        record = hosted_tested(json.loads(github.api(f'repos/{github.repo}/check-runs/{run["id"]}/annotations')))
        if not record or record['plan'] != plan or record['head'] != head:
            return None, f'"{name}" on {head[:7]} did not record that it tested {plan} on this head'
        found[name] = {**record, 'url': run.get('html_url', '')}
    return found, ''


def merged_tree(tree: Path, base: str, head: str) -> str | None:
    """The tree of <head> merged onto <base>, as a merge commit would hold it; None on a conflict."""
    done = subprocess.run(['git', '-C', str(tree), 'merge-tree', '--write-tree', base, head],
                          capture_output=True, text=True)
    return done.stdout.split('\n', 1)[0].strip() if done.returncode == 0 else None


# How long the automerge run waits for fast checks off the Mac that are still running on this head (#1389). A PR is
# usually armed the moment it is pushed, so its hosted checks (about 6 minutes) were still running when the Mac
# reached them: the first two lane runs after LANE_HOSTED_FAST went on (39661421482, 39667637891) ran the whole
# --plan fast on the Mac for that reason alone. Waiting costs the Mac nothing but an idle job.
HOSTED_FAST_WAIT = 15 * 60
HOSTED_FAST_POLL = 30
NOT_FINISHED = 'had not finished'


def hosted_fast_checks(github, tree: Path, base: str, head: str, base_sha: str, env=None,
                       records=hosted_fast_records, wait: float | None = None, poll: float = HOSTED_FAST_POLL,
                       clock=time.monotonic, sleep=time.sleep, out=sys.stdout,
                       checks: dict = HOSTED_FAST_CHECKS) -> tuple[dict | None, str]:
    """(the fast checks off the Mac that stand for <head> merged onto <base> at <base_sha>, '') or (None, why the Mac
    runs the whole --plan fast). While none stands and one of them is still running, it waits up to <wait> seconds
    (HOSTED_FAST_WAIT inside a lane job, else none, so tests and local runs never sleep)."""
    env = os.environ if env is None else env
    if wait is None:
        wait = HOSTED_FAST_WAIT if env.get('GITHUB_ACTIONS') == 'true' else 0
    deadline = clock() + wait
    while True:
        found, why = _hosted_fast_checks_once(github, tree, base, head, base_sha, env, records, checks)
        if found is not None or NOT_FINISHED not in why or clock() + poll > deadline:
            return found, why
        print(f'[lane] waiting for the fast checks off the Mac: {why}', file=out, flush=True)
        sleep(poll)


def _hosted_fast_checks_once(github, tree: Path, base: str, head: str, base_sha: str, env,
                             records, checks: dict = HOSTED_FAST_CHECKS) -> tuple[dict | None, str]:
    """The GitHub-hosted pair, with the switch on; each record says which runner ('runner').

    A run stands when it tested exactly <head> merged onto some next (its merge tree matches the one this
    runner computes for that next), and that next is <base_sha> or next's commits since can't change what it showed:
    the rule a held PASS meets after next moves (untested_moves)."""
    if not hosted_fast_on(env):
        return None, f'the hosted fast checks are off ({HOSTED_FAST_SWITCH} is not `on`)'
    found, why = _fast_checks_stand(github, tree, base, head, base_sha, records, checks)
    if found is None:
        return None, why
    return {name: {**record, 'runner': 'GitHub-hosted'} for name, record in found.items()}, ''


def _fast_checks_stand(github, tree: Path, base: str, head: str, base_sha: str, records,
                       checks: dict) -> tuple[dict | None, str]:
    try:
        found, why = records(github, head, checks)
        if found is None:
            return None, why
        for name, record in found.items():
            if merged_tree(tree, record['base'], head) != record['tree']:
                return None, (f'"{name}" tested a tree that is not {head[:7]} merged onto {base} at '
                              f'{record["base"][:7]}')
            if record['base'] != base_sha:
                skipped, why = untested_moves(tree, record['base'], base_sha, head)
                if skipped is None:
                    return None, f'"{name}" tested it on {base} at {record["base"][:7]}, and {base} since: {why}'
                record['moved'] = skipped
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        return None, f'the runner could not read the fast checks off the Mac ({error!r})'
    return found, ''


def hosted_fast_ran(found: dict) -> str:
    bases = sorted({record['base'][:7] for record in found.values()})
    where = sorted({record.get('runner', 'GitHub-hosted') for record in found.values()})
    if set(HOSTED_REST_CHECK) <= set(found):
        return (f'host tests ({" and ".join(where)}: --plan fast-portable, SessionKitCoreTests and --plan fast-mac-rest '
                f'with next at {", ".join(bases)}; none on the Mac)')
    return (f'host tests ({" and ".join(where)}: --plan fast-portable and SessionKitCoreTests with next at {", ".join(bases)}; '
            'Mac: --plan fast-mac-rest)')


def hosted_fast_lines(found: dict) -> list[str]:
    lines = []
    for name, record in found.items():
        moved = record.get('moved')
        since = (f'; next\'s {len(moved)} commit{"s" if len(moved) != 1 else ""} since touch none of this PR\'s files '
                 'and no build inputs its checks read' if moved else '')
        lines.append(f'{record.get("runner", "GitHub-hosted")} check "{name}": PASS on this head merged with next at {record["base"][:7]} '
                     f'(tree {record["tree"][:7]}){since}. {record.get("url", "")}'.rstrip())
    return lines


# #2459: how long the hosted automerge job waits for the three hosted checks. It waits on GitHub-hosted Linux, which
# the public repo doesn't pay for and which holds no Mac, so the wait is long enough for the Mac-rest check to queue
# behind the free plan's 5 concurrent hosted Macs and run (about 8 minutes of tests on the build Mac).
HOSTED_REST_WAIT = 60 * 60
# A check run GitHub hasn't created yet looks like a check that never ran. Right after a push the hosted checks can
# be a few seconds behind the automerge job, so a missing one is waited for this long before the job gives up on it.
HOSTED_MISSING_GRACE = 5 * 60
HOSTED_FAILED = re.compile(r'" ended (failure|timed_out) on ')
HOSTED_MISSING = re.compile(r'^no ".+" check ran on ')
# What _fast_checks_stand says when a check passed on an older next whose commits since can matter.
HOSTED_STALE = re.compile(r'" tested (a tree that is not|it on .+ and .+ since: )')
HOSTED_WORKFLOW = 'hosted-portable.yml'
HOSTED_REDISPATCHES = 3  # fresh runs per job when next keeps moving under them; then the Mac fallback takes it
NEEDS_MAC = 'NEEDS_MAC'  # the hosted automerge job's cue to hand the run to lane.yml's automerge-mac job
MOVED_ON = 'stopped waiting for the hosted checks: '


def pr_moved_on(github, head: str) -> str | None:
    """Why a run waiting on <head> should stop (the PR moved on, lost automerge or closed: a newer run or nobody
    wants this one), or None. A failed read is no reason to stop."""
    try:
        now = github.pull()
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if now.get('state', 'open') != 'open':
        return f'{MOVED_ON}the PR is {now.get("state")}'
    if now['head']['sha'] != head:
        return f'{MOVED_ON}the PR moved on to {now["head"]["sha"][:7]}, whose own run tests it'
    if AUTOMERGE not in {label['name'] for label in now.get('labels', [])}:
        return f'{MOVED_ON}the automerge label is gone'
    return None


def hosted_rest_checks(github, tree: Path, base: str, head: str, base_sha: str, alive, dispatch, env=None,
                       records=hosted_fast_records, wait: float | None = None, poll: float = HOSTED_FAST_POLL,
                       grace: float = HOSTED_MISSING_GRACE, clock=time.monotonic, sleep=time.sleep,
                       out=sys.stdout, checks: dict | None = None) -> tuple[dict | None, str]:
    """(all three hosted checks standing for <head> merged onto <base> at <base_sha>, '') or (None, why not), for the
    hosted automerge job (#2459). It never runs a test. While a check is still running, or missing within <grace>,
    it waits, up to <wait> seconds (HOSTED_REST_WAIT in a lane job, else none). When one passed on an older next that
    has since moved in ways that matter, it calls dispatch() (up to HOSTED_REDISPATCHES times: a fresh run of hosted-portable.yml on the PR's
    branch, merged onto <base>) and waits for that. alive() names why to stop (the PR moved on, say) or is falsy.
    checks: the checks to wait for, all three by default; the hosted pair alone (HOSTED_FAST_CHECKS) when the hosted
    job only waits for them before handing the run to the build Mac (LANE_HOSTED_MAC_REST off)."""
    env = os.environ if env is None else env
    if wait is None:
        wait = HOSTED_REST_WAIT if env.get('GITHUB_ACTIONS') == 'true' else 0
    checks = {**HOSTED_FAST_CHECKS, **HOSTED_REST_CHECK} if checks is None else checks
    started = clock()
    deadline = started + wait
    dispatches, dispatched_at, running_seen = 0, started, False
    while True:
        stop = alive()
        if stop:
            return None, stop
        found, why = _hosted_fast_checks_once(github, tree, base, head, base_sha, env, records, checks)
        if found is not None or HOSTED_FAILED.search(why):
            return found, why
        if NOT_FINISHED in why:
            running_seen = True
        elif HOSTED_STALE.search(why):
            # First time, or the run started again finished and next had moved again meanwhile.
            if dispatches == 0 or running_seen:
                if dispatches >= HOSTED_REDISPATCHES:
                    return None, f'{why} (after {dispatches} fresh runs)'
                problem = dispatch()
                if problem:
                    return None, f'{why}; running them again on {base} failed: {problem}'
                dispatches, dispatched_at, running_seen = dispatches + 1, clock(), False
                print(f'[lane] {why}; started them again on the newest {base}', file=out, flush=True)
            elif clock() - dispatched_at > grace:
                return None, f'{why}; the run started again {duration(clock() - dispatched_at)} ago has not shown up'
        elif not (HOSTED_MISSING.search(why) and clock() - started < grace):
            return None, why
        if clock() + poll > deadline:
            return None, f'{why} (waited {duration(clock() - started)})'
        print(f'[lane] waiting for the hosted checks: {why}', file=out, flush=True)
        sleep(poll)


def hosted_checks_missing(why: str, fallback: str = NEEDS_MAC) -> tuple[str, str, str, list[str]]:
    """What a run that merges on the hosted checks returns when they don't stand: FAIL when one failed on this head
    (the PR's code, as the Mac's own run would have shown), else <fallback> with why."""
    if HOSTED_FAILED.search(why):
        return 'FAIL', 'hosted checks', 'hosted fast checks: failed', [
            f'not merged: {why}. Its log is in the PR\'s checks; fix it and push.']
    return fallback, 'hosted Linux runner', 'nothing', [f'the hosted checks do not stand: {why}']


def hosted_rest_ran(evidence: Path, changed=None) -> tuple[str, list[str]]:
    """run_automerge's mac_rest when the hosted Mac-rest check passed: nothing runs here; hosted_fast_lines says
    which check ran it."""
    return 'PASS', []


AUDIT_SHA = re.compile(r'`([0-9a-f]{7,40})`')
CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)  # how the audit task's verdict line opens


def audit_blocker(comments: list[dict], head: str) -> str | None:
    """Why the Codex or Claude audits on the PR don't clear its head, or None when the newest audit of the head is clean.

    #441: any audit comment used to clear the PR, whatever commit it covered or what it found. An audit
    counts only if its heading names the head commit (the hourly task's says "on `<sha7>`"), and it clears
    only if its verdict, the first line after the heading, opens "No blocking findings". Anything else
    holds, so a new audit format fails closed.
    """
    audits = []
    for comment in comments:
        body = (comment.get('body') or '').lstrip()
        if (body.startswith(AUDITS[:2]) or
                re.fullmatch(r'\*\*Claude audit on `[0-9a-f]{7,40}`\*\*', body.partition('\n')[0].rstrip())):
            heading, _, rest = body.partition('\n')
            verdict = next((line.strip() for line in rest.splitlines() if line.strip()), '')
            audits.append((AUDIT_SHA.findall(heading), verdict))
    if not audits:
        return 'has no Codex or Claude audit comment yet'
    on_head = [verdict for shas, verdict in audits if any(head.startswith(sha) for sha in shas)]
    if not on_head:
        audited = next((shas[0] for shas, _ in reversed(audits) if shas), None)
        return (f'has no Codex or Claude audit of its head: the audit is on `{audited}`, the head is `{head[:7]}`' if audited
                else f'has no Codex or Claude audit naming its head `{head[:7]}`')
    if not CLEAN_AUDIT.match(on_head[-1]):
        return f'the Codex or Claude audit on the head `{head[:7]}` has blocking findings (it doesn\'t say "No blocking findings")'
    return None


# Owner rule 2026-10-09 (#1203, #1210): arming and merging a PR that touches the runner itself or anything under
# .github/ is the owner's tap. The runner can't test itself, and a bad runner or workflow change could wave later
# PRs through, so a clean audit doesn't let the runner merge these. Other lane paths still merge on an audit.
OWNER_TAP_FILES = {'scripts/lane-runner.py'}
OWNER_TAP_PREFIXES = ('.github/',)


def owner_tap_paths(scope: dict) -> list[str]:
    """The PR's changed paths only the owner merges, whatever an audit says (OWNER_TAP_FILES, OWNER_TAP_PREFIXES)."""
    paths = {f.get('path') or '' for f in scope.get('files', [])} | set(scope.get('lane_paths') or [])
    return sorted(p for p in paths if p in OWNER_TAP_FILES or p.startswith(OWNER_TAP_PREFIXES))


def owner_tap_note(paths: list[str]) -> str:
    shown = ', '.join(f'`{p}`' for p in paths)
    return (f'not merged by the runner: it touches {shown}, which only the owner merges (owner rule 2026-10-09, '
            '#1203), whatever an audit says. It needs the owner\'s tap.')


INHERITED_HOLD = 'it inherits a blocking audit finding'  # lane_inherited_holds.INHERITED: a test keeps them equal
INHERITED_FAILED = 'the check for inherited audit findings could not finish'
INHERITED_POLICY = 'scripts/lane_inherited_holds.py'
# Other PRs' comments, kept by PR number and updated_at so an unchanged PR costs no call on the next run.
INHERITED_CACHE = Path(os.environ.get('SM_LANE_INHERITED_CACHE') or
                       Path.home() / 'Library/Caches/SpokenMarginsLane/inherited-holds.json')


def inherited_check(github, tree: Path, base: str, head: str):
    """#712: a function from the PR's comments to the reasons its inherited audit findings hold it (see
    scripts/lane_inherited_holds.py). The lookup reads other PRs' audits for the commits this PR brings in beyond
    next; the rules come from next's copy, like the other policies. A lookup that can't finish holds the merge."""
    try:
        policy = base_policy(tree, base, INHERITED_POLICY)
        if policy is None:
            raise RuntimeError(f'{base} has no {INHERITED_POLICY} yet')
        holds = policy.find_holds(tree, github.repo, f'origin/{base}', head, github.pr, cache=INHERITED_CACHE)
    except Exception as error:  # noqa: BLE001 - any failure to look holds the merge instead of waving it through
        why = f'{INHERITED_FAILED}: {str(error)[:200]}. Remove and re-add automerge to check again'
        return lambda comments: [why]
    return lambda comments: policy.reasons(policy.unresolved(holds, comments, head), head)


def merge_blockers(scope: dict, comments: list[dict], head: str, inherited=None) -> list[str]:
    """Why the runner won't merge this PR yet even on PASS: an audited kind of change without a clean Codex or Claude
    audit of its head. Lane changes are one of those kinds; they no longer wait for a person (owner rule
    2026-10-01). The audit script re-arms automerge after a clean audit, and that run merges.

    inherited (inherited_check's answer) adds a hold per blocking audit on another PR's commits this PR brings in
    (#712): a clean audit of this head doesn't clear it, a resolution of that finding plus a clean audit after does."""
    reasons = []
    # Imported here, like lane_slots: the workflow runs this file from $RUNNER_TEMP, where ROOT/scripts is
    # not the workspace, so a top-level import fails before main() puts the tree on sys.path.
    from lane_audit_policy import requires_persistence_audit
    risky = {AUDITED[f['category']] for f in scope['files'] if f['category'] in AUDITED}
    # #1658: test-scope's sessionkit category does not describe persistence risk.
    # Use the auditor's existing eligibility rules as well, without changing tiers.
    if requires_persistence_audit([f.get('path', '') for f in scope['files']]):
        risky.add('persistence')
    risky = sorted(risky)
    if scope.get('lane_paths'):  # owner rule 2026-10-01: lane changes need the audit too (test-scope.py)
        risky.append('the lane')
    audit = audit_blocker(comments, head) if risky else None
    if audit:
        reasons.append(f'it touches {" and ".join(risky)}, and {audit}' if audit.startswith('the ')
                       else f'it touches {" and ".join(risky)} and {audit}')
    return reasons + (inherited(comments) if inherited else [])


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
    """The line a held automerge report carries when its checks passed: what held_checks reads."""
    return '<!-- lane-checks: ' + json.dumps({'commit': head, 'next': tested_base, 'ran': ran, 'where': where},
                                             sort_keys=True) + ' -->'


def held_checks(comments: list[dict], head: str, hold=None, verdict: str | None = None) -> dict | None:
    """The checks the automerge run held on <head> passed: {'next', 'ran', 'where', 'url'}, or None.

    #834: the lane job that reported a T3 PASS ran --plan fast and both builds on sm-lane-mac, the one runner
    that runs T3s, 7 to 39 minutes a PR (2026-10-04), while the build runner could have run them as the T3
    waited. Now the build runner's automerge run does, and its held report says what passed with which next
    (checks_note). Only the newest automerge report counts, and only when it is the runner's own (posted
    with the workflow's token), on <head>, held (for T3 unless <hold> says another hold line), PASS when
    <verdict> says so, and names the head and a full next commit.
    The checks line and the hold must each be a whole line of their own: the PR's own test output appears in
    a report only indented (first_errors), so it can't pass for either. The last checks line counts.
    """
    hold = hold or PENDING_T3_HOLD
    for comment in reversed(comments):
        body = comment.get('body') or ''
        wanted = report_identity(body)
        reported = REPORT.search(body)
        if not (wanted and wanted.get('tier') == 'auto' and reported):
            continue
        found = CHECKS.findall(body)
        if wanted.get('commit') != head or (comment.get('user') or {}).get('login') != BOT[0] \
                or not hold.search(body) or not found or (verdict and reported.group(1) != verdict):
            return None
        try:
            checked = json.loads(found[-1])
        except ValueError:
            return None
        if not isinstance(checked, dict) or checked.get('commit') != head \
                or not re.fullmatch(r'[0-9a-f]{40}', str(checked.get('next') or '')):
            return None
        return {'next': checked['next'], 'ran': str(checked.get('ran') or 'host tests'),
                'where': str(checked.get('where') or 'no simulator (compile only)'),
                'url': comment.get('html_url') or ''}
    return None


def audit_held_checks(comments: list[dict], head: str) -> dict | None:
    """#1461: the checks an automerge run passed on <head> before the audit hold stopped it, or None.

    A lane, audio, persistence or packet PR passes its automerge run, can't merge until its head is audited,
    and the audit re-arms automerge: that run used to test the same commit on the same next again (13 to 25
    times a day, about 6 minutes each). Its hold report carries the passed checks (run_auto), and the re-armed
    run lets them stand under the same rules as after a T3 hold: unless next has since moved in ways that
    matter (untested_moves). The newest automerge report must be that PASS, so a later FAIL or run wins.
    """
    checked = held_checks(comments, head, AUDIT_HOLD, 'PASS')
    if checked:
        checked['held'] = 'the automerge run held for the audit' + (f' ({checked["url"]})' if checked['url'] else '')
    return checked


def t3_request_for_head(comments: list[dict], labels, head: str) -> str | None:
    """The link to a /lane T3 request for <head> that the lane job has still to answer, or None.

    An automerge run on such a PR can't merge: the T3 gate holds it until the T3 reports, and the lane
    job that reports a T3 PASS merges it (#421). On the build runner the automerge run still runs its host
    tests, and that lane job merges without them when next hasn't moved in ways that matter
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
    runner's merges. After each merge, run the base's audit over the last two hours instead. Best effort: never fails a job."""
    try:
        audit = base_policy(tree, base, 'scripts/merge_audit.py')
        if audit:
            audit.main(['--sweep-hours', '2', '--base', base])
    except Exception as error:  # noqa: BLE001 - the audit is a safety net, not part of the verdict
        print(f'merge-audit sweep skipped: {error!r}')


# hosted-integration.yml tests the trunk's tip on a GitHub-hosted Mac (#1389), whichever branch that is (#1492).
HOSTED_INTEGRATION_WORKFLOW = 'hosted-integration.yml'


def dispatch_hosted_integration(base: str) -> str:
    """Start hosted-integration on <base>'s new tip after the runner pushed it (#2127), and say what happened.

    The runner pushes with the workflow token, and such a push starts no workflow, so hosted-integration's push
    trigger never sees the runner's merges. A workflow_dispatch does start a run from that token, as for the
    release job (hand_off_release). GitHub accepts it only once the workflow file is on the default branch (main);
    until then it refuses, and the Mac's integration script tests the tip itself (sm_integration_run.py). While
    LANE_HOSTED_APP is not `on` the run's job is skipped, at no cost. Best effort: never fails a job. Only inside
    the lane job (GITHUB_ACTIONS and GH_TOKEN set), so tests and local runs dispatch nothing."""
    if base != trunk():
        return f'hosted integration not started: it tests {trunk()}, not {base}'
    repo = os.environ.get('GH_REPO')
    if os.environ.get('GITHUB_ACTIONS') != 'true' or not os.environ.get('GH_TOKEN') or not repo:
        return 'hosted integration not started: not in a lane job'
    try:
        sent = subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{repo}/actions/workflows/'
                               f'{HOSTED_INTEGRATION_WORKFLOW}/dispatches', '-f', f'ref={base}'],
                              capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        return f'hosted integration not started: {error!r}'
    if sent.returncode:
        return f'hosted integration not started: {(sent.stderr or sent.stdout).strip()[-200:]}'
    return f'hosted integration started on {base} ({HOSTED_INTEGRATION_WORKFLOW}, workflow_dispatch)'


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


# scripts/ files a PR's automerge checks never read, unless the PR itself touches a path in
# HOST_FULL_RUN_TRIGGERS (#1208). Without one, its run is the hot-file ratchet, test-scope.py and --plan fast with
# only the runner tests' readers (verify-tests.py RUNNER_TEST_READERS) and no ops tests, and no app build
# (NO_APP_BUILD_PER_PR). next changing one of these alone can't change what that run showed, so the PR re-merges
# without testing again. Measured 2026-10-12 by tracing every file the readers and a whole --plan fast for an
# App/ + Packages/ diff open (a Python audit hook in every Python process, leaving out verify-tests.py's
# input_identity digest, which only spots edits made during the run) and every command they start. Re-measure
# the same way after adding a reader or a fast step. A file not listed counts as a build input, so a new
# script is safe until someone lists it. Left off on purpose although the trace didn't read them: the
# Build 29 compatibility tools (shipped-build-compat.yml runs them), the Linux T1 runner and the Python
# bootstrap.
HOST_UNREAD_SCRIPTS = frozenset({
    # The lane's and the Mac's own tools: job dedupe, ledger, guard, merge audit, the FAIL re-check on next,
    # integration precheck, phone builds and app builds (no app build per PR).
    'scripts/lane_dedupe.py', 'scripts/lane_ledger.py', 'scripts/lane_guard.py', 'scripts/install-lane-guard.py',
    'scripts/merge_audit.py', 'scripts/lane_next_rerun.py', 'scripts/integration-precheck.py',
    'scripts/phone-build', 'scripts/com.spokenmargins.phone-build.plist', 'scripts/install-phone-build.command',
    'scripts/xcodebuild-lane',
    # Release, app-plan, build-phase and site scripts.
    'scripts/TestFlightUploadOptions.plist', 'scripts/check-release-test-hooks.sh', 'scripts/verify-bundle.py',
    'scripts/validate-developer-recording.py', 'scripts/normalize-embedded-framework-minimum-os.sh',
    'scripts/remove-embedded-static-onnxruntime.sh', 'scripts/deploy-spoken-margins-site.sh',
    'scripts/smoke-simulator.sh', 'scripts/run-podcast-anchor-benchmark.sh', 'scripts/audit-gate1-readiness.py',
    'scripts/verify-gate1.sh', 'scripts/verify-gate1-closeout.sh', 'scripts/verify-gate1-routine.sh',
    'scripts/verify-gate2.sh',
    # Runner test modules that aren't readers, so only a lane PR's own run (all runner tests) runs them.
    *(f'scripts/tests/{name}.py' for name in (
        'test_host_audio', 'test_integration_precheck', 'test_lane_beside_simulator', 'test_lane_dedupe',
        'test_lane_guard', 'test_lane_ledger', 'test_lane_next_moved', 'test_lane_next_rerun', 'test_lane_sim_pool',
        'test_lane_slots', 'test_lane_t3_first', 'test_lane_release_handoff', 'test_merge_audit', 'test_phone_build', 'test_posterboard_repair',
        'test_sessionkit_steps', 'test_test_scope', 'test_ui_test_hooks_debug_only', 'test_xcresult_attachments')),
})
# A PR touching any of these runs every runner test or the ops tests, which between them read the lane's own
# scripts, so for it every scripts/ change still counts: verify-tests.py's RUNNER_TEST_TRIGGERS and
# OPS_TEST_TRIGGERS (a test keeps them covered).
HOST_FULL_RUN_TRIGGERS = ('scripts/', '.github/', '.gitignore', 'ops/', 'project.yml', 'TestPlans/', 'AGENTS.md')


def widens_host_checks(paths) -> bool:
    return any(path == prefix or path.startswith(prefix) for path in paths for prefix in HOST_FULL_RUN_TRIGGERS)


def counts_for_pr(path: str, pr_paths) -> bool:
    """Whether next changing <path> can change what this PR's automerge checks showed: a build input, unless
    the checks never read it (HOST_UNREAD_SCRIPTS) and the PR's own diff didn't widen them to every runner test
    or the ops tests."""
    if not is_build_input(path):
        return False
    return path not in HOST_UNREAD_SCRIPTS or widens_host_checks(pr_paths)


def untested_moves(tree: Path, tested_base: str, new_base: str, head: str) -> tuple[list[str] | None, str]:
    """(next's commits since <tested_base>, '') when they can't change what the PR's test showed, else (None, why).

    They can't when they touch none of the PR's files and no build input its checks read (counts_for_pr). Each
    first-parent commit counts with everything it brought in, so a merge of another PR counts with that PR's files.
    """
    git = ['git', '-C', str(tree)]
    if subprocess.run(git + ['merge-base', '--is-ancestor', tested_base, new_base], capture_output=True).returncode:
        return None, f'it no longer contains the tested commit {tested_base[:7]}'
    merge_base = subprocess.check_output(git + ['merge-base', tested_base, head], text=True).strip()
    # Both sides of a rename, so a PR that moves a file out of scripts/ still counts as touching scripts/, and
    # NUL-separated: git quotes a name like scripts/tests/test_café.py otherwise, and it no longer starts with scripts/.
    mine = {path for path in subprocess.check_output(git + ['diff', '--name-only', '--no-renames', '-z', merge_base,
                                                             head], text=True).split('\0') if path}
    # Both sides of a rename on next too (a PR's file renamed there is still its file), and unquoted names.
    log = subprocess.check_output(git + ['-c', 'core.quotePath=false', 'log', '--first-parent', '-m', '--name-only',
                                         '--no-renames', '--format=%x00%h %s', f'{tested_base}..{new_base}'],
                                  text=True)
    commits, touched = [], set()
    for line in log.splitlines():
        if line.startswith('\0'):
            commits.append(line[1:])
        elif line.strip():
            touched.add(line.strip())
    shared = sorted(touched & mine)
    if shared:
        return None, f'its commits touch this PR\'s files ({", ".join(shared[:5])})'
    inputs = sorted(p for p in touched if counts_for_pr(p, mine))
    if inputs:
        return None, f'its commits touch build inputs ({", ".join(inputs[:5])})'
    return commits, ''


def merge_check_untested(head: str, merge_sha: str, base: str, base_sha: str, tested_base: str, ran: str,
                         commits: list[str], reused: str | None = None) -> str:
    """The merge check for a re-merge pushed without testing again. It never says "Pushing `<sha7>`":
    scripts/phone-build reads that as "the runner tested this exact commit"."""
    shown = ', '.join(f'`{c}`' for c in commits[:SKIPPED_SHOWN]) + \
        (f' and {len(commits) - SKIPPED_SHOWN} more' if len(commits) > SKIPPED_SHOWN else '')
    moved = (f'- {base} has since moved to `{base_sha[:7]}`, and its commits touch none of this PR\'s files and no '
             f'build inputs its checks read: {shown}.\n' if commits else
             f'- {base} hasn\'t moved since that run.\n' if reused else
             f'- {base} hasn\'t moved since (the test ran in the automerge run held for T3).\n')
    return (f'{MERGE_CHECK} on `{head[:7]}`: PASS, re-merged onto the newest {base} without re-testing.**\n'
            + (f'- Reuses the earlier PASS: {reused}.\n' if reused else '')
            + f'- Tested this PR merged with {base} at `{tested_base[:7]}`. Ran: {ran}.\n'
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
            'build inputs its checks read.\n'
            '_Posted by the lane runner (scripts/lane-runner.py)._')


class AutoRunContext:
    """The base of the latest merge/check attempt, available even if that attempt raises."""
    def __init__(self, tested_base: str):
        self.tested_base = tested_base


def checks_stand(checked: dict | None, base_sha: str, head: str) -> bool:
    """Whether run_auto will let <checked> stand on <base_sha>: next's commits since touch nothing the checks read."""
    if not checked:
        return False
    try:
        return untested_moves(ROOT, checked['next'], base_sha, head)[0] is not None
    except (OSError, subprocess.SubprocessError):
        return False


def run_auto(github, pull: dict, pr: int, base: str, head: str, base_sha: str, evidence: Path,
             comments: list[dict], labels=(), attempts: int = MERGE_ATTEMPTS,
             context: AutoRunContext | None = None,
             checked: dict | None = None, hosted: bool = False, rest_hosted: bool = False,
             rest_wait: float | None = None) -> tuple[str, str, str, list[str]]:
    """The automerge run: test the merge commit, and push it to <base> on PASS unless something blocks it.

    checked: the checks the automerge run held for T3 (held_checks) or for the audit (audit_held_checks) on this
    head passed. They stand, as after a refused push, when next's commits since touch none of the PR's files and no
    build inputs its checks read (#834, #1461); otherwise this run tests again.

    hosted: the hosted Linux job. A T0 or ops diff runs its tests here; any other runs on the three hosted checks
    (hosted_rest_on, #2459), as rest_hosted asks anywhere: a PR held for T3 is reported held before any wait, and
    otherwise the run waits for the checks (hosted_rest_checks, up to <rest_wait>) and runs no test itself. When they
    can't be had, the hosted job returns NEEDS_MAC and any other run INCONCLUSIVE; a failed one is a FAIL.
    With only LANE_HOSTED_FAST on, the hosted job does the same up to the merge, on the hosted pair alone: held for
    T3 is reported held, a failed check is the FAIL, and once the pair passed on this head (or can't be had) it
    returns NEEDS_MAC, so the build Mac runs --plan fast-mac-rest and merges without idling for the pair.
    """
    notes: list[str] = []
    tested_base, skipped = None, None  # the next the last test ran on; next's commits since, when they can't matter
    reused = None  # the held automerge run whose passed checks stand (#834, #1461), for the merge check
    scope, tested, checks = None, '', []
    if checked:
        try:
            skipped, why = untested_moves(ROOT, checked['next'], base_sha, head)
        except (OSError, subprocess.SubprocessError) as error:  # can't tell: test again
            skipped, why = None, f'the runner could not compare the commits ({error!r})'
        held_by = checked.get('held') or 'the automerge run held for T3'
        held_run = f'{held_by} passed its checks with {base} at {checked["next"][:7]}'
        if skipped is None:
            notes.append(f'{held_run}; tested again on {base_sha[:7]}, because {why}')
        else:
            tested_base, ran, where, verdict = checked['next'], checked['ran'], checked['where'], 'PASS'
            reused = checked.get('held')
            tested = (f'not re-tested: {held_run}, and ' + (
                f'{base}\'s {len(skipped)} commit{"s" if len(skipped) != 1 else ""} since touch none of this PR\'s '
                'files and no build inputs its checks read' if skipped else f'{base} hasn\'t moved since'))
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
        rest = rest_hosted  # merge on the three hosted checks, testing nothing here (#2459)
        pair = False  # wait here for the hosted pair, then hand the run to the build Mac (#2459, Mac rest off)
        if hosted:
            # Recheck with the current base's policy on every merge attempt, including reused checks.
            policy = base_policy(ROOT, base, 'scripts/test-scope.py')
            if not policy.hosted_automerge(diff_scope(ROOT, base)):
                if hosted_rest_on():
                    rest = True
                elif hosted_fast_on():
                    pair = True
                else:
                    return 'INCONCLUSIVE', 'hosted Linux runner', 'nothing', [
                        'The current diff requires the Mac; remove and re-add automerge to route it again.']
        if skipped is None:
            if rest or pair:
                held = t3_gate(comments) if attempt == 1 else None
                if held:  # the lane job that reports the T3 PASS merges it (merge_after_t3): nothing to test here
                    return held[0], 'hosted Linux runner', 'nothing', notes + [
                        f'not merged: {held[1]}.',
                        'This run tested nothing and took no Mac: the T3 PASS\'s merge runs the host tests then, '
                        'or merges on the hosted checks that stand for this head.']
                found, why = hosted_rest_checks(github, ROOT, base, head, base_sha, wait=rest_wait,
                                                alive=lambda: pr_moved_on(github, head),
                                                dispatch=lambda: github.dispatch_hosted_checks(pull['head']['ref'],
                                                                                               base),
                                                **({'checks': HOSTED_FAST_CHECKS} if pair else {}))
                if why.startswith(MOVED_ON):
                    return 'INCONCLUSIVE', 'hosted Linux runner', 'nothing', notes + [f'not merged: {why}']
                if not found:
                    return hosted_checks_missing(why, NEEDS_MAC if hosted else 'INCONCLUSIVE')
                if pair:  # the build Mac takes the hosted pair's PASS and runs only --plan fast-mac-rest
                    return NEEDS_MAC, 'hosted Linux runner', 'nothing', notes + [
                        f'the hosted fast pair passed on {head[:7]} with {base} at '
                        f'{", ".join(sorted({record["base"][:7] for record in found.values()}))}; the build Mac runs '
                        '--plan fast-mac-rest and merges']
            tried.mkdir(parents=True, exist_ok=True)
            warm = 'no Mac build folders needed' if hosted or rest else host_build_folders(ROOT)
            scope = diff_scope(ROOT, base)
            (tried / 'scope.json').write_text(json.dumps(scope, indent=2))
            if not rest:
                found, why = (None, '') if hosted else hosted_fast_checks(github, ROOT, base, head, base_sha)
            if why and not rest:
                notes.append(f'the whole --plan fast ran on the Mac: {why}')
            verdict, where, ran, checks = run_automerge(
                scope, tried, ratchet=lambda: hot_file_violations(ROOT, base, set(labels)),
                changed=lambda: changed_paths_for_tests(ROOT, base),
                recheck=recheck_on_base(github, base_sha), **({'hosted': True} if hosted and not rest else {}),
                **({'hosted_fast': found} if found else {}), **({'mac_rest': hosted_rest_ran} if rest else {}))
            tested = f'tested the merge commit {merge_sha[:7]} ({base} at {base_sha[:7]} first, then this PR); {warm}'
            if verdict != 'PASS':
                return verdict, where, ran, [tested] + notes + checks
            tested_base, reused = base_sha, None
        elif scope is None:  # the held run's checks stand; the audit hold still reads the diff's scope
            if context is not None:  # the report says which next the checks ran with, not the newest
                context.tested_base = tested_base
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
        blockers = merge_blockers(scope, latest, head, inherited_check(github, ROOT, base, head))
        tap = owner_tap_paths(scope)
        if blockers or tap:  # the audit hold line goes first: the Mac's audit script finds lane PRs to audit by it
            # What passed, for the automerge run the audit re-arms (#1461); the owner's tap is checked again then.
            return verdict, where, ran, details + [checks_note(head, tested_base, ran, where)] + [
                f'not merged by the runner: {b}.' if b.startswith((INHERITED_HOLD, INHERITED_FAILED)) else
                f'not merged by the runner: {b}. It merges once a Codex or Claude audit '
                'of its head says "No blocking findings".' for b in blockers] + (
                [owner_tap_note(tap)] if tap else [])
        now = github.pull()
        if now['head']['sha'] != head or AUTOMERGE not in {label['name'] for label in now.get('labels', [])} \
                or now.get('state', 'open') != 'open':  # another run merged it meanwhile, or someone closed it
            return verdict, where, ran, details + ['not merged: the PR moved on, lost the automerge label or was '
                                                   'closed while it was tested']
        github.comment(merge_check(head, merge_sha, base, base_sha, ran) if skipped is None else
                       merge_check_untested(head, merge_sha, base, base_sha, tested_base, ran, skipped, reused))
        pushed, message = push_merge(ROOT, merge_sha, base)
        if pushed:
            sweep_merge_audit(ROOT, base)
            print(f'[lane] {dispatch_hosted_integration(base)}', flush=True)
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
                         f'since the tested {tested_base[:7]} touch none of this PR\'s files and no build inputs its checks '
                         f'read, so the re-merge onto {base_sha[:7]} goes without testing again (skipped: {shown})')
    return 'PASS', where, ran, details + notes[-1:] + [
        f'not merged: {base} kept moving ({attempts} attempts). Remove and re-add automerge to try again.']


def clean_tree(tree: Path) -> None:
    """Drop changes to tracked files a test run left, so checking out another commit can't refuse."""
    subprocess.run(['git', '-C', str(tree), 'reset', '--hard', '--quiet'], check=True, capture_output=True)


def retest_reason(checked: dict | None, base_sha: str, head: str) -> str | None:
    """Why the held automerge run's checks don't stand on <base_sha> (run_auto would test again), or None if they do."""
    if not checked:
        return 'the automerge run held for T3 has no passed checks to reuse'
    try:
        skipped, why = untested_moves(ROOT, checked['next'], base_sha, head)
    except (OSError, subprocess.SubprocessError) as error:
        return f'the runner could not compare the commits ({error!r})'
    if skipped is not None:
        return None
    return f'its checks passed with {checked["next"][:7]}, and next at {base_sha[:7]} differs: {why}'


# How long after a hand-off a release run with nothing on the PR counts as lost (#1542): the release job's
# 150-minute timeout, plus half an hour for it to start. A run that never starts (cancelled or timed out in the
# queue) runs no step, so it can post nothing; the hand-off note names this time for the Hourly dispatch instead.
RELEASE_LOST_AFTER = 3 * 60 * 60


def handed_off_note(head: str, why: str, reason: str, where: str, now=None) -> str:
    """The lane job's note when it hands a released automerge run to the build runner (#1209). It starts like the
    automerge run's own notes, so it answers no /lane request (is_automerge_comment), and it is not a report.
    It names when the release run counts as lost (#1542), in words that lane_report_verdict doesn't read as a
    stopped job's note."""
    import datetime
    now = now or datetime.datetime.now(datetime.timezone.utc)
    lost = (now + datetime.timedelta(seconds=RELEASE_LOST_AFTER)).astimezone(datetime.timezone.utc)
    return (f'{HANDED_OFF} on `{head[:7]}` goes to the build runner (#1209).\n'
            f'- {why}; that run has to test the merge commit again, because {reason}.\n'
            '- So this simulator runner moves on to the next T3, and a `lane` release run on the build runner tests '
            f'the merge commit and merges on PASS: {where}.\n'
            '- Its report follows here. Nobody needs to push or re-label.\n'
            f'- If neither its report nor a note that it stopped is here by {lost:%Y-%m-%d %H:%M}Z, and no `lane` '
            f'run named `pr=<this PR> head={head[:7]}…` is still queued or running, the release run was lost: '
            f'remove and re-add `automerge` once (#1542).\n{NOTE}')


def merge_after_t3(github, pr: int, base: str, head: str, request_id: str, evidence: Path, base_sha: str,
                   why: str, hand_off=None, room=None, hosted: bool = False) -> str | None:
    """After a T3 PASS on <head>: the automerge run the T3 gate held, run here in the lane job (#421).

    When that held run passed its host tests (held_checks), they aren't run again here unless next
    has since moved in ways that matter (#834): the merge takes seconds instead of minutes on sm-lane-mac.

    hand_off (#1209): the lane job on the simulator runner passes it. When the held run's checks don't stand, it
    calls hand_off() (a workflow_dispatch of lane.yml, GitHub.hand_off_release) instead of testing here, posts
    handed_off_note and returns that note: the build runner's release run (--mode release) tests and merges. If the
    hand-off fails, this job tests as before.
    room: the release run passes the build runner's room wait (wait_for_room_to_test_on_host); it is called only
    when the checks have to run.
    #2459: when the three hosted checks stand for this head right now (hosted_rest_on), nothing is handed off or
    tested: the merge runs on them, in seconds, wherever this is. hosted: the hosted Linux automerge job calls it.

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
        reason = retest_reason(checked, base_sha, head) if hand_off or room or hosted else None
        rest = False
        if reason and hosted_rest_on():
            found, _ = hosted_rest_checks(github, ROOT, base, head, base_sha, alive=lambda: None,
                                          dispatch=lambda: 'not from here', wait=0)
            rest = found is not None
            reason = None if rest else reason
        if reason and hosted:  # the hosted job never runs the Mac's host tests: the Mac's release run does
            hand_off = hand_off or (lambda: github.hand_off_release(base, head, ''))
        handed = None
        if reason and hand_off:
            try:
                handed = hand_off()
            except Exception as error:  # noqa: BLE001 - no hand-off: test here, as before #1209
                started_by.append(f'the hand-off to the build runner failed ({str(error).strip()[:200] or error!r}), '
                                  'so this job tests it')
        if handed:
            note = handed_off_note(head, why, reason, handed)
            print(note)
            try:
                github.comment(note)
            except Exception as error:  # noqa: BLE001 - the release run is on its way; a lane-error report would
                print(f'[lane] could not post the hand-off note: {error!r}')  # read as the newest, un-held run
            return note
        no_room, beside = room() if reason and room else (None, None)
        if reason and room and not no_room:  # up to 90 minutes passed: a push or a re-arm since starts its own run
            now = github.pull()
            if now.get('state', 'open') != 'open' or now['head']['sha'] != head \
                    or AUTOMERGE not in {label['name'] for label in now.get('labels', [])}:
                print(f'PR #{pr} moved on, closed or lost automerge while this waited for room; nothing to release.')
                return None
        if beside:  # the host-only trial beside a simulator job, logged as the automerge job logs it
            started_by.append(beside)
            note_beside_simulator(request_id, pr, beside)
        if no_room:
            verdict, where, ran = 'INCONCLUSIVE', 'no build', 'nothing'
            details = [f'{no_room}. Remove and re-add automerge to run it again.']
        else:
            verdict, where, ran, details = run_auto(github, pull, pr, base, head, base_sha, evidence, comments,
                                                   labels, context=context, checked=checked,
                                                   **({'rest_hosted': True, 'rest_wait': 0} if rest else {}),
                                                   **({'hosted': True} if hosted and not rest else {}))
            if verdict == NEEDS_MAC:  # the hand-off to the Mac's release run failed above; no Mac here
                verdict, details = 'INCONCLUSIVE', details + ['Remove and re-add automerge to run it again.']
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


def run_release(github, pr: int, base: str, head: str, request_id: str, evidence: Path, t3_report: str) -> int:
    """--mode release (#1209): the held automerge run a T3 PASS released, handed over by the lane job on the
    simulator runner through a workflow_dispatch of lane.yml, run here on a build runner under its room rules.

    It re-reads everything (merge_after_t3 checks the PR is open on <head>, armed, held for T3 and no longer held),
    so a dispatch for a PR that moved on, or one anyone else sent, does nothing. Like any lane job that reports and
    doesn't merge, it ends by removing and re-adding lane:done, which the lane job skipped when it handed off.
    """
    pull = github.pull()
    if (pull.get('base') or {}).get('ref', base) != base:
        print(f'PR #{pr} targets {pull["base"]["ref"]}, not {base}; nothing to release.')
        return 0
    # Only same-repository PRs ever get lane runs (lane.yml); a dispatch naming a fork's PR runs none of its code.
    if ((pull.get('head') or {}).get('repo') or {}).get('full_name') != os.environ.get('GH_REPO'):
        print(f'PR #{pr} is not from a branch in this repository; nothing to release.')
        return 0
    link_tools(tools_source())
    why = f'started by the T3 PASS ({t3_report or "the lane job"}), handed to the build runner by its lane job'
    released = merge_after_t3(github, pr, base, head, request_id, evidence, fetch_base(ROOT, base), why,
                              room=wait_for_room_to_test_on_host)
    if released is None:
        print('Nothing to release: the PR moved on, closed, lost automerge, or is no longer held for T3.')
    verdict = REPORT.search(released or '')
    if verdict:
        record_outcome(verdict.group(1))
    merged = any(line.startswith(f'merged into {base} as ') for line in (released or '').splitlines())
    if released and not merged:
        github.relabel(DONE, DONE)  # the Hourly dispatch wakes on lane:done's `labeled` event
    flush_ledger(pr, head, lambda body: Repo(os.environ['GH_REPO']).comment(OPS_ISSUE, body))
    drop_workspace_builds(ROOT)
    return 0


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


def prune_lane_folder(evidence_root: Path) -> str:
    """Cap the lane folder and age out lane evidence before a build takes room (#1775): ops/disk/sm_lane_prune.py
    from the tools checkout, which the disk relief job also runs, though it can't read artifacts/lane in
    ~/Documents. Returns a line for the log; never fails the job."""
    script = tools_source() / 'ops/disk/sm_lane_prune.py'
    if not script.is_file():
        return 'lane folder prune: not installed in the tools checkout'
    state = Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane')
    try:
        done = subprocess.run([sys.executable, str(script), '--lane-dir', str(state), '--evidence-dir',
                               str(evidence_root)], capture_output=True, text=True, timeout=PRUNE_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f'lane folder prune: did not run ({error!r})'
    if done.returncode != 0:
        return f'lane folder prune: failed ({done.stderr.strip()[-200:]})'
    return 'lane folder prune: ' + (done.stdout.strip().splitlines() or ['nothing to do'])[-1]


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



# ---- No cache for automerge runs (#1207) ---------------------------------------------------------

def host_build_folders(tree: Path, root: Path | None = None) -> str:
    """The build folders for an automerge run, which builds no app (NO_APP_BUILD_PER_PR); returns a line for the report.

    It links no warm cache: the host tests build SessionKit in the workspace (Packages/SessionKit/.build),
    and main() empties that when the job ends (drop_workspace_builds). A warm SwiftPM cache saved about 50 s of
    a 5-minute run on the 48% of runs whose SessionKit key it had, and the build runners kept four of them
    each, 1.3 GB apiece: about 9 GB, which held automerge runs at the 20 GB disk floor (#1207).

    A T3 earlier in the same job linked the tree's folders to its cache: those links are undone (the cache
    stays, still locked by this job), so the host tests don't add a SwiftPM build to a T3 cache. Then the
    idle caches with no app build in them that this checkout's earlier automerge runs left are removed.
    """
    for link in (tree / '.build', tree / 'Packages/SessionKit/.build'):
        if link.is_symlink():
            link.unlink()
    removed, freed = sweep_host_test_caches(tree, root)
    line = 'build folders: in the workspace, no cache kept (automerge runs build no app)'
    if removed:
        line += (f'; removed {removed} idle host-test cache{"s" if removed != 1 else ""} ({freed / 10**9:.1f} GB) '
                 'that earlier automerge runs on this runner kept')
    return line


def holds_app_build(cache: Path) -> bool:
    """Whether a warm cache holds an app build: a T2's DerivedData (root/dd-simulator, root/dd-device) or a T3's
    (root/verification/<plan>). A cache with neither was made by an automerge run, for its SwiftPM build."""
    try:
        for child in (cache / 'root').iterdir():
            if child.is_dir() and (child.name.startswith('dd') or
                                   (child.name == 'verification' and any(child.iterdir()))):
                return True
    except OSError:
        return False
    return False


def folder_size(folder: Path) -> int:
    """Bytes on disk under folder, links not followed."""
    total = 0
    for parent, _, files in os.walk(folder):
        for name in files:
            try:
                total += os.lstat(os.path.join(parent, name)).st_blocks * 512
            except OSError:
                pass
    return total


def sweep_host_test_caches(tree: Path, root: Path | None = None) -> tuple[int, int]:
    """Remove this checkout's idle warm caches that hold no app build; returns (how many, bytes freed).

    Only this checkout's folder (one per runner, checkout_folder), never another runner's, and never a cache a
    job holds (_cache_busy) or one with a T2 or T3 build in it (holds_app_build): those are the T3 runner's to
    keep, under warm_build_folders' limits. Nothing is created: a checkout with no folder has nothing to sweep.
    """
    folder = (root or warm_root()) / checkout_folder(tree)
    if not folder.is_dir():
        return 0, 0
    removed, freed = 0, 0
    for cache in sorted(folder.glob('sk-*')):
        if not cache.is_dir() or cache.is_symlink() or holds_app_build(cache) or _cache_busy(cache):
            continue
        size = folder_size(cache)
        shutil.rmtree(cache, ignore_errors=True)
        if not cache.exists():
            removed, freed = removed + 1, freed + size
    return removed, freed


def drop_workspace_builds(tree: Path) -> None:
    """At the end of a job, empty the build folders it kept in the workspace rather than in a warm cache: an
    automerge run's SwiftPM build (1.3 GB), or a cold T2 or T3's DerivedData. Links to a warm cache stay."""
    if not (tree / '.build').is_symlink():  # a cold job (disk floor, busy cache) built in the workspace
        for derived in (tree / '.build').glob('dd*'):
            shutil.rmtree(derived, ignore_errors=True)
        shutil.rmtree(tree / '.build/verification', ignore_errors=True)
    swiftpm = tree / 'Packages/SessionKit/.build'
    if swiftpm.is_dir() and not swiftpm.is_symlink():
        shutil.rmtree(swiftpm, ignore_errors=True)

# ---- The build-only runner ----------------------------------------------------------------------

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
    usual rules hold.
    """
    from lane_slots import memory_pressure_level, simulator_jobs_running
    return wait_for_room(out, max_wait, poll, clock, sleep, simulator_jobs or simulator_jobs_running,
                         pressure or memory_pressure_level, free)


def wait_for_room(out, max_wait, poll, clock, sleep, simulator_jobs, pressure, free) -> tuple:
    """(None or why it gave up, a note when there's room beside a simulator job)."""
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
        else:
            if level not in (1, None):
                busy.append('memory pressure is above normal')
            if room < BUILD_RUNNER_FREE_DISK:
                busy.append(f'less than {BUILD_RUNNER_FREE_DISK // 10**9} GB of disk is free')
        if not busy:
            return None, (f'ran beside a simulator job (trial): memory pressure normal, '
                          f'{room // 2**30} GiB free' if jobs else None)
        waited = clock() - started
        if waited >= max_wait:
            return f'the build runner waited {duration(waited)} for room: {"; ".join(busy)}', None
        if last_note is None or clock() - last_note >= 300:
            print(f'[lane] build runner waiting ({duration(waited)} so far): {"; ".join(busy)}', file=out, flush=True)
            last_note = clock()
        sleep(poll)


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
        for found in recovered_startup_stalls(manifest):
            stall = found['stall']
            details.append(f'{plan}: recovered after 1 startup stall ({found["step"]} printed no test output '
                           f'{stall.get("after_seconds")}s after launch); the first retry passed '
                           f'{found["passed"]} test(s), which counts as a PASS (owner\'s call 2026-10-11). Logged '
                           f'on #{STALL_ISSUE}. evidence: {output}/{found["step"]}-stall-{stall.get("attempt")}/')
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


def boot_t3_device(udid: str, log, replace=None, evidence: Path | None = None, info: dict | None = None) -> tuple:
    """Boot the clone under the lane's boot rules (scripts/lane_sim.py).

    A clone has never booted as itself, so it gets the first-boot tolerance (one SpringBoard change in the
    first 30 s, #184). Without it every clone boot stopped on that change from 06:00 UTC on 2026-10-11 (#1359).
    At a boot stall, replace(old) gives one fresh clone to boot instead (#1802); each stall goes to
    <evidence>/boot-stalls.json, which log_recovered_stalls posts on #1802 with the report's link and verdict.

    Returns (None when ready or the reason it isn't, details such as the memory pressure at boot). info['udid']
    is the device the run holds now, ready or not; pass info to read it even if the boot raises.
    """
    import lane_sim
    info = {} if info is None else info

    def note(label, stalls, outcome):
        if evidence is not None:
            (evidence / BOOT_STALLS).write_text(json.dumps({'label': label, 'stalls': stalls, 'outcome': outcome},
                                                           indent=2) + '\n')

    try:
        lane_sim.boot_with_retry(udid, f'runner boot {udid}', replace, out=log, info=info, first_boot=True,
                                 log_stall=note)
    except lane_sim.BootError as error:
        return str(error), info
    return None, info


@ledger_step('app tests (T3)', lambda args, result: manifest_failures(*sorted(args[2].glob('verify-*'))))
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


def prepare_t3_build(grouped, runtime, evidence):
    """Both T3 plans use SpokenMarginsAppBehavior; prepare it before taking a simulator slot."""
    python = ROOT / '.venv/bin/python'
    output = evidence / 'verify-build'
    command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py',
               '--plan', next(iter(grouped)), '--build-only', '--runtime', runtime, '--output', str(output)]
    started = time.monotonic()
    with (evidence / 'verify-build.log').open('w') as log:
        finished = run_bounded(command, log, T3_TIMEOUT)
    manifest = _read_manifest(output)
    if finished is None:
        manifest.update(status='timed out', error='the runner build budget ran out; interrupted')
    if manifest.get('status') == 'verified':
        return 'PASS', [f'shared build before simulator boot took {duration(time.monotonic() - started)} '
                        f'(reused: {manifest.get("reused_build", False)}); evidence: {output}/manifest.json']
    summary = summarize_manifest(manifest)
    verdict = t3_verdict([summary], [manifest.get('status', 'missing')])
    return verdict, [f'Build before simulator boot: {manifest.get("error") or "no verified build manifest"}; '
                     f'evidence: {output}/manifest.json', *failed_step_errors(manifest, output)]


def _run_t3_grouped(grouped, request_id, evidence):
    """Build first, then take the simulator slot and run the grouped selectors on a clone."""
    import lane_sim
    runtime = lane_sim.newest_runtime()
    if not runtime:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', [f'No iOS {lane_sim.IOS_MAJOR} simulator runtime is installed.'],
                'none', '')
    verdict, build_details = prepare_t3_build(grouped, runtime, evidence)
    if verdict != 'PASS':
        return verdict, 'no simulator', 'nothing', build_details, 'none', ''
    from lane_slots import acquire_simulator_slot, release_handle
    try:
        slot = acquire_simulator_slot(f'runner T3 {request_id}', out=sys.stdout, max_wait=RUNNER_SLOT_WAIT)
    except TimeoutError as error:
        return ('INCONCLUSIVE', 'no simulator', 'nothing', ['The Mac\'s simulator slots stayed busy (a Test Desk job or '
                f'another run, and no room for a second simulator), so this run did not start one: {error}'], 'none', '')
    try:
        verdict, where, ran, details, crashes, cc = _t3_on_fresh_device(grouped, request_id, evidence, runtime)
        return verdict, where, ran, build_details + details, crashes, cc
    except (lane_sim.BootError, OSError, subprocess.SubprocessError) as error:
        return 'INCONCLUSIVE', 'no simulator', 'nothing', build_details + [f'Template or clone failed: {error}'], 'none', ''
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
    clone_started = time.monotonic()
    with (evidence / 'simulator-clone.log').open('w') as log:
        udid = lane_sim.clone_temporary(RUNNER_SIMULATOR_PREFIX + request_id, runtime, out=log)
    clone_seconds = time.monotonic() - clone_started
    where = f'cloned iPhone 17, {runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")}'
    python = ROOT / '.venv/bin/python'

    def run_plan(plan, selectors, output):
        command = [str(python if python.exists() else sys.executable), 'scripts/verify-tests.py', '--plan', plan,
                   '--device', udid, '--require-build', '--output', str(output)]
        for selector in selectors:
            command += ['--only-testing', selector]
        with (evidence / f'verify-{plan}.log').open('w') as log:
            if run_bounded(command, log, T3_TIMEOUT) is None:
                return {**_read_manifest(output), 'status': 'timed out',
                        'error': f'the runner\'s {duration(T3_TIMEOUT)} budget for the whole verify-tests.py run '
                                 '(build and tests) ran out; interrupted'}
        return _read_manifest(output) or {'status': 'missing', 'error': 'verify-tests.py wrote no manifest'}

    def replace(stalled):
        lane_sim.release(stalled)
        with (evidence / 'simulator-clone.log').open('a') as log:
            return lane_sim.clone_temporary(RUNNER_SIMULATOR_PREFIX + request_id, runtime, out=log)

    try:
        boot_started = time.monotonic()
        boot_info = {}
        with (evidence / 'first-boot.log').open('w') as log:
            try:
                problem, boot_info = boot_t3_device(udid, log, replace, evidence, boot_info)
            finally:
                udid = boot_info.get('udid', udid)  # after a stall, the fresh clone is the one to release
        boot_seconds = time.monotonic() - boot_started  # the boot alone, before any build or test
        if problem:
            details = [f'The cloned simulator did not boot: {problem} evidence: {evidence}/first-boot.log']
            if boot_info.get('period') == 'two-simulator' and 'not ready after' in problem \
                    and lane_sim.back_to_one_simulator(f'a two-simulator T3 boot ({request_id}) timed out: {problem}'):
                details.append('This boot ran while two simulators were up, so the lane is back to one simulator '
                               '(noted on #184).')
            return 'INCONCLUSIVE', where, 'nothing', details, 'watched during boot', ''
        lane_sim.start_watcher(udid, ROOT / 'scripts/lane-sim-boot',  # stops the device at a SpringBoard crash
                               crash_window=boot_info.get('boot_window'))
        summaries, statuses, ran, details = run_plans(grouped, run_plan, evidence,
                                                      lambda: lane_sim.is_available(udid))
        details.insert(0, f'boot of the cloned simulator took {duration(boot_seconds)} (memory pressure at boot: '
                          f'{boot_info.get("pressure", "unknown")}, after waiting {boot_info.get("pressure_waited", 0)}s; '
                          f'{boot_info.get("period", "one-simulator")} period)')
        if boot_info.get('boot_retry'):
            retry = boot_info['boot_retry']
            details.insert(1, f'boot stall on the first clone ({retry["stalled"]}), so it was deleted and one fresh clone '
                              f'({retry["fresh"]}) booted in {retry["seconds"]}s instead, before any app install or test (#1802); the stall is logged on #1802')
        if boot_info.get('tolerated'):
            details.insert(1, f'tolerated one SpringBoard change in the first 30 s of the first boot (owner\'s rule, '
                              f'#184): {boot_info["tolerated"]}')
        details.append(f'template preparation and simulator clone took {duration(clone_seconds)}; '
                       f'evidence: {evidence}/simulator-clone.log')
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
        """The PR's comments the runner may act on: only trusted authors' (trusted_comment, #1719)."""
        lines = self.api('--paginate', '--jq', '.[] | @json', f'repos/{self.repo}/issues/{self.pr}/comments')
        comments = [json.loads(line) for line in lines.splitlines() if line.strip()]
        kept = [comment for comment in comments if trusted_comment(comment)]
        if len(kept) < len(comments):
            ignored = sorted({(c.get('user') or {}).get('login') or 'unknown' for c in comments if not trusted_comment(c)})
            print(f'[lane] ignored {len(comments) - len(kept)} comment(s) from authors who are not the owner, a '
                  f'collaborator or the project\'s bot: {", ".join(ignored)}', flush=True)
        return kept

    def comment(self, body: str) -> str:
        return json.loads(self.api(f'repos/{self.repo}/issues/{self.pr}/comments', '-f', f'body={body}'))['html_url']

    def relabel(self, remove: str | None, add: str | None) -> None:
        if remove:
            subprocess.run(['gh', 'api', '-X', 'DELETE',
                            f'repos/{self.repo}/issues/{self.pr}/labels/{remove.replace(":", "%3A")}'],
                           capture_output=True)
        if add:
            self.api('-X', 'POST', f'repos/{self.repo}/issues/{self.pr}/labels', '-f', f'labels[]={add}')

    def hand_off_release(self, base: str, head: str, t3_report: str) -> str:
        """Start lane.yml's release job on a build runner for this PR's head (#1209), and return where to watch it.

        A workflow_dispatch, unlike a label change, does start a run when the workflow's own token sends it. The run
        uses <base>'s lane.yml and lane-runner.py, never the PR's. Raises when GitHub refuses: no actions: write on
        this job's token (a PR whose merge ref predates #1209), or a base whose lane.yml has no workflow_dispatch.
        """
        self.api('-X', 'POST', f'repos/{self.repo}/actions/workflows/{LANE_WORKFLOW}/dispatches', '-f', f'ref={base}',
                 '-f', f'inputs[pr]={self.pr}', '-f', f'inputs[head]={head}', '-f', f'inputs[t3]={t3_report}')
        server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
        return f'{server}/{self.repo}/actions/workflows/{LANE_WORKFLOW}?query=event%3Aworkflow_dispatch'

    def dispatch_hosted_checks(self, branch: str, base: str) -> str:
        """Run hosted-portable.yml again on the PR's <branch>, merged onto <base>'s tip (#2459), and return '' or why
        it could not. Its check runs land on the branch's head, where hosted_fast_records reads the newest. A
        branch whose hosted-portable.yml has no `base` input is refused by GitHub, so nothing runs untested there."""
        try:
            self.api('-X', 'POST', f'repos/{self.repo}/actions/workflows/{HOSTED_WORKFLOW}/dispatches',
                     '-f', f'ref={branch}', '-f', f'inputs[base]={base}')
        except (OSError, subprocess.SubprocessError) as error:
            return str(error).strip()[:200] or repr(error)
        return ''


# ---- Auto-revert of a lane change that broke the lane (owner rule 2026-10-01) ---------------------

OPS_ISSUE = 337
AUTO_REVERT = 'Lane auto-revert'  # how both the revert comment and the could-not-revert comment on #337 start
STOPPED = 'stopped before reporting'  # cleanup()'s note when a job died before its report
MERGE_SUBJECT = re.compile(r'^Merge pull request #(\d+)(?::\s*(.*)| from \S+)')
TESTED_ON = re.compile(r'\(tested merged with (\S+) at ([0-9a-f]{7,40})\)')
REVERTS = re.compile(r'^This reverts commit ([0-9a-f]{40})', re.M)  # git revert's own line
# INCONCLUSIVE reports that are the PR's or the request's own doing, not the lane's.
NOT_LANE_FAULTS = (('does not merge cleanly', 'a merge conflict'),
                   ('names no tests', 'a T3 request with no tests'), ('Nothing to run.', 'nothing to run'),
                   ('lane fault: no audio output', "the Mac's sound output, not a lane change (#909)"),
                   ('too: not this PR', 'a test broken on the base too, filed as its own issue (#1204)'))
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


def lane_reports_after(tree: Path, merge: dict, comments, base: str | None = None) -> list[dict]:
    """The runner's lane reports on PRs from after the lane merge, oldest first, at most two.

    `comments` is the repository's issue comments, oldest first. A report counts only if it says it
    tested <base> (not a lane-check/** branch, which tests some other lane change) at a commit that
    already had the merge in it, so a job that started before the merge landed doesn't count. A
    stopped-job note counts on the same terms, from the base cleanup() found recorded; one that names
    no tested commit (the job stopped before it fetched one, or a runner from before 2026-10-01's
    audit fix) doesn't count.
    """
    base = base or trunk()
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
                print(f'[lane] {dispatch_hosted_integration(base)}', flush=True)
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
    global TESTED_BASE
    TESTED_BASE = sha  # the step ledger's shared-failure rule compares failures on the same next
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


def cleanup(github: GitHub, run_url: str, mode: str = 'any', hosted: bool = False) -> int:
    """After a failed or cancelled job: remove leftovers, say so on the PR, and free the labels."""
    if not hosted:
        sweep_runner_simulators()
    tested = tested_note()
    if mode in ('auto', 'release'):  # lane:queued and lane:running belong to /lane requests
        github.comment(f'Lane: the automerge run stopped before reporting ({run_url}){tested}. Push again, or '
                       f'remove and re-add automerge, to run it again.\n{NOTE}')
        if mode == 'release':  # the lane job left lane:done to this run (#1209): wake the dispatcher
            github.relabel(DONE, DONE)
        return 0
    _, desk_waiting = pending_requests(github.comments())
    github.comment(f'Lane: the runner stopped before reporting ({run_url}){tested}. If it is still needed, '
                   f'comment the request again and add lane:queued.\n{NOTE}')
    github.relabel(RUNNING, None)
    if not desk_waiting:
        github.relabel(QUEUED, None)
    return 0


LOST_REASON = ('The lane job ended without running or reporting: its runner was lost, or the job was cancelled or '
               'killed before its first step (GitHub shows "The self-hosted runner lost communication with the server" '
               'for a runner that stopped answering)')


def report_lost(github: GitHub, pr: int, run_id: str, attempt: str | None, event_head: str, base: str,
                run_url: str) -> int:
    """Answer a /lane request whose lane job ended with no report and no tidy-up of its own (#2174).

    A job whose runner is lost runs no step, so neither its Verdict nor its tidy step can speak and the PR keeps
    lane:queued with the request unanswered. lane.yml's `lane-lost` job, on a runner that is not the lane's, runs
    this after the lane job failed or was cancelled. It posts an INCONCLUSIVE report for the pending T2/T3 request,
    naming the run, and frees the labels as cleanup() does. The report names no tested commit, so the auto-revert
    never counts it against a lane change. Does nothing when the lane job reported or tidied up, the PR moved on,
    or there is no unanswered request.
    """
    pull = github.pull()
    if pull.get('state', 'open') != 'open' or pull['head']['sha'] != event_head:
        print('The PR moved on or closed; nothing to report.')
        return 0
    comments = github.comments()
    name = request_name(pr, run_id, attempt)
    for comment in comments:
        body = comment.get('body') or ''
        if body.startswith(f'Lane report {name} ') or f'Lane: the runner stopped before reporting ({run_url})' in body:
            print(f'This run already reported ({comment.get("html_url")}); nothing to add.')
            return 0
    request, desk_waiting = pending_requests(comments)
    changed = False
    if request is not None and request['tier'] in RUNNER_TIERS:
        details = [f'{LOST_REASON}. Run {run_url} (attempt {attempt or "1"}) has no steps or log to read; the Mac '
                   "runner's _diag logs for that time say why. No test ran. To try again, comment the same "
                   f'`/lane {request["tier"]}` request with the same `tests:` line and add lane:queued.']
        github.comment(report(name, 'INCONCLUSIVE', event_head, 'unknown', request['tier'], 'no runner', 0,
                              'nothing', details, 'none', 'none', NOT_VERIFIED,
                              identity(request['tier'], event_head, '', request['tests']), '', base))
        changed = True
    else:
        print('No unanswered T2/T3 request; only the labels come off.')
    labels = {label['name'] for label in pull.get('labels', [])}
    if RUNNING in labels:
        github.relabel(RUNNING, None)
        changed = True
    if not desk_waiting and QUEUED in labels:
        github.relabel(QUEUED, None)
        changed = True
    if changed:  # nothing posted and no label left: the lane job had already answered; don't wake the dispatcher
        github.relabel(DONE, DONE)  # the Hourly dispatch wakes on lane:done's
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
    # Not the owner's main checkout in ~/Documents: macOS privacy (TCC) denies the runners' node access to
    # Documents, and every host-test run died reading .venv/pyvenv.cfg there (#2493).
    return Path(os.environ.get('SM_LANE_TOOLS') or Path.home() / 'Library/Caches/SpokenMarginsLane/tools')


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
    parser.add_argument('--base', help='branch the PR merges into (default: the trunk, scripts/trunk.py)')
    parser.add_argument('--cleanup', action='store_true', help='tidy up after a cancelled or failed job')
    parser.add_argument('--lost', action='store_true',
                        help='report a lane job that ended with no report (its runner was lost); runs on another runner')
    parser.add_argument('--hosted', action='store_true', help='auto only: T0 or ops Python tests, no Mac setup')
    parser.add_argument('--mode', choices=['explicit', 'auto', 'release', 'any'], default='any',
                        help='explicit: answer /lane requests only; auto: the automerge label only; release: the '
                             'automerge run a T3 PASS released, handed to the build runner (#1209)')
    parser.add_argument('--t3-report', default='', help='release: the T3 PASS report that released the run')
    args = parser.parse_args(argv)
    if args.hosted and args.mode != 'auto':
        parser.error('--hosted requires --mode auto')
    ROOT = args.tree.resolve()
    sys.path.insert(0, str(ROOT / 'scripts'))
    if not args.base:  # the workflows always pass the PR's base; a local run means the trunk
        args.base = trunk()
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
    if args.lost:
        return report_lost(github, args.pr, args.run_id, os.environ.get('GITHUB_RUN_ATTEMPT'), args.event_head,
                           args.base, run_url)
    if args.cleanup:
        return cleanup(github, run_url, args.mode, hosted=args.hosted)
    STEP_RUNS.clear()
    if args.base == trunk() and not args.hosted and not github_hosted():  # Mac jobs own the lane auto-revert check
        try:
            print(f'Lane auto-revert check: {auto_revert(ROOT, args.base, Repo(repo))}')
        except Exception as error:  # noqa: BLE001 - the check must never stop the job it runs in
            print(f'Lane auto-revert check skipped: {error!r}')
    if not args.hosted:
        sweep_runner_simulators()
    if args.mode == 'release':
        if not re.fullmatch(r'[0-9a-f]{40}', args.event_head):
            print(f'--event-head must be a full commit SHA, not {args.event_head!r}; nothing to release.')
            return 0
        request_id = request_name(args.pr, args.run_id, os.environ.get('GITHUB_RUN_ATTEMPT')) + '-auto'
        return run_release(github, args.pr, args.base, args.event_head, request_id,
                           Path(os.environ.get('SM_LANE_EVIDENCE_DIR') or
                                Path.home() / 'Library/Caches/SpokenMarginsLane/evidence') / request_id,
                           args.t3_report)
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

    def after_t3_pass(why: str, t3_report: str = '') -> str | None:
        """Release a held automerge run (#421), and return its report if it posted one. Never changes this
        job's result, which is already reported. The lane job off the build runner hands the run's checks to a
        build runner when they have to run (#1209), and returns the hand-off note."""
        if args.hosted and not hosted_rest_on():
            return None  # the Mac lane job owns T3 release; never run its host suite on Linux
        hand_off = None
        if explicit and os.environ.get('SM_LANE_RUNNER_ROLE') != 'build':  # a /lane job, not an automerge run
            def hand_off():
                return github.hand_off_release(args.base, head, t3_report)
        try:
            if not args.hosted:
                link_tools(tools_source())  # the identical-request path returns before the job links them
            return merge_after_t3(github, args.pr, args.base, head, f'{request_id}-auto',
                                  evidence.parent / f'{request_id}-auto', base_sha, why, hand_off=hand_off,
                                  **({'hosted': True} if args.hosted else {}))
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
            after_t3_pass(f'started by the T3 PASS ({url}) in the same lane job', url)
        flush_ledger(args.pr, head, lambda body: Repo(repo).comment(OPS_ISSUE, body))
        return 0
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'request.json').write_text(json.dumps(dict(request, head=head, base=args.base, base_sha=base_sha),
                                                      indent=2))
    if explicit and not desk_waiting:  # a waiting T4/T5 keeps lane:queued so the Test Desk still sees it
        if DONE in labels:  # a running PR doesn't also say done
            github.relabel(DONE, None)
        github.relabel(QUEUED, RUNNING)
    if not args.hosted:
        link_tools(tools_source())
    # A pending T3 for this head: the lane job that reports its PASS merges. The build runner runs the checks
    # meanwhile, so that job needn't (#834); any other runner leaves them to it, as a simulator runner's time
    # is the T3s'.
    t3_first = t3_request_for_head(comments, labels, head) if request['tier'] == 'auto' else None
    on_build_runner = os.environ.get('SM_LANE_RUNNER_ROLE') == 'build'
    no_room, beside = None, None
    audit_checked = audit_held_checks(comments, head) if request['tier'] == 'auto' else None
    # A run that only reuses the audit-held PASS runs no tests, so it needs no room (#1461): waiting for one could
    # end in an INCONCLUSIVE report that is the newest and takes the PASS away.
    if request['tier'] == 'auto' and on_build_runner and not args.hosted \
            and not checks_stand(audit_checked, base_sha, head):
        # host tests only (NO_APP_BUILD_PER_PR): the host rules
        no_room, beside = wait_for_room_to_test_on_host()
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
                       'and this is not the build runner, so this run skipped its own host tests. The lane '
                       'job that reports a T3 PASS on this head runs them on the merge commit itself and merges on '
                       'PASS; nobody needs to push or re-label.']
        elif no_room:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no build', 'nothing', 'none'
            details = [f'{no_room}. Push again, or remove and re-add automerge, to try again.']
        elif request['tier'] == 'auto':
            verdict, where, ran, details = run_auto(github, pull, args.pr, args.base, head, base_sha, evidence,
                                                    comments, labels, context=context,
                                                    checked=audit_checked, **({'hosted': True} if args.hosted else {}))
            if verdict == NEEDS_MAC:  # no report here: lane.yml's automerge-mac job runs it on the build Mac (#2459)
                print(f'Handing this automerge run to the build Mac: {"; ".join(details)}', flush=True)
                if os.environ.get('GITHUB_OUTPUT'):
                    with open(os.environ['GITHUB_OUTPUT'], 'a') as handle:
                        handle.write('needs_mac=true\n')
                return 0
            details = ([beside] if beside else []) + details
            crashes = 'none'
        elif conflicts:
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no simulator', 'nothing', 'none'
            details = [f'The PR does not merge cleanly into {args.base} ({base_sha[:7]}): {", ".join(conflicts[:10])}. '
                       f'Merge {args.base} into your branch, push, and ask again.']
        elif pointers := ensure_lfs_files(ROOT):
            verdict, where, ran, crashes = 'INCONCLUSIVE', 'no simulator', 'nothing', 'none'
            details = [pointers]
        elif request['tier'] == 'T2':
            print(prune_lane_folder(evidence.parent), flush=True)
            warm = warm_build_folders(ROOT)
            verdict, ran, details = run_t2(evidence)
            where, crashes, details = 'no simulator (compile only)', 'none', [warm] + details
        else:
            print(prune_lane_folder(evidence.parent), flush=True)
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
                       f'({t3_first}) reports. The lane job that reports a T3 PASS on this head runs the host tests on the '
                       'merge commit itself and merges on PASS.')
    if request['tier'] == 'auto':
        base_sha = context.tested_base
        wanted = identity('auto', head, base_sha, request['tests'])
    body = report(request_id, verdict, head, base_sha, request['tier'], where, time.monotonic() - started,
                  ran, moved + details, crashes, str(evidence),
                  NOT_VERIFIED, wanted, cc, args.base, hosted=args.hosted)
    (evidence / 'report.md').write_text(body)
    print(body)
    t3_url = github.comment(body)  # if this fails, the job fails and the tidy step says so on the PR
    if request['tier'] == 'T3':
        log_recovered_stalls(evidence, args.pr, head, t3_url, lambda text: Repo(repo).comment(STALL_ISSUE, text),
                             verdict)
    record_outcome(verdict)
    _, desk_waiting = pending_requests(github.comments())
    if explicit:
        github.relabel(RUNNING, QUEUED if desk_waiting else None)
    released = None
    if explicit and request['tier'] == 'T3' and verdict == 'PASS':
        released = after_t3_pass(f'started by the T3 PASS ({t3_url}) in the same lane job', t3_url)
    elif request['tier'] == 'auto' and verdict != 'PASS':  # a T3 PASS may have landed before this held report
        released = after_t3_pass('started again in the same automerge job, because a T3 PASS landed while it '
                                 'was held')
    last = details + (released or '').splitlines()  # the job's last report: a released automerge run's, if any
    if not any(line.startswith(f'merged into {args.base} as ') for line in last) \
            and not (released or '').startswith(HANDED_OFF) \
            and not (explicit and desk_waiting):  # a merged PR closes: nothing to pick up; a hand-off's run relabels
        # Remove, then add: adding a label the PR already has is no `labeled` event, and the Hourly dispatch
        # wakes on lane:done's. The lane and automerge jobs run side by side, so the other may have added it.
        github.relabel(DONE, DONE)
    flush_ledger(args.pr, head, lambda body: Repo(repo).comment(OPS_ISSUE, body))
    if not args.hosted:
        drop_workspace_builds(ROOT)
    return 0


if __name__ == '__main__':
    sys.exit(main())
