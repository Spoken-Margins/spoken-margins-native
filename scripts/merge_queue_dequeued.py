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
   time costs one retry, not a loop. `automerge` is removed only when the event shows the PR carries it (the owner's own Merge tap on an
   unlabelled PR has nothing to remove, and its comment says nothing about a label). A PR that merged keeps its labels. Each comment carries a hidden marker with the group head (or the PR
   head when no group ran), so a second event for the same group adds nothing. A failed read logs a warning and exits 0: a notifier must not go red.

2. Cancel. When an entry leaves the queue GitHub rebuilds the groups behind it and sends `merge_group: destroyed`
   for the old ones, but Actions only triggers on `checks_requested`, so the old groups' runs keep their Macs until
   they finish. This cancels every queued or running workflow run on a `gh-readonly-queue/main/` branch whose head
   SHA is no longer any queue entry's head commit. The runs are listed first and the entries read second: a group's
   entry exists before its run does, so a run listed first never belongs to an entry created after the read. If
   the entry list can't be read, nothing is cancelled.

Run: `python3 scripts/merge_queue_dequeued.py --event "$GITHUB_EVENT_PATH"` with GH_REPO set.
"""
import argparse
import json
import os
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
TRIES = 3

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


def carries_arm_label(pr):
    return any((label or {}).get('name') == ARM_LABEL for label in pr.get('labels') or [])


def nothing_failed(reason, check):
    """A removal in which no check failed and that is not a conflict, a merge or a removal by hand: a cancelled
    check, or one that never reported before the queue's timeout. Nothing in the PR needs fixing."""
    upper = (reason or '').upper()
    return not check and upper not in NO_LABEL_REASONS and 'CONFLICT' not in upper


def comment_body(number, reason, head, check, armed=True, cancelled=None, retry=False, requeued=None):
    lines = [MARKER.format(head=head),
             f'**Left the merge queue** ({reason or "no reason given"}).']
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
            if requeued:
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
    elif reason and 'CONFLICT' in reason.upper():
        lines.append('The PR conflicts with main. Merge main into the branch and resolve it.')
    else:
        lines.append(f'No failed check found on the merge group `{head[:7]}`.')
    lines.append(f'To get back in: fix it, push, then add `{ARM_LABEL}` again.')
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
        comments = github.get(f'issues/{number}/comments?per_page=100')
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
    try:
        armed = carries_arm_label(pr)
        requeued = github.requeue(number) if retry and armed and hasattr(github, 'requeue') else None
        github.post(f'issues/{number}/comments',
                    {'body': comment_body(number, reason, head, check, armed, cancelled, retry, requeued)})
        if retry:
            print(f'#{number}: nothing failed in group {head[:7]}; left armed for one retry'
                  f'{" and set to merge again" if requeued else ""}.', file=out)
            return 'told: retry'
        if reason.upper() not in NO_LABEL_REASONS:
            github.post(f'issues/{number}/labels', {'labels': [LABEL]})
        # Merged PRs and a first cancelled group returned above, so every removal left here means "stop".
        if armed:
            github.delete(f'issues/{number}/labels/{ARM_LABEL}')
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
