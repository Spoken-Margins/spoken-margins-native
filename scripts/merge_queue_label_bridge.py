#!/usr/bin/env python3
"""The `automerge` label queues a PR in GitHub's merge queue, and removing it takes the PR out (#4693).

Agents already arm a PR by adding `automerge` (AGENTS.md, the lane-request skill, the Claude worker). Keeping that
one interface means no session's instructions have to change in the hour the queue goes on: this script turns the
label into the queue's own commands. merge-queue-label-bridge.yml runs it from main's copy, never the PR's.

- Label added: `needs-fix` comes off (adding `automerge` again is how an author says "fixed", as with the old lane),
  then the PR is queued with `gh pr merge <n>`, no method flag. With a required merge queue that enables auto-merge,
  so GitHub queues the PR once its required checks pass. "Already queued" counts as done.
- Never queued: a draft, or a title that says do not merge, don't merge, DNM, WIP: or throwaway (case, Unicode
  spaces and apostrophes, and separators normalized). Such a PR gets auto-merge turned off and leaves the queue if
  it was in it, plus one comment saying why. Retitling or drafting an armed PR runs the same check (`edited`,
  `converted_to_draft`).
- A PR carrying `needs-fix` is never queued by the sweep or an edit. merge_queue_dequeued.py adds it, and removes
  `automerge`, when a merge group fails, so a failing PR is queued again only after someone re-arms it. Without
  this the 15-minute sweep would queue it again at once, rebuilding every group behind it, four times an hour.
- A PR that left the queue because its jobs failed outside its code (merge_queue_dequeued.py, #4940) keeps `automerge`
  and carries a `setup-retry not-before=<time>` marker in the notifier's comment. Until that time the sweep and an
  edit leave it unqueued (one line says so); after it, the sweep queues it once, as for any armed PR. A person adding
  `automerge` again is never held, since that is "fixed, go". The notifier writes the marker, this reads it.
- A commit that failed a test in two merge groups holding nothing but the trunk and itself (the notifier's
  `own-failure` marker, #5281) is not queued again even on a re-arm: `automerge` comes off, `needs-fix` stays, and one
  comment says to push a fix. A new push is a new commit with no markers.
- Label removed: auto-merge off, and the GraphQL `dequeuePullRequest` mutation if the PR is in the queue.
- Sweep: queues every armed PR, re-reading each one just before acting so a PR stopped after the list was read
  (label removed, retitled, `needs-fix` added) is not queued again. It never takes a PR out: a PR set to merge
  without the label may be the owner's own Merge tap or a maintainer's `gh pr merge`. A PR leaves the queue only on
  the `unlabeled` event, a hold `edited`/`converted_to_draft` event, merge_queue_dequeued.py's label removal, or a
  hand-off (next point).
- Handed off (#5302): a one-PR run (a dispatch or a PR event) on a PR with no arming label that carries `needs-mac`
  or `conflict-resolver` takes it out of the queue and turns auto-merge off. The hosted conflict check (lane_conflicts.py) hands a
  conflicting PR to the conflict resolver by swapping `automerge` for `conflict-resolver` with GITHUB_TOKEN, which wakes no
  `unlabeled` run, so it dispatches one of these. A queued PR that conflicts can't merge, and while queued nobody
  can push the fix (#5276 sat 5 hours that way). The sweep never does this: it only reads armed PRs.

The owner's own `owner-tap` label arms a PR the same way (#4939): it is his tap on a PR that touches `.github/` or
`scripts/lane_merge_rules.py`, which no agent arms, and (owner, 2026-11-22) such a PR goes through the queue on that
label. Only the sweep and the one-PR runs read it: the workflow's `labeled` event still wakes the job for `automerge`
alone, so a PR tapped with `owner-tap` is queued by the next sweep (the VPS backstop fires one when none ran in 15
minutes). `needs-fix` still stops it, and only `automerge` added again says "fixed". Removing a label takes the PR out
only when neither arming label is left.

The owner's approving review of the PR's current head arms a PR touching those tap paths the same way as `owner-tap`
(owner, 2026-11-24): it is the same tap, under the same rule merge_policy.py reads (scripts/owner_review_tap.py; his
latest approve, request-changes or dismissed review decides, on the head commit, and nobody else's review counts).
On 2026-11-24 #5212, #5252 and #5256 were approved by him and nothing queued them. On any other PR his approval arms
nothing (#5274 audit): nobody asked for the queue there, and neither removing `automerge` nor a manual dequeue could
stop it. The PR query carries his reviews and the first 100 changed paths, so this costs no extra call; a tap path
past the first 100 is missed, which leaves the PR unarmed until the label, never armed by mistake. A review starts no run here (this job's `agent-identity` environment admits main only, and a review
event's ref is the PR's), so the next sweep queues an approved PR, as for a label added with GITHUB_TOKEN.

Every call is tried a few times. One plain line per PR. Exit 1 when a PR could not be queued or unqueued, so the
run shows red. The next sweep retries a failed queueing, and the PR gets one comment saying it could not be queued
and why (#4937: with MERGE_QUEUE_TOKEN refused, every armed PR sat unqueued and only the bridge's own run was red,
which nobody reads). Reads, label removals and comments the main token is refused (401 or 403; for a comment, any
failure) are tried once more with FALLBACK_GH_TOKEN (the workflow's GITHUB_TOKEN), so an expired or revoked queue
token still gets as far as `gh pr merge`, fails there, and leaves a note on the PR (FALLBACK_KINDS; #4942's audit found
the first version fell back only for the comment, so a dead token failed on its first read and said nothing). Setting
a PR to merge never falls back. A failed unqueue is not retried (the sweep never takes a
PR out), so it posts a comment on the PR saying it is still set to merge and how to take it out.

Run: `python3 scripts/merge_queue_label_bridge.py --repo owner/name (--pr N --action ACTION | --sweep)`.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import unicodedata

try:  # the workflow checks out this file and owner_review_tap.py; without the latter, only labels arm a PR
    import owner_review_tap
except ImportError:  # pragma: no cover
    owner_review_tap = None

LABEL = 'automerge'
OWNER_TAP = 'owner-tap'  # the owner's tap on a PR only he merges; it arms like `automerge` (#4939)
FIX_LABEL = 'needs-fix'
# lane_conflicts.py's hand-offs, to the Mac finisher or the conflict resolver (#5320); such a PR must not sit queued
HANDOFF_LABELS = ('needs-mac', 'conflict-resolver')  # (#5302)
TRIES = 3
MARKER = '<!-- merge-queue-label-bridge not-queued -->'
QUEUE_FAILED_MARKER = '<!-- merge-queue-label-bridge could-not-queue -->'
# Calls retried once with FALLBACK_GH_TOKEN when the main token is refused (#4937, #4942). Never setting a PR to merge:
# a merge set with GITHUB_TOKEN would put it in a group whose events start no workflows, and it would never pass.
FALLBACK_KINDS = frozenset({'read', 'label', 'comment'})
REFUSED = re.compile(r'\b(401|403)\b|Bad credentials|not accessible', re.I)
# gh's wording when there is nothing left to do. Matched on any reply; an answer that matches is not retried.
ALREADY = re.compile(r'already (queued|in the merge queue|enabled)|auto-?merge (is )?already|is already set to', re.I)
NOT_QUEUED = re.compile(r'not (in|on) the merge queue|not queued', re.I)
AUTO_OFF = re.compile(r"(not|n't) (been )?(enabled|set|configured|turned on)|(not|n't) have auto-?merge|"
                      r"no auto-?merge|already (disabled|off)|"
                      r'auto-?merge (is )?(disabled|off)', re.I)
# The notifier's marker (merge_queue_dequeued.py SETUP_RETRY_MARKER): a comment that sets a PR to merge again no sooner
# than the time it carries. A copy of the pattern, since each workflow checks out only its own script; the notifier's
# tests check the two agree. SETUP_RETRY_MINUTES is the notifier's delay, kept here only so that a test can compare.
SETUP_RETRY = re.compile(r'<!-- merge-queue-dequeued setup-retry not-before=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) -->')
SETUP_RETRY_MINUTES = 30
# The notifier's marker (merge_queue_dequeued.py OWN_FAILURE_MARKER, #5281): this commit failed a test in a merge group
# that held nothing but the trunk and this PR. OWN_FAILURE_LIMIT of them hold the commit out of the queue, even on a
# re-arm, until a new push. The notifier's tests check the copies agree.
OWN_FAILURE = re.compile(r'<!-- merge-queue-dequeued own-failure head=([0-9a-f]{40}) -->')
OWN_FAILURE_LIMIT = 2
HELD_MARKER = '<!-- merge-queue-label-bridge held-commit={head} -->'
TRUSTED_LOGIN = 'github-actions[bot]'
# A marker further ahead than the notifier's delay plus this slack is not the notifier's: ignored, whoever wrote it.
SETUP_RETRY_SLACK = datetime.timedelta(minutes=15)
CHECK_ACTIONS = ('edited', 'converted_to_draft', 'opened', 'reopened', 'synchronize', 'ready_for_review')

# The owner's reviews ride along for his approval (owner_review_tap.py): no extra call. The login is
# owner_review_tap.OWNER_LOGIN; a test keeps them equal.
PR_FIELDS = 'id number isDraft title state headRefOid labels(first: 50) { nodes { name } } autoMergeRequest { enabledAt } ' \
            'mergeQueueEntry { id } files(first: 100) { nodes { path } } ' \
            'reviews(last: 100, author: "uncomposed") { nodes { state submittedAt author { login } commit { oid } } }'
PR_QUERY = '''query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { %s } }
}''' % PR_FIELDS
OPEN_QUERY = '''query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $after) { nodes { %s } pageInfo { hasNextPage endCursor } }
  }
}''' % PR_FIELDS
DEQUEUE = 'mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }'


class Failed(Exception):
    pass


class GitHub:
    """The `gh` calls this script makes. The tests replace it at this boundary."""

    def __init__(self, repo, sleep=time.sleep):
        self.repo = repo
        self.owner, self.name = repo.split('/', 1)
        self.sleep = sleep

    def call(self, kind, args):
        """`gh` with the main token, then once with FALLBACK_GH_TOKEN for a kind in FALLBACK_KINDS when the main token
        was refused (any failure, for a comment)."""
        code, out = self.gh(args)
        fallback = os.environ.get('FALLBACK_GH_TOKEN')
        if code and kind in FALLBACK_KINDS and fallback and fallback != os.environ.get('GH_TOKEN') \
                and (kind == 'comment' or REFUSED.search(out)):
            code, out = self.gh(args, env={**os.environ, 'GH_TOKEN': fallback})
        return code, out

    def gh(self, args, env=None):
        """(returncode, stdout + stderr) after up to TRIES attempts; a non-zero code is returned, not raised."""
        out = ''
        for attempt in range(TRIES):
            try:
                done = subprocess.run(['gh', *args], text=True, capture_output=True, timeout=90, env=env)
            except (OSError, subprocess.SubprocessError) as error:
                out = repr(error)
            else:
                out = (done.stdout or '') + (done.stderr or '')
                if done.returncode == 0 or ALREADY.search(out) or NOT_QUEUED.search(out) or AUTO_OFF.search(out):
                    return done.returncode, out
            if attempt + 1 < TRIES:
                self.sleep(2 ** attempt)
        return 1, out

    def graphql(self, query, **variables):
        args = ['api', 'graphql', '-f', f'query={query}']
        for key, value in variables.items():
            if value is not None:
                args += ['-F' if isinstance(value, int) else '-f', f'{key}={value}']
        code, out = self.call('read', args)
        if code:
            raise Failed(out.strip()[-300:])
        try:
            return json.loads(out)
        except ValueError as error:
            raise Failed(f'unreadable answer: {error}') from error

    def pull(self, number):
        data = self.graphql(PR_QUERY, owner=self.owner, name=self.name, number=int(number))
        pr = ((data.get('data') or {}).get('repository') or {}).get('pullRequest')
        if not pr:
            raise Failed(f'no pull request #{number}')
        return pr

    def open_pulls(self):
        pulls, after = [], None
        while True:
            data = self.graphql(OPEN_QUERY, owner=self.owner, name=self.name, after=after)
            try:
                page = data['data']['repository']['pullRequests']
            except (KeyError, TypeError) as error:
                raise Failed(f'unreadable PR list: {error!r}') from error
            pulls += page['nodes']
            if not page['pageInfo']['hasNextPage']:
                return pulls
            after = page['pageInfo']['endCursor']

    def now(self):
        return datetime.datetime.now(datetime.timezone.utc)

    def trusted_comments(self, number):
        """The text of the workflow's own comments only (the notifier posts as the Actions bot). Anyone can comment, and a
        marker from anyone else must not hold a PR out of the queue."""
        code, out = self.call('read', ['api', f'repos/{self.repo}/issues/{number}/comments', '--paginate', '--jq',
                                       f'.[] | select(.user.login == "{TRUSTED_LOGIN}") | .body'])
        if code:
            raise Failed(out.strip()[-300:])
        return out

    def comments(self, number):
        code, out = self.call('read', ['api', f'repos/{self.repo}/issues/{number}/comments', '--paginate', '--jq',
                                       '.[].body'])
        if code:
            raise Failed(out.strip()[-300:])
        return out

    def comment(self, number, body):
        code, out = self.call('comment', ['pr', 'comment', str(number), '--repo', self.repo, '--body', body])
        if code:
            raise Failed(out.strip()[-300:])

    def remove_label(self, number, name):
        code, out = self.call('label', ['api', '-X', 'DELETE', f'repos/{self.repo}/issues/{number}/labels/{name}'])
        if code and 'Label does not exist' not in out and '404' not in out:
            raise Failed(out.strip()[-300:])

    def merge(self, number):
        return self.gh(['pr', 'merge', str(number), '--repo', self.repo])

    def disable_auto(self, number):
        return self.gh(['pr', 'merge', str(number), '--repo', self.repo, '--disable-auto'])

    def dequeue(self, node_id):
        self.graphql(DEQUEUE, id=node_id)


def normalized(title):
    """Lower case, Unicode folded, apostrophes made plain, and every run of space, hyphen or underscore one space."""
    text = unicodedata.normalize('NFKC', title or '').lower()
    text = re.sub(r'[‘’ʼ`´]', "'", text)
    return re.sub(r'[\s_\-‐-―]+', ' ', text).strip()


HOLD_WORDS = (
    (re.compile(r"\bdo not merge\b|\bdon'?t merge\b"), 'its title says not to merge it'),
    (re.compile(r'\bdnm\b'), 'its title says DNM'),
    (re.compile(r'^\W*wip\b\s*:'), 'its title starts with WIP:'),
    (re.compile(r'\bthrowaway\b'), 'its title says throwaway'),
)


def not_queueable(pr):
    """Why this PR must never be queued, or None."""
    if pr.get('isDraft'):
        return 'it is a draft'
    title = normalized(pr.get('title'))
    for pattern, why in HOLD_WORDS:
        if pattern.search(title):
            return why
    return None


def labels(pr):
    return {node['name'] for node in ((pr.get('labels') or {}).get('nodes') or [])}


def owner_approved(pr):
    """Whether the PR touches the tap paths and the owner's latest decisive review approves its current head
    (owner_review_tap.py). On any other PR the approval is not a tap and arms nothing."""
    return bool(owner_review_tap) and owner_review_tap.touches_tap_paths(
        node.get('path') for node in ((pr.get('files') or {}).get('nodes') or [])) and owner_review_tap.owner_approved(
        ((pr.get('reviews') or {}).get('nodes') or []), pr.get('headRefOid') or '')


def armed(pr):
    """Whether the PR asks for the queue: the `automerge` label, the owner's `owner-tap` label, or, on a PR touching
    the tap paths, his approval of the head."""
    return bool(labels(pr) & {LABEL, OWNER_TAP}) or owner_approved(pr)


def arming_labels(pr):
    names = [f'`{name}`' for name in (LABEL, OWNER_TAP) if name in labels(pr)]
    if not names and owner_approved(pr):
        return "the owner's approval"
    return ' and '.join(names) or f'`{LABEL}`'


def take_out(github, pr, out):
    """Auto-merge off and out of the queue. True when nothing is left set to merge."""
    number = pr['number']
    ok = True
    if pr.get('autoMergeRequest'):
        code, text = github.disable_auto(number)
        if code and not AUTO_OFF.search(text):
            print(f'#{number}: could not turn auto-merge off: {text.strip()[-300:]}', file=out)
            ok = False
    if pr.get('mergeQueueEntry'):
        github.dequeue(pr['id'])
        print(f'#{number}: taken out of the merge queue', file=out)
    return ok


def setup_retry_hold(github, number):
    """The time before which a PR that left the queue on a setup failure may not be queued again, or None. The latest
    marker counts; a marker with a time that does not parse counts for nothing."""
    latest = None
    now = github.now() if hasattr(github, 'now') else datetime.datetime.now(datetime.timezone.utc)
    read = getattr(github, 'trusted_comments', github.comments)
    for stamp in SETUP_RETRY.findall(read(number)):
        try:
            when = datetime.datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
        if when > now + datetime.timedelta(minutes=SETUP_RETRY_MINUTES) + SETUP_RETRY_SLACK:
            continue
        latest = when if latest is None or when > latest else latest
    return latest if latest is not None and now < latest else None


def held_commit(github, pr):
    """Whether the PR's head commit failed OWN_FAILURE_LIMIT merge groups that held nothing but the trunk and it.
    Read only on a re-arm of a PR that carries `needs-fix`, so the sweep spends no reads on it."""
    head = pr.get('headRefOid')
    if not head:
        return False
    read = getattr(github, 'trusted_comments', github.comments)
    return OWN_FAILURE.findall(read(pr['number'])).count(head) >= OWN_FAILURE_LIMIT


def hold_commit(github, pr, out):
    """Leave the PR out of the queue: `needs-fix` stays, `automerge` comes off so that adding it after a push is a fresh
    re-arm, and one comment per commit says why."""
    number, head = pr['number'], pr['headRefOid']
    github.remove_label(number, LABEL)
    marker = HELD_MARKER.format(head=head)
    if marker not in github.comments(number):
        github.comment(number, f'{marker}\nNot queued: commit `{head[:7]}` failed a merge group that held nothing but '
                               f'main and this PR {OWN_FAILURE_LIMIT} times, so the failure is in this commit. `{LABEL}` '
                               f'came off and `{FIX_LABEL}` stays. Push a fix, then add `{LABEL}` again.')
    print(f'#{number}: commit {head[:7]} failed alone {OWN_FAILURE_LIMIT} times; held until a new push', file=out)


def queue(github, pr, out=sys.stdout, rearmed=False):
    """Queue one armed PR. True when it is queued, set to merge, or rightly left alone."""
    number = pr['number']
    if pr.get('state') != 'OPEN':
        print(f'#{number}: not open, nothing to do', file=out)
        return True
    if not armed(pr):
        handed = [name for name in HANDOFF_LABELS if name in labels(pr)]
        if handed and (pr.get('autoMergeRequest') or pr.get('mergeQueueEntry')):
            print(f'#{number}: handed off (`{handed[0]}`) with no `{LABEL}` or `{OWNER_TAP}`, taking it out', file=out)
            return take_out(github, pr, out)
        print(f'#{number}: no `{LABEL}` or `{OWNER_TAP}` label and no owner approval of the head, nothing to queue',
              file=out)
        return True
    why = not_queueable(pr)
    if why:
        ok = take_out(github, pr, out)
        if MARKER not in github.comments(number):
            arming = arming_labels(pr)
            arming = arming if arming.startswith('the owner') else f'{arming} label'
            github.comment(number, f'{MARKER}\nNot queued for merging: {why}. The {arming} stays, but the merge '
                                   'queue will not take this PR until that changes and the label is added again.')
        print(f'#{number}: not queued, {why}', file=out)
        return ok
    if FIX_LABEL in labels(pr):
        if not rearmed:
            print(f'#{number}: carries `{FIX_LABEL}`, not queued until `{LABEL}` is added again', file=out)
            return True
        if held_commit(github, pr):
            hold_commit(github, pr, out)
            return True
        github.remove_label(number, FIX_LABEL)
        print(f'#{number}: `{LABEL}` added again, `{FIX_LABEL}` removed', file=out)
    if pr.get('mergeQueueEntry'):
        print(f'#{number}: already in the merge queue', file=out)
        return True
    if not rearmed and (hold := setup_retry_hold(github, number)):
        print(f'#{number}: left the queue on a failure outside the PR; set to merge again after '
              f'{hold.strftime("%Y-%m-%dT%H:%M:%SZ")}', file=out)
        return True
    code, text = github.merge(number)
    if code == 0 or ALREADY.search(text):
        print(f'#{number}: queued (GitHub adds it once its required checks pass)', file=out)
        return True
    print(f'#{number}: could not queue: {text.strip()[-300:]}', file=out)
    say_could_not_queue(github, number, text, out)
    return False


def say_could_not_queue(github, number, text, out):
    """One comment per PR that it is armed but could not be queued. Never raises: the run is red either way."""
    try:
        if QUEUE_FAILED_MARKER in github.comments(number):
            return
        if REFUSED.search(text):
            why = (' The bridge\'s token (the spoken-margins-agent App token, or `MERGE_QUEUE_TOKEN` when that could '
                   'not be minted, #4915) may have expired or lost its access; nothing in the PR needs changing.')
        else:   # #4942 audit: a conflict or a dirty branch is the PR's own, so don't say nothing needs doing in it
            why = ' If that names something in the PR (a conflict, a draft), fix it and push.'
        github.comment(number, f'{QUEUE_FAILED_MARKER}\n`{LABEL}` is on, but this PR could not be queued for '
                               f'merging: `{text.strip()[-200:]}`.{why} Each sweep tries again.')
    except Failed as error:
        print(f'#{number}: could not say so on the PR either: {error}', file=out)


def unqueue(github, pr, out=sys.stdout):
    """Take one PR back out: no auto-merge, and out of the queue if it is in. True when done."""
    number = pr['number']
    if armed(pr):
        print(f"#{number}: {arming_labels(pr)} still arms it, left queued", file=out)
        return True
    try:
        ok = take_out(github, pr, out)
    except Failed as error:
        print(f'#{number}: could not take it out of the merge queue: {error}', file=out)
        ok = False
    if not ok:
        # Nothing retries this, so say so where the author will see it.
        github.comment(number, f'`{LABEL}` was removed but this PR is still set to merge. Take it out with '
                               f'`gh pr merge {number} --disable-auto` or by hand.')
    elif not pr.get('mergeQueueEntry'):
        print(f'#{number}: auto-merge off', file=out)
    return ok


def sweep(github, out):
    waiting = [pr for pr in github.open_pulls() if armed(pr)]
    print(f'{len(waiting)} open PRs carry `{LABEL}` or `{OWNER_TAP}` (or the owner\'s approval)', file=out)
    results = []
    for pr in waiting:
        try:
            # The list is a snapshot; act on the PR as it is now.
            results.append(queue(github, github.pull(pr['number']), out))
        except Failed as error:
            print(f'#{pr.get("number")}: could not finish: {error}', file=out)
            results.append(False)
    return 0 if all(results) else 1


def main(argv=None, github=None, out=sys.stdout):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', type=int)
    parser.add_argument('--action', choices=['labeled', 'unlabeled', *CHECK_ACTIONS])
    parser.add_argument('--label', default=LABEL, help='the label a labeled/unlabeled event is about')
    parser.add_argument('--sweep', action='store_true', help='queue every armed PR')
    args = parser.parse_args(argv)
    github = github or GitHub(args.repo)
    if args.action in ('labeled', 'unlabeled') and args.label not in (LABEL, OWNER_TAP):
        print(f'label `{args.label}` is not `{LABEL}` or `{OWNER_TAP}`: nothing to do', file=out)
        return 0
    try:
        if args.sweep or not args.pr:
            return sweep(github, out)
        pr = github.pull(args.pr)
        if args.action == 'unlabeled':
            return 0 if unqueue(github, pr, out) else 1
        return 0 if queue(github, pr, out, rearmed=args.action == 'labeled' and args.label == LABEL) else 1
    except Failed as error:
        print(f'could not reach GitHub: {error}', file=out)
        return 1


if __name__ == '__main__':
    sys.exit(main())
