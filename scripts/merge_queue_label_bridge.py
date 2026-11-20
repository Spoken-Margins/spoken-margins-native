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
- Label removed: auto-merge off, and the GraphQL `dequeuePullRequest` mutation if the PR is in the queue.
- Sweep: queues every armed PR, and unqueues every open PR that has auto-merge on or a queue entry but no
  `automerge` label. That retries a failed or lost removal (a removal with GITHUB_TOKEN starts no run at all).

Every call is tried a few times. One plain line per PR. Exit 1 when a PR could not be queued or unqueued, so the
run shows red; the next sweep tries again.

Run: `python3 scripts/merge_queue_label_bridge.py --repo owner/name (--pr N --action ACTION | --sweep)`.
"""
import argparse
import json
import re
import subprocess
import sys
import time
import unicodedata

LABEL = 'automerge'
FIX_LABEL = 'needs-fix'
TRIES = 3
MARKER = '<!-- merge-queue-label-bridge not-queued -->'
# gh's wording when there is nothing left to do. Matched on any reply; an answer that matches is not retried.
ALREADY = re.compile(r'already (queued|in the merge queue|enabled)|auto-?merge (is )?already|is already set to', re.I)
NOT_QUEUED = re.compile(r'not (in|on) the merge queue|not queued', re.I)
AUTO_OFF = re.compile(r"(not|n't) (been )?(enabled|set|configured|turned on)|(not|n't) have auto-?merge|"
                      r"no auto-?merge|already (disabled|off)|"
                      r'auto-?merge (is )?(disabled|off)', re.I)
CHECK_ACTIONS = ('edited', 'converted_to_draft')

PR_FIELDS = 'id number isDraft title state labels(first: 50) { nodes { name } } autoMergeRequest { enabledAt } ' \
            'mergeQueueEntry { id }'
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

    def gh(self, args):
        """(returncode, stdout + stderr) after up to TRIES attempts; a non-zero code is returned, not raised."""
        out = ''
        for attempt in range(TRIES):
            try:
                done = subprocess.run(['gh', *args], text=True, capture_output=True, timeout=90)
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
        code, out = self.gh(args)
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

    def comments(self, number):
        code, out = self.gh(['api', f'repos/{self.repo}/issues/{number}/comments', '--paginate', '--jq', '.[].body'])
        if code:
            raise Failed(out.strip()[-300:])
        return out

    def comment(self, number, body):
        code, out = self.gh(['pr', 'comment', str(number), '--repo', self.repo, '--body', body])
        if code:
            raise Failed(out.strip()[-300:])

    def remove_label(self, number, name):
        code, out = self.gh(['api', '-X', 'DELETE', f'repos/{self.repo}/issues/{number}/labels/{name}'])
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


def queue(github, pr, out=sys.stdout, rearmed=False):
    """Queue one armed PR. True when it is queued, set to merge, or rightly left alone."""
    number = pr['number']
    if pr.get('state') != 'OPEN':
        print(f'#{number}: not open, nothing to do', file=out)
        return True
    if LABEL not in labels(pr):
        print(f'#{number}: no `{LABEL}` label, nothing to queue', file=out)
        return True
    why = not_queueable(pr)
    if why:
        ok = take_out(github, pr, out)
        if MARKER not in github.comments(number):
            github.comment(number, f'{MARKER}\nNot queued for merging: {why}. The `{LABEL}` label stays, but the merge '
                                   'queue will not take this PR until that changes and the label is added again.')
        print(f'#{number}: not queued, {why}', file=out)
        return ok
    if FIX_LABEL in labels(pr):
        if not rearmed:
            print(f'#{number}: carries `{FIX_LABEL}`, not queued until `{LABEL}` is added again', file=out)
            return True
        github.remove_label(number, FIX_LABEL)
        print(f'#{number}: `{LABEL}` added again, `{FIX_LABEL}` removed', file=out)
    if pr.get('mergeQueueEntry'):
        print(f'#{number}: already in the merge queue', file=out)
        return True
    code, text = github.merge(number)
    if code == 0 or ALREADY.search(text):
        print(f'#{number}: queued (GitHub adds it once its required checks pass)', file=out)
        return True
    print(f'#{number}: could not queue: {text.strip()[-300:]}', file=out)
    return False


def unqueue(github, pr, out=sys.stdout):
    """Take one PR back out: no auto-merge, and out of the queue if it is in. True when done."""
    number = pr['number']
    if LABEL in labels(pr):
        print(f'#{number}: `{LABEL}` is back on, left queued', file=out)
        return True
    ok = take_out(github, pr, out)
    if ok and not pr.get('mergeQueueEntry'):
        print(f'#{number}: auto-merge off', file=out)
    return ok


def sweep(github, out):
    pulls = github.open_pulls()
    armed = [pr for pr in pulls if LABEL in labels(pr)]
    loose = [pr for pr in pulls if LABEL not in labels(pr) and (pr.get('autoMergeRequest') or pr.get('mergeQueueEntry'))]
    print(f'{len(armed)} open PRs carry `{LABEL}`; {len(loose)} are set to merge without it', file=out)
    results = []
    for act, pr in [(queue, pr) for pr in armed] + [(unqueue, pr) for pr in loose]:
        try:
            results.append(act(github, pr, out))
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
    parser.add_argument('--sweep', action='store_true', help='queue every armed PR, unqueue every unarmed one')
    args = parser.parse_args(argv)
    github = github or GitHub(args.repo)
    if args.action in ('labeled', 'unlabeled') and args.label != LABEL:
        print(f'label `{args.label}` is not `{LABEL}`: nothing to do', file=out)
        return 0
    try:
        if args.sweep or not args.pr:
            return sweep(github, out)
        pr = github.pull(args.pr)
        if args.action == 'unlabeled':
            return 0 if unqueue(github, pr, out) else 1
        return 0 if queue(github, pr, out, rearmed=args.action == 'labeled') else 1
    except Failed as error:
        print(f'could not reach GitHub: {error}', file=out)
        return 1


if __name__ == '__main__':
    sys.exit(main())
