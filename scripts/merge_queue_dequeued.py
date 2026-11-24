#!/usr/bin/env python3
"""Tell a PR's author why it left GitHub's merge queue, and cancel the runs of merge groups that no longer exist.

Step 5 of the merge queue move (#4693). merge-queue-dequeued.yml runs this from main's copy on every
`pull_request_target: dequeued` event, so it also fires when a merge conflict removed the PR (a `pull_request`
workflow never runs on a conflicted PR). It runs no PR code and reads the PR only through the event file.

Two jobs, independent of each other:

1. Notify. One comment on the PR saying why it left the queue (the event's `reason`), naming the failed check of
   its latest merge-group run with a link when there is one, and how to get back in: fix, push, add `automerge`.
   A removal for a failure also gets the `needs-fix` label and loses `automerge`, so the label bridge
   (merge_queue_label_bridge.py) does not queue it again until someone adds `automerge` again, as with the old
   lane. A removal by hand means "stop": the PR loses `automerge` too, but gets no `needs-fix` since nothing
   failed. A group in which no check failed failed nothing in the PR: its only bad check was cancelled (a job's `timeout-minutes` ends as `cancelled`, not
   `timed_out`), or a check never reported before the queue's timeout (no Mac free for two hours). The first time,
   the PR keeps `automerge`, gets no `needs-fix`, and is set to merge again here with the queue token, so it goes
   back in without waiting for the bridge's sweep, which runs only when the VPS backstop or a schedule GitHub often
   drops starts it (#4937). A second such removal of the same PR is treated as a failure, so a job that hangs every
   time costs one retry, not a loop. A group whose every failed job failed in a setup step, or in a plan step on a
   network error from a host outside GitHub (a package, model or Homebrew download that a flaky runner or a host outage
   broke), failed nothing in the PR either (#4940): the same one retry, but after SETUP_RETRY_DELAY, so a short outage
   can end first. The retry is the label bridge's sweep, which queues the PR once the `not-before` time in this
   comment's marker has passed (the bridge reads that marker, so the two scripts agree on its format; a test checks
   it). A failed test step is the PR's, and gets `needs-fix` at once. `automerge` is removed only when the event shows the PR carries it (the owner's own Merge tap on an
   unlabelled PR has nothing to remove, and its comment says nothing about a label). A PR that merged keeps its labels. Each comment carries a hidden marker with the group head (or the PR
   head when no group ran), so a second event for the same group adds nothing. A test that failed in a group of only
   the trunk and this PR is this PR's: the comment carries an `own-failure` marker for the PR's head commit, and the
   label bridge holds a commit with two of them out of the queue until a new push (#5281). After a failure removal it
   also turns auto-merge off and takes the PR out of the queue again if the bridge's sweep re-queued it first. A failed read logs a warning and exits 0: a notifier must not go red.

2. Cancel. When an entry leaves the queue GitHub rebuilds the groups behind it and sends `merge_group: destroyed`
   for the old ones, but Actions only triggers on `checks_requested`, so the old groups' runs keep their Macs until
   they finish. This cancels every queued or running workflow run on a `gh-readonly-queue/main/` branch whose head
   SHA is no longer any queue entry's head commit. The runs are listed first and the entries read second: a group's
   entry exists before its run does, so a run listed first never belongs to an entry created after the read. If
   the entry list can't be read, nothing is cancelled.

Run: `python3 scripts/merge_queue_dequeued.py --event "$GITHUB_EVENT_PATH"` with GH_REPO set.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

QUEUE_PREFIX = 'gh-readonly-queue/main/'
LABEL = 'needs-fix'
ARM_LABEL = 'automerge'
MARKER = '<!-- merge-queue-dequeued head={head} -->'
# On a comment that let a cancelled group's PR stay armed; a second cancelled removal with one already there is
# treated as a failure.
RETRY_MARKER = '<!-- merge-queue-dequeued retry-after-cancel -->'
ACTIVE = ('queued', 'in_progress', 'waiting', 'pending', 'requested')
FAILED = ('failure', 'timed_out', 'action_required', 'startup_failure')
# Event reasons that mean the PR itself needs work; anything else (merged, removed by hand) gets no label.
MANUAL_REASONS = ('MANUAL', 'DEQUEUED_MANUALLY')
NO_LABEL_REASONS = ('MERGE', 'MERGED', 'ALREADY_MERGED', *MANUAL_REASONS)
# The group's merge commit could not be built: the PR conflicts with main or with a PR ahead of it in the queue (#4942
# was dequeued with INVALID_MERGE_COMMIT on 2026-11-22 after #4941 and #4930 merged ahead of it). Merging main in fixes
# it, so it is a conflict, never a check that failed.
CONFLICT_REASONS = ('CONFLICT', 'INVALID_MERGE_COMMIT')
TRIES = 3

# A group that failed only in setup (#4940). The delay is a Default taken: long enough for a short outage or a runner
# flake to clear, short enough that a PR is not parked for hours. The bridge's sweep runs about every 15 minutes, so the
# PR is queued again within 15 minutes after it.
SETUP_RETRY_DELAY = datetime.timedelta(minutes=30)
# merge_queue_label_bridge.py reads this marker; it keeps its own copy of the pattern because the two workflows each
# check out only their own script. test_merge_queue_dequeued checks the two agree.
SETUP_RETRY_MARKER = '<!-- merge-queue-dequeued setup-retry not-before={when} -->'
TIME_FORMAT = '%Y-%m-%dT%H:%M:%SZ'
# #5281: a test failed in a group that held nothing but the trunk and this PR, so nothing else can have caused it. The
# marker names the PR's head commit; merge_queue_label_bridge.py (OWN_FAILURE, its own copy of the pattern) refuses to
# queue a commit that carries OWN_FAILURE_LIMIT of them, even on a re-arm, until a new push. On 2026-11-24 #5207 failed
# its groups three times on one commit (03:53, 10:38, 19:27 UTC), each time re-armed with no push, and every group
# built behind it failed with it: from 18:32 to 19:27 five groups failed its two catalog tests.
OWN_FAILURE_MARKER = '<!-- merge-queue-dequeued own-failure head={head} -->'
OWN_FAILURE_LIMIT = 2
DEQUEUE = 'mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }'

# Steps whose failure is the runner's, never the PR's code. The names are the real steps of the workflows that run in
# a merge group (hosted-portable.yml, hosted-web.yml); test_merge_queue_dequeued reads those files to keep the list
# true. A `uses:` step is named `Run <action>@<ref>` by Actions. A step that runs the PR's own code or manifests
# (npm ci, pip, go build, the LFS pointers it commits, the version a setup action reads from its files) is a plan step
# below, since its failure can be the PR's (review of #4940).
SETUP_STEPS = frozenset({
    'Set up job', 'Initialize containers', 'Complete job', 'Start the clock',
    'Unpack the compilation cache', 'Install BlackHole (virtual audio output)', 'Speech model cache',
})
SETUP_STEP_PREFIXES = ('Run actions/', 'Post Run actions/')
# `actions/setup-*` reads a version from the PR's files, so it is a plan step.
PLAN_STEP_PREFIXES = ('Run actions/setup-',)
# Steps that can fail for the PR's reasons or the network's. They count as outside the PR only when the failing step's
# log ends in a network error from a host outside GitHub (EXTERNAL_HOSTS): `tools` inside the Mac plan failed on
# 2026-11-21 because download.onnxruntime.ai served a bad certificate (#4795), and that shows only in the step's log.
PLAN_STEPS = frozenset({
    'Portable fast plan', 'SessionKitCoreTests on Linux', 'SessionKit build and SessionKitCoreTests',
    'Build the app for the simulator (build-for-testing, no tests)', 'Mac rest of the fast plan',
    'Caddy and smserver for the Caddyfile tests', 'Python tools and Node packages', 'Python tools',
    'List LFS objects', 'Fetch LFS files', 'Install packages', 'Install Playwright browsers',
})
# Hosts the jobs fetch from at run time (scripts/ci_harness.py EXTERNAL_DOWNLOADS lists the jobs).
EXTERNAL_HOSTS = ('download.onnxruntime.ai', 'pypi.org', 'files.pythonhosted.org', 'registry.npmjs.org', 'github.com',
                  'githubusercontent.com', 'huggingface.co', 'hf.co', 'cdn.playwright.dev', 'playwright.azureedge.net',
                  'registry-1.docker.io', 'docker.io', 'ghcr.io', 'formulae.brew.sh', 'brew.sh')
NETWORK_ERROR = re.compile(
    r'certificate|\bSSL\b|\bTLS\b|Could not resolve host|Temporary failure in name resolution|Name or service not known|'
    r'nodename nor servname|Connection (?:timed out|reset|refused)|Operation timed out|Network is unreachable|'
    r'curl: \(\d+\)|ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|'
    r'\b5\d\d (?:Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out)|HTTP(?: error)? 5\d\d', re.I)
# A failed test in the step's log tail makes the failure the PR's, whatever network words other lines carry: a test
# whose assertion message quotes a certificate error next to a github.com URL is still a failed test (#5070 audit).
# Only the forms a test runner prints for one failed test count, never a wrapper's word for a failed step: verify-tests
# ends every failed step with `<step>: 41s — FAILED`, a network failure included (second audit of #5070).
# verify-tests keeps each runner's raw output in the step's log file, so the job log shows only its own lines, and it
# prints the prefix `Failed: ` for a failed test and nothing else (verify-tests.py: `Failed: <unittest header> at
# <file:line>` from report_unittest_failures, `Failed: Module/Class/testX` from reconcile, `Failed: and N more`), at
# a line's start or inside its `Process exit 1; ...` error (third audit of #5070). The other forms are the runners'
# own, for a plan step that runs one directly: unittest's `FAIL:`/`ERROR: test (module.Class)`, pytest's
# `FAILED path::test`, Go's `--- FAIL: Test`, XCTest's `Test Case '-[...]' failed` and `error: -[...] : XCTAssert`,
# Swift Testing's `✘ Test ... failed` and a raised `AssertionError`. They are read after the Actions timestamp that
# starts every job-log line. test_merge_queue_dequeued builds verify-tests' lines with its own functions.
TEST_FAILURE = re.compile(
    r'(?:^|; )Failed: |^(?:FAIL|ERROR): \w+ \([\w.]+\)|^FAILED \S+::|'
    r"^\s*--- FAIL: \w|Test Case '-\[.+\]' failed|error: -\[.+\] : XCTAssert|✘ Test .+ (?:failed|recorded an issue)|"
    r'^\s*AssertionError\b')
LOG_TIMESTAMP = re.compile(r'^\ufeff?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?')
LOG_TAIL_LINES = 80
JOB_IN_URL = re.compile(r'/job/(\d+)(?:/|$)')

ENTRIES_QUERY = '''query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: "main") { entries(first: 100) { nodes { headCommit { oid } } } }
  }
}'''


class ReadFailed(Exception):
    pass


class GitHub:
    """`gh api` with a few tries for reads. The tests replace this class at the same boundary."""

    def __init__(self, repo, sleep=time.sleep):
        self.repo = repo
        self.sleep = sleep

    def _gh(self, args, data=None):
        return subprocess.run(['gh', 'api', *args], input=data, text=True, timeout=60, capture_output=True, check=True)

    def get(self, path):
        error = None
        for attempt in range(TRIES):
            try:
                return json.loads(self._gh([f'repos/{self.repo}/{path}']).stdout)
            except (subprocess.SubprocessError, OSError, ValueError) as caught:
                error = caught
                if attempt + 1 < TRIES:
                    self.sleep(2 * (attempt + 1))
        raise ReadFailed(f'GET {path}: {error!r}')

    def queue_heads(self):
        owner, name = self.repo.split('/', 1)
        error = None
        for attempt in range(TRIES):
            try:
                out = self._gh(['graphql', '-f', f'query={ENTRIES_QUERY}', '-F', f'owner={owner}', '-F', f'name={name}'])
                queue = json.loads(out.stdout)['data']['repository']['mergeQueue']
                nodes = (queue or {}).get('entries', {}).get('nodes') or []
                return {node['headCommit']['oid'] for node in nodes if node.get('headCommit')}
            except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError) as caught:
                error = caught
                if attempt + 1 < TRIES:
                    self.sleep(2 * (attempt + 1))
        raise ReadFailed(f'merge queue entries: {error!r}')

    def now(self):
        return datetime.datetime.now(datetime.timezone.utc)

    def log_tail(self, job_id):
        """The last lines of a job's log before its first error line, or raises ReadFailed. A failed job's log is usually under a megabyte."""
        error = None
        for attempt in range(TRIES):
            try:
                lines = self._gh([f'repos/{self.repo}/actions/jobs/{job_id}/logs']).stdout.splitlines()
                # The failing step ends at the first `##[error]` line (`Process completed with exit code 1.`); the steps
                # after it (`if: always()` uploads, post steps) are not its output. Seen in a real log, 2026-11-23.
                end = next((i for i, line in enumerate(lines) if '##[error]' in line), len(lines))
                return '\n'.join(lines[max(0, end - LOG_TAIL_LINES):end])
            except (subprocess.SubprocessError, OSError) as caught:
                error = caught
                if attempt + 1 < TRIES:
                    self.sleep(2 * (attempt + 1))
        raise ReadFailed(f'job {job_id} log: {error!r}')

    def post(self, path, body):
        self._gh(['-X', 'POST', f'repos/{self.repo}/{path}', '--input', '-'], data=json.dumps(body))

    def requeue(self, number):
        """Set the PR to merge again (`gh pr merge`), with MERGE_QUEUE_TOKEN when the workflow passes it as
        QUEUE_TOKEN: an enqueue by GITHUB_TOKEN may get merge groups whose checks never start (see
        merge-queue-label-bridge.yml). True when it is set to merge."""
        env = dict(os.environ)
        if env.get('QUEUE_TOKEN'):
            env['GH_TOKEN'] = env['QUEUE_TOKEN']
        try:
            done = subprocess.run(['gh', 'pr', 'merge', str(number), '--repo', self.repo], env=env, text=True,
                                  timeout=90, capture_output=True)
        except (OSError, subprocess.SubprocessError):
            return False
        return done.returncode == 0 or 'already' in f'{done.stdout}{done.stderr}'.lower()

    def stop_merging(self, number, node_id, in_queue):
        """Auto-merge off, and out of the queue when it is in it, with the queue token (#5281). The label bridge's sweep
        can set a PR to merge again in the seconds between GitHub's removal and this script's `needs-fix` (#5207 at
        10:38:14 on 2026-11-24), and this script's label removal, made with GITHUB_TOKEN, wakes no bridge run to undo it.
        True when nothing is left set to merge."""
        env = dict(os.environ)
        if env.get('QUEUE_TOKEN'):
            env['GH_TOKEN'] = env['QUEUE_TOKEN']
        ok = True
        try:
            if in_queue and node_id:
                done = subprocess.run(['gh', 'api', 'graphql', '-f', f'query={DEQUEUE}', '-f', f'id={node_id}'], env=env,
                                      text=True, timeout=90, capture_output=True)
                ok = done.returncode == 0
            done = subprocess.run(['gh', 'pr', 'merge', str(number), '--repo', self.repo, '--disable-auto'], env=env,
                                  text=True, timeout=90, capture_output=True)
            text = f'{done.stdout}{done.stderr}'.lower()
            ok = ok and (done.returncode == 0 or 'not' in text or 'already' in text)
        except (OSError, subprocess.SubprocessError):
            return False
        return ok

    def delete(self, path):
        """DELETE; a 404 (already gone) is fine."""
        try:
            self._gh(['-X', 'DELETE', f'repos/{self.repo}/{path}'])
        except subprocess.CalledProcessError as error:
            if '404' not in f'{error.stdout or ""}{error.stderr or ""}':
                raise


def warn(message, out):
    print(f'::warning::{message}', file=out)


# --- notify -------------------------------------------------------------------------------------------------------

def latest_group_run(github, number):
    """The newest merge_group workflow run on one of this PR's queue branches (pr-<n>-<base>), or None."""
    prefix = f'{QUEUE_PREFIX}pr-{number}-'
    runs = github.get('actions/runs?event=merge_group&per_page=100').get('workflow_runs', [])
    mine = [run for run in runs if str(run.get('head_branch', '')).startswith(prefix)]
    return max(mine, key=lambda run: run.get('created_at', ''), default=None)


def failed_check(github, sha):
    """The most recently finished failed check run on the group head, or None."""
    runs = github.get(f'commits/{sha}/check-runs?per_page=100').get('check_runs', [])
    failed = [run for run in runs if run.get('conclusion') in FAILED]
    return max(failed, key=lambda run: run.get('completed_at') or '', default=None)


def cancelled_check(github, sha):
    """The most recently finished cancelled check run on the group head, or None."""
    runs = github.get(f'commits/{sha}/check-runs?per_page=100').get('check_runs', [])
    cancelled = [run for run in runs if run.get('conclusion') == 'cancelled']
    return max(cancelled, key=lambda run: run.get('completed_at') or '', default=None)


def failed_checks(github, sha):
    """Every failed check run on the group head (the latest per name, as the API lists them)."""
    runs = github.get(f'commits/{sha}/check-runs?per_page=100').get('check_runs', [])
    return [run for run in runs if run.get('conclusion') in FAILED]


def step_kind(name):
    """'setup' (never the PR's), 'plan' (the PR's unless its log shows an outside network error) or 'test'."""
    name = name or ''
    if name in PLAN_STEPS or name.startswith(PLAN_STEP_PREFIXES):
        return 'plan'
    return 'setup' if name in SETUP_STEPS or name.startswith(SETUP_STEP_PREFIXES) else 'test'


def outside_network_error(log):
    """Whether one line of a log names a host outside GitHub's runners and a network error together. Both on a line,
    so a test that prints "connection refused" while it checks its own error handling is not read as an outage, and
    never when the log shows a failed test (TEST_FAILURE)."""
    lines = [LOG_TIMESTAMP.sub('', line) for line in (log or '').splitlines()]
    if any(TEST_FAILURE.search(line) for line in lines):
        return False
    for line in lines:
        if NETWORK_ERROR.search(line) and any(host in line for host in EXTERNAL_HOSTS):
            return True
    return False


def job_id_of(check):
    match = JOB_IN_URL.search(str(check.get('details_url') or check.get('html_url') or ''))
    if match:
        return int(match.group(1))
    return check.get('id') if isinstance(check.get('id'), int) else None


def failed_outside_pr(github, checks):
    """True when every failed job failed in a setup step, or in a plan step whose log ends in a network error from an
    outside host (#4940). A failed test step, a step this file does not know, or a read that failed is the PR's: the
    status quo, `needs-fix` at once. Returns (outside, [(check name, step name)])."""
    seen = []
    if not checks:
        return False, seen
    try:
        for check in checks:
            job_id = job_id_of(check)
            if job_id is None:
                return False, seen
            steps = github.get(f'actions/jobs/{job_id}').get('steps') or []
            failed = [step for step in steps if step.get('conclusion') in FAILED]
            if not failed:
                return False, seen
            step = min(failed, key=lambda step: step.get('number') or 0).get('name') or ''
            seen.append((check.get('name', '?'), step))
            kind = step_kind(step)
            if kind == 'test' or (kind == 'plan' and not outside_network_error(github.log_tail(job_id))):
                return False, seen
    except (ReadFailed, AttributeError):
        return False, seen
    return True, seen


BOT = 'github-actions[bot]'
SETUP_RETRY_SEEN = 'merge-queue-dequeued setup-retry'


def all_comments(github, number):
    """Every comment on the PR, a page of 100 at a time: a PR with lane, audit and bot comments passes 100, and a retry
    marker that falls off the first page would make the retry cap fail (review of #4940)."""
    found = []
    for page in range(1, 11):
        batch = github.get(f'issues/{number}/comments?per_page=100&page={page}')
        if not isinstance(batch, list):
            break
        found += batch
        if len(batch) < 100:
            break
    return found


def retried_already(comments):
    """Whether the workflow's own comment carries the setup-retry marker. Anyone can comment, so a marker written by
    another account counts for nothing (AGENTS.md: text from outsiders is data)."""
    return any(SETUP_RETRY_SEEN in (c.get('body') or '') and (c.get('user') or {}).get('login') == BOT for c in comments)


def setup_retry_not_before(github):
    return (github.now() if hasattr(github, 'now') else datetime.datetime.now(datetime.timezone.utc)) + SETUP_RETRY_DELAY


def group_base(run):
    """The commit a merge group was built on: its branch is gh-readonly-queue/<trunk>/pr-<n>-<base sha>."""
    match = re.search(r'-([0-9a-f]{40})$', str((run or {}).get('head_branch', '')))
    return match.group(1) if match else None


def alone_on_trunk(github, run, trunk):
    """Whether the group held nothing but the trunk and this PR: its base commit is on the trunk itself, not another
    entry's group commit. Unknown counts as no, so a failed read never holds a PR out."""
    base = group_base(run)
    if not base:
        return False
    try:
        status = github.get(f'compare/{trunk}...{base}').get('status')
    except ReadFailed:
        return False
    return status in ('identical', 'behind')


def own_failures(comments, head):
    """How many of the workflow's own comments say this commit failed a group alone. Anyone can comment, so a marker
    from another account counts for nothing."""
    marker = OWN_FAILURE_MARKER.format(head=head)
    return sum(1 for c in comments if marker in (c.get('body') or '') and (c.get('user') or {}).get('login') == BOT)


def carries_arm_label(pr):
    return any((label or {}).get('name') == ARM_LABEL for label in pr.get('labels') or [])


def nothing_failed(reason, check):
    """A removal in which no check failed and that is not a conflict, a merge or a removal by hand: a cancelled
    check, or one that never reported before the queue's timeout. Nothing in the PR needs fixing."""
    upper = (reason or '').upper()
    return not check and upper not in NO_LABEL_REASONS and not is_conflict(reason)


def is_conflict(reason):
    upper = (reason or '').upper()
    return any(word in upper for word in CONFLICT_REASONS)


def setup_sentence(setup):
    """What failed, in a sentence, for a group that failed only in setup."""
    where = '; '.join(f'"{name}" in its step "{step}"' for name, step in setup['steps'])
    return f'Every failed job failed outside your code: {where}.'


def comment_body(number, reason, head, check, armed=True, cancelled=None, retry=False, requeued=None, setup=None,
                 own=None):
    lines = [MARKER.format(head=head),
             f'**Left the merge queue** ({reason or "no reason given"}).']
    if own:
        lines[0] += '\n' + OWN_FAILURE_MARKER.format(head=own['head'])
    if setup and setup.get('when'):
        lines[0] += '\n' + SETUP_RETRY_MARKER.format(when=setup['when'])
        lines.append(f'{setup_sentence(setup)} That is a setup step or a download (a runner problem or a host that was '
                     f'down), so nothing needs fixing in the PR. Failed check: {check.get("html_url", "") if check else ""}')
        if armed:
            lines.append(f'It keeps `{ARM_LABEL}`. The label bridge\'s sweep sets it to merge again after '
                         f'{setup["when"]} (about {int(SETUP_RETRY_DELAY.total_seconds() // 60)} minutes), once. If it fails '
                         f'in a setup step again it is held as a failure.')
        else:
            lines.append(f'It has no `{ARM_LABEL}` label, so nothing queues it again: tap Merge again, or add '
                         f'`{ARM_LABEL}`.')
        return '\n\n'.join(lines)
    if nothing_failed(reason, check) and (cancelled or retry or 'TIME' in (reason or '').upper()):
        if cancelled:
            where = f'"{cancelled.get("name", "?")}" on the merge group `{head[:7]}` was cancelled, not failed: ' \
                    f'{cancelled.get("html_url", "")}'
        else:
            where = f'No check failed on the merge group `{head[:7]}`; one did not report before the queue\'s time ' \
                    f'limit (usually no runner was free)'
        if retry:
            lines[0] += '\n' + RETRY_MARKER
            lines.append(f'{where}. That usually means it ran out of time, so nothing needs fixing in the PR.')
            if not armed:
                # #4942 audit: a PR set to merge by hand, without the label, is queued again by nothing here.
                lines.append(f'It has no `{ARM_LABEL}` label, so nothing queues it again: tap Merge again, or add '
                             f'`{ARM_LABEL}`.')
            elif requeued:
                lines.append(f'It keeps `{ARM_LABEL}` and is set to merge again now, once.')
            else:
                lines.append(f'It keeps `{ARM_LABEL}`; setting it to merge again failed here, so the label bridge\'s '
                             f'sweep will queue it, once.')
            return '\n\n'.join(lines)
        again = 'It was cancelled on its last try too' if cancelled else 'That happened on its last try too'
        lines.append(f'{where}. {again}, so it is held as a failure this time.')
        lines.append(f'To get back in: find why that job does not finish, push, then add `{ARM_LABEL}` again.')
        return '\n\n'.join(lines)
    if reason.upper() in MANUAL_REASONS:
        if armed:
            lines.append(f'It was taken out by hand, so `{ARM_LABEL}` came off and it will not be queued again.')
            lines.append(f'To queue it again, add `{ARM_LABEL}` again.')
        else:
            lines.append('It was taken out by hand.')
        return '\n\n'.join(lines)
    if check:
        lines.append(f'Failed check: "{check.get("name", "?")}" on the merge group `{head[:7]}`: {check.get("html_url", "")}')
        if own:
            if own['count'] >= OWN_FAILURE_LIMIT:
                lines.append(f'That group held nothing but main and this PR, and commit `{own["head"][:7]}` has now failed '
                             f'that way {own["count"]} times, so the queue will not take this commit again, even if '
                             f'`{ARM_LABEL}` is added again. Push a fix.')
            else:
                lines.append(f'That group held nothing but main and this PR, so the failure is this PR\'s, not one ahead '
                             f'of it. If it was a flaky test, adding `{ARM_LABEL}` again retries this commit once; a second '
                             f'failure like this holds commit `{own["head"][:7]}` out of the queue until a new push.')
        if setup:
            lines.append(f'{setup_sentence(setup)} It was set to merge again once for that and failed the same way, so '
                         f'it is held as a failure this time.')
    elif is_conflict(reason):
        lines.append('The merge queue could not merge it onto main as it stands: it conflicts with main or with a PR '
                     'ahead of it in the queue. Merge main into the branch and resolve it.')
    else:
        lines.append(f'No failed check found on the merge group `{head[:7]}`.')
    again = f'add `{ARM_LABEL}` again' if armed else f'tap Merge again (or add `{ARM_LABEL}`)'
    lines.append(f'To get back in: fix it, push, then {again}.')
    return '\n\n'.join(lines)


def notify(github, event, out=sys.stdout):
    """Post the one comment and label. Returns what it did, for the tests and the log; never raises on a read."""
    pr = event.get('pull_request') or {}
    number = pr.get('number')
    reason = event.get('reason') or ''
    if not number:
        warn('no pull request in the event', out)
        return 'skipped: no PR'
    if pr.get('merged') or reason.upper() in ('MERGE', 'MERGED', 'ALREADY_MERGED'):
        print(f'#{number} merged; nothing to say.', file=out)
        return 'skipped: merged'
    try:
        run = latest_group_run(github, number)
        head = (run or {}).get('head_sha') or (pr.get('head') or {}).get('sha') or 'unknown'
        check = failed_check(github, run['head_sha']) if run and run.get('head_sha') else None
        cancelled = None
        if nothing_failed(reason, check) and run and run.get('head_sha'):
            cancelled = cancelled_check(github, run['head_sha'])
        outside, steps = False, []
        if check and reason.upper() not in NO_LABEL_REASONS and not is_conflict(reason):
            try:
                outside, steps = failed_outside_pr(github, failed_checks(github, run['head_sha']))
            except ReadFailed:
                outside = False   # not knowing is the status quo: the PR is told it failed
        comments = all_comments(github, number)
        own = None
        if check and not outside and reason.upper() not in NO_LABEL_REASONS and not is_conflict(reason) \
                and alone_on_trunk(github, run, (pr.get('base') or {}).get('ref') or 'main'):
            pr_head = (pr.get('head') or {}).get('sha')
            if pr_head:
                own = {'head': pr_head, 'count': own_failures(comments, pr_head) + 1}
    except ReadFailed as error:
        warn(f'#{number}: could not read GitHub, no comment posted ({error})', out)
        return 'skipped: read failed'
    marker = MARKER.format(head=head)
    if any(marker in (comment.get('body') or '') for comment in comments):
        print(f'#{number}: already told about group {head[:7]}.', file=out)
        return 'skipped: already told'
    # A group nothing failed in (a cancelled check, or a queue timeout with no check reported) gets one retry.
    # MANUAL removals are not retried: they mean "stop".
    retry = nothing_failed(reason, check) and reason.upper() not in MANUAL_REASONS \
        and (bool(cancelled) or 'TIME' in reason.upper()) \
        and not any(RETRY_MARKER in (comment.get('body') or '') for comment in comments)
    armed = carries_arm_label(pr)
    # A PR with no `automerge` (an owner-tap PR, or a Merge tapped by hand) is never retried here: the bridge would queue
    # an owner-tap PR without his tap, and a hand tap would spend its one retry on nothing.
    outside = outside and armed
    setup = {'steps': steps} if outside else None
    try:
        if outside and not retried_already(comments):
            # One retry for a failure outside the PR: keep `automerge`, say when the bridge's sweep may queue it again.
            setup['when'] = setup_retry_not_before(github).strftime(TIME_FORMAT)
            github.post(f'issues/{number}/comments', {'body': comment_body(number, reason, head, check, armed, setup=setup)})
            print(f'#{number}: group {head[:7]} failed only outside the PR; left armed for one retry after '
                  f'{setup["when"]}.', file=out)
            return 'told: setup retry'
        requeued = github.requeue(number) if retry and armed and hasattr(github, 'requeue') else None
        github.post(f'issues/{number}/comments',
                    {'body': comment_body(number, reason, head, check, armed, cancelled, retry, requeued, setup,
                                          None if outside else own)})
        if retry:
            print(f'#{number}: nothing failed in group {head[:7]}; left armed for one retry'
                  f'{" and set to merge again" if requeued else ""}.', file=out)
            return 'told: retry'
        if reason.upper() not in NO_LABEL_REASONS:
            github.post(f'issues/{number}/labels', {'labels': [LABEL]})
        # Merged PRs and a first cancelled group returned above, so every removal left here means "stop".
        if armed:
            github.delete(f'issues/{number}/labels/{ARM_LABEL}')
            # #5281: undo a re-queue that slipped in before the label above came off.
            if reason.upper() not in NO_LABEL_REASONS and hasattr(github, 'stop_merging'):
                pr_head = (pr.get('head') or {}).get('sha')
                try:
                    in_queue = bool(pr_head) and pr_head in github.queue_heads()
                except ReadFailed:
                    in_queue = True
                if not github.stop_merging(number, pr.get('node_id'), in_queue):
                    warn(f'#{number}: could not make sure it is no longer set to merge', out)
    except (subprocess.SubprocessError, OSError) as error:
        warn(f'#{number}: could not post ({error!r})', out)
        return 'skipped: post failed'
    print(f'#{number}: told why it left the queue (group {head[:7]}).', file=out)
    return 'told'


# --- cancel -------------------------------------------------------------------------------------------------------

def active_queue_runs(github):
    runs = {}
    for status in ACTIVE:
        for run in github.get(f'actions/runs?status={status}&per_page=100').get('workflow_runs', []):
            if str(run.get('head_branch', '')).startswith(QUEUE_PREFIX):
                runs[run['id']] = run
    return list(runs.values())


def cancel_dead(github, out=sys.stdout):
    """Cancel queued or running runs of destroyed merge groups. Returns the cancelled run ids."""
    try:
        runs = active_queue_runs(github)   # first: see the module docstring
        if not runs:
            return []
        live = github.queue_heads()         # second
    except ReadFailed as error:
        warn(f'could not read the runs or the queue, cancelled nothing ({error})', out)
        return []
    cancelled = []
    for run in runs:
        if run.get('head_sha') in live:
            continue
        try:
            github.post(f'actions/runs/{run["id"]}/cancel', {})
            cancelled.append(run['id'])
            print(f'Cancelled run {run["id"]} on {run.get("head_branch")}: its group left the queue.', file=out)
        except (subprocess.SubprocessError, OSError) as error:
            warn(f'could not cancel run {run["id"]} ({error!r})', out)
    return cancelled


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--event', required=True, help='the pull_request_target event JSON ($GITHUB_EVENT_PATH)')
    args = parser.parse_args(argv)
    github = GitHub(os.environ['GH_REPO'])
    with open(args.event) as handle:
        event = json.load(handle)
    notify(github, event)
    cancel_dead(github)
    return 0


if __name__ == '__main__':
    sys.exit(main())
